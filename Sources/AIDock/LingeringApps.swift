import Foundation

/// 主程序已经退出、但它启动的子进程还在运行的 App（系统记为 exited-with-subordinates），
/// 例如退出 Cursor 后，它的 cursor-agent 还在后台跑。强制退出窗口里仍会列出它，系统 Dock 给它画半透明的指示灯。
/// 这个状态只有 LaunchServices 知道，用它的内部接口按进程号查询（运行时查找，找不到就不显示）。
enum LingeringApps {
    private typealias CopyInfo = @convention(c) (Int32, CFTypeRef, CFArray?) -> Unmanaged<CFDictionary>?
    private typealias ASNWithPid = @convention(c) (CFAllocator?, Int32) -> Unmanaged<CFTypeRef>?
    private static let exitedKey = "LSApplicationExitedTimeKey"

    private static let api: (info: CopyInfo, asn: ASNWithPid)? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW),
              let i = dlsym(h, "_LSCopyApplicationInformation"), let a = dlsym(h, "_LSASNCreateWithPid") else { return nil }
        return (unsafeBitCast(i, to: CopyInfo.self), unsafeBitCast(a, to: ASNWithPid.self))
    }()

    /// 这个进程号的 App 是否「已退出、子进程还在」
    static func isLingering(pid: pid_t) -> Bool {
        guard let api, let asn = api.asn(nil, pid)?.takeRetainedValue(),
              let info = api.info(-2, asn, nil)?.takeRetainedValue() as? [String: Any] else { return false }
        return info[exitedKey] != nil
    }

    /// 启动时找出已经处于这种状态的 App：App 路径 → 原来的进程号（读一次 lsappinfo）
    static func scan() async -> [String: pid_t] {
        let (_, out) = await Shell.run("/usr/bin/lsappinfo", ["list"])
        var found: [String: pid_t] = [:]
        var path: String?
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("bundle path=\"") {
                path = String(s.dropFirst("bundle path=\"".count).dropLast())
            } else if s.hasPrefix("pid = "), s.contains("exited-with-subordinates"), let p = path,
                      let pid = Int32(s.dropFirst(6).prefix { $0.isNumber }) {
                found[URL(fileURLWithPath: p).resolvingSymlinksInPath().path] = pid
            } else if s.first?.isNumber == true, s.contains(") \"") {
                path = nil
            }
        }
        return found
    }
}
