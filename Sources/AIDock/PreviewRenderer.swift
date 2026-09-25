import SwiftUI
import AppKit

/// `AIDock --render <目录>`：用示例数据把界面渲染成 PNG（不读取任何本地数据或登录信息），用于检查布局。
@MainActor
enum PreviewRenderer {
    static func run(to dir: URL) {
        RenderEnv.preview = true
        // 本机真实检测结果 + 几个示例工具，检查工具较多时的布局
        var tools = ToolDetector.detect()
        for id in ["gemini", "deepseek", "kimi", "ollama"] where !tools.contains(where: { $0.id == id }) {
            if let d = ToolCatalog.def(id) { tools.append(DetectedTool(def: d)) }
        }
        ToolRegistry.update(tools)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 用单独的配置域，不影响真实设置
        let settings = AppSettings(defaults: UserDefaults(suiteName: "local.aidock.preview") ?? .standard)
        settings.hiddenProviders = []
        settings.showActivityTile = true
        let store = UsageStore(settings: settings)
        store.loadDemo()
        let model = DockModel(demo: ["/Applications/Safari.app", "/System/Applications/Safari.app",
                                     "/Applications/Google Chrome.app", "/Applications/WeChat.app",
                                     "/Applications/Claude.app", "/Applications/ChatGPT.app", "/Applications/Cursor.app",
                                     "/System/Applications/System Settings.app", "/System/Applications/Utilities/Terminal.app"])
        let ui = DockUIState()
        ui.revealed = true

        // 其他语言的布局检查
        for lang in [AppLanguage.en, .ja, .de] {
            Loc.apply(lang)
            render(DockView(model: model, store: store, settings: settings, ui: ui,
                            metrics: DockMetrics(icon: 54, widgetsCompact: false, magnify: false)),
                   appearance: .darkAqua, to: dir.appendingPathComponent("i18n-\(lang.rawValue)-dock.png"))
            render(MenuContentView(store: store, settings: settings), appearance: .darkAqua,
                   to: dir.appendingPathComponent("i18n-\(lang.rawValue)-menu.png"))
            for pane in SettingsView.Pane.allCases {
                render(SettingsView(settings: settings, model: model, store: store, pane: pane), appearance: .darkAqua,
                       to: dir.appendingPathComponent("i18n-\(lang.rawValue)-settings-\(pane.rawValue).png"))
            }
        }
        Loc.apply(.zhHans)

        // 小组件插在 App 之间（Claude、微信、Cursor 这样混排），鼠标停在 Claude 圆环上
        let mixed = DockModel(demo: ["/Applications/Safari.app", "widget:claude", "/Applications/WeChat.app", "widget:cursor",
                                     "/Applications/Google Chrome.app", "/System/Applications/System Settings.app"])
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let mm = DockMetrics(icon: 54, widgetsCompact: false, magnify: true, magnification: 1.5)
            let ui2 = DockUIState()
            ui2.revealed = true
            render(DockView(model: mixed, store: store, settings: settings, ui: ui2, metrics: mm),
                   appearance: appearance, to: dir.appendingPathComponent("dock-mixed-\(name).png"))
            ui2.pointerX = mm.padH + 2 * (mm.icon + mm.spacing) + mm.icon / 2
            render(DockView(model: mixed, store: store, settings: settings, ui: ui2, metrics: mm),
                   appearance: appearance, to: dir.appendingPathComponent("dock-mixed-magnify-\(name).png"))
        }

