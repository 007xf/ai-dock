import Foundation

/// Antigravity 套餐额度：Antigravity 运行时会在本机开一个语言服务（只监听 127.0.0.1），
/// 它自己界面上的额度就是从这里读的。AI Dock 找到这个进程的端口和访问令牌，读取同样的数据。
/// 分「Gemini 模型」和「Claude / GPT 模型」两组，每组有 5 小时和每周两个限额。
struct AntigravityProvider {
    static let provider = Provider(id: "antigravity")

    struct Endpoint: Equatable {
        let pid: Int32
        let port: Int
        let csrf: String
        let https: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedEndpoint: Endpoint?

    private static let metadata: [String: Any] = [
        "metadata": ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"],
    ]

    func fetch() async -> ProviderUsage {
        var u = ProviderUsage(provider: Self.provider)
        for attempt in 0..<2 {
            guard let ep = await Self.endpoint(fresh: attempt > 0) else {
                u.error = L("Antigravity 没有运行。打开 Antigravity 后即可读取额度。")
                return u
            }
            let summary = await Self.call(ep, "RetrieveUserQuotaSummary", Self.metadata)
            let status = await Self.call(ep, "GetUserStatus", Self.metadata)
            // 令牌被拒或连不上：Antigravity 可能重启过，重新找一次
            if [summary.status, status.status].allSatisfy({ $0 == 0 || $0 == 401 || $0 == 403 }) {
                Self.setCached(nil)
                continue
            }
            let st = Self.parseUserStatus(status.body)
            u.plan = st.plan
            u.account = st.email
            u.windows = summary.status == 200 ? Self.parseSummary(summary.body) : []
            if u.windows.isEmpty { u.windows = st.windows }
            if u.windows.isEmpty {
                u.error = L("Antigravity 没有返回额度信息。")
            } else {
                u.source = .api
                u.updatedAt = Date()
            }
            return u
        }
        u.error = L("无法连接 Antigravity。")
        return u
    }

    // MARK: 解析

    private static func fraction(_ raw: Any?) -> Double? {
        guard let d = raw as? [String: Any] else { return nil }
        let v = (d["case"] as? String) == "remainingFraction" ? d["value"] : d["remainingFraction"]
        return jnum(v)
    }

    private static func resetDate(_ v: Any?) -> Date? {
        if let s = v as? String { return parseISODate(s) }
        if let n = jnum(v), n > 0 { return Date(timeIntervalSince1970: n) }
        return nil
    }

    /// 模型分组的短名
    private static func groupName(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("claude") || l.contains("gpt") { return "Claude/GPT" }
        if l.contains("gemini") { return "Gemini" }
        return s
    }

    private static func window(group: String, weekly: Bool, remaining: Double, reset: Date?) -> UsageWindow {
        UsageWindow(id: "\(group)-\(weekly ? "week" : "5h")",
                    label: "\(group) · " + (weekly ? L("本周") : L("5 小时窗口")),
                    short: "\(group) " + (weekly ? L("本周") : "5h"),
                    usedPercent: min(100, max(0, (1 - remaining) * 100)), resetsAt: reset)
    }

    /// RetrieveUserQuotaSummary：每个模型组有 5 小时和每周两个限额
    static func parseSummary(_ body: Any?) -> [UsageWindow] {
        let root = ((body as? [String: Any])?["response"] as? [String: Any]) ?? (body as? [String: Any])
        var out: [UsageWindow] = []
        for g in root?["groups"] as? [[String: Any]] ?? [] {
            let group = groupName(g["displayName"] as? String ?? "")
            var windows: [UsageWindow] = []
            for b in g["buckets"] as? [[String: Any]] ?? [] where (b["disabled"] as? Bool) != true {
                // window 是 "weekly" / "5h"；旧版本没有这个字段，只能看名字
                let name = "\(b["window"] as? String ?? "") \(b["bucketId"] as? String ?? "") \(b["displayName"] as? String ?? "")".lowercased()
                let weekly = name.contains("week")
                guard weekly || name.contains("5h") || name.contains("5-hour") || name.contains("five") || name.contains("session"),
                      let f = jnum(b["remainingFraction"]) ?? fraction(b["remaining"]) else { continue }
                windows.append(window(group: group, weekly: weekly, remaining: f, reset: resetDate(b["resetTime"])))
            }
            out += windows.sorted { !$0.id.hasSuffix("week") && $1.id.hasSuffix("week") }
        }
        return out
    }

