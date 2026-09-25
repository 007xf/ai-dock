import Foundation
import Security

/// 可以用 API Key 查询余额的平台
enum APIService: String, CaseIterable, Identifiable, Codable {
    case deepseek, moonshot, siliconflow, openrouter
    var id: String { rawValue }
    var name: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .moonshot: return "Kimi"
        case .siliconflow: return L("硅基流动")
        case .openrouter: return "OpenRouter"
        }
    }
}

/// 根据 Key 的格式识别平台（只看格式，不会把 Key 发给多家平台去试）
enum KeyDetection: Equatable {
    /// 识别成功；ambiguous = 同样格式还可能是别家，允许用户改
    case supported(APIService, ambiguous: Bool)
    /// 识别出了平台，但官方不提供余额查询接口
    case unsupported(String)
    case unknown

    static func detect(_ raw: String) -> KeyDetection {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ pattern: String) -> Bool { k.range(of: pattern, options: .regularExpression) != nil }
        if k.hasPrefix("sk-or-") { return .supported(.openrouter, ambiguous: false) }
        if k.hasPrefix("sk-ant-") { return .unsupported("Anthropic") }
        if k.hasPrefix("sk-proj-") || k.hasPrefix("sk-svcacct-") || k.hasPrefix("sk-admin-") { return .unsupported("OpenAI") }
        if k.hasPrefix("AIza") { return .unsupported("Google Gemini") }
        if k.hasPrefix("xai-") { return .unsupported("xAI") }
        if k.hasPrefix("gsk_") { return .unsupported("Groq") }
        if matches("^[0-9a-f]{32}\\.[A-Za-z0-9]{16}$") { return .unsupported(L("智谱 GLM")) }
        // DeepSeek：sk- + 32 位十六进制（阿里云百炼的 Key 也是这个格式）
        if matches("^sk-[0-9a-f]{32}$") { return .supported(.deepseek, ambiguous: true) }
        // 硅基流动：sk- + 48 位小写字母
        if matches("^sk-[a-z]{48}$") { return .supported(.siliconflow, ambiguous: true) }
        // Kimi（月之暗面）：sk- + 48 位字母数字
        if matches("^sk-[A-Za-z0-9]{48}$") { return .supported(.moonshot, ambiguous: true) }
        if k.hasPrefix("sk-"), k.count > 20 { return .supported(.deepseek, ambiguous: true) }
        return .unknown
    }
}

struct APIKeyEntry: Codable, Identifiable, Equatable {
    let id: String
    var service: APIService
    /// 只保存打码后的样子用于显示，真正的 Key 在钥匙串里
    var masked: String
}

struct APIBalance: Equatable {
    var amount: Double?
    var currency = "CNY"
    var detail: String?
    var error: String?
    var updatedAt = Date()

    var amountText: String {
        guard let amount else { return "—" }
        let symbol = currency == "USD" ? "$" : "¥"
        return symbol + String(format: amount >= 100 ? "%.0f" : "%.2f", amount)
    }
}

enum APIKeyStore {
    private static let service = "local.aidock.apikeys"
    private static let listKey = "apiKeyEntries"

    static var entries: [APIKeyEntry] {
        guard let d = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([APIKeyEntry].self, from: d) else { return [] }
        return list
    }

    private static func saveList(_ list: [APIKeyEntry]) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: listKey) }
    }

    static func mask(_ key: String) -> String {
        guard key.count > 10 else { return "••••" }
        return String(key.prefix(6)) + "…" + String(key.suffix(4))
    }

    @discardableResult
    static func add(_ key: String, service s: APIService) -> APIKeyEntry? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = APIKeyEntry(id: UUID().uuidString, service: s, masked: mask(k))
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: entry.id, kSecValueData as String: Data(k.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return nil }
        saveList(entries + [entry])
        return entry
    }

    static func secret(_ e: APIKeyEntry) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: e.id, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func remove(_ e: APIKeyEntry) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: e.id]
        SecItemDelete(q as CFDictionary)
        saveList(entries.filter { $0.id != e.id })
    }
}

enum APIBalanceProvider {
    private static func two(_ v: Double?) -> String { String(format: "%.2f", v ?? 0) }

    static func fetch(_ e: APIKeyEntry) async -> APIBalance {
        var b = APIBalance()
        guard let key = APIKeyStore.secret(e) else { b.error = L("钥匙串里找不到这个 Key"); return b }
        let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        do {
            switch e.service {
            case .deepseek:
                let (status, json) = try await HTTP.getJSON(URL(string: "https://api.deepseek.com/user/balance")!, headers: headers)
                guard status == 200, let d = json as? [String: Any] else { b.error = HTTP.describe(status: status); return b }
                if let info = (d["balance_infos"] as? [[String: Any]])?.first {
                    b.currency = info["currency"] as? String ?? "CNY"
                    b.amount = jnum(info["total_balance"])
                    b.detail = L("充值 %@ · 赠送 %@", "\(two(jnum(info["topped_up_balance"])))", "\(two(jnum(info["granted_balance"])))")
                }
                if (d["is_available"] as? Bool) == false { b.detail = L("余额不足，API 已不可用") }

            case .moonshot:
                // 国内站和国际站各有一个域名
                var result: (Int, Any?) = (0, nil)
                for host in ["https://api.moonshot.cn", "https://api.moonshot.ai"] {
                    result = try await HTTP.getJSON(URL(string: "\(host)/v1/users/me/balance")!, headers: headers)
                    if result.0 == 200 { break }
                }
                guard result.0 == 200, let d = (result.1 as? [String: Any])?["data"] as? [String: Any] else {
                    b.error = HTTP.describe(status: result.0); return b
                }
                b.amount = jnum(d["available_balance"])
                b.detail = L("现金 %@ · 代金券 %@", "\(two(jnum(d["cash_balance"])))", "\(two(jnum(d["voucher_balance"])))")

            case .siliconflow:
                let (status, json) = try await HTTP.getJSON(URL(string: "https://api.siliconflow.cn/v1/user/info")!, headers: headers)
                guard status == 200, let d = (json as? [String: Any])?["data"] as? [String: Any] else { b.error = HTTP.describe(status: status); return b }
                b.amount = jnum(d["totalBalance"]) ?? jnum(d["balance"])
                b.detail = L("充值 %@ · 赠送 %@", "\(two(jnum(d["chargeBalance"])))", "\(two(jnum(d["balance"])))")

            case .openrouter:
                let (status, json) = try await HTTP.getJSON(URL(string: "https://openrouter.ai/api/v1/credits")!, headers: headers)
                guard status == 200, let d = (json as? [String: Any])?["data"] as? [String: Any] else { b.error = HTTP.describe(status: status); return b }
                let total = jnum(d["total_credits"]) ?? 0, used = jnum(d["total_usage"]) ?? 0
                b.currency = "USD"
                b.amount = total - used
                b.detail = L("已充值 $%@ · 已用 $%@", "\(two(total))", "\(two(used))")
            }
        } catch {
            b.error = L("网络错误：%@", "\(error.localizedDescription)")
        }
        return b
    }
}
