import SwiftUI
import AppKit

// MARK: - Colors

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) == .darkAqua
                || appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) == .vibrantDark
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // 状态色（仅用于告警，且总是配合图标）
    static let statusWarning = Color(nsColor: NSColor(hex: 0xFAB219))
    static let statusSerious = Color(nsColor: NSColor(hex: 0xEC835A))
    static let statusCritical = Color(nsColor: NSColor(hex: 0xD03B3B))

    static let chartGrid = Color.adaptive(light: 0xE1E0D9, dark: 0x2C2C2A)
    static let chartAxis = Color.adaptive(light: 0xC3C2B7, dark: 0x383835)
}

func statusColor(for percent: Double) -> Color? {
    if percent >= 90 { return .statusCritical }
    if percent >= 75 { return .statusWarning }
    return nil
}

// MARK: - Formatting

enum Fmt {
    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }

    static func minutes(_ m: Int) -> String {
        if m >= 60 { return m % 60 == 0 ? L("%@ 小时", "\(m / 60)") : L("%@ 小时 %@ 分", "\(m / 60)", "\(m % 60)") }
        return L("%@ 分", "\(m)")
    }

    static func minutesCompact(_ m: Int) -> String {
        if m >= 60 { return "\(m / 60)h\(m % 60 > 0 ? "\(m % 60)m" : "")" }
        return "\(m)m"
    }

    static func money(cents: Double) -> String { String(format: "$%.2f", cents / 100) }

    // 日期格式跟随界面语言（用系统模板生成，例如中文「9月24日」、英文「Sep 24」）
    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Loc.locale
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: Loc.locale) ?? template
        return f
    }
    static private(set) var weekdayTime = formatter("EEEHHmm")
    static private(set) var monthDay = formatter("MMMd")
    static private(set) var hour: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:00"; return f
    }()
    static private(set) var weekday = formatter("EEE")

    static func resetFormatters() {
        weekdayTime = formatter("EEEHHmm")
        monthDay = formatter("MMMd")
        weekday = formatter("EEE")
    }

    static func reset(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return L("已到重置时间") }
        if s < 3600 { return L("%@ 分钟后重置", "\(max(1, Int(s / 60)))") }
        if s < 86400 {
            let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? L("%@ 小时 %@ 分后重置", "\(h)", "\(m)") : L("%@ 小时后重置", "\(h)")
        }
        if s < 7 * 86400 { return L("%@ 重置", "\(weekdayTime.string(from: date))") }
        return L("%@ 重置", "\(monthDay.string(from: date))")
    }

    /// 紧凑版重置时间，用在单行额度里：「32 分后」「4h12m 后」「周一 08:33」「11月5日」
    static func resetCompact(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return L("已重置") }
        if s < 3600 { return L("%@ 分后", "\(max(1, Int(s / 60)))") }
        if s < 86400 {
            let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? L("%@h%@m 后", "\(h)", "\(m)") : L("%@ 小时后", "\(h)")
        }
        if s < 7 * 86400 { return weekdayTime.string(from: date) }
        return monthDay.string(from: date)
    }

    /// 短版倒计时，用在 Dock 小组件里
    static func resetShort(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return nil }
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86400 { return "\(Int(s / 3600))h\(Int(s.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "\(Int(s / 86400))d\(Int(s.truncatingRemainder(dividingBy: 86400) / 3600))h"
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = now.timeIntervalSince(date)
        if s < 10 { return L("刚刚") }
        if s < 60 { return L("%@ 秒前", "\(Int(s))") }
        if s < 3600 { return L("%@ 分钟前", "\(Int(s / 60))") }
        if s < 86400 { return L("%@ 小时前", "\(Int(s / 3600))") }
        return L("%@ 天前", "\(Int(s / 86400))")
    }
}

// MARK: - JSON helpers

func jnum(_ v: Any?) -> Double? {
    switch v {
    case let n as NSNumber:
        // 排除布尔值
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}

func jdate(_ v: Any?) -> Date? {
    if let s = v as? String {
        if let d = parseISODate(s) { return d }
        if let n = Double(s) { return epochDate(n) }
        return nil
    }
    if let n = jnum(v) { return epochDate(n) }
    return nil
}

private func epochDate(_ n: Double) -> Date {
    // 同时兼容秒与毫秒
    Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
}

/// 快速 ISO-8601 解析，支持小数秒和时区偏移（2026-09-21T10:32:11.068Z / +08:00）
func parseISODate(_ s: String) -> Date? {
    let u = Array(s.utf8)
    guard u.count >= 19 else { return nil }
    func num(_ a: Int, _ b: Int) -> Int32? {
        var v: Int32 = 0
        for i in a..<b {
            let c = u[i]
            guard c >= 48, c <= 57 else { return nil }
            v = v * 10 + Int32(c - 48)
        }
        return v
    }
    guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10),
          let h = num(11, 13), let mi = num(14, 16), let se = num(17, 19) else { return nil }
    var t = tm()
    t.tm_year = y - 1900; t.tm_mon = mo - 1; t.tm_mday = d
    t.tm_hour = h; t.tm_min = mi; t.tm_sec = se
    var secs = Double(timegm(&t))
    var i = 19
    if i < u.count, u[i] == 46 { // '.'
        i += 1
        var frac = 0.0, scale = 0.1
        while i < u.count, u[i] >= 48, u[i] <= 57 {
            frac += Double(u[i] - 48) * scale; scale /= 10; i += 1
        }
        secs += frac
    }
    if i < u.count, u[i] == 43 || u[i] == 45, i + 3 <= u.count { // '+' / '-'
        let sign: Double = u[i] == 43 ? 1 : -1
        let oh = num(i + 1, i + 3) ?? 0
        var om: Int32 = 0
        if i + 6 <= u.count { om = (u[i + 3] == 58 ? num(i + 4, i + 6) : num(i + 3, i + 5)) ?? 0 }
        secs -= sign * Double(oh * 3600 + om * 60)
    }
    return Date(timeIntervalSince1970: secs)
}

/// 解码 JWT 的 payload（不校验签名，只读字段）
func decodeJWTPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - Process / HTTP

enum Shell {
    /// 在后台线程运行命令并返回 stdout
    static func run(_ path: String, _ args: [String]) async -> (status: Int32, output: Data) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: (-1, Data())); return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, data))
            }
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    static func getJSON(_ url: URL, headers: [String: String]) async throws -> (status: Int, json: Any?) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, try? JSONSerialization.jsonObject(with: data))
    }

    static func describe(status: Int) -> String {
        switch status {
        case 401, 403: return L("登录已失效（%@）", "\(status)")
        case 429: return L("请求过于频繁，稍后会自动重试")
        case 500...599: return L("服务暂时不可用（%@）", "\(status)")
        default: return L("接口返回 %@", "\(status)")
        }
    }
}

extension FileManager {
    var home: URL { homeDirectoryForCurrentUser }
}

// MARK: - 本地 UI 状态
// 新版 SDK 里 @State 由 SwiftUI 宏实现，而命令行工具链不带这个宏插件；
// 用 @StateObject + Box 代替，这样无需安装 Xcode 也能编译。
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
