import AppKit

/// 系统 Dock 自己的菜单文案：直接读系统 Dock 的本地化文件，和原生菜单一字不差（跟随 AI Dock 的界面语言）
@MainActor
enum DockStrings {
    private static var table: [String: String] = [:]
    private static var loadedFor: AppLanguage?

    private static var lproj: String {
        switch Loc.language {
        case .system, .zhHans: return "zh_CN"
        case .zhHant: return "zh_TW"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .es: return "es"
        case .fr: return "fr"
        case .de: return "de"
        }
    }

    /// 系统 Dock 的文件读不到时用的英文原文
    private static let fallback: [String: String] = [
        "OPTIONS": "Options", "KEEP_IN_DOCK": "Keep in Dock", "REMOVE_FROM_DOCK": "Remove from Dock",
        "OPEN_AT_LOGIN": "Open at Login", "SHOW_IN_FINDER": "Show in Finder", "SHOW_ALL_WINDOWS": "Show All Windows",
        "HIDE": "Hide", "HIDE_OTHERS": "Hide Others", "SHOW": "Show", "OPEN": "Open", "QUIT": "Quit",
        "FORCE_QUIT": "Force Quit", "RELAUNCH": "Relaunch", "EMPTY_TRASH": "Empty Trash",
        "OPEN_FILENAME": "Open “%@”", "OPEN_IN_FINDER": "Open in Finder",
        "TURN_HIDING_ON": "Turn Hiding On", "TURN_HIDING_OFF": "Turn Hiding Off",
        "TURN_MAG_ON": "Turn Magnification On", "TURN_MAG_OFF": "Turn Magnification Off",
        "MINIMIZE_USING": "Minimize Using", "GENIE_EFFECT": "Genie Effect", "SCALE_EFFECT": "Scale Effect",
        "DOCK_SETTINGS": "Dock Settings…", "APPLICATION_NOT_RESPONDING": "Application Not Responding",
    ]

    static func s(_ key: String) -> String {
        if loadedFor != Loc.language {
            let path = "/System/Library/CoreServices/Dock.app/Contents/Resources/\(lproj).lproj/DockMenus.strings"
            table = NSDictionary(contentsOfFile: path) as? [String: String] ?? [:]
            loadedFor = Loc.language
        }
        return table[key] ?? fallback[key] ?? key
    }

    static func s(_ key: String, _ arg: String) -> String {
        String(format: s(key), arg)
    }
}

/// 带闭包的菜单项
final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    /// 选中时先通知外层（Dock 菜单据此关闭）
    var onFire: (() -> Void)?

    init(_ title: String, state: NSControl.StateValue = .off, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.state = state
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() {
        onFire?()
        handler()
    }

    /// 按住 Option 时替换上一项（例如「退出」→「强制退出」）
    func alternate() -> ActionItem {
        isAlternate = true
        keyEquivalentModifierMask = .option
        return self
    }
}

extension NSMenu {
    func submenu(_ title: String, _ items: [NSMenuItem]) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        items.forEach(sub.addItem)
        item.submenu = sub
        addItem(item)
    }
}

/// 「登录时打开」：和系统 Dock 一样写入系统的登录项（通过「系统事件」）
@MainActor
enum LoginItems {
    private static var paths: Set<String>?

    /// 是否已设为登录时打开。还没授权控制「系统事件」时返回 nil（不在打开菜单时弹授权框）
    static func contains(_ path: String) -> Bool? {
        if paths == nil, permitted(ask: false) { paths = fetch() }
        return paths?.contains(path)
    }

    static func set(_ path: String, on: Bool) {
        guard let current = fetch() else { return }
        let p = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        if on, !current.contains(path) {
            run("tell application \"System Events\" to make login item at end with properties {path:\"\(p)\", hidden:false}")
        } else if !on, current.contains(path) {
            run("tell application \"System Events\" to delete (every login item whose path is \"\(p)\")")
        }
        paths = fetch()
    }

    private static func fetch() -> Set<String>? {
        guard let out = run("tell application \"System Events\" to get the path of every login item") else { return nil }
        if out.numberOfItems == 0, let s = out.stringValue { return [s] }
        return Set((0..<out.numberOfItems).compactMap { out.atIndex($0 + 1)?.stringValue })
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            // -1743：用户没有允许 AI Dock 控制「系统事件」
            let code = err[NSAppleScript.errorNumber] as? Int
            DockModel.alert(DockStrings.s("OPEN_AT_LOGIN"),
                            code == -1743 ? L("请在“系统设置 > 隐私与安全性 > 自动化”中允许 AI Dock 控制“系统事件”。")
                                          : (err[NSAppleScript.errorMessage] as? String ?? ""),
                            buttons: [L("好")])
            return nil
        }
        return out
    }

    /// 查询自动化授权，不会弹窗（ask = false）
    private static func permitted(ask: Bool) -> Bool {
        let bid = Array("com.apple.systemevents".utf8)
        var addr = AEAddressDesc()
        guard AECreateDesc(typeApplicationBundleID, bid, bid.count, &addr) == OSErr(noErr) else { return false }
        defer { AEDisposeDesc(&addr) }
        return AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, ask) == OSStatus(noErr)
    }
}

/// 系统 Dock 菜单里对 App 的操作
@MainActor
enum AppActions {
    /// 「显示所有窗口」：先切到这个 App，再打开调度中心的「应用程序窗口」
    static func showAllWindows(_ app: NSRunningApplication) {
        app.unhide()
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
            p.arguments = ["2"]
            try? p.run()
        }
    }

    /// 「隐藏其他」：切到这个 App，隐藏其余所有 App
    static func hideOthers(_ app: NSRunningApplication) {
        app.unhide()
        app.activate()
        for other in NSWorkspace.shared.runningApplications
        where other.activationPolicy == .regular && other != app && other.processIdentifier != getpid() {
            other.hide()
        }
    }

    /// 访达的「重启」
    static func relaunchFinder(_ app: NSRunningApplication) {
        app.forceTerminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
