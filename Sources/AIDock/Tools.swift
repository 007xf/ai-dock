import SwiftUI
import AppKit

/// AI 工具目录：怎么识别（App / 命令行 / 数据目录）以及能提供哪些数据。
/// 启动时检测本机装了哪些，界面只为检测到的工具生成内容。
struct ToolDef {
    enum Category: Int, CaseIterable {
        case agent, ide, chat, local
        var title: String {
            switch self {
            case .agent: return L("编程助手")
            case .ide: return L("AI 编辑器")
            case .chat: return L("聊天应用")
            case .local: return L("本地模型")
            }
        }
    }

    let id: String
    let name: String
    var short: String? = nil
    let category: Category
    /// 固定色槽（-1 = 按检测顺序分配剩余色槽）
    var slot: Int = -1
    var bundleIDs: [String] = []
    /// 没有 bundleID 时按 /Applications 下的 App 名称识别
    var appNames: [String] = []
    var clis: [String] = []
    /// 相对家目录的数据目录
    var paths: [String] = []
    var quota = false
    /// 有可解析的本地会话日志
    var logs = false
    var localModels = false
}

/// 当前检测结果（启动时和「重新检测」时在主线程更新）
enum ToolRegistry {
    static var detected: [DetectedTool] = []
    static var slots: [String: Int] = [:]

    static func update(_ tools: [DetectedTool]) {
        detected = tools
        slots = Palette.assign(tools)
    }

    static func tool(_ id: String) -> DetectedTool? { detected.first { $0.id == id } }

    /// 前台 App 的 bundleID → 工具
    /// 正在运行的工具：它的 App 在运行，或者它的命令行进程在运行
    static func runningTools() -> Set<String> {
        var out = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let id = toolID(forBundle: app.bundleIdentifier) { out.insert(id) }
        }
        var clis: [String: String] = [:]
        for t in detected { for c in t.def.clis { clis[c] = t.id } }
        if !clis.isEmpty {
            for name in ProcessNames.current() { if let id = clis[name] { out.insert(id) } }
        }
        return out
    }

    static func toolID(forBundle bundle: String?) -> String? {
        guard let bundle else { return nil }
        return detected.first { $0.bundleIDs.contains(bundle) }?.id
    }

    static var quotaTools: [Provider] { detected.filter { $0.def.quota }.map { Provider(id: $0.id) } }
    static var localModelTools: [Provider] { detected.filter { $0.def.localModels }.map { Provider(id: $0.id) } }
    static var usageTools: [Provider] {
        detected.filter { !$0.def.quota && !$0.def.localModels && !$0.capabilities.isEmpty }.map { Provider(id: $0.id) }
    }
    static var all: [Provider] { detected.map { Provider(id: $0.id) } }
}

