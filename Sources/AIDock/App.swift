import SwiftUI
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let settings = AppSettings()
    var settings: AppSettings { Self.settings }
    lazy var store = UsageStore(settings: settings)
    private(set) lazy var model = DockModel()
    private var dock: DockController?
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 常驻的 Dock：不让系统在「没有窗口」时自动把它关掉
        ProcessInfo.processInfo.disableAutomaticTermination("AI Dock 是常驻的 Dock")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.mainMenu = makeMainMenu()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            PreviewRenderer.run(to: URL(fileURLWithPath: args[i + 1]))
            NSApp.terminate(nil)
            return
        }
        store.start()
        statusItem = StatusItemController { [unowned self] maxHeight in
            MenuContentView(store: self.store, settings: self.settings, openSettings: { [weak self] in self?.openSettings() },
                            maxHeight: maxHeight)
        }
        // 没有 Dock 时菜单栏图标是唯一入口，强制显示
        Publishers.CombineLatest(settings.$showMenuBarIcon, settings.$dockEnabled)
            .sink { [weak self] show, dock in self?.statusItem?.visible = show || !dock }
            .store(in: &bag)
        dock = DockController(model: model, store: store, settings: settings, openSettings: { [weak self] in self?.openSettings() })

        // 切换语言：重建菜单和窗口标题，重新获取一次数据（报错、标签等文字按新语言生成）
        settings.$language.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                NSApp.mainMenu = self.makeMainMenu()
                self.settingsWindow?.title = L("AI Dock 设置")
                self.store.refreshNow()
            }
            .store(in: &bag)

        // 系统 Dock 的隐藏 / 恢复只跟随用户的设置
        Publishers.CombineLatest(settings.$dockEnabled, settings.$hideSystemDock)
            .removeDuplicates { $0 == $1 }
            .sink { enabled, hide in
                DispatchQueue.global(qos: .userInitiated).async {
                    if enabled && hide { SystemDock.suppress() } else { SystemDock.restore() }
                }
            }
            .store(in: &bag)

        if settings.dockEnabled && !settings.askedHideSystemDock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.askHideSystemDock() }
        }
    }

    /// ⌘Q 只在设置窗口在最前面时才退出 AI Dock。其他时候 AI Dock 不该是前台 App，
    /// 按 ⌘Q 多半是想退出别的 App——取消退出，并把前台还给原来的 App（系统 Dock 也不会被 ⌘Q 退出）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let e = NSApp.currentEvent, e.type == .keyDown, e.modifierFlags.contains(.command),
           e.charactersIgnoringModifiers?.lowercased() == "q", settingsWindow?.isKeyWindow != true {
            Focus.giveBack(force: true)
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
        if settings.hideSystemDock { SystemDock.restore() }
    }

    /// 从聚焦搜索 / 启动台再次打开时，显示设置窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func askHideSystemDock() {
        let alert = NSAlert()
        alert.messageText = L("要隐藏系统 Dock 吗？")
        alert.informativeText = L("AI Dock 已经包含你 Dock 里的 App，和 Claude、Codex、Cursor 的用量小组件。\n\n隐藏系统 Dock 后，鼠标移到屏幕底部只会出现 AI Dock，不会两个叠在一起。退出 AI Dock 时会自动恢复系统 Dock，也可以随时在设置里改回来。")
        alert.addButton(withTitle: L("隐藏系统 Dock"))
        alert.addButton(withTitle: L("暂不"))
        Focus.borrow()
        let answer = alert.runModal()
        // 用户真正做出选择后才记为「已问过」
        settings.askedHideSystemDock = true
        if answer == .alertFirstButtonReturn { settings.hideSystemDock = true }
        Focus.giveBack()
    }

    // MARK: 菜单与快捷键（标准 macOS 快捷键：⌘, ⌘W ⌘M ⌘H ⌘Q 以及编辑快捷键）

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        submenu("AI Dock", [
            item(L("关于 AI Dock"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item(L("设置…"), #selector(openSettingsAction(_:)), ",", target: self),
            .separator(),
            item(L("隐藏 AI Dock"), #selector(NSApplication.hide(_:)), "h"),
            item(L("隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("全部显示"), #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item(L("退出 AI Dock"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu(L("编辑"), [
            item(L("撤销"), Selector(("undo:")), "z"),
            item(L("重做"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("剪切"), #selector(NSText.cut(_:)), "x"),
            item(L("拷贝"), #selector(NSText.copy(_:)), "c"),
            item(L("粘贴"), #selector(NSText.paste(_:)), "v"),
            item(L("全选"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(L("窗口"), [
            item(L("最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("关闭"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    @objc func openSettingsAction(_ sender: Any?) { openSettings() }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = L("AI Dock 设置")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings, model: model, store: store))
            w.center()
            // 关闭后释放视图，不占内存
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.settingsWindow?.contentView = nil
                    self?.settingsWindow = nil
                    Focus.giveBack()
                }
            }
            settingsWindow = w
        }
        Focus.borrow()
        settingsWindow?.makeKeyAndOrderFront(nil)
        // 打开时不自动聚焦任何控件（不出现键盘焦点蓝框）
        settingsWindow?.makeFirstResponder(nil)
    }
}

// MARK: - 菜单栏

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let makeContent: (CGFloat?) -> MenuContentView
    /// 弹窗打开时再点一次图标：按下鼠标时弹窗已经因为「点到外面」先关掉了，松开时按钮动作不应再把它打开
    private var closedByIconAt: Date?

    var visible: Bool {
        get { item.isVisible }
        set { if item.isVisible != newValue { item.isVisible = newValue } }
    }

    init(content: @escaping (CGFloat?) -> MenuContentView) {
        makeContent = content
        super.init()
        item.button?.image = MenuBarIcon.image
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "AI Dock"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if let t = closedByIconAt {
            closedByIconAt = nil
            if Date().timeIntervalSince(t) < 1 { return }
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // 打开时才创建界面，关闭后释放，平时不占内存。
            // 先量好尺寸再固定：内容比屏幕高时中间改成滚动，避免面板被推出屏幕顶部
            let maxH = ((button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 40
            let hc = NSHostingController(rootView: makeContent(nil))
            hc.sizingOptions = []
            var size = hc.sizeThatFits(in: CGSize(width: 320, height: 10_000))
            if size.height > maxH {
                hc.rootView = makeContent(maxH)
                size.height = maxH
            }
            popover.contentSize = size
            popover.contentViewController = hc
            Focus.borrow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            hc.view.window?.makeFirstResponder(nil)
        }
    }

    func popoverWillClose(_ notification: Notification) {
        // 这次关闭是不是由点按菜单栏图标引起的
        if let ev = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown].contains(ev.type),
           let w = item.button?.window, ev.window === w {
            closedByIconAt = Date()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        Focus.giveBack()
    }
}

// MARK: - 窗口

/// 系统 Dock 所在层级；AI Dock 放在它上面一层，保证鼠标事件先到这里
private let dockLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = dockLevel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        // 不带 .fullScreenAuxiliary：全屏的视频 / App 所在空间里不会出现
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Dock 的拖放：从 Dock 拖出（排序 / 移除）、从访达拖入（添加 / 用某个 App 打开 / 移到废纸篓）
@MainActor
protocol DockDragHandler: AnyObject {
    func dragItem(atX x: CGFloat) -> (id: String, url: URL, image: NSImage)?
    var dragIconSize: CGFloat { get }
    func dragBegan(id: String)
    func dragMoved(to screenPoint: NSPoint, session: NSDraggingSession)
    func dragEnded(at screenPoint: NSPoint, operation: NSDragOperation)
    func dropUpdated(_ info: NSDraggingInfo, x: CGFloat) -> NSDragOperation
    func dropExited()
    func performDrop(_ info: NSDraggingInfo, x: CGFloat) -> Bool
    /// 右键 / Control + 点按 / 按住不放：弹出和系统 Dock 一样的菜单；返回 false 表示交给 SwiftUI（小组件自己的菜单）
    func showMenu(at point: NSPoint) -> Bool
    /// 这个位置是不是图标（按住不放只对图标弹菜单）
    func isIcon(at point: NSPoint) -> Bool
}

/// 拖动源代理：把系统的拖动回调转给 Dock 控制器
final class DockDragSource: NSObject, NSDraggingSource {
    weak var handler: DockDragHandler?
    var onEnd: (() -> Void)?

    // Dock 之外不接受任何放置（拖到外面松手 = 从 Dock 移除，不会把 App 复制到别处）
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        MainActor.assumeIsolated { handler?.dragMoved(to: screenPoint, session: session) }
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            onEnd?()
            handler?.dragEnded(at: screenPoint, operation: operation)
        }
    }
}

final class DockHostingView<Content: View>: NSHostingView<Content> {
    weak var dragHandler: DockDragHandler? {
        didSet { dragSource.handler = dragHandler }
    }
    private let dragSource = DockDragSource()
    private var downEvent: NSEvent?
    private var dragging = false
    private var pressWork: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Control + 点按 = 右键（和系统 Dock 一样）
        if event.modifierFlags.contains(.control), dragHandler?.showMenu(at: p) == true { return }
        downEvent = event
        super.mouseDown(with: event)
        // 在图标上按住不放：弹出菜单（和系统 Dock 一样）
        pressWork?.cancel()
        guard dragHandler?.isIcon(at: p) == true else { return }
        let w = DispatchWorkItem { [weak self] in self?.longPress(at: p, event: event) }
        pressWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    override func rightMouseDown(with event: NSEvent) {
        if dragHandler?.showMenu(at: convert(event.locationInWindow, from: nil)) == true { return }
        super.rightMouseDown(with: event)
    }

    private func longPress(at p: NSPoint, event: NSEvent) {
        pressWork = nil
        guard downEvent != nil, !dragging else { return }
        downEvent = nil
        releaseButton(event)
        _ = dragHandler?.showMenu(at: p)
    }

    /// 让 SwiftUI 按钮结束按下状态（在很远的地方松开，不会触发点按）
    private func releaseButton(_ event: NSEvent) {
        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: [],
                                       timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 0) {
            super.mouseUp(with: up)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if !dragging, let down = downEvent, let h = dragHandler,
           hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 5,
           let hit = h.dragItem(atX: convert(down.locationInWindow, from: nil).x) {
            dragging = true
            downEvent = nil
            pressWork?.cancel()
            // 让按钮结束按下状态，避免拖完后图标一直是按下的样子
            releaseButton(event)
            let item = NSDraggingItem(pasteboardWriter: hit.url as NSURL)
            let size = NSSize(width: h.dragIconSize, height: h.dragIconSize)
            let p = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height),
                                  contents: hit.image)
            dragSource.onEnd = { [weak self] in self?.dragging = false }
            let session = beginDraggingSession(with: [item], event: event, source: dragSource)
            session.animatesToStartingPositionsOnCancelOrFail = false
            h.dragBegan(id: hit.id)
            return
        }
        if !dragging { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        downEvent = nil
        pressWork?.cancel()
        super.mouseUp(with: event)
    }

    // 拖放目标
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragHandler?.dropUpdated(sender, x: convert(sender.draggingLocation, from: nil).x) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragHandler?.dropUpdated(sender, x: convert(sender.draggingLocation, from: nil).x) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragHandler?.dropExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragHandler?.performDrop(sender, x: convert(sender.draggingLocation, from: nil).x) ?? false
    }
}

/// 屏幕最底部 2pt 高的触发条：鼠标碰到底边时通知显示 Dock（只用追踪区域，不轮询鼠标位置）
final class EdgeTriggerPanel: NSPanel {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private(set) var mouseInside = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 2),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = dockLevel
        // 几乎透明但不是完全透明：完全透明的像素会被窗口服务器当成「穿透」，收不到鼠标事件
        backgroundColor = NSColor(white: 0, alpha: 0.004)
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = TrackingView(frame: NSRect(x: 0, y: 0, width: 100, height: 2))
        v.autoresizingMask = [.width, .height]
        v.onChange = { [weak self] inside in
            self?.mouseInside = inside
            inside ? self?.onEnter?() : self?.onExit?()
        }
        contentView = v
    }

    private final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var area: NSTrackingArea?

        private func install() {
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                   owner: self, userInfo: nil)
            addTrackingArea(a)
            area = a
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        override func updateTrackingAreas() { super.updateTrackingAreas(); install() }
        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}

// MARK: - Dock 控制

@MainActor
final class DockController: DockDragHandler {
    private let panel = DockPanel()
    private let trigger = EdgeTriggerPanel()
    private let host: DockHostingView<DockView>
    private let model: DockModel
    private let store: UsageStore
    private let settings: AppSettings
    private let ui = DockUIState()
    private let openSettings: () -> Void
    private var metrics = DockMetrics(icon: 54, widgetsCompact: false, magnify: false, magnification: 1.33)
    /// Dock 内容（含两侧放大留白）的宽度
    private var contentWidth: CGFloat = 0
    private var showingRemove = false
    private var revealed = false
    private var fullscreen = false
    /// 前台 App 要求完全隐藏 Dock
    private var suppressed = false
    private var presentationObservation: NSKeyValueObservation?
    private var menuTracking = false
    private var orderOutWork: DispatchWorkItem?
    private lazy var slide = WindowSlide(panel)
    private var sliding: Bool? // 正在进行的动画方向：true 弹出，false 收起
    private var bag = Set<AnyCancellable>()

    init(model: DockModel, store: UsageStore, settings: AppSettings, openSettings: @escaping () -> Void) {
        self.model = model
        self.store = store
        self.settings = settings
        self.openSettings = openSettings
        host = DockHostingView(rootView: DockView(model: model, store: store, settings: settings, ui: ui,
                                                  metrics: metrics, openSettings: openSettings))
        host.sizingOptions = []
        host.dragHandler = self
        host.registerForDraggedTypes([.fileURL])
        panel.contentView = host

        trigger.onEnter = { [weak self] in self?.edgeEntered() }
        trigger.onExit = { [weak self] in self?.edgeExited() }

        // 内容数量变化（App 启动/退出、设置变化、检测到新工具）才重新排版
        model.objectWillChange.merge(with: settings.objectWillChange, store.$tools.map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.relayout(); self?.applyMode() }
            .store(in: &bag)

        let nc = NotificationCenter.default
        nc.publisher(for: NSMenu.didBeginTrackingNotification).sink { [weak self] _ in self?.menuTracking = true }.store(in: &bag)
        nc.publisher(for: NSMenu.didEndTrackingNotification).sink { [weak self] _ in self?.menuTracking = false }.store(in: &bag)
        nc.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.relayout(); self?.applyMode() }.store(in: &bag)

        // 全屏检测只在切换 App / 切换桌面时做一次，不定时轮询
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.activeSpaceDidChangeNotification).merge(with: ws.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFullscreen() }
            .store(in: &bag)
        // 前台 App 进入 / 退出全屏、要求隐藏 Dock 时系统会更新呈现选项
        presentationObservation = NSApp.observe(\.currentSystemPresentationOptions) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateFullscreen() }
        }
        // 系统 Dock 重启（例如隐藏/恢复系统 Dock）后，把触发条重新放到最前
        ws.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .filter { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.dock" }
            .delay(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyMode() }
            .store(in: &bag)

        relayout()
        // 启动时先读一次壁纸亮度（之后只用缓存），第一次弹出时不卡顿
        updateBackdrop()
        applyMode()
    }

    // MARK: 排版

    private var screen: NSScreen? { NSScreen.screens.first }

    private func makeView(_ m: DockMetrics) -> DockView {
        DockView(model: model, store: store, settings: settings, ui: ui, metrics: m, openSettings: openSettings)
    }

    /// 放不下时先把小组件切成只显示圆环，再逐步缩小图标（和系统 Dock 一样）
    private func relayout() {
        guard let screen else { return }
        var m = DockMetrics(icon: CGFloat(settings.iconSize), widgetsCompact: settings.widgetStyle == .compact,
                            magnify: settings.magnify, magnification: CGFloat(settings.magnifySize / settings.iconSize))
        // 临时的测量控制器：量完就释放，不常驻、不跟着数据刷新
        let measurer = NSHostingController(rootView: makeView(m))
        func width(_ m: DockMetrics) -> CGFloat {
            measurer.rootView = makeView(m)
            return measurer.sizeThatFits(in: CGSize(width: 100_000, height: 2_000)).width
        }
        func fits(_ m: DockMetrics, _ w: CGFloat) -> Bool { w <= screen.frame.width - 12 }
        var w = width(m)
        if !fits(m, w), settings.widgetStyle == .auto {
            m.widgetsCompact = true
            w = width(m)
        }
        while !fits(m, w), m.icon > 30 {
            m.icon -= 2
            w = width(m)
        }
        metrics = m
        ui.metrics = m
        contentWidth = ceil(min(w, screen.frame.width))
        host.rootView = makeView(m)
        if revealed { updateBackdrop() }
        // 窗口和屏幕同宽、Dock 居中：两端的名称标签、放大和拖动让位都不会被窗口边缘截断（透明部分不挡点击）
        let size = NSSize(width: screen.frame.width, height: ceil(m.totalHeight))
        panel.setFrame(NSRect(origin: origin(for: size, shown: revealed), size: size), display: false)
        let f = screen.frame
        trigger.setFrame(NSRect(x: f.minX, y: f.minY, width: f.width, height: 2), display: false)
    }

    /// 显示时停在屏幕底部，隐藏时整个窗口移到屏幕下方
    private func origin(for size: NSSize, shown: Bool = true) -> NSPoint {
        guard let f = screen?.frame else { return .zero }
        return NSPoint(x: (f.midX - size.width / 2).rounded(), y: shown ? f.minY + 2 : f.minY - size.height - 4)
    }

    // MARK: 显示模式

    /// 按自动隐藏处理：用户打开了自动隐藏，或者前台 App 全屏（和系统 Dock 一样，全屏时移到底边才出现）
    private var effectiveAutoHide: Bool { settings.autoHide || fullscreen }

    private func applyMode() {
        guard settings.dockEnabled else {
            revealWork?.cancel()
            orderOutWork?.cancel()
            slide.cancel()
            sliding = nil
            panel.orderOut(nil)
            trigger.orderOut(nil)
            revealed = false
            ui.revealed = false
            return
        }
        // 前台 App 要求完全隐藏 Dock（游戏、幻灯片放映等）：和系统 Dock 一样不出现
        if suppressed {
            revealWork?.cancel()
            trigger.orderOut(nil)
            conceal()
            return
        }
        if effectiveAutoHide {
            trigger.orderFrontRegardless()
            trigger.ignoresMouseEvents = false
            // 收起动画还没播完时不要提前移走窗口
            if revealed { startPointerWatch() } else if sliding == nil { panel.orderOut(nil) }
        } else {
            trigger.orderOut(nil)
            reveal()
        }
    }

    /// 前台 App 的全屏状态：优先用系统的呈现选项（原生全屏、要求隐藏 Dock），再看有没有盖满屏幕的无边框窗口
    /// 透明背景：看 Dock 显示位置背后是亮还是暗，决定文字颜色
    private func updateBackdrop() {
        guard settings.dockBackground == .clear, let screen else {
            if ui.backdropLight != nil { ui.backdropLight = nil }
            return
        }
        let barW = contentWidth - 2 * (metrics.growMax + 4)
        let x = origin(for: panel.frame.size, shown: true).x + barOriginX
        let rect = NSRect(x: x, y: screen.frame.minY + 2, width: barW, height: metrics.barHeight)
        let light = BackdropSampler.isLight(behind: rect, on: screen)
        if ui.backdropLight != light { ui.backdropLight = light }
    }

    private func updateFullscreen() {
        if revealed { updateBackdrop() }
        let opts = NSApp.currentSystemPresentationOptions
        let hide = opts.contains(.hideDock)
        let fs = !hide && (opts.contains(.fullScreen) || opts.contains(.autoHideDock) || Self.frontmostIsFullscreen())
        guard fs != fullscreen || hide != suppressed else { return }
        fullscreen = fs
        suppressed = hide
        applyMode()
    }

    /// 前台 App 有没有盖满整个屏幕的窗口（无边框全屏，比如视频播放器）
    static func frontmostIsFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let screen = NSScreen.screens.first?.frame,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.5,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { continue }
            if x <= 0, y <= 0, width >= screen.width, height >= screen.height { return true }
        }
        return false
    }

    // MARK: 显示 / 隐藏（节奏和系统 Dock 一样：底边停留 0.2 秒弹出，滑动 0.5 秒，都读取系统 Dock 的设置）

    private var revealWork: DispatchWorkItem?

    /// 鼠标碰到屏幕底边：停留满系统 Dock 的弹出延迟后再弹出，只是划过底边不会弹出
    private func edgeEntered() {
        guard settings.dockEnabled, !suppressed, !revealed else { return }
        updateFullscreen()
        guard effectiveAutoHide, !suppressed else { return }
        revealWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let f = self.screen?.frame, NSEvent.mouseLocation.y <= f.minY + 2 else { return }
            self.reveal()
        }
        revealWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + SystemDock.revealDelay, execute: w)
    }

    private func edgeExited() {
        revealWork?.cancel()
        revealWork = nil
    }

    private static let slideCurve = CubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    private static let baseBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    private func reveal() {
        orderOutWork?.cancel()
        revealWork?.cancel()
        if revealed, panel.isVisible {
            // 已经在显示或正在弹出；只有位置不对（比如被其他改动打断）时直接归位
            let target = origin(for: panel.frame.size, shown: true)
            if sliding != true, panel.frame.origin != target { panel.setFrameOrigin(target) }
            return
        }
        revealed = true
        ui.revealed = true
        model.refreshTrash()
        updateBackdrop()
        let size = panel.frame.size
        if !panel.isVisible {
            // 全屏的 App 里也能叫出来（和系统 Dock 一样）；平时不加这个标记，切到全屏空间时不会带过去
            panel.collectionBehavior = fullscreen ? Self.baseBehavior.union(.fullScreenAuxiliary) : Self.baseBehavior
            panel.setFrameOrigin(origin(for: size, shown: false))
            panel.orderFrontRegardless()
        }
        // 整个窗口从屏幕下方滑上来，时长和曲线跟系统 Dock 一致
        sliding = true
        slide.move(to: origin(for: size, shown: true), duration: SystemDock.slideDuration, curve: Self.slideCurve) { [weak self] in
            self?.sliding = nil
        }
        startPointerWatch()
    }

    // 隐藏判断：只在 Dock 显示期间，每 0.1 秒读一次鼠标的真实位置，离开 Dock 就收起（和系统 Dock 一样）。
    // 不依赖「鼠标进入/离开」事件——Dock 在鼠标下面收起时系统不会补发离开事件，状态会卡住。
    private var pointerWatch: Timer?
    private var outsideSince: Date?

    private func startPointerWatch() {
        outsideSince = nil
        guard effectiveAutoHide, pointerWatch == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        pointerWatch = t
    }

    private func stopPointerWatch() {
        pointerWatch?.invalidate()
        pointerWatch = nil
        outsideSince = nil
    }

    /// Dock 条左边缘在托管视图里的横坐标
    private var barOriginX: CGFloat { (host.bounds.width - contentWidth) / 2 + metrics.growMax + 4 }

    /// Dock 条在屏幕上的区域
    private var barScreenRect: NSRect {
        let f = panel.frame
        let barW = contentWidth - 2 * (metrics.growMax + 4)
        return NSRect(x: f.minX + barOriginX, y: f.minY, width: barW, height: metrics.barHeight)
    }

    /// 判断鼠标是否还在 Dock 上（放大时向上、向两侧扩展）
    private var dockHotRect: NSRect {
        let m = metrics
        let magnified = ui.pointerX != nil ? m.icon * (m.maxScale - 1) : 0
        let b = barScreenRect
        return NSRect(x: b.minX - m.growMax - 4, y: b.minY - 4,
                      width: b.width + 2 * (m.growMax + 4), height: b.height + magnified + 10)
    }

    // MARK: 拖放

    var dragIconSize: CGFloat { metrics.icon }

    func dragItem(atX x: CGFloat) -> (id: String, url: URL, image: NSImage)? {
        guard let hit = hitIcon(atBarX: x - barOriginX), hit.id != "trash", hit.id != model.finder?.id,
              let item = model.item(id: hit.id) else { return nil }
        let id = hit.id
        return (id, item.url, model.icon(for: item))
    }

    func dragBegan(id: String) {
        ui.pointer(nil)
        ui.pointerX = nil
        ui.hovered = nil
        ui.dragID = id
        showingRemove = false
    }

    /// 拖到 Dock 外面时，图标上方出现「移除」（和系统 Dock 一样）
    func dragMoved(to screenPoint: NSPoint, session: NSDraggingSession) {
        guard let id = ui.dragID, model.pinned.contains(where: { $0.id == id }) else { return }
        let outside = !barScreenRect.insetBy(dx: -10, dy: -40).contains(screenPoint)
        guard outside != showingRemove, let item = model.item(id: id) else { return }
        showingRemove = outside
        let icon = model.icon(for: item)
        let image = outside ? Self.removeImage(icon: icon, size: metrics.icon) : icon
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSURL.self], searchOptions: [:]) { dragItem, _, _ in
            let f = dragItem.draggingFrame
            let size = image.size
            dragItem.setDraggingFrame(NSRect(x: f.midX - size.width / 2, y: f.minY, width: size.width, height: size.height), contents: image)
        }
    }

    func dragEnded(at screenPoint: NSPoint, operation: NSDragOperation) {
        defer {
            ui.dragID = nil
            ui.dropIndex = nil
            ui.dropTarget = nil
            showingRemove = false
        }
        guard let id = ui.dragID, operation.isEmpty else { return }
        // 拖到 Dock 外面松手：从 Dock 移除（正在运行但没固定的 App 不能移除，会回到原位）
        if !barScreenRect.insetBy(dx: -10, dy: -40).contains(screenPoint), model.pinned.contains(where: { $0.id == id }) {
            model.remove(id)
            NSAnimationEffect.poof.show(centeredAt: screenPoint, size: NSSize(width: metrics.icon, height: metrics.icon))
        }
    }

    private static func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private static func isAppOrFolder(_ url: URL) -> Bool {
        if url.pathExtension == "app" { return true }
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
            && !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    func dropUpdated(_ info: NSDraggingInfo, x: CGFloat) -> NSDragOperation {
        guard let L = ui.layout else { return [] }
        let xb = x - barOriginX
        // 从 Dock 里拖动：排序，拖到废纸篓 = 移除
        if let id = ui.dragID {
            if L.item(at: xb) == "trash", model.pinned.contains(where: { $0.id == id }) {
                setDrop(index: nil, target: "trash"); return .move
            }
            setDrop(index: L.insertionIndex(at: xb, excluding: id), target: nil)
            return ui.dropIndex == nil ? [] : .move
        }
        let urls = Self.urls(info)
        guard !urls.isEmpty else { return [] }
        // 从外面拖进 App / 文件夹：插入到固定区
        if urls.allSatisfy(Self.isAppOrFolder), let idx = L.insertionIndex(at: xb, excluding: nil) {
            setDrop(index: idx, target: nil); return .copy
        }
        // 文件拖到 App 图标上 = 用它打开；拖到文件夹 = 放进去；拖到废纸篓 = 移到废纸篓
        if let target = L.item(at: xb) {
            if target == "trash" { setDrop(index: nil, target: target); return .move }
            guard let item = model.item(id: target) else { setDrop(index: nil, target: nil); return [] }
            switch item.kind {
            case .folder:
                setDrop(index: nil, target: target)
                return NSEvent.modifierFlags.contains(.option) ? .copy : .move
            case .app where accepts(info, app: item, urls: urls):
                setDrop(index: nil, target: target); return .copy
            default:
                setDrop(index: nil, target: nil); return []
            }
        }
        setDrop(index: nil, target: nil)
        return []
    }

    private func setDrop(index: Int?, target: String?) {
        if ui.dropIndex != index { ui.dropIndex = index }
        if ui.dropTarget != target { ui.dropTarget = target }
    }

    func dropExited() { setDrop(index: nil, target: nil) }

    func performDrop(_ info: NSDraggingInfo, x: CGFloat) -> Bool {
        defer { setDrop(index: nil, target: nil) }
        if let id = ui.dragID {
            if ui.dropTarget == "trash" {
                model.remove(id)
                NSAnimationEffect.poof.show(centeredAt: NSEvent.mouseLocation, size: NSSize(width: metrics.icon, height: metrics.icon))
            } else if let idx = ui.dropIndex {
                model.move(id, to: idx)
            }
            return true
        }
        let urls = Self.urls(info)
        if let idx = ui.dropIndex {
            for (k, u) in urls.enumerated() { model.insert(u, at: idx + k) }
            return true
        }
        if let t = ui.dropTarget {
            if t == "trash" {
                model.trash(urls)
            } else if let item = model.item(id: t) {
                if item.kind == .folder {
                    model.drop(urls, into: item, copy: NSEvent.modifierFlags.contains(.option))
                } else {
                    model.open(urls, with: item)
                }
            }
            return true
        }
        return false
    }

    /// 这个 App 能不能打开拖进来的文件（同一次拖动只算一次）
    private var acceptCache: (seq: Int, id: String, ok: Bool)?

    private func accepts(_ info: NSDraggingInfo, app: DockModel.Item, urls: [URL]) -> Bool {
        if NSEvent.modifierFlags.contains([.command, .option]) { return true }
        if let c = acceptCache, c.seq == info.draggingSequenceNumber, c.id == app.id { return c.ok }
        let ok = urls.allSatisfy { u in
            NSWorkspace.shared.urlsForApplications(toOpen: u).contains { $0.resolvingSymlinksInPath().path == app.id }
        }
        acceptCache = (info.draggingSequenceNumber, app.id, ok)
        return ok
    }

    // MARK: 菜单（结构、文案、位置都和系统 Dock 一样）

    private var fisheye: Fisheye? {
        guard let L = ui.layout else { return nil }
        return Fisheye(pointer: ui.menuOpen ? ui.menuPointer : ui.pointerX, lower: metrics.padH,
                       upper: L.trashCenter + metrics.icon / 2, metrics: metrics)
    }

    /// 按放大后的真实位置找图标：返回 id 和它在 Dock 条里的原始中心
    private func hitIcon(atBarX x: CGFloat) -> (id: String, center: CGFloat)? {
        guard let L = ui.layout, let fe = fisheye else { return nil }
        var best: (id: String, center: CGFloat, d: CGFloat)?
        for (id, c) in L.allIcons {
            let d = abs(c + fe.shift(at: c) - x)
            if d <= metrics.icon * fe.scale(at: c) / 2 + metrics.spacing / 2, d < (best?.d ?? .infinity) { best = (id, c, d) }
        }
        return best.map { ($0.id, $0.center) }
    }

    func isIcon(at point: NSPoint) -> Bool { hitIcon(atBarX: point.x - barOriginX) != nil }

    private let menu = DockMenuController()

    func showMenu(at point: NSPoint) -> Bool {
        guard let L = ui.layout, let fe = fisheye else { return false }
        let x = point.x - barOriginX
        let entries: [DockMenuEntry]
        let centerX: CGFloat, top: CGFloat
        var target: String?
        if x > L.trashCenter + metrics.icon / 2 + metrics.spacing {
            // AI 小组件：同样的菜单样式，出现在小组件上方
            entries = widgetMenu(activity: ui.hovered == "w-activity")
            centerX = point.x
            top = metrics.padBottom + metrics.dotRow + metrics.icon
        } else if let hit = hitIcon(atBarX: x) {
            entries = hit.id == "trash" ? trashMenu() : itemMenu(hit.id)
            centerX = barOriginX + hit.center + fe.shift(at: hit.center)
            top = metrics.padBottom + metrics.dotRow + metrics.icon * fe.scale(at: hit.center)
            target = hit.id
        } else {
            entries = dockMenu()
            centerX = point.x
            top = metrics.barHeight
        }
        guard !entries.isEmpty else { return true }
        // 菜单打开期间放大保持不动、名称标签隐藏、被点的图标变暗（和系统 Dock 一样）
        ui.menuPointer = ui.pointerX
        ui.menuTarget = target
        ui.menuOpen = true
        let f = panel.frame
        // 尖角指向图标顶端上方一点（系统 Dock 大约留 14pt）
        menu.show(entries, tip: NSPoint(x: f.minX + centerX, y: f.minY + top + 14)) { [weak self] in
            guard let self else { return }
            self.ui.menuOpen = false
            self.ui.menuTarget = nil
            if !self.barScreenRect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) { self.ui.pointer(nil) }
        }
        return true
    }

    /// App / 文件夹图标的菜单（结构和文案照搬系统 Dock）
    private func itemMenu(_ id: String) -> [DockMenuEntry] {
        guard let item = model.item(id: id) else { return [] }
        let S: (String) -> String = DockStrings.s
        let model = model
        let isFinder = id == model.finder?.id
        let pinned = model.isPinned(item)
        let showInFinder = ActionItem(S("SHOW_IN_FINDER"), enabled: item.kind != .missing) { model.revealInFinder(item) }
        let remove = ActionItem(S("REMOVE_FROM_DOCK")) { model.remove(item.id) }
        var entries: [DockMenuEntry] = []

        if item.kind == .app, let app = model.runningApp(item) {
            if !isFinder {
                entries.append(DockMenuEntry(title: S("OPTIONS"), submenu: [
                    ActionItem(S("KEEP_IN_DOCK"), state: pinned ? .on : .off) { model.togglePin(item) },
                    loginItem(item), showInFinder,
                ]))
                entries.append(.separator)
            }
            entries.append(DockMenuEntry(title: S("SHOW_ALL_WINDOWS"), action: { AppActions.showAllWindows(app) }))
            if app.isHidden {
                entries.append(DockMenuEntry(title: S("SHOW"), action: { app.unhide(); app.activate() }))
            } else {
                entries.append(DockMenuEntry(title: S("HIDE"), action: { app.hide() },
                                             alternate: (S("HIDE_OTHERS"), { AppActions.hideOthers(app) })))
            }
            if isFinder {
                // 访达不能退出；按住 Option 时多一项「重启」
                if NSEvent.modifierFlags.contains(.option) {
                    entries.append(DockMenuEntry(title: S("RELAUNCH"), action: { AppActions.relaunchFinder(app) }))
                }
            } else {
                entries.append(DockMenuEntry(title: S("QUIT"), action: { app.terminate() },
                                             alternate: (S("FORCE_QUIT"), { app.forceTerminate() })))
            }
            return entries
        }

        switch item.kind {
        case .folder:
            entries.append(DockMenuEntry(title: S("OPTIONS"), submenu: [remove, showInFinder]))
            entries.append(.separator)
            entries.append(DockMenuEntry(title: S("OPEN_IN_FINDER"), action: { model.open(item) }))
        case .app, .missing:
            var options: [NSMenuItem] = []
            if pinned {
                options.append(remove)
            } else {
                // 最近使用的 App：可以留在 Dock，也可以从最近使用里移除
                options.append(ActionItem(S("KEEP_IN_DOCK")) { model.togglePin(item) })
                options.append(ActionItem(S("REMOVE_FROM_DOCK")) { model.dismissRecent(item) })
            }
            if item.kind == .app { options.append(loginItem(item)) }
            options.append(showInFinder)
            entries.append(DockMenuEntry(title: S("OPTIONS"), submenu: options))
            entries.append(.separator)
            entries.append(DockMenuEntry(title: S("OPEN"), action: { model.open(item) }))
        }
        return entries
    }

    private func loginItem(_ item: DockModel.Item) -> NSMenuItem {
        let on = LoginItems.contains(item.id) ?? false
        return ActionItem(DockStrings.s("OPEN_AT_LOGIN"), state: on ? .on : .off) { LoginItems.set(item.id, on: !on) }
    }

    private func trashMenu() -> [DockMenuEntry] {
        let model = model
        return [
            DockMenuEntry(title: DockStrings.s("OPEN"), action: { model.openTrash() }),
            .separator,
            DockMenuEntry(title: DockStrings.s("EMPTY_TRASH"), enabled: model.trashFull, action: { model.confirmEmptyTrash() }),
        ]
    }

    /// AI 小组件的菜单；AI 活动小组件多两项：范围、显示内容
    private func widgetMenu(activity: Bool) -> [DockMenuEntry] {
        let settings = settings, store = store
        var entries: [DockMenuEntry] = []
        if activity {
            entries.append(DockMenuEntry(title: L("范围"), submenu: [
                ActionItem(L("24 小时"), state: settings.activityRange == 0 ? .on : .off) { settings.activityRange = 0 },
                ActionItem(L("7 天"), state: settings.activityRange == 1 ? .on : .off) { settings.activityRange = 1 },
            ]))
            entries.append(DockMenuEntry(title: L("显示"), submenu: [
                ActionItem(L("使用时长"), state: settings.activityMetric == 0 ? .on : .off) { settings.activityMetric = 0 },
                ActionItem(L("Token 用量"), state: settings.activityMetric == 1 ? .on : .off) { settings.activityMetric = 1 },
            ]))
            entries.append(.separator)
        }
        entries.append(DockMenuEntry(title: L("立即刷新额度"), action: { store.refreshNow() }))
        entries.append(DockMenuEntry(title: L("AI Dock 设置…"), action: { [weak self] in self?.openSettings() }))
        return entries
    }

    /// 在 Dock 分隔线 / 空白处右键：和系统 Dock 一样的设置菜单
    private func dockMenu() -> [DockMenuEntry] {
        let S: (String) -> String = DockStrings.s
        let settings = settings
        let effect = SystemDock.minimizeEffect
        return [
            DockMenuEntry(title: S(settings.autoHide ? "TURN_HIDING_OFF" : "TURN_HIDING_ON"), action: { settings.autoHide.toggle() }),
            DockMenuEntry(title: S(settings.magnify ? "TURN_MAG_OFF" : "TURN_MAG_ON"), action: { settings.magnify.toggle() }),
            DockMenuEntry(title: S("MINIMIZE_USING"), submenu: [
                ActionItem(S("GENIE_EFFECT"), state: effect == "genie" ? .on : .off) { SystemDock.setMinimizeEffect("genie") },
                ActionItem(S("SCALE_EFFECT"), state: effect == "scale" ? .on : .off) { SystemDock.setMinimizeEffect("scale") },
            ]),
            .separator,
            DockMenuEntry(title: S("DOCK_SETTINGS"), action: { [weak self] in self?.openSettings() }),
        ]
    }

    /// 拖出 Dock 时的图标：上方带「移除」标签
    private static func removeImage(icon: NSImage, size: CGFloat) -> NSImage {
        let text = L("移除") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let ts = text.size(withAttributes: attrs)
        let pillW = ts.width + 20, pillH: CGFloat = 22
        let w = max(size, pillW), h = size + pillH + 6
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            icon.draw(in: NSRect(x: (w - size) / 2, y: 0, width: size, height: size))
            let pill = NSRect(x: (w - pillW) / 2, y: size + 6, width: pillW, height: pillH)
            NSColor(white: 0.12, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
            text.draw(at: NSPoint(x: pill.midX - ts.width / 2, y: pill.midY - ts.height / 2), withAttributes: attrs)
            return true
        }
    }

    private func checkPointer() {
        guard effectiveAutoHide, revealed, let screen else { stopPointerWatch(); return }
        let p = NSEvent.mouseLocation
        let atEdge = p.y <= screen.frame.minY + 3 && p.x >= screen.frame.minX && p.x <= screen.frame.maxX
        let keep = atEdge || dockHotRect.contains(p) || Focus.hasPopover || menuTracking || ui.menuOpen || ui.dragID != nil
        if keep {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) >= 0.08 { conceal() }
        } else {
            outsideSince = Date()
        }
    }

    private func conceal() {
        revealWork?.cancel()
        guard revealed else { return }
        stopPointerWatch()
        revealed = false
        ui.hovered = nil
        ui.hoveredIndex = nil
        ui.pointerX = nil
        ui.overDock = false
        ui.revealed = false
        orderOutWork?.cancel()
        let size = panel.frame.size
        sliding = false
        slide.move(to: origin(for: size, shown: false), duration: SystemDock.slideDuration, curve: Self.slideCurve) { [weak self] in
            guard let self else { return }
            self.sliding = nil
            // 完全收起后移出屏幕合成，不再占用 GPU
            if !self.revealed {
                self.panel.orderOut(nil)
                self.panel.collectionBehavior = Self.baseBehavior
            }
        }
    }
}
