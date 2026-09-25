import Foundation
import CoreServices

/// 基于 FSEvents 的目录监听：只有文件真的变化时才回调，空闲时零开销。
/// latency 让系统把一段时间内的多次写入合并成一次回调。
final class FileWatcher {
    struct Event { let path: String; let rescan: Bool }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "aidock.fsevents", qos: .utility)
    private let handler: ([Event]) -> Void

    init?(paths: [String], latency: TimeInterval, handler: @escaping ([Event]) -> Void) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        self.handler = handler

        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, pathsPtr, flagsPtr, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(pathsPtr).takeUnretainedValue() as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<min(count, paths.count) {
                let f = Int(flagsPtr[i])
                let rescan = f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                  | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
                events.append(Event(path: paths[i], rescan: rescan))
            }
            watcher.handler(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagIgnoreSelf)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, existing as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return nil
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