        // Dock 菜单（系统 Dock 样式）
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let entries = [DockMenuEntry(title: DockStrings.s("OPTIONS"), submenu: []), .separator,
                           DockMenuEntry(title: DockStrings.s("SHOW_ALL_WINDOWS"), action: {}),
                           DockMenuEntry(title: DockStrings.s("HIDE"), action: {}), DockMenuEntry(title: DockStrings.s("QUIT"), action: {})]
            let v = DockMenuController.previewView(entries, highlighted: 3)
            v.appearance = NSAppearance(named: appearance)
            let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: v.frame.width + 40, height: v.frame.height + 40),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.backgroundColor = appearance == .darkAqua ? NSColor(hex: 0x1E3040) : NSColor(hex: 0x6B8CA8)
            w.appearance = NSAppearance(named: appearance)
            v.frame.origin = NSPoint(x: 20, y: 20)
            w.contentView?.addSubview(v)
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if let cv = w.contentView, let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                cv.cacheDisplay(in: cv.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("dockmenu-\(name).png"))
            }
            w.orderOut(nil)
        }

        // 透明 Dock：放在壁纸、白色窗口、深色背景上检查文字是否清楚
        settings.dockBackground = .clear
        settings.activityMetric = 1
        let wall = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap { NSImage(contentsOf: $0) }
        for (name, bg) in [("wall", wall.map { Color(nsColor: NSColor(patternImage: $0)) } ?? Color.blue),
                           ("white", Color.white), ("black", Color.black)] {
            let m = DockMetrics(icon: 54, widgetsCompact: true, magnify: false)
            render(DockView(model: model, store: store, settings: settings, ui: ui, metrics: m).padding(20).background(bg),
                   appearance: .aqua, to: dir.appendingPathComponent("dock-clear-\(name).png"))
        }
        settings.dockBackground = .glass
        settings.activityMetric = 0

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for compact in [false, true] {
                let m = DockMetrics(icon: 54, widgetsCompact: compact, magnify: false)
                render(DockView(model: model, store: store, settings: settings, ui: ui, metrics: m),
                       appearance: appearance, to: dir.appendingPathComponent("dock\(compact ? "-compact" : "")-\(name).png"))
            }
            // 鼠标停在第 4 个图标上时的鱼眼放大
            let mm = DockMetrics(icon: 54, widgetsCompact: true, magnify: true, magnification: 1.6)
            ui.pointerX = mm.padH + 3 * (mm.icon + mm.spacing) + mm.icon / 2
            render(DockView(model: model, store: store, settings: settings, ui: ui, metrics: mm),
                   appearance: appearance, to: dir.appendingPathComponent("dock-magnify-\(name).png"))
            ui.pointerX = nil
            render(MenuContentView(store: store, settings: settings), appearance: appearance,
                   to: dir.appendingPathComponent("menu-\(name).png"))
            if name == "dark" {
                for pane in SettingsView.Pane.allCases {
                    render(SettingsView(settings: settings, model: model, store: store, pane: pane), appearance: appearance,
                           to: dir.appendingPathComponent("settings-\(pane.rawValue).png"))
                }
            }
            settings.activityRange = 1
            render(ActivityCard(activity: store.activity, settings: settings).padding(14).frame(width: 320),
                   appearance: appearance, to: dir.appendingPathComponent("activity-week-\(name).png"))
            settings.activityRange = 0
            render(ProviderCard(provider: .cursor, usage: store.usages[.cursor], live: store.activity.live[.cursor], showDetails: true)
                    .padding(14).frame(width: 300),
                   appearance: appearance, to: dir.appendingPathComponent("popover-cursor-\(name).png"))
            // Antigravity 的四个额度，以及借用它的 Gemini（按真实接口返回的结构解析）
            let resetSoon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600))
            let resetWeek = ISO8601DateFormatter().string(from: Date().addingTimeInterval(6 * 86400))
            let summary: [String: Any] = ["response": ["groups": [
                ["displayName": "Gemini Models", "buckets": [
                    ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.62, "resetTime": resetWeek],
                    ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.35, "resetTime": resetSoon]]],
                ["displayName": "Claude and GPT models", "buckets": [
                    ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.9, "resetTime": resetWeek],
                    ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 1, "resetTime": resetSoon]]]]]]
            var ag = ProviderUsage(provider: AntigravityProvider.provider)
            ag.windows = AntigravityProvider.parseSummary(summary)
            ag.plan = "Pro"
            ag.source = .api
            var all: [Provider: ProviderUsage] = [AntigravityProvider.provider: ag]
            var gm = ProviderUsage(provider: .gemini)
            gm.quotaMoved = true
            gm.error = "moved"
            all[.gemini] = gm
            UsageStore.borrowGeminiQuota(&all)
            render(VStack(alignment: .leading, spacing: 14) {
                ProviderCard(provider: AntigravityProvider.provider, usage: all[AntigravityProvider.provider])
                ProviderCard(provider: .gemini, usage: all[.gemini])
            }.padding(14).frame(width: 320), appearance: appearance, to: dir.appendingPathComponent("card-antigravity-\(name).png"))
        }
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let dark = appearance == .darkAqua
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: dark ? NSColor(hex: 0x1E1E20) : NSColor(hex: 0xF2F1EE))))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .darkAqua ? NSColor(hex: 0x1E1E20) : NSColor(hex: 0xE9E8E4)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }
}

extension UsageStore {
    /// 示例数据（仅用于预览渲染）
    func loadDemo() {
        let now = Date()
        var claude = ProviderUsage(provider: .claude)
        claude.plan = "Max 20x"
        claude.windows = [
            UsageWindow(id: "five_hour", label: "5 小时窗口", short: "5h", usedPercent: 34, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60)),
            UsageWindow(id: "seven_day", label: "本周 · 全部模型", short: "本周", usedPercent: 61, resetsAt: now.addingTimeInterval(3 * 86400 + 5000)),
            UsageWindow(id: "seven_day_opus", label: "本周 · Opus", short: "Opus", usedPercent: 12, resetsAt: now.addingTimeInterval(3 * 86400 + 5000)),
        ]
        claude.source = .api; claude.updatedAt = now.addingTimeInterval(-40)

