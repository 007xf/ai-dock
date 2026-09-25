import Foundation

/// Claude Code 套餐额度：读取 Claude Code 自己保存的 OAuth 登录（钥匙串或 ~/.claude/.credentials.json），
/// 调用 Claude Code `/usage` 背后的同一个接口。令牌只在本机使用，只读，不会刷新或改写。
struct ClaudeProvider {
    struct Credentials {
        enum Source { case keychain(account: String), file(URL) }
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var subscription: String?
        var tier: String?
        /// 原始 JSON（写回时保留其他字段）
        var raw: [String: Any]
        var source: Source
    }

    private static let keychainService = "Claude Code-credentials"

    static var configDirs: [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            dirs += env.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        }
        dirs.append(FileManager.default.home.appendingPathComponent(".claude"))
        dirs.append(FileManager.default.home.appendingPathComponent(".config/claude"))
        return dirs
    }

    static func loadCredentials() async -> Credentials? {
        var raw: Data?
        var source: Credentials.Source?
        let (status, out) = await Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"])
        if status == 0, !out.isEmpty {
            raw = out
            // 钥匙串条目的账户名，写回时要用
            let (_, attrs) = await Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService])
            let text = String(decoding: attrs, as: UTF8.self)
            let account = text.range(of: "\"acct\"<blob>=\"([^\"]*)\"", options: .regularExpression)
                .map { String(text[$0]).replacingOccurrences(of: "\"acct\"<blob>=\"", with: "").dropLast() }
                .map(String.init) ?? NSUserName()
            source = .keychain(account: account)
        } else {
            for dir in configDirs {
                let url = dir.appendingPathComponent(".credentials.json")
                if let d = try? Data(contentsOf: url) { raw = d; source = .file(url); break }
            }
        }
        guard let raw, let source,
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        let o = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let token = o["accessToken"] as? String, !token.isEmpty else { return nil }
        return Credentials(accessToken: token,
                           refreshToken: o["refreshToken"] as? String,
                           expiresAt: jdate(o["expiresAt"]),
                           subscription: o["subscriptionType"] as? String,
                           tier: o["rateLimitTier"] as? String,
                           raw: obj, source: source)
    }

    /// 用续期令牌换新令牌（和 Claude Code 自己的续期一样），写回原来的钥匙串条目 / 文件
    static func refresh(_ c: Credentials) async -> Credentials? {
        guard let rt = c.refreshToken, TokenRefresh.mayTry("claude") else { return nil }
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": rt,
                                   "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"]
        for endpoint in ["https://console.anthropic.com/v1/oauth/token", "https://platform.claude.com/v1/oauth/token"] {
            guard let (status, json) = try? await TokenRefresh.postJSON(URL(string: endpoint)!, body),
                  status == 200, let json, let access = json["access_token"] as? String else { continue }
            var n = c
            n.accessToken = access
            if let newRT = json["refresh_token"] as? String { n.refreshToken = newRT }
            if let sec = jnum(json["expires_in"]) { n.expiresAt = Date().addingTimeInterval(sec) }
            // 保留原来的其他字段，只更新令牌和过期时间
            var obj = c.raw
            var o = (obj["claudeAiOauth"] as? [String: Any]) ?? [:]
            o["accessToken"] = n.accessToken
            o["refreshToken"] = n.refreshToken
            if let exp = n.expiresAt { o["expiresAt"] = Int64(exp.timeIntervalSince1970 * 1000) }
            obj["claudeAiOauth"] = o
            n.raw = obj
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            switch c.source {
            case .keychain(let account):
                let (st, _) = await Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-a", account,
                                                                    "-s", keychainService, "-w", String(decoding: data, as: UTF8.self)])
                guard st == 0 else { return nil }
            case .file(let url):
                guard (try? TokenRefresh.writeFile(data, to: url)) != nil else { return nil }
            }
            TokenRefresh.succeeded("claude")
            return n
        }
        return nil
    }

    static func planName(subscription: String?, tier: String?) -> String? {
        let t = (tier ?? "").lowercased()
        if t.contains("20x") { return "Max 20x" }
        if t.contains("5x") { return "Max 5x" }
        guard let s = subscription, !s.isEmpty else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    func fetch() async -> ProviderUsage {
        var u = ProviderUsage(provider: .claude)
        guard var creds = await Self.loadCredentials() else {
            u.error = L("未找到 Claude Code 登录信息。在终端运行 claude 并登录一次即可。")
            return u
        }
        u.plan = Self.planName(subscription: creds.subscription, tier: creds.tier)
        // 令牌过期：自动续期
        if let exp = creds.expiresAt, exp < Date().addingTimeInterval(60) {
            guard let fresh = await Self.refresh(creds) else {
                u.error = L("Claude Code 登录已过期，自动续期没有成功。打开 Claude Code 发一条消息即可恢复。")
                return u
            }
            creds = fresh
        }
        do {
            func request(_ token: String) async throws -> (Int, Any?) {
                try await HTTP.getJSON(
                    URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "anthropic-beta": "oauth-2025-04-20",
                        "Accept": "application/json",
                        "Content-Type": "application/json",
                        "User-Agent": "claude-code/2.1 (AIDock)"
                    ])
            }
            var (status, json) = try await request(creds.accessToken)
            // 服务端说令牌无效：续期后再试一次
            if status == 401, let fresh = await Self.refresh(creds) {
                creds = fresh
                (status, json) = try await request(creds.accessToken)
            }
            guard status == 200, let d = json as? [String: Any] else {
                u.error = L("Claude：") + HTTP.describe(status: status)
                return u
            }
            u.windows = Self.parse(d)
            u.source = .api
            u.updatedAt = Date()
            if u.windows.isEmpty { u.note = L("接口没有返回额度窗口（可能是 API Key 登录或企业账号）") }
        } catch {
            u.error = L("网络错误：%@", "\(error.localizedDescription)")
        }
        return u
    }

    static func parse(_ d: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        let known: [(key: String, label: String, short: String, secs: Double, always: Bool)] = [
            ("five_hour", L("5 小时窗口"), "5h", 5 * 3600, true),
            ("seven_day", L("本周 · 全部模型"), L("本周"), 7 * 86400, true),
            ("seven_day_opus", L("本周 · Opus"), "Opus", 7 * 86400, false),
            ("seven_day_sonnet", L("本周 · Sonnet"), "Sonnet", 7 * 86400, false),
            ("seven_day_oauth_apps", L("本周 · 第三方应用"), L("应用"), 7 * 86400, false),
        ]
        func window(_ key: String, label: String, short: String, secs: Double?, always: Bool) -> UsageWindow? {
            guard let o = d[key] as? [String: Any], let used = jnum(o["utilization"]) else { return nil }
            let reset = jdate(o["resets_at"])
            if !always, used <= 0, reset == nil { return nil }
            return UsageWindow(id: key, label: label, short: short, usedPercent: used, resetsAt: reset, windowSeconds: secs)
        }
        for k in known {
            if let w = window(k.key, label: k.label, short: k.short, secs: k.secs, always: k.always) { windows.append(w) }
        }
        // 接口里还会出现内部代号的窗口（例如 iguana_necktie），没有用过就不显示；
        // 真的用了额度时统一显示为「其他限额」，不暴露看不懂的代号
        let knownKeys = Set(known.map(\.key))
        for key in d.keys.sorted() where !knownKeys.contains(key) && key != "extra_usage" {
            guard let o = d[key] as? [String: Any], let used = jnum(o["utilization"]), used >= 1 else { continue }
            windows.append(UsageWindow(id: key, label: L("其他限额"), short: L("其他"), usedPercent: used,
                                       resetsAt: jdate(o["resets_at"])))
        }
        if let extra = d["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true,
           let used = jnum(extra["utilization"]) {
            windows.append(UsageWindow(id: "extra_usage", label: L("额外用量（本月）"), short: L("额外"),
                                       usedPercent: used, resetsAt: nil))
        }
        return windows
    }
}
