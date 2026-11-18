import Foundation

/// 登录令牌续期：和 Claude Code / Codex 命令行自己的续期流程一样，用保存的续期令牌换新令牌，
/// 并把新令牌原样写回原来的位置（钥匙串 / 配置文件），命令行工具之后也能继续正常使用。
/// 只在令牌过期或接口返回「未登录」时才续期；失败后 10 分钟内不再重试。
enum TokenRefresh {
    private static var lastAttempt: [String: Date] = [:]
    private static let lock = NSLock()

    /// 冷却检查：同一个工具 10 分钟内只尝试一次
    static func mayTry(_ tool: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let t = lastAttempt[tool], Date().timeIntervalSince(t) < 600 { return false }
        lastAttempt[tool] = Date()
        return true
    }

    static func succeeded(_ tool: String) {
        lock.lock(); defer { lock.unlock() }
        lastAttempt[tool] = nil
    }

    static func postJSON(_ url: URL, _ body: [String: Any], headers: [String: String] = [:]) async throws -> (Int, [String: Any]?) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await HTTP.session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    /// 原子写入文件，从临时文件创建起即保持严格权限（默认 0600），避免默认 umask 造成短暂可读窗口
    static func writeFile(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let existingMode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        let mode = mode_t((existingMode ?? 0o600) & 0o777)
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            guard fchmod(fd, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let n = write(fd, base.advanced(by: written), raw.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += n
                }
            }
            close(fd)
            guard rename(tmp.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            close(fd)
            unlink(tmp.path)
            throw error
        }
    }

    /// JWT 是否已过期（留 60 秒余量）
    static func jwtExpired(_ token: String) -> Bool {
        guard let exp = jnum(decodeJWTPayload(token)?["exp"]) else { return false }
        return Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(60)
    }
}
