import AppKit
import SwiftUI

/// Dock 菜单里的一项
struct DockMenuEntry {
    var title = ""
    var enabled = true
    var action: (() -> Void)?
    /// 按住 Option 时换成的项（例如「退出」→「强制退出」）
    var alternate: (title: String, action: () -> Void)?
    /// 子菜单（例如「选项」），用系统菜单弹出，和系统 Dock 一样
    var submenu: [NSMenuItem]?
    var isSeparator = false

    static let separator = DockMenuEntry(isSeparator: true)

    var selectable: Bool { !isSeparator && enabled }
}

@MainActor
final class DockMenuState: ObservableObject {
    @Published var option = false
    @Published var highlighted: Int?
}

/// 菜单尺寸（和 macOS 26 的菜单一致）
enum DockMenuMetrics {
    static let rowHeight: CGFloat = 24
    static let separatorHeight: CGFloat = 11
    static let padV: CGFloat = 5
    static let tail: CGFloat = 9
    static let tailWidth: CGFloat = 20
    static let radius: CGFloat = 12

    /// 第 i 项顶端到菜单顶端的距离
    static func top(of index: Int, in entries: [DockMenuEntry]) -> CGFloat {
        padV + entries.prefix(index).reduce(0) { $0 + ($1.isSeparator ? separatorHeight : rowHeight) }
    }
}

struct DockMenuView: View {
    let entries: [DockMenuEntry]
    @ObservedObject var state: DockMenuState
    let onPick: (Int) -> Void
    let onHover: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries.indices, id: \.self) { i in
                let e = entries[i]
                if e.isSeparator {
                    Rectangle().fill(Color.primary.opacity(0.13)).frame(height: 1)
                        .padding(.horizontal, 16)
                        .frame(height: DockMenuMetrics.separatorHeight)
                } else {
                    row(i, e)
                }
            }
        }
        .padding(.vertical, DockMenuMetrics.padV)
        .padding(.bottom, DockMenuMetrics.tail)
        .fixedSize()
    }

    private func row(_ i: Int, _ e: DockMenuEntry) -> some View {
        let hi = state.highlighted == i && e.enabled
        let title = state.option ? (e.alternate?.title ?? e.title) : e.title
        return HStack(spacing: 0) {
            Text(title)
            Spacer(minLength: e.submenu == nil ? 20 : 28)
            if e.submenu != nil {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(hi ? Color.white : (e.enabled ? Color.primary : Color.secondary))
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: DockMenuMetrics.rowHeight, maxHeight: DockMenuMetrics.rowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hi ? Color.accentColor : Color.clear))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onHover { inside in onHover(inside ? i : nil) }
        .onTapGesture { onPick(i) }
    }
}

/// 可以接收键盘但不激活 App 的面板：菜单打开时菜单栏和前台 App 都不变（和系统 Dock 一样）
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 菜单外形：圆角矩形 + 底部指向图标的小尖角
private func menuPath(in r: NSRect, tailX: CGFloat) -> NSBezierPath {
    let m = DockMenuMetrics.self
    let body = NSRect(x: r.minX, y: r.minY + m.tail, width: r.width, height: r.height - m.tail)
    let path = NSBezierPath(roundedRect: body, xRadius: m.radius, yRadius: m.radius)
    let x = min(max(tailX, body.minX + m.radius + m.tailWidth / 2), body.maxX - m.radius - m.tailWidth / 2)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: x - m.tailWidth / 2, y: body.minY + 0.5))
    tail.curve(to: NSPoint(x: x, y: r.minY), controlPoint1: NSPoint(x: x - m.tailWidth / 4, y: body.minY),
               controlPoint2: NSPoint(x: x - 2, y: r.minY))
    tail.curve(to: NSPoint(x: x + m.tailWidth / 2, y: body.minY + 0.5), controlPoint1: NSPoint(x: x + 2, y: r.minY),
               controlPoint2: NSPoint(x: x + m.tailWidth / 4, y: body.minY))
    tail.close()
    path.append(tail)
    path.windingRule = .nonZero
    return path
}

/// 菜单描边
private final class MenuBorderView: NSView {
    var tailX: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        let path = menuPath(in: bounds.insetBy(dx: 0.25, dy: 0.25), tailX: tailX)
        path.lineWidth = 0.5
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(white: dark ? 1 : 0, alpha: dark ? 0.22 : 0.12).setStroke()
        path.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 和系统 Dock 一样的菜单：出现在图标正上方，带指向图标的小尖角；
/// 用不激活 App 的面板显示，菜单栏和当前 App 的焦点都不受影响
@MainActor
final class DockMenuController {
    private var panel: MenuPanel?
    private var entries: [DockMenuEntry] = []
    private let state = DockMenuState()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?
    private var submenuWork: DispatchWorkItem?
    private var submenuOpen = false

    var isOpen: Bool { panel != nil }

    /// 预览渲染：返回菜单视图（不显示窗口）
    static func previewView(_ entries: [DockMenuEntry], highlighted: Int?) -> NSView {
        let state = DockMenuState()
        state.highlighted = highlighted
        let host = NSHostingView(rootView: DockMenuView(entries: entries, state: state, onPick: { _ in }, onHover: { _ in }))
        let fit = host.fittingSize
        let size = NSSize(width: ceil(max(fit.width, 64)), height: ceil(fit.height))
        return makeRoot(host: host, size: size, tailX: size.width / 2)
    }