    /// GetUserStatus：套餐名、邮箱，以及旧版本的按模型额度（同组取用得最多的模型）
    static func parseUserStatus(_ body: Any?) -> (plan: String?, email: String?, windows: [UsageWindow]) {
        guard let st = (body as? [String: Any])?["userStatus"] as? [String: Any] else { return (nil, nil, []) }
        let plan = ((st["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        let email = st["email"] as? String
        var pools: [String: UsageWindow] = [:]
        let configs = (st["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []
        for m in configs {
            guard let label = m["label"] as? String, let q = (m["quotaInfo"] ?? m["quota_info"]) as? [String: Any],
                  let f = fraction(q) else { continue }
            let group = groupName(label)
            let w = window(group: group, weekly: false, remaining: f, reset: resetDate(q["resetTime"] ?? q["reset_time"]))
            if let old = pools[group], old.usedPercent >= w.usedPercent { continue }
            pools[group] = w
        }
        return (plan, email, pools.values.sorted { $0.id < $1.id }.reversed())
    }

    // MARK: 找到语言服务

    private static func setCached(_ ep: Endpoint?) {
        lock.lock(); cachedEndpoint = ep; lock.unlock()
    }

    private static func getCached() -> Endpoint? {
        lock.lock(); defer { lock.unlock() }
        return cachedEndpoint
    }

    private static func endpoint(fresh: Bool) async -> Endpoint? {
        if !fresh, let cached = getCached(), kill(cached.pid, 0) == 0 { return cached }

        let (_, out) = await Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="])
        let lines = String(decoding: out, as: UTF8.self).split(separator: "\n")
        for line in lines {
            let s = line.trimmingCharacters(in: .whitespaces)
            // 旧版叫 language_server_macos(_arm)，2.x 起是 App 里的 Resources/bin/language_server
            guard s.contains("language_server"), s.lowercased().contains("antigravity"),
                  let space = s.firstIndex(of: " "), let pid = Int32(s[..<space]) else { continue }
            let cmd = String(s[space...])
            guard let csrf = match(#"--csrf_token[=\s]+"?([A-Za-z0-9-]+)"#, cmd) else { continue }
            var ports = await listeningPorts(pid)
            if let p = match(#"--extension_server_port[=\s]+(\d+)"#, cmd).flatMap(Int.init) { ports.append(p) }
            for port in ports {
                for https in [true, false] {
                    let ep = Endpoint(pid: pid, port: port, csrf: csrf, https: https)
                    if await call(ep, "GetUnleashData", ["wrapper_data": [String: Any]()]).status == 200 {
                        setCached(ep)
                        return ep
                    }
                }
            }
        }
        return nil
    }

    private static func listeningPorts(_ pid: Int32) async -> [Int] {
        let (_, out) = await Shell.run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", "\(pid)"])
        let text = String(decoding: out, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #"TCP\s+\S*:(\d+)\s+\(LISTEN\)"#) else { return [] }
        let ports = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
        return Array(Set(ports)).sorted()
    }

    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: 请求（只连 127.0.0.1；它用自签名证书，只对本机地址放行）

    private final class LoopbackTrust: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == "127.0.0.1",
               let trust = space.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]   // 本机地址不走代理
        c.timeoutIntervalForRequest = 5
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c, delegate: LoopbackTrust(), delegateQueue: nil)
    }()

    private static func call(_ ep: Endpoint, _ method: String, _ body: [String: Any]) async -> (status: Int, body: Any?) {
        guard let url = URL(string: "\(ep.https ? "https" : "http")://127.0.0.1:\(ep.port)/exa.language_server_pb.LanguageServerService/\(method)")
        else { return (0, nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(ep.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await session.data(for: req) else { return (0, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
    }
}
