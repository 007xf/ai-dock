import SwiftUI
import AppKit

/// 一个 AI 工具（按 id 标识；名称、颜色、标志来自工具目录和本机检测结果）
struct Provider: Hashable, Identifiable, Comparable {
    let id: String

    static let claude = Provider(id: "claude")
    static let codex = Provider(id: "codex")
    static let cursor = Provider(id: "cursor")
    static let gemini = Provider(id: "gemini")
    static let qwen = Provider(id: "qwen")

    var rawValue: String { id }
    var def: ToolDef? { ToolCatalog.def(id) }
    static let other = Provider(id: "other")

    var name: String { def.map { L($0.name) } ?? (id == "other" ? L("其他") : id) }
    var short: String { (def?.short ?? def?.name).map { L($0) } ?? (id == "other" ? L("其他") : id) }
    var slot: Int { ToolRegistry.slots[id] ?? 99 }

    /// 固定色槽的分类色；超出 8 个的工具用「其他」灰色
    var color: Color {
        guard let s = ToolRegistry.slots[id], s < Palette.slots.count else { return Palette.other }
        return .adaptive(light: Palette.slots[s].0, dark: Palette.slots[s].1)
    }

    /// 官方标志：打包的透明标志，或从 App 图标里提取
    func logo(dark: Bool) -> NSImage? { LogoStore.logo(for: ToolRegistry.tool(id), id: id, dark: dark) }

    /// 图表里按色槽顺序堆叠（色槽顺序就是做过相邻色差校验的顺序）
    static func < (a: Provider, b: Provider) -> Bool { a.slot == b.slot ? a.id < b.id : a.slot < b.slot }
}

struct UsageWindow: Identifiable, Hashable {
    var id: String
    /// 完整名称，例如「5 小时窗口」
    var label: String
    /// 短名称，例如「5h」「本周」
    var short: String
    /// 0–100
    var usedPercent: Double
    var resetsAt: Date?
    var detail: String?
    var windowSeconds: Double?
}

enum DataSource: Equatable {
    case none, api, localLog

    var label: String {
        switch self {
        case .none: return "—"
        case .api: return L("官方接口")
        case .localLog: return L("本地会话日志")
        }
    }
}

struct ProviderUsage: Equatable {
    var provider: Provider
    var plan: String?
    var account: String?
    var windows: [UsageWindow] = []
    var source: DataSource = .none
    var updatedAt: Date?
    var error: String?
    var note: String?
    /// 本次刷新失败，展示的是上一次成功的数据
    var stale = false
    /// 额度已经不在这个工具里了（Gemini 个人账号的额度移到了 Antigravity）
    var quotaMoved = false

    init(provider: Provider) { self.provider = provider }

    var maxPercent: Double? { windows.map(\.usedPercent).max() }
    /// 最紧张的窗口
    var tightest: UsageWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
}

// MARK: - Activity

struct Totals: Hashable {
    var minutes = 0
    var requests = 0
    var tokens = 0

    mutating func add(_ o: Totals) {
        minutes += o.minutes; requests += o.requests; tokens += o.tokens
    }
}

struct ActivityColumn: Identifiable, Equatable {
    let id: Int
    let start: Date
    var values: [Provider: Totals] = [:]

    func total(_ providers: [Provider]) -> Int {
        providers.reduce(0) { $0 + (values[$1]?.minutes ?? 0) }
    }

    func totalTokens(_ providers: [Provider]) -> Int {
        providers.reduce(0) { $0 + (values[$1]?.tokens ?? 0) }
    }
}

struct LiveStatus: Equatable {
    /// 最近一次使用（AI 输出，或 App 在前台）
    var lastActive: Date?
    /// 最近一次 AI 真正产生输出（会话日志写入）。只有这个才算「工作中」——App 开在前台不算
    var lastOutput: Date?
    /// 最近 60 秒内有写入的会话数
    var sessions = 0
    var installed = false
    /// App 或命令行正在运行
    var running = false

    /// working：AI 正在输出（亮点）；recent：打开了但没在工作（暗点）；idle：没打开（空心圈）
    enum State { case working, recent, idle, missing }

    func state(now: Date = Date()) -> State {
        guard installed else { return .missing }
        if let lastOutput, now.timeIntervalSince(lastOutput) < 60 { return .working }
        return running ? .recent : .idle
    }

    func text(now: Date = Date()) -> String {
        switch state(now: now) {
        case .missing: return L("未检测到")
        case .working: return sessions > 1 ? L("工作中 ×%@", "\(sessions)") : L("工作中")
        case .recent:
            if let lastActive, now.timeIntervalSince(lastActive) < 3600 { return L("%@活跃", "\(Fmt.ago(lastActive, now: now))") }
            return L("已打开")
        case .idle: return L("未打开")
        }
    }
}

struct ActivitySnapshot: Equatable {
    var hours: [ActivityColumn] = []
    var days: [ActivityColumn] = []
    var live: [Provider: LiveStatus] = [:]
    /// 生成快照时计算好的状态；状态变化（工作中 → 空闲）时快照才算「变了」
    var states: [Provider: LiveStatus.State] = [:]
    var scannedAt: Date?

    var today: [Provider: Totals] { days.last?.values ?? [:] }

    func totals(_ columns: [ActivityColumn], _ p: Provider) -> Totals {
        columns.reduce(into: Totals()) { acc, col in
            let v = col.values[p] ?? Totals()
            acc.minutes += v.minutes
            acc.requests += v.requests
            acc.tokens += v.tokens
        }
    }

    /// 这段时间里有活动（或正在工作）的工具，按色槽顺序排列
    func tools(in columns: [ActivityColumn]) -> [Provider] {
        var set = Set<Provider>()
        for c in columns { for (p, t) in c.values where t.minutes > 0 { set.insert(p) } }
        for (p, s) in states where s == .working { set.insert(p) }
        return set.sorted()
    }

    /// 比较内容时忽略扫描时间，避免没有变化也触发界面刷新
    private static func sessionsEqual(_ a: ActivitySnapshot, _ b: ActivitySnapshot) -> Bool {
        Set(a.live.keys).union(b.live.keys).allSatisfy { a.live[$0]?.sessions == b.live[$0]?.sessions }
    }

    static func == (a: ActivitySnapshot, b: ActivitySnapshot) -> Bool {
        a.hours == b.hours && a.days == b.days && a.states == b.states && sessionsEqual(a, b) && (a.scannedAt == nil) == (b.scannedAt == nil)
    }
}
