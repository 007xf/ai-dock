import Foundation

/// 上次成功读到的额度。工具没开（Antigravity 的额度只能在它运行时读取）、网络暂时不通时继续显示，
/// 而不是退回到使用时长；到了重置时间就按已重置显示。只存额度数字和套餐名，不存账号和令牌。
enum QuotaCache {
    private static let key = "quotaCache"

    static func load() -> [Provider: ProviderUsage] {
        guard let all = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        var out: [Provider: ProviderUsage] = [:]
        for (id, raw) in all {
            guard let d = raw as? [String: Any], let list = d["windows"] as? [[String: Any]] else { continue }
            var u = ProviderUsage(provider: Provider(id: id))
            u.plan = d["plan"] as? String
            u.updatedAt = (d["updated"] as? Double).map(Date.init(timeIntervalSince1970:))
            u.source = .api
            u.stale = true
            u.windows = list.compactMap { w in
                guard let wid = w["id"] as? String, let label = w["label"] as? String, let short = w["short"] as? String,
                      let used = w["used"] as? Double else { return nil }
                return UsageWindow(id: wid, label: label, short: short, usedPercent: used,
                                   resetsAt: (w["reset"] as? Double).map(Date.init(timeIntervalSince1970:)),
                                   detail: w["detail"] as? String, windowSeconds: w["seconds"] as? Double)
            }
            u.windows = aged(u.windows)
            if !u.windows.isEmpty { out[u.provider] = u }
        }
        return out
    }

    static func save(_ usages: [ProviderUsage]) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        for u in usages where !u.windows.isEmpty && !u.stale {
            var d: [String: Any] = ["windows": u.windows.map { w -> [String: Any] in
                var e: [String: Any] = ["id": w.id, "label": w.label, "short": w.short, "used": w.usedPercent]
                if let r = w.resetsAt { e["reset"] = r.timeIntervalSince1970 }
                if let s = w.windowSeconds { e["seconds"] = s }
                if let t = w.detail { e["detail"] = t }
                return e
            }]
            if let p = u.plan { d["plan"] = p }
            if let t = u.updatedAt { d["updated"] = t.timeIntervalSince1970 }
            all[u.provider.id] = d
        }
        UserDefaults.standard.set(all, forKey: key)
    }

    /// 已经过了重置时间的窗口按 0% 显示
    static func aged(_ windows: [UsageWindow], now: Date = Date()) -> [UsageWindow] {
        windows.map { w in
            guard let r = w.resetsAt, r <= now else { return w }
            var w = w
            w.usedPercent = 0
            w.resetsAt = nil
            w.detail = nil
            return w
        }
    }
}
