import SwiftUI
import Combine
import os

private let usageLog = Logger(subsystem: "local.aidock.app", category: "usage")

enum WidgetStyle: String, CaseIterable, Identifiable {
    case auto, full, compact
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return L("自动")
        case .full: return L("显示数字")
        case .compact: return L("仅圆环")
        }
    }
}

/// Dock 背景：透明（默认）或系统玻璃
enum DockBackground: String, CaseIterable, Identifiable {
    case clear, glass
    var id: String { rawValue }
    var label: String { self == .clear ? L("透明") : L("玻璃") }
}

@MainActor
final class AppSettings: ObservableObject {
    private let d: UserDefaults

    @Published var dockEnabled: Bool { didSet { d.set(dockEnabled, forKey: "dockEnabled") } }
    @Published var hideSystemDock: Bool { didSet { d.set(hideSystemDock, forKey: "hideSystemDock") } }
    @Published var autoHide: Bool { didSet { d.set(autoHide, forKey: "autoHide") } }
    @Published var iconSize: Double { didSet { d.set(iconSize, forKey: "iconSize") } }
    @Published var magnify: Bool { didSet { d.set(magnify, forKey: "magnify") } }
    /// 放大后的图标大小
    @Published var magnifySize: Double { didSet { d.set(magnifySize, forKey: "magnifySize") } }
    @Published var widgetStyle: WidgetStyle { didSet { d.set(widgetStyle.rawValue, forKey: "widgetStyle") } }
    @Published var showActivityTile: Bool { didSet { d.set(showActivityTile, forKey: "showActivityTile") } }
    @Published var hiddenProviders: Set<String> { didSet { d.set(Array(hiddenProviders), forKey: "hiddenProviders") } }
    @Published var refreshMinutes: Int { didSet { d.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    /// 界面语言（切换后立即生效）
    @Published var language: AppLanguage {
        didSet {
            d.set(language.rawValue, forKey: "language")
            Loc.apply(language)
        }
    }
    /// 0 = 24 小时，1 = 7 天；弹窗和 Dock 小组件共用
    @Published var activityRange: Int { didSet { d.set(activityRange, forKey: "activityRange") } }
    /// AI 活动小组件的柱状图和下方数字：0 = 使用时长，1 = Token 用量
    @Published var activityMetric: Int { didSet { d.set(activityMetric, forKey: "activityMetric") } }
    @Published var dockBackground: DockBackground { didSet { d.set(dockBackground.rawValue, forKey: "dockBackground") } }

    var askedHideSystemDock: Bool {
        get { d.bool(forKey: "askedHideSystemDock") }
        set { d.set(newValue, forKey: "askedHideSystemDock") }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        // 第一次启动时沿用系统 Dock 的习惯（自动隐藏、图标大小、放大效果）
        let sys = UserDefaults(suiteName: "com.apple.dock")
        d.register(defaults: [
            "dockEnabled": true, "hideSystemDock": false,
            "autoHide": sys?.object(forKey: "autohide") as? Bool ?? false,
            "iconSize": min(80, max(36, sys?.object(forKey: "tilesize") as? Double ?? 54)),
            "magnify": sys?.object(forKey: "magnification") as? Bool ?? false,
            "magnifySize": min(128, max(40, sys?.object(forKey: "largesize") as? Double ?? 80)),
            "widgetStyle": WidgetStyle.auto.rawValue, "showActivityTile": true,
            "refreshMinutes": 5, "showMenuBarIcon": true, "activityRange": 0,
            "activityMetric": 0, "dockBackground": DockBackground.clear.rawValue
        ])
        dockEnabled = d.bool(forKey: "dockEnabled")
        hideSystemDock = d.bool(forKey: "hideSystemDock")
        autoHide = d.bool(forKey: "autoHide")
        iconSize = d.double(forKey: "iconSize")
        magnify = d.bool(forKey: "magnify")
        magnifySize = d.double(forKey: "magnifySize")
        widgetStyle = WidgetStyle(rawValue: d.string(forKey: "widgetStyle") ?? "") ?? .auto
        showActivityTile = d.bool(forKey: "showActivityTile")
        hiddenProviders = Set(d.stringArray(forKey: "hiddenProviders") ?? [])
        refreshMinutes = max(1, d.integer(forKey: "refreshMinutes"))
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        activityRange = d.integer(forKey: "activityRange")
        activityMetric = d.integer(forKey: "activityMetric")
        dockBackground = DockBackground(rawValue: d.string(forKey: "dockBackground") ?? "") ?? .clear
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        Loc.apply(language)
    }

    private func visible(_ list: [Provider]) -> [Provider] { list.filter { !hiddenProviders.contains($0.id) } }
    /// 有套餐额度的工具（额度圆环 / 额度卡片）
    var visibleProviders: [Provider] { visible(ToolRegistry.quotaTools) }
    /// 本地模型工具
    var visibleLocalTools: [Provider] { visible(ToolRegistry.localModelTools) }
    /// 没有额度接口、只有活动日志或使用时长的工具（Gemini、Antigravity 等）
    var visibleUsageTools: [Provider] { visible(ToolRegistry.usageTools) }
    func isVisible(_ id: String) -> Bool { !hiddenProviders.contains(id) }

    func binding(for p: Provider) -> Binding<Bool> {
        Binding(get: { !self.hiddenProviders.contains(p.rawValue) },
                set: { on in if on { self.hiddenProviders.remove(p.rawValue) } else { self.hiddenProviders.insert(p.rawValue) } })
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var usages: [Provider: ProviderUsage] = [:]
    @Published private(set) var activity = ActivitySnapshot()
    @Published private(set) var localModels: [Provider: LocalModelsInfo] = [:]
    @Published private(set) var apiKeys: [APIKeyEntry] = APIKeyStore.entries
    /// 按 Key 分别查询的余额（键是 APIKeyEntry.id）
    @Published private(set) var apiBalances: [String: APIBalance] = [:]
    @Published private(set) var tools: [DetectedTool] = []
    @Published private(set) var refreshing = false
    @Published private(set) var lastRefresh: Date?

    let settings: AppSettings
    private let scanner = ActivityScanner()
    private var watcher: FileWatcher?
    private var usageLoop: Task<Void, Never>?
    private var tickLoop: Task<Void, Never>?
    private var asleep = false
    private var frontTool: String?
    private var frontSince = Date()
    private var bag = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        settings.$refreshMinutes.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.restartUsageLoop() }
            .store(in: &bag)

        let ws = NSWorkspace.shared.notificationCenter
        // 睡眠时不发网络请求，唤醒后补一次刷新
        ws.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.asleep = true; self?.setFront(nil) }
            .store(in: &bag)
        ws.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.asleep = false
                self?.restartUsageLoop(delay: 5)
                self?.setFront(NSWorkspace.shared.frontmostApplication)
                self?.tickNow()
            }
            .store(in: &bag)
        // 新装的 AI App 第一次启动时重新检测
        ws.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { app in
                guard ToolRegistry.toolID(forBundle: app.bundleIdentifier) == nil else { return false }
                let name = app.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
                return ToolCatalog.all.contains { $0.bundleIDs.contains(app.bundleIdentifier ?? "") || $0.appNames.contains(name) }
            }
            .sink { [weak self] _ in self?.redetect() }
            .store(in: &bag)
        // 有额度的 App 启动后（例如 Antigravity 的本地服务）过几秒再读一次额度
        ws.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
            .filter { id in ToolRegistry.quotaTools.contains { $0.id == ToolRegistry.toolID(forBundle: id) } }
            .debounce(for: .seconds(10), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshNow() }
            .store(in: &bag)
        // App 启动 / 退出：更新「打开了没」
        Publishers.MergeMany(ws.publisher(for: NSWorkspace.didLaunchApplicationNotification),
                             ws.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRunning() }
            .store(in: &bag)
        // 使用时长：只在切换 App 时记一笔，不轮询
        ws.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] n in self?.setFront(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication) }
            .store(in: &bag)
        Publishers.MergeMany(ws.publisher(for: NSWorkspace.screensDidSleepNotification),
                             ws.publisher(for: NSWorkspace.sessionDidResignActiveNotification))
            .sink { [weak self] _ in self?.setFront(nil) }
            .store(in: &bag)
        Publishers.MergeMany(ws.publisher(for: NSWorkspace.screensDidWakeNotification),
                             ws.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification))
            .sink { [weak self] _ in self?.setFront(NSWorkspace.shared.frontmostApplication) }
            .store(in: &bag)
    }

    func start() {
        // 先显示上次读到的额度，刷新完成后再更新
        for (p, u) in QuotaCache.load() where usages[p] == nil { usages[p] = u }
        detectTools()
        // 读一次登录 shell 的环境（PATH、配置目录）；和缓存不同就重新检测
        Task { [weak self] in
            if await UserEnv.refresh() { self?.redetect() }
        }
        restartUsageLoop()
        setFront(NSWorkspace.shared.frontmostApplication)
        let runningIDs = ToolRegistry.runningTools()
        Task { [weak self] in
            guard let self else { return }
            await self.scanner.setRunning(runningIDs)
            let snap = await self.scanner.initialScan()
            self.apply(snap)
            self.startWatching()
        }
        // 只做内存计算（整点翻页、状态从「工作中」变成「空闲」），带较大容差让系统合并唤醒
        tickLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(15))
                guard let self, !self.asleep else { continue }
                self.flushFront()
                // 命令行工具没有启动 / 退出通知，跟着这次定时检查一起看
                await self.scanner.setRunning(ToolRegistry.runningTools())
                self.apply(await self.scanner.tick())
            }
        }
    }

    /// 检测本机的 AI 工具，界面按结果生成
    func detectTools() {
        let found = ToolDetector.detect()
        ToolRegistry.update(found)
        if found != tools { tools = found }
        let ids = found.map(\.id)
        Task { [scanner] in await scanner.configure(tools: ids) }
    }

    func redetect() {
        detectTools()
        refreshNow()
        tickNow()
    }

    func shutdown() {
        flushFront()
        let scanner = self.scanner
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await scanner.flush(); sem.signal() }
        _ = sem.wait(timeout: .now() + 1)
    }

    // MARK: 使用时长

    private func setFront(_ app: NSRunningApplication?) {
        flushFront()
        let id = app.flatMap { $0.processIdentifier == getpid() ? nil : ToolRegistry.toolID(forBundle: $0.bundleIdentifier) }
        frontTool = id
        frontSince = Date()
        Task { [scanner] in await scanner.setFront(id) }
    }

    /// 把当前前台 AI App 的使用时间记下来；用户离开超过 5 分钟的部分不算
    private func flushFront() {
        guard let tool = frontTool else { return }
        let now = Date()
        var end = now
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 300 { end = now.addingTimeInterval(-idle) }
        let start = frontSince
        frontSince = now
        guard end > start else { return }
        Task { [scanner] in await scanner.addPresence(tool, from: start, to: end) }
    }

    private func startWatching() {
        let scanner = self.scanner
        watcher = FileWatcher(paths: scanner.watchPaths, latency: 5) { [weak self] events in
            Task { [weak self] in
                let snap = await scanner.handle(events)
                await self?.apply(snap)
            }
        }
    }

    private func updateRunning() {
        let ids = ToolRegistry.runningTools()
        Task { [weak self] in
            guard let self else { return }
            await self.scanner.setRunning(ids)
            self.apply(await self.scanner.tick())
        }
    }

    private func tickNow() {
        Task { [weak self] in
            guard let self else { return }
            self.flushFront()
            self.apply(await self.scanner.tick())
        }
    }

    private func apply(_ snap: ActivitySnapshot) {
        if snap != activity { activity = snap }
    }

    // MARK: 额度 / 本地模型

    private func restartUsageLoop(delay: Double = 0) {
        usageLoop?.cancel()
        usageLoop = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            while !Task.isCancelled {
                guard let self else { return }
                if !self.asleep { await self.refreshUsage() }
                let secs = Double(max(1, self.settings.refreshMinutes) * 60)
                try? await Task.sleep(for: .seconds(secs), tolerance: .seconds(secs * 0.1))
            }
        }
    }

    func refreshNow() {
        Task { await refreshUsage() }
    }

    /// Google 把个人账号的 Gemini 额度移到了 Antigravity：Gemini 命令行读不到时，显示 Antigravity 里「Gemini 模型」那一组。
    /// 两边登录的不是同一个 Google 账号时不借用
    static func borrowGeminiQuota(_ usages: inout [Provider: ProviderUsage]) {
        guard var g = usages[.gemini], g.quotaMoved, let a = usages[AntigravityProvider.provider] else { return }
        if let e1 = g.account?.lowercased(), let e2 = a.account?.lowercased(), e1 != e2 { return }
        let windows = a.windows.filter { $0.id.hasPrefix("Gemini-") }.map { w -> UsageWindow in
            var w = w
            let weekly = w.id.hasSuffix("week")
            w.id = "antigravity-" + w.id
            w.label = weekly ? L("本周") : L("5 小时窗口")
            w.short = weekly ? L("本周") : "5h"
            return w
        }
        guard !windows.isEmpty else { return }
        g.windows = windows
        g.plan = a.plan
        g.source = a.source
        g.updatedAt = a.updatedAt
        g.stale = a.stale
        g.error = a.stale ? a.error : nil
        g.note = L("Google 已把个人账号的 Gemini 额度移到 Antigravity，这里显示 Antigravity 中 Gemini 模型的额度。")
        usages[.gemini] = g
    }

    private nonisolated static func fetchQuota(_ p: Provider) async -> ProviderUsage {
        switch p.id {
        case "claude": return await ClaudeProvider().fetch()
        case "codex": return await CodexProvider().fetch()
        case "cursor": return await CursorProvider().fetch()
        case "gemini": return await GeminiProvider().fetch()
        case "antigravity": return await AntigravityProvider().fetch()
        default: return ProviderUsage(provider: p)
        }
    }

    func refreshUsage() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let quota = ToolRegistry.quotaTools
        let local = ToolRegistry.localModelTools
        let results = await withTaskGroup(of: ProviderUsage.self) { group in
            for p in quota { group.addTask { await Self.fetchQuota(p) } }
            var out: [ProviderUsage] = []
            for await r in group { out.append(r) }
            return out
        }
        var next = usages
        for r in results {
            usageLog.debug("\(r.provider.id, privacy: .public): \(r.windows.count) windows \(r.windows.map { "\($0.short)=\(Int($0.usedPercent))%" }.joined(separator: " "), privacy: .public) plan=\(r.plan ?? "-", privacy: .public) error=\(r.error ?? "-", privacy: .public)")
            // 刷新失败时保留上一次成功的数据（包括上次运行时保存的），只标记为过期；过了重置时间的按已重置显示
            if r.windows.isEmpty, r.error != nil, !r.quotaMoved, var old = next[r.provider], !old.windows.isEmpty {
                old.error = r.error
                old.stale = true
                old.windows = QuotaCache.aged(old.windows)
                next[r.provider] = old
            } else {
                next[r.provider] = r
            }
        }
        Self.borrowGeminiQuota(&next)
        if let g = next[.gemini], g.quotaMoved { usageLog.debug("gemini: showing \(g.windows.count) windows from Antigravity") }
        for (p, u) in next where usages[p] != u { usages[p] = u }
        QuotaCache.save(results)
        for p in local {
            let info = await LocalModelsProvider.fetch(p.id)
            if localModels[p] != info { localModels[p] = info }
        }
        await refreshBalances()
        lastRefresh = Date()
        // 把刷新过程中用过又释放的内存还给系统（否则空闲时也一直占着）
        malloc_zone_pressure_relief(nil, 0)
    }

    func refreshBalances() async {
        for e in apiKeys {
            var b = await APIBalanceProvider.fetch(e)
            // 余额没变时保持旧对象，避免界面无谓刷新
            if let old = apiBalances[e.id], old.amount == b.amount, old.error == b.error, old.detail == b.detail { b = old }
            if apiBalances[e.id] != b { apiBalances[e.id] = b }
        }
    }

    func addAPIKey(_ key: String, service: APIService) {
        guard APIKeyStore.add(key, service: service) != nil else { return }
        apiKeys = APIKeyStore.entries
        Task { await refreshBalances() }
    }

    func removeAPIKey(_ e: APIKeyEntry) {
        APIKeyStore.remove(e)
        apiKeys = APIKeyStore.entries
        apiBalances[e.id] = nil
    }

    func setDemo(usages: [Provider: ProviderUsage], activity: ActivitySnapshot, local: [Provider: LocalModelsInfo] = [:]) {
        self.usages = usages
        self.activity = activity
        self.localModels = local
        self.tools = ToolRegistry.detected
        self.lastRefresh = Date().addingTimeInterval(-40)
    }
}
