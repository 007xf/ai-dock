import Foundation
import SQLite3

/// Cursor 套餐额度：从 Cursor 本地状态库（state.vscdb，只读）拿到登录态，
/// 再请求 cursor.com 控制台用的用量接口。
struct CursorProvider {
    static var globalStorage: URL {
        FileManager.default.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
    }
    static var stateDB: URL { globalStorage.appendingPathComponent("state.vscdb") }

    func fetch() async -> ProviderUsage {
        var u = ProviderUsage(provider: .cursor)
        guard FileManager.default.fileExists(atPath: Self.stateDB.path) else {
            u.error = L("未检测到 Cursor。")
            return u
        }
        let kv = await Task.detached(priority: .utility) {
            Self.readItems(["cursorAuth/accessToken", "cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType"])
        }.value
        guard let token = kv["cursorAuth/accessToken"], !token.isEmpty else {
            u.error = L("Cursor 未登录。")
            return u
        }
        u.account = kv["cursorAuth/cachedEmail"]
        u.plan = Self.planName(kv["cursorAuth/stripeMembershipType"])
        // Cursor 的令牌由 Cursor 自己续期（写它正在使用的数据库有损坏风险，AI Dock 不替它续期）
        if TokenRefresh.jwtExpired(token) {
            u.error = L("Cursor 登录已过期。打开 Cursor 即可自动续期。")
            return u
        }

        guard let sub = decodeJWTPayload(token)?["sub"] as? String,
              let userId = sub.split(separator: "|").last.map(String.init) else {
            u.error = L("无法解析 Cursor 登录信息。")
            return u
        }
        let headers = [
            "Cookie": "WorkosCursorSessionToken=\(userId)%3A%3A\(token)",
            "Accept": "application/json",
            "Origin": "https://cursor.com",
            "Referer": "https://cursor.com/dashboard",
            "User-Agent": "Mozilla/5.0 (Macintosh) AIDock"
        ]

        var lastError: String?
        do {
            let (status, json) = try await HTTP.getJSON(URL(string: "https://cursor.com/api/usage-summary")!, headers: headers)
            if status == 200, let d = json as? [String: Any] {
                let parsed = Self.parseSummary(d)
                if !parsed.windows.isEmpty || parsed.note != nil {
                    u.windows = parsed.windows
                    u.note = parsed.note
                    u.plan = Self.planName(parsed.plan) ?? u.plan
                    u.source = .api
                    u.updatedAt = Date()
                    return u
                }
            } else {
                lastError = [401, 403].contains(status) ? L("Cursor 登录已过期。打开 Cursor 即可自动续期。") : L("Cursor：") + HTTP.describe(status: status)
            }
        } catch {
            lastError = L("网络错误：%@", "\(error.localizedDescription)")
        }

        // 旧版按请求次数计费的套餐
        do {
            var comps = URLComponents(string: "https://cursor.com/api/usage")!
            comps.queryItems = [URLQueryItem(name: "user", value: userId)]
            let (status, json) = try await HTTP.getJSON(comps.url!, headers: headers)
            if status == 200, let d = json as? [String: Any] {
                u.windows = Self.parseLegacy(d)
                if !u.windows.isEmpty {
                    u.source = .api
                    u.updatedAt = Date()
                    return u
                }
            } else if lastError == nil {
                lastError = [401, 403].contains(status) ? L("Cursor 登录已过期。打开 Cursor 即可自动续期。") : L("Cursor：") + HTTP.describe(status: status)
            }
        } catch {
            lastError = lastError ?? L("网络错误：%@", "\(error.localizedDescription)")
        }
        u.error = lastError ?? L("没有拿到 Cursor 用量数据。")
        return u
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free", "free_trial": return raw.lowercased() == "free" ? "Free" : L("试用")
        case "pro": return "Pro"
        case "pro_plus", "pro-plus", "proplus": return "Pro+"
        case "ultra": return "Ultra"
        case "business", "team": return "Business"
        case "enterprise": return "Enterprise"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func parseSummary(_ d: [String: Any]) -> (plan: String?, windows: [UsageWindow], note: String?) {
        var windows: [UsageWindow] = []
        var notes: [String] = []
        let cycleEnd = jdate(d["billingCycleEnd"])
        let plan = d["membershipType"] as? String

        if (d["isUnlimited"] as? Bool) == true { notes.append(L("无限额度套餐")) }

        if let iu = d["individualUsage"] as? [String: Any] {
            if let p = iu["plan"] as? [String: Any], (p["enabled"] as? Bool) != false {
                let used = jnum(p["used"]), limit = jnum(p["limit"])
                let pct = jnum(p["totalPercentUsed"]) ?? {
                    guard let used, let limit, limit > 0 else { return nil }
                    return used / limit * 100
                }()
                if let pct {
                    var detail: String?
                    if let used, let limit, limit > 0 { detail = "\(Fmt.money(cents: used)) / \(Fmt.money(cents: limit))" }
                    windows.append(UsageWindow(id: "plan", label: L("本期套餐额度"), short: L("套餐"), usedPercent: pct,
                                               resetsAt: cycleEnd, detail: detail))
                }
                if let a = jnum(p["autoPercentUsed"]) {
                    windows.append(UsageWindow(id: "auto", label: L("Auto / Composer 模型"), short: "Auto",
                                               usedPercent: a, resetsAt: cycleEnd))
                }
                if let a = jnum(p["apiPercentUsed"]) {
                    windows.append(UsageWindow(id: "api", label: L("指定模型（API 计价）"), short: "API",
                                               usedPercent: a, resetsAt: cycleEnd))
                }
            }
            if let od = iu["onDemand"] as? [String: Any], (od["enabled"] as? Bool) == true {
                let used = jnum(od["used"]) ?? 0
                if let limit = jnum(od["limit"]), limit > 0 {
                    windows.append(UsageWindow(id: "ondemand", label: L("按需用量"), short: L("按需"),
                                               usedPercent: used / limit * 100, resetsAt: cycleEnd,
                                               detail: "\(Fmt.money(cents: used)) / \(Fmt.money(cents: limit))"))
                } else if used > 0 {
                    notes.append(L("按需已用 %@", "\(Fmt.money(cents: used))"))
                }
            }
        }
        return (plan, windows, notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    static func parseLegacy(_ d: [String: Any]) -> [UsageWindow] {
        let start = jdate(d["startOfMonth"])
        let reset = start.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) }
        var windows: [UsageWindow] = []
        for (key, label) in [("gpt-4", L("高级模型请求")), ("gpt-4-32k", L("长上下文请求"))] {
            guard let g = d[key] as? [String: Any],
                  let n = jnum(g["numRequests"]), let max = jnum(g["maxRequestUsage"]), max > 0 else { continue }
            windows.append(UsageWindow(id: key, label: label, short: L("请求"), usedPercent: n / max * 100,
                                       resetsAt: reset, detail: L("%@ / %@ 次", "\(Int(n))", "\(Int(max))")))
        }
        return windows
    }

    // MARK: SQLite（只读）

    static func readItems(_ keys: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var db: OpaquePointer?
        let uri = stateDB.absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return result
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        let placeholders = keys.map { _ in "?" }.joined(separator: ",")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM ItemTable WHERE key IN (\(placeholders))", -1, &stmt, nil) == SQLITE_OK else {
            return result
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, k) in keys.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), k, -1, transient) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kp = sqlite3_column_text(stmt, 0) else { continue }
            let key = String(cString: kp)
            var value: String?
            if sqlite3_column_type(stmt, 1) == SQLITE_BLOB, let b = sqlite3_column_blob(stmt, 1) {
                value = String(data: Data(bytes: b, count: Int(sqlite3_column_bytes(stmt, 1))), encoding: .utf8)
            } else if let t = sqlite3_column_text(stmt, 1) {
                value = String(cString: t)
            }
            if var v = value?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                result[key] = v
            }
        }
        return result
    }
}
