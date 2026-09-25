import AppKit

/// 前台焦点管理：弹窗 / 设置窗口需要 AI Dock 临时成为前台 App，
/// 用完立刻把前台还给之前的 App——否则 ⌘Q 等快捷键会误发给 AI Dock。
@MainActor
enum Focus {
    private static var previous: NSRunningApplication?

    /// 临时把 AI Dock 激活到前台，记下原来的前台 App
    static func borrow() {
        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            previous = front
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 屏幕上还有 AI Dock 的弹窗吗（Dock 小组件详情、菜单栏面板）
    static var hasPopover: Bool {
        NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    /// 设置窗口等普通窗口是否开着
    static var hasUserWindow: Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.styleMask.contains(.titled) }
    }

    /// 没有需要焦点的窗口时，把前台还给原来的 App（等窗口真正关掉后再判断）
    static func giveBack(force: Bool = false) {
        DispatchQueue.main.async {
            guard NSApp.isActive else { previous = nil; return }
            if !force, hasPopover || hasUserWindow { return }
            let target = previous ?? NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isHidden
            }
            previous = nil
            guard let target else { return }
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: target) }
            target.activate()
        }
    }
}