enum ToolCatalog {
    static let all: [ToolDef] = [
        // 编程助手
        ToolDef(id: "claude", name: "Claude", category: .agent, slot: 1,
                bundleIDs: ["com.anthropic.claudefordesktop"], clis: ["claude"], paths: [".claude"], quota: true, logs: true),
        // ChatGPT 桌面 App 与 Codex 是同一套账号和额度，合并为一个工具
        ToolDef(id: "codex", name: "ChatGPT", category: .agent, slot: 0,
                bundleIDs: ["com.openai.codex", "com.openai.chat"], appNames: ["ChatGPT", "Codex"],
                clis: ["codex"], paths: [".codex"], quota: true, logs: true),
        ToolDef(id: "cursor", name: "Cursor", category: .ide, slot: 2,
                bundleIDs: ["com.todesktop.230313mzl4w4u92"], clis: ["cursor-agent"], paths: [".cursor"], quota: true, logs: true),
        ToolDef(id: "gemini", name: "Gemini", category: .agent, slot: 6,
                bundleIDs: ["com.google.GeminiMacOS"], clis: ["gemini"], paths: [".gemini"], quota: true, logs: true),
        ToolDef(id: "qwen", name: "Qwen Code", short: "Qwen", category: .agent, clis: ["qwen"], paths: [".qwen"], logs: true),
        ToolDef(id: "copilot", name: "GitHub Copilot", short: "Copilot", category: .agent,
                clis: ["copilot"], paths: [".config/github-copilot", ".copilot"]),
        ToolDef(id: "opencode", name: "OpenCode", category: .agent, clis: ["opencode"], paths: [".local/share/opencode"]),
        ToolDef(id: "aider", name: "Aider", category: .agent, clis: ["aider"], paths: [".aider"]),
        ToolDef(id: "amp", name: "Amp", category: .agent, clis: ["amp"], paths: [".config/amp"]),
        ToolDef(id: "droid", name: "Factory Droid", short: "Droid", category: .agent, clis: ["droid"], paths: [".factory"]),
        ToolDef(id: "kimicli", name: "Kimi CLI", category: .agent, clis: ["kimi"], paths: [".kimi"]),
        ToolDef(id: "iflow", name: "iFlow CLI", short: "iFlow", category: .agent, clis: ["iflow"], paths: [".iflow"]),
        // AI 编辑器
        ToolDef(id: "windsurf", name: "Windsurf", category: .ide, bundleIDs: ["com.exafunction.windsurf"], appNames: ["Windsurf"], paths: [".codeium/windsurf"]),
        ToolDef(id: "trae", name: "Trae", category: .ide, appNames: ["Trae", "Trae CN"], paths: [".trae", ".trae-cn"]),
        ToolDef(id: "kiro", name: "Kiro", category: .ide, appNames: ["Kiro"], paths: [".kiro"]),
        ToolDef(id: "qoder", name: "Qoder", category: .ide, appNames: ["Qoder"], paths: [".qoder"]),
        ToolDef(id: "codebuddy", name: "CodeBuddy", category: .ide, appNames: ["CodeBuddy", "CodeBuddy CN"], clis: ["codebuddy"], paths: [".codebuddy"]),
        ToolDef(id: "antigravity", name: "Antigravity", category: .ide, bundleIDs: ["com.google.antigravity"], appNames: ["Antigravity"],
                quota: true),
        ToolDef(id: "zed", name: "Zed", category: .ide, bundleIDs: ["dev.zed.Zed"], appNames: ["Zed"]),
        // 聊天应用
        ToolDef(id: "perplexity", name: "Perplexity", category: .chat, bundleIDs: ["ai.perplexity.mac"], appNames: ["Perplexity"]),
        ToolDef(id: "doubao", name: "豆包", category: .chat, appNames: ["Doubao", "豆包"]),
        ToolDef(id: "kimi", name: "Kimi", category: .chat, appNames: ["Kimi"]),
        ToolDef(id: "deepseek", name: "DeepSeek", category: .chat, appNames: ["DeepSeek"]),
        ToolDef(id: "yuanbao", name: "元宝", category: .chat, appNames: ["Yuanbao", "元宝", "腾讯元宝"]),
        ToolDef(id: "tongyi", name: "通义", category: .chat, appNames: ["Tongyi", "通义", "通义千问", "Qwen"]),
        ToolDef(id: "poe", name: "Poe", category: .chat, appNames: ["Poe"]),
        ToolDef(id: "cherry", name: "Cherry Studio", short: "Cherry", category: .chat, appNames: ["Cherry Studio"]),
        ToolDef(id: "chatbox", name: "Chatbox", category: .chat, appNames: ["Chatbox"]),
        // 本地模型
        ToolDef(id: "ollama", name: "Ollama", category: .local, appNames: ["Ollama"], clis: ["ollama"], paths: [".ollama"], localModels: true),
        ToolDef(id: "lmstudio", name: "LM Studio", category: .local, appNames: ["LM Studio"], clis: ["lms"], paths: [".lmstudio"], localModels: true),
    ]

    static func def(_ id: String) -> ToolDef? { all.first { $0.id == id } }
}

