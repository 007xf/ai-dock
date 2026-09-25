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

    /// 原子写入文件，保留原来的权限（这些文件通常是 600）
    static func writeFile(_ data: Data, to url: URL) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        try data.write(to: url, options: .atomic)
        if let perm = attrs?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: perm], ofItemAtPath: url.path)
        }
    }

    /// JWT 是否已过期（留 60 秒余量）
    static func jwtExpired(_ token: String) -> Bool {
        guard let exp = jnum(decodeJWTPayload(token)?["exp"]) else { return false }
        return Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(60)
    }
}
