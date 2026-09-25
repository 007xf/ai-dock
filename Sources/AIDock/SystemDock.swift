import Foundation

/// 隐藏 / 恢复系统 Dock：打开自动隐藏，并把弹出延迟设得很长，鼠标碰到屏幕底边也不会出来。
/// 修改前会记下原来的设置，恢复时原样写回。
enum SystemDock {
    private static let domain = "com.apple.dock"
    private static let savedKey = "savedSystemDock"
    private static let hiddenDelay = 1000.0

    static var isSuppressed: Bool {
        let d = UserDefaults(suiteName: domain)
        return (d?.object(forKey: "autohide") as? Bool) == true
            && (d?.object(forKey: "autohide-delay") as? Double ?? 0) >= hiddenDelay
    }

    /// 用户原来（被 AI Dock 接管之前）的系统 Dock 弹出延迟，默认 0.2 秒
    static var revealDelay: Double {
        if let saved = UserDefaults.standard.dictionary(forKey: savedKey) {
            return saved["autohide-delay"] as? Double ?? 0.2
        }
        let d = UserDefaults(suiteName: domain)?.object(forKey: "autohide-delay") as? Double
        return d.map { $0 >= hiddenDelay ? 0.2 : $0 } ?? 0.2
    }

    /// 系统 Dock 显示 / 隐藏动画的时长（autohide-time-modifier），默认 0.5 秒
    static var slideDuration: Double {
        max(0, UserDefaults(suiteName: domain)?.object(forKey: "autohide-time-modifier") as? Double ?? 0.5)
    }

    /// 系统 Dock 的其他显示偏好（AI Dock 跟着一起遵守）
    static var showsIndicators: Bool { UserDefaults(suiteName: domain)?.object(forKey: "show-process-indicators") as? Bool ?? true }
    static var launchBounce: Bool { UserDefaults(suiteName: domain)?.object(forKey: "launchanim") as? Bool ?? true }
    static var showsRecents: Bool { UserDefaults(suiteName: domain)?.object(forKey: "show-recents") as? Bool ?? true }
    static var minimizeEffect: String { UserDefaults(suiteName: domain)?.string(forKey: "mineffect") ?? "genie" }

    /// 「最小化时使用」：窗口最小化动画由系统 Dock 负责，改完需要重启系统 Dock 生效
    static func setMinimizeEffect(_ effect: String) {
        run("/usr/bin/defaults", ["write", domain, "mineffect", "-string", effect])
        run("/usr/bin/killall", ["Dock"])
    }

    static func suppress() {
        guard !isSuppressed else { return }
        let d = UserDefaults(suiteName: domain)
        if UserDefaults.standard.dictionary(forKey: savedKey) == nil {
            var saved: [String: Any] = ["autohide": d?.object(forKey: "autohide") as? Bool ?? false]
            if let delay = d?.object(forKey: "autohide-delay") as? Double { saved["autohide-delay"] = delay }
            UserDefaults.standard.set(saved, forKey: savedKey)
        }
        run("/usr/bin/defaults", ["write", domain, "autohide", "-bool", "true"])
        run("/usr/bin/defaults", ["write", domain, "autohide-delay", "-float", "\(hiddenDelay)"])
        run("/usr/bin/killall", ["Dock"])
    }

    static func restore() {
        let saved = UserDefaults.standard.dictionary(forKey: savedKey)
        guard saved != nil || isSuppressed else { return }
        let autohide = saved?["autohide"] as? Bool ?? false
        run("/usr/bin/defaults", ["write", domain, "autohide", "-bool", autohide ? "true" : "false"])
        if let delay = saved?["autohide-delay"] as? Double {
            run("/usr/bin/defaults", ["write", domain, "autohide-delay", "-float", "\(delay)"])
        } else {
            run("/usr/bin/defaults", ["delete", domain, "autohide-delay"])
        }
        run("/usr/bin/killall", ["Dock"])
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