/// 检测结果
struct DetectedTool: Identifiable, Equatable {
    let def: ToolDef
    var appURL: URL?
    var bundleID: String?
    /// 这个工具对应的所有 App（例如 ChatGPT 和 Codex 两个 App）
    var bundleIDs: [String] = []
    var cliPath: String?
    var dataPath: String?
    var id: String { def.id }

    enum Capability: String, CaseIterable {
        case quota, activity, usageTime, localModels
        var title: String {
            switch self {
            case .quota: return L("套餐额度")
            case .activity: return L("活动日志")
            case .usageTime: return L("使用时长")
            case .localModels: return L("本地模型")
            }
        }
    }

    /// 这个工具在本机能显示哪些数据
    var capabilities: [Capability] {
        var c: [Capability] = []
        if def.quota { c.append(.quota) }
        if def.logs, dataPath != nil || cliPath != nil { c.append(.activity) }
        if appURL != nil { c.append(.usageTime) }
        if def.localModels { c.append(.localModels) }
        return c
    }

    var sources: String {
        var s: [String] = []
        if let a = appURL { s.append(L("App：%@", "\(FileManager.default.displayName(atPath: a.path).replacingOccurrences(of: ".app", with: ""))")) }
        if let c = cliPath { s.append(L("命令行：%@", "\((c as NSString).lastPathComponent)")) }
        if let d = dataPath { s.append(L("数据：~/%@", "\(d)")) }
        return s.joined(separator: " · ")
    }

    static func == (a: DetectedTool, b: DetectedTool) -> Bool {
        a.id == b.id && a.appURL == b.appURL && a.cliPath == b.cliPath && a.dataPath == b.dataPath
    }
}

enum ToolDetector {
    /// 登录 shell 的 PATH + 常见安装位置（nvm、Volta、pnpm、Bun、Homebrew 等），见 UserEnv
    private static var searchDirs: [String] { UserEnv.binDirs }

    static func detect() -> [DetectedTool] {
        let fm = FileManager.default
        let home = fm.home.path
        let appDirs = ["/Applications", "\(home)/Applications", "/System/Applications"]
        let dirs = searchDirs
        var result: [DetectedTool] = []
        var claimedApps = Set<String>()

        for def in ToolCatalog.all {
            var t = DetectedTool(def: def)
            for id in def.bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    if t.appURL == nil { t.appURL = url; t.bundleID = id }
                    t.bundleIDs.append(id)
                }
            }
            if t.appURL == nil {
                outer: for name in def.appNames {
                    for dir in appDirs {
                        let path = "\(dir)/\(name).app"
                        if fm.fileExists(atPath: path), !claimedApps.contains(path) {
                            t.appURL = URL(fileURLWithPath: path)
                            t.bundleID = Bundle(path: path)?.bundleIdentifier
                            if let b = t.bundleID { t.bundleIDs.append(b) }
                            break outer
                        }
                    }
                }
            }
            if let a = t.appURL { claimedApps.insert(a.path) }
            for cli in def.clis {
                if let d = dirs.first(where: { fm.isExecutableFile(atPath: "\($0)/\(cli)") }) { t.cliPath = "\(d)/\(cli)"; break }
            }
            t.dataPath = def.paths.first { fm.fileExists(atPath: "\(home)/\($0)") }
            if t.appURL != nil || t.cliPath != nil || t.dataPath != nil { result.append(t) }
        }
        return result
    }
}

// MARK: - 颜色

enum Palette {
    /// 分类色（固定顺序，已做色盲可分辨性校验）：蓝 橙 青绿 黄 品红 绿 紫 红
    static let slots: [(UInt32, UInt32)] = [
        (0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70), (0xEDA100, 0xC98500),
        (0xE87BA4, 0xD55181), (0x008300, 0x008300), (0x4A3AA7, 0x9085E9), (0xE34948, 0xE66767),
    ]
    static let other = Color.adaptive(light: 0x898781, dark: 0x898781)