        var codex = ProviderUsage(provider: .codex)
        codex.plan = "Plus"
        codex.account = "you@example.com"
        codex.windows = [
            UsageWindow(id: "p", label: "5 小时窗口", short: "5h", usedPercent: 12, resetsAt: now.addingTimeInterval(4 * 3600 + 2 * 60)),
            UsageWindow(id: "s", label: "本周", short: "本周", usedPercent: 93, resetsAt: now.addingTimeInterval(2 * 86400 + 7200)),
        ]
        codex.source = .api; codex.updatedAt = now.addingTimeInterval(-40)

        var cursor = ProviderUsage(provider: .cursor)
        cursor.plan = "Pro"
        cursor.account = "you@example.com"
        cursor.windows = [
            UsageWindow(id: "plan", label: "本期套餐额度", short: "套餐", usedPercent: 72, resetsAt: now.addingTimeInterval(9 * 86400), detail: "$14.40 / $20.00"),
            UsageWindow(id: "auto", label: "Auto / Composer 模型", short: "Auto", usedPercent: 35, resetsAt: now.addingTimeInterval(9 * 86400)),
            UsageWindow(id: "api", label: "指定模型（API 计价）", short: "API", usedPercent: 81, resetsAt: now.addingTimeInterval(9 * 86400)),
        ]
        cursor.source = .api; cursor.updatedAt = now.addingTimeInterval(-40)

        var rng = SystemRandomNumberGenerator()
        let cal = Calendar.current
        let hourStart = cal.dateInterval(of: .hour, for: now)!.start
        let hours = (0..<24).map { i -> ActivityColumn in
            var c = ActivityColumn(id: i, start: cal.date(byAdding: .hour, value: i - 23, to: hourStart)!)
            let workHour = (i >= 9 && i <= 13) || i >= 17
            if workHour {
                let m1 = Int.random(in: 8...38, using: &rng), m2 = Int.random(in: 0...22, using: &rng), m3 = Int.random(in: 0...12, using: &rng)
                c.values[.claude] = Totals(minutes: m1, requests: m1 * 3, tokens: m1 * 21000)
                c.values[.codex] = Totals(minutes: m2, requests: m2 * 2, tokens: m2 * 15000)
                c.values[.cursor] = Totals(minutes: m3)
                if i >= 19 {
                    c.values[.gemini] = Totals(minutes: Int.random(in: 2...10, using: &rng), requests: 6, tokens: 30000)
                    c.values[Provider(id: "deepseek")] = Totals(minutes: Int.random(in: 3...15, using: &rng))
                }
            }
            return c
        }
        let dayStart = cal.startOfDay(for: now)
        let days = (0..<7).map { i -> ActivityColumn in
            var c = ActivityColumn(id: i, start: cal.date(byAdding: .day, value: i - 6, to: dayStart)!)
            let m1 = Int.random(in: 60...300, using: &rng), m2 = Int.random(in: 20...160, using: &rng), m3 = Int.random(in: 0...90, using: &rng)
            c.values[.claude] = Totals(minutes: m1, requests: m1 * 3, tokens: m1 * 21000)
            c.values[.codex] = Totals(minutes: m2, requests: m2 * 2, tokens: m2 * 15000)
            c.values[.cursor] = Totals(minutes: m3)
            c.values[.gemini] = Totals(minutes: Int.random(in: 0...40, using: &rng), requests: 20, tokens: 90000)
            c.values[Provider(id: "deepseek")] = Totals(minutes: Int.random(in: 10...50, using: &rng))
            c.values[Provider(id: "kimi")] = Totals(minutes: Int.random(in: 0...25, using: &rng))
            return c
        }
        var snap = ActivitySnapshot(hours: hours, days: days)
        snap.live = [
            .claude: LiveStatus(lastActive: now, lastOutput: now, sessions: 2, installed: true, running: true),
            .codex: LiveStatus(lastActive: now.addingTimeInterval(-6 * 60), sessions: 0, installed: true, running: true),
            .cursor: LiveStatus(lastActive: now.addingTimeInterval(-3 * 3600), sessions: 0, installed: true),
        ]
        snap.states = snap.live.mapValues { $0.state() }
        snap.scannedAt = now
        var ollama = LocalModelsInfo(running: true)
        ollama.models = [LocalModel(id: "qwen3:14b", sizeBytes: 9_300_000_000, loaded: true, detail: "14.8B · Q4_K_M"),
                         LocalModel(id: "deepseek-r1:8b", sizeBytes: 5_200_000_000, loaded: false, detail: "8.2B · Q4_K_M"),
                         LocalModel(id: "gemma3:4b", sizeBytes: 3_300_000_000, loaded: false, detail: "4.3B · Q4_K_M")]
        setDemo(usages: [.claude: claude, .codex: codex, .cursor: cursor], activity: snap, local: [Provider(id: "ollama"): ollama])
    }
}
