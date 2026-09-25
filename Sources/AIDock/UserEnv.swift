import Foundation

/// 用户登录 shell 里的环境变量。
/// 从访达 / Dock 启动的 App 拿不到 .zshrc、.bash_profile 里设置的 PATH 和配置目录（CODEX_HOME 等），
/// 用 nvm、Volta、pnpm 装的命令行工具、自定义了配置目录的用户就会读取失败。
/// 这里在后台读一次登录 shell 的环境并缓存，下次启动直接用缓存。
enum UserEnv {
    private static let cacheKey = "userShellEnv"
    /// 只保留需要的变量，不缓存其他内容（例如令牌）
    private static let wanted: Set<String> = [
        "PATH", "SHELL", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_CLI_HOME", "NVM_DIR", "VOLTA_HOME",
        "PNPM_HOME", "BUN_INSTALL", "FNM_DIR", "ASDF_DATA_DIR", "MISE_DATA_DIR", "XDG_CONFIG_HOME",
    ]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var vars: [String: String] =
        UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]

    static func value(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let v = vars[key], !v.isEmpty { return v }
        return ProcessInfo.processInfo.environment[key]
    }

    /// 可能装着命令行工具的所有目录：登录 shell 的 PATH + 常见版本管理器和包管理器的位置
    static var binDirs: [String] {
        let fm = FileManager.default
        let home = fm.home.path
        var dirs = (value("PATH") ?? "").split(separator: ":").map(String.init)
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
            "\(home)/.local/bin", "\(home)/bin", "\(home)/.npm-global/bin", "\(home)/.npm/bin",
            "\(value("BUN_INSTALL") ?? "\(home)/.bun")/bin", "\(value("VOLTA_HOME") ?? "\(home)/.volta")/bin",
            value("PNPM_HOME") ?? "\(home)/Library/pnpm", "\(home)/.yarn/bin", "\(home)/.config/yarn/global/node_modules/.bin",
            "\(home)/.cargo/bin", "\(home)/.deno/bin",
            "\(value("ASDF_DATA_DIR") ?? "\(home)/.asdf")/shims", "\(value("MISE_DATA_DIR") ?? "\(home)/.local/share/mise")/shims",
        ]
        // nvm / fnm：每个已安装的 Node 版本都有自己的 bin 目录
        let nvm = "\(value("NVM_DIR") ?? "\(home)/.nvm")/versions/node"
        dirs += ((try? fm.contentsOfDirectory(atPath: nvm)) ?? []).sorted(by: >).map { "\(nvm)/\($0)/bin" }
        for fnm in [value("FNM_DIR") ?? "\(home)/Library/Application Support/fnm", "\(home)/.local/share/fnm"] {
            let base = "\(fnm)/node-versions"
            dirs += ((try? fm.contentsOfDirectory(atPath: base)) ?? []).sorted(by: >).map { "\(base)/\($0)/installation/bin" }
        }
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 在这些目录里找可执行文件
    static func which(_ name: String) -> String? {
        binDirs.lazy.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 后台读取登录 shell 的环境（最多等 5 秒）；有变化时返回 true
    static func refresh() async -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__AIDOCK_ENV__"
        let out: String? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: shell)
                // 交互 + 登录：nvm 等通常写在 .zshrc 里，只有交互 shell 才会加载
                p.arguments = ["-ilc", "printf '\\n\(marker)\\n'; /usr/bin/env; printf '\\n\(marker)\\n'"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: String(data: data, encoding: .utf8))
            }
        }
        guard let out, let a = out.range(of: "\n\(marker)\n"),
              let b = out.range(of: "\n\(marker)\n", range: a.upperBound..<out.endIndex) else { return false }
        var found: [String: String] = [:]
        for line in out[a.upperBound..<b.lowerBound].split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq])
            if wanted.contains(k) { found[k] = String(line[line.index(after: eq)...]) }
        }
        guard !found.isEmpty else { return false }
        let changed = store(found)
        if changed { UserDefaults.standard.set(found, forKey: cacheKey) }
        return changed
    }

    private static func store(_ found: [String: String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let changed = found != vars
        vars = found
        return changed
    }
}
