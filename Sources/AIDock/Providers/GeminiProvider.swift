import Foundation
import os

private let geminiLog = Logger(subsystem: "local.aidock.app", category: "gemini")

/// Gemini 套餐额度：用 Gemini 命令行保存的 Google 登录（~/.gemini/oauth_creds.json），
/// 请求 Gemini Code Assist 的额度接口（和命令行里 /stats 显示的额度同源），按 Pro / Flash 两组显示。
struct GeminiProvider {
    /// Gemini 的配置目录（GEMINI_CLI_HOME 可以改到别处）
    static var geminiHome: URL {
        let base = UserEnv.value("GEMINI_CLI_HOME").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? FileManager.default.home
        return base.appendingPathComponent(".gemini")
    }
    static var credsURL: URL { geminiHome.appendingPathComponent("oauth_creds.json") }
    private static let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    /// 两个主机都查：有反馈说其中一个会一直返回 100% 剩余，取两边里用得更多的那个
    private static let quotaURLs = [
        URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
        URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
    ]

    func fetch() async -> ProviderUsage {
        var u = ProviderUsage(provider: .gemini)
        guard var creds = Self.readCreds() else {
            u.error = L("Gemini 命令行没有用 Google 账号登录，无法读取额度。")
            return u
        }
        if let id = creds["id_token"] as? String, let email = decodeJWTPayload(id)?["email"] as? String { u.account = email }

        var token = creds["access_token"] as? String
        if token == nil || Self.expired(creds) {
            token = await Self.refresh(&creds)
        }
        guard var token else {
            u.error = L("Gemini 登录已过期，运行一次 gemini 命令即可续期。")
            return u
        }

        do {
            // 套餐和项目
            var (status, load) = try await Self.post(Self.loadURL, ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]], token: token)
            if status == 401, let t = await Self.refresh(&creds) {
                token = t
                (status, load) = try await Self.post(Self.loadURL, ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]], token: token)
            }
            guard status == 200 else {
                u.error = status == 401 ? L("Gemini 登录已过期，运行一次 gemini 命令即可续期。") : "Gemini：" + HTTP.describe(status: status)
                return u
            }
            u.plan = Self.planName(load)
            if load?["currentTier"] == nil,
               let reason = (load?["ineligibleTiers"] as? [[String: Any]])?.first {
                u.error = (reason["reasonCode"] as? String) == "UNSUPPORTED_CLIENT"
                    ? L("Google 已不再为个人账号提供 Gemini 命令行额度，额度改在 Antigravity 中显示。")
                    : (reason["reasonMessage"] as? String ?? L("这个 Google 账号没有开通 Gemini Code Assist。"))
                return u
            }
            let project = (load?["cloudaicompanionProject"] as? String)
                ?? ((load?["cloudaicompanionProject"] as? [String: Any])?["id"] as? String)

            // 额度：每个模型剩余的比例
            var models: [String: (remaining: Double, reset: Date?)] = [:]
            let reasons = (load?["ineligibleTiers"] as? [[String: Any]] ?? []).map { "\($0["tierId"] ?? "?"):\($0["reasonCode"] ?? "?"):\($0["reasonMessage"] ?? "")" }
            geminiLog.debug("ineligible: \(reasons.joined(separator: " | "), privacy: .public) allowed: \((load?["allowedTiers"] as? [[String: Any]] ?? []).map { "\($0["id"] ?? "?")" }.joined(separator: ","), privacy: .public)")
            geminiLog.debug("loadCodeAssist ok, project=\(project != nil), tier=\((load?["currentTier"] as? [String: Any])?["id"] as? String ?? "-", privacy: .public) keys=\((load ?? [:]).keys.sorted().joined(separator: ","), privacy: .public)")
            for url in Self.quotaURLs {
                let r = try? await Self.post(url, project.map { ["project": $0] } ?? [:], token: token)
                let summary = (r?.1?["buckets"] as? [[String: Any]])?.map { b in
                    "\(b["modelId"] ?? "?")=\(b["remainingFraction"] ?? "nil") keys:\(b.keys.sorted().joined(separator: "/"))"
                }.joined(separator: "; ") ?? "no buckets, keys=\((r?.1 ?? [:]).keys.sorted().joined(separator: ","))"
                geminiLog.debug("quota \(url.host ?? "", privacy: .public) status=\(r?.0 ?? -1) \(summary, privacy: .public)")
                guard let (st, body) = r, st == 200 else { continue }
                for b in body?["buckets"] as? [[String: Any]] ?? [] {
                    guard let model = b["modelId"] as? String, let f = jnum(b["remainingFraction"]) else { continue }
                    let reset = (b["resetTime"] as? String).flatMap(parseISODate)
                    if let old = models[model], old.remaining <= f { continue }
                    models[model] = (f, reset)
                }
            }
            u.windows = Self.windows(models)
            if u.windows.isEmpty {
                u.error = L("Gemini 没有返回额度信息。")
            } else {
                u.source = .api
                u.updatedAt = Date()
            }
        } catch {
            u.error = "Gemini：" + error.localizedDescription
        }
        return u
    }

    /// 按 Pro / Flash 分组，每组取剩余最少的模型
    static func windows(_ models: [String: (remaining: Double, reset: Date?)]) -> [UsageWindow] {
        var out: [UsageWindow] = []
        for (key, name) in [("pro", "Pro"), ("flash", "Flash")] {
            let group = models.filter { $0.key.lowercased().contains(key) && (key != "pro" || !$0.key.lowercased().contains("flash")) }
            guard let worst = group.min(by: { $0.value.remaining < $1.value.remaining }) else { continue }
            out.append(UsageWindow(id: key, label: "Gemini \(name)", short: name,
                                   usedPercent: min(100, max(0, (1 - worst.value.remaining) * 100)),
                                   resetsAt: worst.value.reset, detail: worst.key))
        }
        return out
    }

    private static func planName(_ load: [String: Any]?) -> String? {
        if let paid = (load?["paidTier"] as? [String: Any])?["name"] as? String, !paid.isEmpty { return paid }
        let tier = (load?["currentTier"] as? [String: Any])
        switch tier?["id"] as? String {
        case "standard-tier": return (tier?["name"] as? String) ?? "Paid"
        case "free-tier": return "Free"
        case "legacy-tier": return "Legacy"
        default: return tier?["name"] as? String
        }
    }

    // MARK: 登录

    private static func readCreds() -> [String: Any]? {
        guard let data = try? Data(contentsOf: credsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// expiry_date 是毫秒时间戳；留 60 秒余量
    private static func expired(_ creds: [String: Any]) -> Bool {
        guard let ms = jnum(creds["expiry_date"]) else { return false }
        return Date(timeIntervalSince1970: ms / 1000) < Date().addingTimeInterval(60)
    }

    /// 用续期令牌换新的访问令牌，写回 oauth_creds.json（和 Gemini 命令行自己续期的做法一样）
    private static func refresh(_ creds: inout [String: Any]) async -> String? {
        guard let refreshToken = creds["refresh_token"] as? String, TokenRefresh.mayTry("gemini"),
              let client = GeminiOAuthClient.find() else { return nil }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["client_id": client.id, "client_secret": client.secret, "refresh_token": refreshToken, "grant_type": "refresh_token"]
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        guard let (data, resp) = try? await HTTP.session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String else { return nil }
        creds["access_token"] = access
        if let exp = jnum(json["expires_in"]) { creds["expiry_date"] = Int((Date().timeIntervalSince1970 + exp) * 1000) }
        if let id = json["id_token"] { creds["id_token"] = id }
        if let data = try? JSONSerialization.data(withJSONObject: creds, options: [.prettyPrinted]) {
            try? TokenRefresh.writeFile(data, to: credsURL)
        }
        TokenRefresh.succeeded("gemini")
        return access
    }

    private static func post(_ url: URL, _ body: [String: Any], token: String) async throws -> (Int, [String: Any]?) {
        try await TokenRefresh.postJSON(url, body, headers: ["Authorization": "Bearer \(token)"])
    }
}

/// Gemini 命令行的 OAuth 客户端（开源项目里公开的桌面应用凭据），从本机安装的命令行里读取，不写死在 AI Dock 里
enum GeminiOAuthClient {
    private static var cached: (id: String, secret: String)?
    private static let lock = NSLock()

    static func find() -> (id: String, secret: String)? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        for file in candidateFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("OAUTH_CLIENT_SECRET") else { continue }
            // 按变量名取：同一个文件里还有 gcloud 的客户端 ID（CLOUD_SDK_CLIENT_ID），不能取第一个看起来像的
            if let id = capture(#"OAUTH_CLIENT_ID\s*=\s*["']([^"']+\.apps\.googleusercontent\.com)["']"#, in: text),
               let secret = capture(#"OAUTH_CLIENT_SECRET\s*=\s*["'](GOCSPX-[^"']+)["']"#, in: text) {
                cached = (id, secret)
                return cached
            }
        }
        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// 从 gemini 命令的真实位置往上找到安装包，再找存放 OAuth 配置的文件
    private static func candidateFiles() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        let clis = UserEnv.binDirs.map { "\($0)/gemini" }
        for c in clis where fm.fileExists(atPath: c) {
            var dir = URL(fileURLWithPath: c).resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<6 {
                if fm.fileExists(atPath: dir.appendingPathComponent("package.json").path) { roots.append(dir); break }
                dir = dir.deletingLastPathComponent()
            }
        }
        var files: [URL] = []
        for root in roots {
            let direct = ["node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
                          "../gemini-cli-core/dist/src/code_assist/oauth2.js"]
            files += direct.map { root.appendingPathComponent($0).standardizedFileURL }.filter { fm.fileExists(atPath: $0.path) }
            // 打包版：配置在 bundle 目录的某个 js 文件里
            for sub in ["bundle", "dist"] {
                let dir = root.appendingPathComponent(sub)
                guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
                var n = 0
                for case let f as URL in e where f.pathExtension == "js" {
                    n += 1
                    if n > 400 { break }
                    if f.lastPathComponent == "oauth2.js" { files.insert(f, at: 0) } else if sub == "bundle" { files.append(f) }
                }
            }
        }
        return files
    }
}
