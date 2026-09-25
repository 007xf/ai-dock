import AppKit
import Combine

/// Dock 里的 App / 文件夹。固定列表第一次从系统 Dock 导入，之后由 AI Dock 自己保存。
@MainActor
final class DockModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        /// missing：固定的项目已被删除或移动（和系统 Dock 一样显示问号）
        enum Kind { case app, folder, missing }
        let id: String          // 文件路径
        let url: URL
        let name: String
        let bundleID: String?
        let kind: Kind
    }

    @Published private(set) var pinned: [Item] = []
    /// 正在运行但没有固定的 App，以及系统 Dock 的「最近使用的 App」
    @Published private(set) var extraRunning: [Item] = []
    /// 系统 Dock 设置里的「显示已打开的应用程序的指示灯」
    @Published private(set) var showIndicators = SystemDock.showsIndicators
    @Published private(set) var running: Set<String> = []
    @Published private(set) var trashFull = false
    /// 正在启动的 App（图标跳动，直到启动完成）
    @Published private(set) var launching: Set<String> = []

    private let finderPath = "/System/Library/CoreServices/Finder.app"
    private var iconCache: [String: NSImage] = [:]
    private var bag = Set<AnyCancellable>()
    private let defaultsKey = "pinnedItems"
    /// 用户从「最近使用」里移除的 App（再次打开后会回来，和系统 Dock 一样）
    private var dismissedRecents = Set(UserDefaults.standard.stringArray(forKey: "dismissedRecents") ?? [])

    init(demo: [String]? = nil) {
        if let demo {
            pinned = demo.compactMap { Self.item(path: $0) }
            running = Set(pinned.prefix(3).map(\.id))
            return
        }
        if let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) {
            pinned = saved.compactMap { Self.item(path: $0, allowMissing: true) }
        } else {
            importFromSystemDock()
        }
        refreshRunning()
        refreshTrash()
        // 只监听系统通知，不轮询
        let nc = NSWorkspace.shared.notificationCenter
        Publishers.MergeMany(
            nc.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            nc.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.refreshRunning() }
        .store(in: &bag)
    }

    private(set) lazy var finder: Item? = Self.item(path: finderPath)

    // MARK: 数据

    func importFromSystemDock() {
        var paths: [String] = []
        let url = FileManager.default.home.appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for section in ["persistent-apps", "persistent-others"] {
                for tile in plist[section] as? [[String: Any]] ?? [] {
                    guard let td = tile["tile-data"] as? [String: Any],
                          let fd = td["file-data"] as? [String: Any],
                          let s = fd["_CFURLString"] as? String,
                          let u = URL(string: s), u.isFileURL else { continue }
                    paths.append(u.path)
                }
            }
        }
        pinned = paths.filter { $0 != finderPath }.compactMap { Self.item(path: $0, allowMissing: true) }
        save()
        refreshRunning()
    }

    private func save() {
        UserDefaults.standard.set(pinned.map(\.id), forKey: defaultsKey)
    }

    private static func item(path: String, allowMissing: Bool = false) -> Item? {
        let raw = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard FileManager.default.fileExists(atPath: raw) else {
            guard allowMissing else { return nil }
            let name = (raw as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return Item(id: raw, url: URL(fileURLWithPath: raw), name: name, bundleID: nil, kind: .missing)
        }
        // 解析符号链接（例如 /Applications/Safari.app），避免图标带「替身」箭头、运行状态对不上
        let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        let p = url.path
        let isApp = url.pathExtension == "app"
        let bundle = isApp ? Bundle(url: url) : nil
        let name = FileManager.default.displayName(atPath: p).replacingOccurrences(of: ".app", with: "")
        return Item(id: p, url: url, name: name, bundleID: bundle?.bundleIdentifier, kind: isApp ? .app : .folder)
    }

    func refreshRunning() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
        let paths = apps.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
        let set = Set(paths)
        if set != running { running = set }
        if !dismissedRecents.isDisjoint(with: set) {
            dismissedRecents.subtract(set)
            UserDefaults.standard.set(Array(dismissedRecents), forKey: "dismissedRecents")
        }
        let known = Set(pinned.map(\.id)).union([finder?.id ?? finderPath])
        var extraPaths = paths.filter { !known.contains($0) }
        for p in Self.recentPaths() where !known.contains(p) && !extraPaths.contains(p) && !dismissedRecents.contains(p) {
            extraPaths.append(p)
        }
        let extra = extraPaths.compactMap { Self.item(path: $0) }
        if extra != extraRunning { extraRunning = extra }
        if !launching.isDisjoint(with: set) { launching.subtract(set) }
        let indicators = SystemDock.showsIndicators
        if indicators != showIndicators { showIndicators = indicators }
    }

    /// 系统 Dock 记录的「最近使用的 App」（系统设置里打开了「在程序坞中显示建议和最近使用的 App」时才显示）
    private static func recentPaths() -> [String] {
        guard SystemDock.showsRecents else { return [] }
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let tiles = CFPreferencesCopyAppValue("recent-apps" as CFString, domain) as? [[String: Any]] ?? []
        return tiles.compactMap { tile in
            guard let td = tile["tile-data"] as? [String: Any], let fd = td["file-data"] as? [String: Any],
                  let s = fd["_CFURLString"] as? String, let u = URL(string: s), u.isFileURL else { return nil }
            return u.resolvingSymlinksInPath().path
        }
    }

    /// 从「最近使用」里移除
    func dismissRecent(_ item: Item) {
        dismissedRecents.insert(item.id)
        UserDefaults.standard.set(Array(dismissedRecents), forKey: "dismissedRecents")
        refreshRunning()
    }

    /// ~/.Trash 受系统隐私保护，读不到时按「空」处理
    func refreshTrash() {
        let trash = FileManager.default.home.appendingPathComponent(".Trash").path
        let full = ((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? []).contains { $0 != ".DS_Store" }
        if full != trashFull { trashFull = full }
    }

    // MARK: 图标（缩小到显示尺寸再缓存，避免把 1024px 的原图常驻内存）

    func icon(for item: Item) -> NSImage {
        if let cached = iconCache[item.id] { return cached }
        let img = item.kind == .missing ? Self.missingIcon : Self.downsample(NSWorkspace.shared.icon(forFile: item.id), points: 80)
        iconCache[item.id] = img
        return img
    }

    /// 找不到原始项目时的问号图标（通用 App 图标上叠一个问号，和系统 Dock 一样）
    private static let missingIcon: NSImage = {
        let base = downsample(NSWorkspace.shared.icon(for: .applicationBundle), points: 80)
        return NSImage(size: NSSize(width: 80, height: 80), flipped: false) { r in
            base.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.55)
            let q = "?" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 46, weight: .bold),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.95)]
            let s = q.size(withAttributes: attrs)
            q.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
            return true
        }
    }()

    lazy var trashEmptyIcon: NSImage = Self.downsample(NSImage(named: NSImage.trashEmptyName) ?? NSImage(), points: 80)
    lazy var trashFullIcon: NSImage = Self.downsample(NSImage(named: NSImage.trashFullName) ?? NSImage(), points: 80)

    nonisolated static func downsample(_ image: NSImage, points: CGFloat) -> NSImage {
        let px = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: px * 4, bitsPerPixel: 32) else { return image }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }

    // MARK: 操作

    /// 点按图标，修饰键和系统 Dock 一样：⌘ 在访达中显示；⌥ 切换并隐藏刚才的 App；⌘⌥ 切换并隐藏其他所有 App
    func open(_ item: Item, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection([.command, .option])
        if flags == .command { revealInFinder(item); return }
        guard item.kind == .app, flags.contains(.option) else { open(item); return }
        let previous = NSWorkspace.shared.frontmostApplication
        open(item) { app in
            if flags == [.command, .option] {
                AppActions.hideOthers(app)
            } else if let previous, previous != app, previous.processIdentifier != getpid() {
                previous.hide()
            }
        }
    }

    func open(_ item: Item, then: ((NSRunningApplication) -> Void)? = nil) {
        // 原始项目已被删除或移动：和系统 Dock 一样提示，可以直接从 Dock 移除
        guard item.kind != .missing, FileManager.default.fileExists(atPath: item.url.path) else {
            let answer = Self.alert(L("找不到“%@”的原始项目。", item.name), L("这个项目可能已被移动、删除或重命名。"),
                                    buttons: [DockStrings.s("REMOVE_FROM_DOCK"), L("好")])
            if answer == .alertFirstButtonReturn { remove(item.id) }
            return
        }
        switch item.kind {
        case .missing:
            break
        case .app:
            // 没在运行的 App：图标跳动直到启动完成（最多 12 秒）
            if !running.contains(item.id), SystemDock.launchBounce {
                launching.insert(item.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.launching.remove(item.id) }
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: item.url, configuration: cfg) { [weak self] app, error in
                if let app, let then { DispatchQueue.main.async { then(app) } }
                guard let error else { return }
                DispatchQueue.main.async { [weak self] in
                    // 打不开：停止跳动并说明原因
                    self?.launching.remove(item.id)
                    _ = Self.alert(L("无法打开“%@”。", item.name), error.localizedDescription, buttons: [L("好")])
                }
            }
        case .folder:
            if !NSWorkspace.shared.open(item.url) {
                _ = Self.alert(L("无法打开“%@”。", item.name), "", buttons: [L("好")])
            }
        }
    }

    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.home.appendingPathComponent(".Trash"))
    }

    func isPinned(_ item: Item) -> Bool { pinned.contains { $0.id == item.id } }

    func togglePin(_ item: Item) {
        if isPinned(item) { pinned.removeAll { $0.id == item.id } } else { pinned.append(item) }
        save()
        refreshRunning()
    }

    // MARK: 拖动排序 / 添加 / 移除（index 按「去掉被拖图标后的固定列表」计算）

    func item(id: String) -> Item? {
        ([finder].compactMap { $0 } + pinned + extraRunning).first { $0.id == id }
    }

    func move(_ id: String, to index: Int) {
        if let from = pinned.firstIndex(where: { $0.id == id }) {
            let it = pinned.remove(at: from)
            pinned.insert(it, at: min(max(0, index), pinned.count))
            save()
        } else if let it = extraRunning.first(where: { $0.id == id }) {
            // 把正在运行但没固定的 App 拖进固定区 = 在 Dock 中保留
            insert(it.url, at: index)
        }
    }

    func insert(_ url: URL, at index: Int) {
        guard let it = Self.item(path: url.path), it.id != finder?.id else { return }
        if let i = pinned.firstIndex(where: { $0.id == it.id }) { pinned.remove(at: i) }
        pinned.insert(it, at: min(max(0, index), pinned.count))
        save()
        refreshRunning()
    }

    func remove(_ id: String) {
        pinned.removeAll { $0.id == id }
        save()
        refreshRunning()
    }

    /// 把文件交给某个 App 打开（文件拖到 App 图标上）
    func open(_ urls: [URL], with item: Item) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: item.url, configuration: cfg) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                _ = Self.alert(L("“%@”无法打开这些文件。", item.name), error.localizedDescription, buttons: [L("好")])
            }
        }
    }

    /// 文件拖到废纸篓：移到废纸篓（可以从废纸篓放回）
    func trash(_ urls: [URL]) {
        var failed: Error?
        for u in urls {
            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil) } catch { failed = error }
        }
        refreshTrash()
        if let failed { _ = Self.alert(L("无法将项目移到废纸篓。"), failed.localizedDescription, buttons: [L("好")]) }
    }

    /// 文件拖到 Dock 里的文件夹上：同一个磁盘上移动，跨磁盘或按住 ⌥ 时拷贝（和访达一样）
    func drop(_ urls: [URL], into folder: Item, copy: Bool) {
        let fm = FileManager.default
        func volume(_ u: URL) -> NSObject? {
            (try? u.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        let target = volume(folder.url)
        var failed: Error?
        for u in urls {
            let dest = folder.url.appendingPathComponent(u.lastPathComponent)
            do {
                if copy || target == nil || volume(u).map({ !$0.isEqual(target) }) ?? true {
                    try fm.copyItem(at: u, to: dest)
                } else {
                    try fm.moveItem(at: u, to: dest)
                }
            } catch { failed = error }
        }
        if let failed { Self.alert(L("无法将项目放到“%@”。", folder.name), failed.localizedDescription, buttons: [L("好")]) }
    }

    /// 和访达一样先确认：清倒后不能恢复
    func confirmEmptyTrash() {
        let answer = Self.alert(L("确定要永久抹掉废纸篓中的项目吗？"), L("此操作不能撤销。"),
                                buttons: [DockStrings.s("EMPTY_TRASH"), L("取消")])
        if answer == .alertFirstButtonReturn { emptyTrash() }
    }

    /// 清倒废纸篓：交给访达执行（和访达里「清倒废纸篓」一样）
    func emptyTrash() {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty the trash")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        refreshTrash()
        if let err {
            _ = Self.alert(L("无法清倒废纸篓。"), (err[NSAppleScript.errorMessage] as? String) ?? "", buttons: [L("好")])
        }
    }

    /// 和系统 Dock 一样的提示框；弹出时临时借用前台，关闭后还回去
    @discardableResult
    static func alert(_ title: String, _ info: String, buttons: [String]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.alertStyle = .warning
        buttons.forEach { a.addButton(withTitle: $0) }
        Focus.borrow()
        let r = a.runModal()
        Focus.giveBack()
        return r
    }

    func runningApp(_ item: Item) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.resolvingSymlinksInPath().path == item.id }
    }

    func hide(_ item: Item) { runningApp(item)?.hide() }
    func quit(_ item: Item) { runningApp(item)?.terminate() }
    func forceQuit(_ item: Item) { runningApp(item)?.forceTerminate() }
    func revealInFinder(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
}
