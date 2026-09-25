import Foundation

/// Codex 套餐额度：优先用 ~/.codex/auth.json 的 ChatGPT 登录调用官方用量接口；
/// 失败时退回到本地会话日志里最近一次 `token_count` 事件附带的 rate_limits。
struct CodexProvider {
    static var home: URL {
        if let env = UserEnv.value("CODEX_HOME") { return URL(fileURLWithPath: (env as NSString).expandingTildeInPath) }
        return FileManager.default.home.appendingPathComponent(".codex")
    }

    static var sessionRoots: [URL] {
        [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
    }

    func fetch() async -> ProviderUsage {
        var u = ProviderUsage(provider: .codex)
        var apiError: String?

        if var auth = Self.loadAuth() {
            do {
                // 令牌过期：先续期
                if TokenRefresh.jwtExpired(auth.token), let fresh = await Self.refresh(auth) { auth = fresh }
                func request(_ a: Auth) async throws -> (Int, Any?) {
                    var headers = [
                        "Authorization": "Bearer \(a.token)",
                        "Accept": "application/json",
                        "User-Agent": "codex_cli_rs (AIDock)",
                        "originator": "codex_cli_rs"
                    ]
                    if let acct = a.accountId { headers["ChatGPT-Account-Id"] = acct }
                    return try await HTTP.getJSON(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
                }
                var (status, json) = try await request(auth)
                // 服务端说令牌无效：续期后再试一次
                if status == 401, let fresh = await Self.refresh(auth) {
                    auth = fresh
                    (status, json) = try await request(auth)
                }
                if status == 200, let d = json as? [String: Any] {
                    let parsed = Self.parseAPI(d)
                    if !parsed.windows.isEmpty {
                        u.windows = parsed.windows
                        u.plan = Self.planName(parsed.plan) ?? Self.planName(auth.plan)
                        u.note = parsed.note
                        u.source = .api
                        u.updatedAt = Date()
                        u.account = auth.email
                        return u
                    }
                    apiError = L("接口没有返回额度窗口")
                } else {
                    apiError = L("Codex：") + HTTP.describe(status: status)
                }
            } catch {
                apiError = L("网络错误：%@", "\(error.localizedDescription)")
            }
            u.plan = Self.planName(auth.plan)
            u.account = auth.email
        }

        if let local = await Task.detached(priority: .utility, operation: { Self.latestLocalLimits() }).value {
            u.windows = local.windows
            u.plan = u.plan ?? Self.planName(local.plan)
            u.source = .localLog
            u.updatedAt = local.timestamp
            u.note = L("来自本地会话日志（最后一次 Codex 请求时的数据）")
            return u
        }
        u.error = apiError ?? L("未找到 Codex 登录信息或会话记录。运行一次 codex 并登录即可。")
        return u
    }

    // MARK: auth.json

    struct Auth {
        var token: String
        var accountId: String?
        var plan: String?
        var email: String?
        var refreshToken: String?
        /// 原始 JSON（写回时保留其他字段）
        var raw: [String: Any] = [:]
    }

    private static var authURL: URL { home.appendingPathComponent("auth.json") }

    /// 用续期令牌换新令牌（和 Codex 命令行自己的续期一样），写回 ~/.codex/auth.json
    static func refresh(_ a: Auth) async -> Auth? {
        guard let rt = a.refreshToken, TokenRefresh.mayTry("codex") else { return nil }
        let body: [String: Any] = ["client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "grant_type": "refresh_token",
                                   "refresh_token": rt, "scope": "openid profile email"]
        guard let (status, json) = try? await TokenRefresh.postJSON(URL(string: "https://auth.openai.com/oauth/token")!, body),
              status == 200, let json, let access = json["access_token"] as? String else { return nil }
        var obj = a.raw
        var tokens = (obj["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = access
        if let id = json["id_token"] as? String { tokens["id_token"] = id }
        if let r = json["refresh_token"] as? String { tokens["refresh_token"] = r }
        obj["tokens"] = tokens
        obj["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              (try? TokenRefresh.writeFile(data, to: authURL)) != nil else { return nil }
        TokenRefresh.succeeded("codex")
        return loadAuth()
    }

    static func loadAuth() -> Auth? {
        guard let data = try? Data(contentsOf: authURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        var accountId = tokens["account_id"] as? String
        var plan: String?, email: String?
        if let idToken = tokens["id_token"] as? String, let claims = decodeJWTPayload(idToken) {
            email = claims["email"] as? String
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                accountId = accountId ?? auth["chatgpt_account_id"] as? String
                plan = auth["chatgpt_plan_type"] as? String
            }
        }
        return Auth(token: access, accountId: accountId, plan: plan, email: email,
                    refreshToken: tokens["refresh_token"] as? String, raw: obj)
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite", "pro_lite", "pro-lite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    static func labels(forSeconds secs: Double?) -> (String, String) {
        guard let secs, secs > 0 else { return (L("额度窗口"), L("限额")) }
        let h = secs / 3600
        switch h {
        case 4.5...5.5: return (L("5 小时窗口"), "5h")
        case 23...25: return (L("今日"), L("日"))
        case 160...176: return (L("本周"), L("本周"))
        case 670...750: return (L("本月"), L("本月"))
        default:
            if h < 48 { return (L("%@ 小时窗口", "\(Int(h.rounded()))"), "\(Int(h.rounded()))h") }
            return (L("%@ 天窗口", "\(Int((h / 24).rounded()))"), "\(Int((h / 24).rounded()))d")
        }
    }

    // MARK: API

    static func parseAPI(_ d: [String: Any]) -> (plan: String?, windows: [UsageWindow], note: String?) {
        var windows: [UsageWindow] = []

        func parseLimit(_ rl: [String: Any], prefix: String?, idPrefix: String) {
            for key in ["primary_window", "secondary_window"] {
                guard let w = rl[key] as? [String: Any], let used = jnum(w["used_percent"]) else { continue }
                let secs = jnum(w["limit_window_seconds"])
                let reset = jdate(w["reset_at"]) ?? jnum(w["reset_after_seconds"]).map { Date().addingTimeInterval($0) }
                var (label, short) = labels(forSeconds: secs)
                if let prefix { label = "\(prefix) · \(label)"; short = prefix }
                windows.append(UsageWindow(id: idPrefix + key, label: label, short: short,
                                           usedPercent: used, resetsAt: reset, windowSeconds: secs))
            }
        }
        if let rl = d["rate_limit"] as? [String: Any] { parseLimit(rl, prefix: nil, idPrefix: "") }
        if let extras = d["additional_rate_limits"] as? [[String: Any]] {
            for (i, e) in extras.enumerated() {
                guard let rl = e["rate_limit"] as? [String: Any] else { continue }
                let name = (e["limit_name"] as? String) ?? (e["metered_feature"] as? String) ?? L("附加")
                parseLimit(rl, prefix: name, idPrefix: "extra\(i)_")
            }
        }
        windows.sort { ($0.windowSeconds ?? .infinity) < ($1.windowSeconds ?? .infinity) }

        var note: String?
        if let c = d["credits"] as? [String: Any] {
            if (c["unlimited"] as? Bool) == true {
                note = L("Credits：无限")
            } else if (c["has_credits"] as? Bool) == true, let b = c["balance"] {
                note = L("剩余 Credits：%@", "\(b)")
            }
        }
        return (d["plan_type"] as? String, windows, note)
    }

    // MARK: 本地日志回退

    struct LocalLimits { var windows: [UsageWindow]; var timestamp: Date; var plan: String? }

    static func latestLocalLimits() -> LocalLimits? {
        let fm = FileManager.default
        var files: [(URL, Date)] = []
        for root in sessionRoots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((url, m))
            }
        }
        files.sort { $0.1 > $1.1 }

        var best: LocalLimits?
        for (url, mtime) in files.prefix(8) {
            if let b = best, mtime < b.timestamp { break }
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let start = size > 1_048_576 ? size - 1_048_576 : 0
            try? h.seek(toOffset: start)
            guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any],
                      let ts = jdate(obj["timestamp"]) else { continue }
                let windows = parseLocal(rl, eventTime: ts)
                if windows.isEmpty { continue }
                if best == nil || ts > best!.timestamp {
                    best = LocalLimits(windows: windows, timestamp: ts, plan: rl["plan_type"] as? String)
                }
                break
            }
        }
        return best
    }

    static func parseLocal(_ rl: [String: Any], eventTime: Date) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any], var used = jnum(w["used_percent"]) else { continue }
            let secs = jnum(w["window_minutes"]).map { $0 * 60 }
            var reset = jdate(w["resets_at"]) ?? jnum(w["resets_in_seconds"]).map { eventTime.addingTimeInterval($0) }
            var detail: String?
            if let r = reset, r < Date() {
                // 记录之后窗口已经重置过了
                used = 0; reset = nil; detail = L("窗口已重置")
            }
            let (label, short) = labels(forSeconds: secs)
            windows.append(UsageWindow(id: key, label: label, short: short, usedPercent: used,
                                       resetsAt: reset, detail: detail, windowSeconds: secs))
        }
        return windows.sorted { ($0.windowSeconds ?? .infinity) < ($1.windowSeconds ?? .infinity) }
    }
}