    /// 固定色槽的工具先占位，其余按目录顺序分配剩下的色槽；8 个用完后归为「其他」灰色
    static func assign(_ tools: [DetectedTool]) -> [String: Int] {
        var map: [String: Int] = [:]
        var used = Set<Int>()
        for t in tools where t.def.slot >= 0 { map[t.id] = t.def.slot; used.insert(t.def.slot) }
        var free = (0..<slots.count).filter { !used.contains($0) }
        for t in tools where t.def.slot < 0 {
            if free.isEmpty { break }
            map[t.id] = free.removeFirst()
        }
        return map
    }
}

// MARK: - 标志

enum LogoStore {
    private static var cache: [String: NSImage] = [:]

    /// 优先用打包的官方透明标志（有深色版本时按外观切换）；否则从 App 图标里去掉底板提取，失败时用 App 图标本身
    static func logo(for tool: DetectedTool?, id: String, dark: Bool = false) -> NSImage? {
        if dark {
            let key = id + "-dark"
            if let img = cache[key] { return img }
            if let url = Bundle.main.url(forResource: key, withExtension: "png", subdirectory: "Logos"),
               let img = NSImage(contentsOf: url) {
                cache[key] = img
                return img
            }
        }
        if let img = cache[id] { return img }
        var img: NSImage?
        if let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Logos") {
            img = NSImage(contentsOf: url)
        } else if let cached = try? Data(contentsOf: cacheURL(id)), let i = NSImage(data: cached) {
            img = i
        } else if let app = tool?.appURL {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            if let extracted = LogoExtractor.extract(from: icon) {
                img = extracted
                if let tiff = extracted.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: cacheURL(id))
                }
            } else {
                img = DockModel.downsample(icon, points: 64)
            }
        }
        if let img { cache[id] = img }
        return img
    }

    private static func cacheURL(_ id: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIDock/logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id).png")
    }
}

/// 从 App 图标里去掉浅色/深色底板，只留下彩色标志（和 scripts/make_logos.swift 同一算法）
enum LogoExtractor {
    static func extract(from icon: NSImage) -> NSImage? {
        let size = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: size * 4, bitsPerPixel: 32), let p = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        let w = size, h = size
        func chroma(_ i: Int) -> Int { let r = Int(p[i]), g = Int(p[i+1]), b = Int(p[i+2]); return max(r, g, b) - min(r, g, b) }
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let k = stack.popLast() {
            if seen[k] { continue }
            let i = k * 4
            guard p[i + 3] < 128 || chroma(i) < 38 else { continue }
            seen[k] = true
            p[i] = 0; p[i+1] = 0; p[i+2] = 0; p[i+3] = 0
            let x = k % w, y = k / w
            if x > 0 { stack.append(k - 1) }; if x < w - 1 { stack.append(k + 1) }
            if y > 0 { stack.append(k - w) }; if y < h - 1 { stack.append(k + w) }
        }
        // 剩下的部分太少（单色标志被一起去掉了）或太多（整张图标都是彩色的）就放弃
        var opaque = 0
        for k in 0..<(w * h) where p[k * 4 + 3] > 0 { opaque += 1 }
        let ratio = Double(opaque) / Double(w * h)
        guard ratio > 0.04, ratio < 0.6 else { return nil }
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let k = y * w + x, i = k * 4
            guard p[i + 3] > 0, seen[k - 1] || seen[k + 1] || seen[k - w] || seen[k + w] else { continue }
            let a = min(1.0, Double(chroma(i)) / 120.0)
            for c in 0..<4 { p[i + c] = UInt8(Double(p[i + c]) * a) }
        } }
        let img = NSImage(size: NSSize(width: 64, height: 64))
        img.addRepresentation(rep)
        return img
    }
}

/// 当前所有进程的名字（只读进程名，约 1 毫秒）
enum ProcessNames {
    static func current() -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var out = Set<String>()
        var buf = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            if proc_name(pid, &buf, UInt32(buf.count)) > 0 { out.insert(String(cString: buf)) }
        }
        return out
    }
}