    /// tip：尖角指向的屏幕坐标（图标上方）
    func show(_ entries: [DockMenuEntry], tip: NSPoint, onClose: @escaping () -> Void) {
        close()
        self.entries = entries
        self.onClose = onClose
        state.highlighted = nil
        state.option = NSEvent.modifierFlags.contains(.option)

        let host = NSHostingView(rootView: DockMenuView(entries: entries, state: state,
                                                        onPick: { [weak self] in self?.pick($0) },
                                                        onHover: { [weak self] in self?.hover($0) }))
        let fit = host.fittingSize
        let size = NSSize(width: ceil(max(fit.width, 64)), height: ceil(fit.height))
        // 贴着屏幕边时菜单整体移进来，尖角仍然指向图标
        let screen = NSScreen.screens.first(where: { $0.frame.contains(tip) }) ?? NSScreen.screens.first
        var x = tip.x - size.width / 2
        if let vf = screen?.frame {
            x = min(max(x, vf.minX + 6), vf.maxX - size.width - 6)
        }
        let frame = NSRect(x: x.rounded(), y: tip.y.rounded(), width: size.width, height: size.height)
        let tailX = tip.x - frame.minX

        let p = MenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let root = Self.makeRoot(host: host, size: size, tailX: tailX)
        p.contentView = root

        // 淡入（系统菜单也是一闪即出，这里只做很短的淡入）
        root.wantsLayer = true
        p.makeKeyAndOrderFront(nil)
        p.invalidateShadow()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.1
        root.layer?.add(fade, forKey: "fade")
        panel = p
        installMonitors()
    }

    /// 菜单外观：系统菜单材质，裁成带尖角的形状，再描一圈细边
    static func makeRoot(host: NSView, size: NSSize, tailX: CGFloat) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let fx = NSVisualEffectView(frame: root.bounds)
        fx.material = .menu
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = NSImage(size: size, flipped: false) { r in
            NSColor.black.setFill()
            menuPath(in: r, tailX: tailX).fill()
            return true
        }
        fx.autoresizingMask = [.width, .height]
        root.addSubview(fx)
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        let border = MenuBorderView(frame: root.bounds)
        border.tailX = tailX
        root.addSubview(border)
        return root
    }

    func close() {
        submenuWork?.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        guard let p = panel else { return }
        panel = nil
        p.orderOut(nil)
        let done = onClose
        onClose = nil
        done?()
    }

    // MARK: 交互

    private func hover(_ i: Int?) {
        guard !submenuOpen else { return }
        submenuWork?.cancel()
        guard let i else {
            // 离开没有子菜单的行时取消高亮
            if let h = state.highlighted, entries[h].submenu == nil { state.highlighted = nil }
            return
        }
        state.highlighted = entries[i].selectable ? i : nil
        if entries[i].submenu != nil {
            let w = DispatchWorkItem { [weak self] in self?.openSubmenu(i) }
            submenuWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        }
    }

    private func pick(_ i: Int) {
        let e = entries[i]
        guard e.selectable else { return }
        if e.submenu != nil { openSubmenu(i); return }
        let action = state.option ? (e.alternate?.action ?? e.action) : e.action
        close()
        action?()
    }

    private func openSubmenu(_ i: Int) {
        guard let panel, let items = entries[i].submenu, !submenuOpen else { return }
        state.highlighted = i
        let menu = NSMenu()
        menu.autoenablesItems = false
        var picked = false
        for item in items {
            if let a = item as? ActionItem { a.onFire = { picked = true } }
            menu.addItem(item)
        }
        // 子菜单贴着这一行的右侧弹出（和系统 Dock 一样是普通菜单）
        let rowTop = panel.frame.maxY - DockMenuMetrics.top(of: i, in: entries)
        submenuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: panel.frame.maxX - 2, y: rowTop), in: nil)
        submenuOpen = false
        items.forEach { menu.removeItem($0) }
        if picked { close() }
    }

    private func move(_ delta: Int) {
        let selectable = entries.indices.filter { entries[$0].selectable }
        guard !selectable.isEmpty else { return }
        if let h = state.highlighted, let k = selectable.firstIndex(of: h) {
            state.highlighted = selectable[(k + delta + selectable.count) % selectable.count]
        } else {
            state.highlighted = delta > 0 ? selectable.first : selectable.last
        }
    }

    private func installMonitors() {
        // 键盘：上下选择、回车执行、→ 打开子菜单、Esc 关闭（和系统菜单一样）
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] ev in
            guard let self, self.panel != nil else { return ev }
            switch ev.keyCode {
            case 125: self.move(1)
            case 126: self.move(-1)
            case 36, 76, 49: if let h = self.state.highlighted { self.pick(h) }
            case 124: if let h = self.state.highlighted, self.entries[h].submenu != nil { self.openSubmenu(h) }
            case 53: self.close()
            default: break
            }
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] ev in
            self?.state.option = ev.modifierFlags.contains(.option)
            return ev
        }) { monitors.append(m) }
        // 点到菜单外面（包括 Dock 自己和其他 App）就关闭
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] ev in
            guard let self, let p = self.panel else { return ev }
            if ev.window !== p { self.close() }
            return ev
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        // 切换 App（例如 ⌘Tab）或切换桌面时也关闭
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
    }
}
