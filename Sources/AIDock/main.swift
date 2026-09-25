import AppKit

// 标准 AppKit 启动：菜单和快捷键完全由 AppDelegate 管理（不用 SwiftUI 的 App 生命周期）
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
