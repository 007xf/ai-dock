import Foundation
import AppKit
import os

private let activityLog = Logger(subsystem: "local.aidock.app", category: "activity")

/// 统计 AI 活动（事件驱动，空闲时不做任何事）。每个工具的「活跃分钟」来自这些信号的并集：
/// - 会话日志：Claude Code（~/.claude/projects）、Codex（~/.codex/sessions）、Gemini / Qwen CLI（~/.gemini|.qwen/tmp/*/chats）
/// - 使用时长：检测到的 AI App 在前台的时间（由 UsageStore 在切换 App 时上报）
/// - Cursor：Cursor 运行时本地状态库的写入（估算）
/// - 只能看出「在输出」的工具（Antigravity、Cursor Agent）：会话文件的写入
/// 启动时扫描一次最近 8 天的日志，之后只在 FSEvents 报告文件变化时增量读取。
actor ActivityScanner {
    private struct FileState { var offset: UInt64 = 0; var lastTotal = -1 }
    private struct MinuteStat { var requests = 0; var tokens = 0 }

    let claudeRoots: [String]
    let codexRoots: [String]
    let chatRoots: [(tool: String, path: String)]
    let cursorGlobal = CursorProvider.globalStorage.path
    /// 会话文件写入就说明 AI 在输出，但内容不解析的目录
    let outputRoots: [(tool: String, path: String)]
    nonisolated var watchPaths: [String] { claudeRoots + codexRoots + chatRoots.map(\.path) + outputRoots.map(\.path) + [cursorGlobal] }

    private var files: [String: FileState] = [:]
    /// Claude / Codex：按分钟累计的请求数和 tokens
    private var stats: [String: [Int: MinuteStat]] = [:]
    /// Gemini / Qwen：会话文件会整体重写，按文件保存解析结果
    private var chatFiles: [String: (tool: String, minutes: [Int: MinuteStat])] = [:]
    /// 使用时长 + Cursor 采样：有活动的分钟（持久化）
    private var presence: [String: Set<Int>] = [:]
    private var presenceDirty = false
    private var lastPresenceSave = Date()
    /// 最近两分钟内写入过的会话（用于「工作中 · N 个会话」）
    private var recentWrites: [String: [String: Date]] = [:]
    private var latest: [String: Date] = [:]
    /// 最近一次 AI 输出（会话日志写入），决定「工作中」
    private var lastOutput: [String: Date] = [:]
    private var front: String?
    /// 正在运行（App 或命令行）的工具
    private var running = Set<String>()
    /// 只存消息 ID 的稳定哈希（FNV-1a），比存字符串省内存，也能跨启动保存
    private var claudeSeen = Set<UInt64>()
    /// 自上次保存扫描缓存以来有没有读到新数据
    private var cacheDirty = false
    private var lastCacheSave = Date()
    private var tools: [String] = []
    private var scanned = false
    private let keepMinutes = 8 * 24 * 60

    init() {
        let home = FileManager.default.home
        claudeRoots = ClaudeProvider.configDirs.map { $0.appendingPathComponent("projects").path }
        codexRoots = CodexProvider.sessionRoots.map(\.path)
        chatRoots = [("gemini", GeminiProvider.geminiHome.appendingPathComponent("tmp").path),
                     ("qwen", home.appendingPathComponent(".qwen/tmp").path)]
        let gemini = GeminiProvider.geminiHome
        outputRoots = [("antigravity", gemini.appendingPathComponent("antigravity/conversations").path),
                       ("antigravity", gemini.appendingPathComponent("antigravity-cli/conversations").path),
                       ("cursor", home.appendingPathComponent(".cursor/chats").path)]
        presence = Self.loadPresence()
        for (t, m) in presence { if let last = m.max() { latest[t] = Date(timeIntervalSince1970: Double(last + 1) * 60) } }
    }

    deinit { scratch.deallocate() }

    // MARK: 入口

    /// 设置本机检测到的工具（决定报告哪些工具的状态）
    func configure(tools ids: [String]) { tools = ids }

    func initialScan(now: Date = Date()) -> ActivitySnapshot {
        // 先载入上次保存的读取进度和统计，只读新增内容
        loadCache()
        for root in claudeRoots { scanTree(root, tool: "claude", now: now) }
        for root in codexRoots { scanTree(root, tool: "codex", now: now) }
        for (tool, root) in chatRoots { scanChatTree(root, tool: tool, now: now) }
        for (tool, root) in outputRoots { scanOutputRoot(root, tool: tool) }
        scanned = true
        if cacheDirty { saveCache() }
        // 首次扫描读过大量日志，把已释放的内存立即还给系统
        bytesSinceRelief = 0
        malloc_zone_pressure_relief(nil, 0)
        return snapshot(now: now)
    }

    func handle(_ events: [FileWatcher.Event], now: Date = Date()) -> ActivitySnapshot {
        var cursorTouched = false
        var output: [(tool: String, root: String, path: String)] = []
        for e in events {
            let path = e.path
            if let root = claudeRoots.first(where: { path.hasPrefix($0) }) {
                if e.rescan { scanTree(root, tool: "claude", now: now) } else if path.hasSuffix(".jsonl") { ingestPath(path, "claude", now: now) }
            } else if let root = codexRoots.first(where: { path.hasPrefix($0) }) {
                if e.rescan { scanTree(root, tool: "codex", now: now) } else if path.hasSuffix(".jsonl") { ingestPath(path, "codex", now: now) }
            } else if let chat = chatRoots.first(where: { path.hasPrefix($0.path) }) {
                if e.rescan { scanChatTree(chat.path, tool: chat.tool, now: now) } else if Self.isChatFile(path) { parseChatFile(path, tool: chat.tool, now: now) }
            } else if path.hasPrefix(cursorGlobal) {
                let name = (path as NSString).lastPathComponent
                if name == "state.vscdb-wal" || name == "state.vscdb" { cursorTouched = true }
            } else if let o = outputRoots.first(where: { path.hasPrefix($0.path) }) {
                output.append((o.tool, o.path, path))
            }
        }
        // Cursor 编辑器的状态库随时都在写（界面状态、设置），只能说明「在用」，不能说明 AI 在工作；
        // Cursor Agent 命令行写会话记录才算 AI 输出
        if cursorTouched, Self.cursorIDERunning() {
            addPresence("cursor", from: now, to: now)
        }
        for o in output {
            addPresence(o.tool, from: now, to: now)
            recentWrites[o.tool, default: [:]][Self.sessionKey(o.path, root: o.root)] = now
            lastOutput[o.tool] = now
            activityLog.debug("output \(o.tool, privacy: .public)")
        }
        relieveMemoryIfNeeded()
        return snapshot(now: now)
    }

    /// 时间流逝（整点翻页、「工作中」变「空闲」）时调用，只做内存计算
    func tick(now: Date = Date()) -> ActivitySnapshot {
        if presenceDirty, now.timeIntervalSince(lastPresenceSave) > 120 { savePresence() }
        if cacheDirty, now.timeIntervalSince(lastCacheSave) > 30 * 60 { saveCache() }
        return snapshot(now: now)
    }

    /// 记录某个工具在一段时间内处于活动状态（前台使用、Cursor 采样）
    func addPresence(_ tool: String, from: Date, to: Date) {
        let a = Int(from.timeIntervalSince1970 / 60), b = Int(to.timeIntervalSince1970 / 60)
        guard b >= a, b - a < 24 * 60 else { return }
        var set = presence[tool] ?? []
        for m in a...b { set.insert(m) }
        presence[tool] = set
        if to > (latest[tool] ?? .distantPast) { latest[tool] = to }
        presenceDirty = true
    }

    func setFront(_ tool: String?) { front = tool }

    func setRunning(_ ids: Set<String>) { running = ids }

    func flush() {
        if presenceDirty { savePresence() }
        if cacheDirty { saveCache() }
    }

    // MARK: 只看写入时间的会话目录

    /// 会话名：根目录下的第一层（去掉 .db-wal 之类的后缀），同一个会话的几个文件算一个
    private static func sessionKey(_ path: String, root: String) -> String {
        let rest = path.dropFirst(root.count).split(separator: "/").first.map(String.init) ?? path
        return rest.split(separator: ".").first.map(String.init) ?? rest
    }

    /// 启动时取最近一次写入的时间（刚启动时就能显示「工作中」）
    private func scanOutputRoot(_ root: String, tool: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return }
        for name in names {
            let path = root + "/" + name
            guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if m > (lastOutput[tool] ?? .distantPast) { lastOutput[tool] = m }
            if m > (latest[tool] ?? .distantPast) { latest[tool] = m }
        }
    }

    // MARK: Claude / Codex 日志

    private func scanTree(_ root: String, tool: String, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(keepMinutes) * 60)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let mtime = v.contentModificationDate else { continue }
            noteWrite(tool, url.path, mtime, now: now)
            if mtime > cutoff { ingest(url.path, size: UInt64(v.fileSize ?? 0), tool: tool) }
        }
    }

    private func ingestPath(_ path: String, _ tool: String, now: Date) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return }
        noteWrite(tool, path, (attrs[.modificationDate] as? Date) ?? now, now: now)
        ingest(path, size: size, tool: tool)
    }

    private func noteWrite(_ tool: String, _ path: String, _ mtime: Date, now: Date) {
        if mtime > (latest[tool] ?? .distantPast) { latest[tool] = mtime }
        if mtime > (lastOutput[tool] ?? .distantPast) { lastOutput[tool] = mtime }
        if now.timeIntervalSince(mtime) < 120 {
            recentWrites[tool, default: [:]][path] = mtime
            activityLog.debug("output \(tool, privacy: .public) \((path as NSString).lastPathComponent, privacy: .public) age=\(Int(now.timeIntervalSince(mtime)))s")
        }
    }

    /// 固定大小的读缓冲区，反复使用，避免每次读文件都申请/释放大块内存
    private let scratch = UnsafeMutableRawPointer.allocate(byteCount: 256 << 10, alignment: 16)
    private let scratchSize = 256 << 10
    /// 跨缓冲区的半行内容（只在一行超过 256KB 时才会变大，用完就收缩）
    private var carry: [UInt8] = []
    private var bytesSinceRelief = 0

    private func ingest(_ path: String, size: UInt64, tool: String) {
        var st = files[path] ?? FileState()
        if size < st.offset { st = FileState() } // 文件被截断/重写
        guard size > st.offset else { files[path] = st; return }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }

        let isClaude = tool == "claude"
        let needles: [[UInt8]] = isClaude
            ? [Array("\"usage\"".utf8), Array("\"type\":\"assistant\"".utf8)]
            : [Array("\"token_count\"".utf8)]
        let base = scratch.assumingMemoryBound(to: UInt8.self)
        var readOffset = st.offset
        var committed = st.offset      // 最后一个完整行之后的位置
        carry.removeAll(keepingCapacity: true)

        func process(_ ptr: UnsafePointer<UInt8>, _ len: Int) {
            guard len > 20, needles.allSatisfy({ memmem(ptr, len, $0, $0.count) != nil }) else { return }
            if isClaude {
                handleClaude(ptr, len)
            } else {
                autoreleasepool { handleCodex(Data(bytes: ptr, count: len), &st) }
            }
        }

        while true {
            let n = pread(fd, scratch, scratchSize, off_t(readOffset))
            if n <= 0 { break }
            bytesSinceRelief += n
            var pos = 0
            while pos < n {
                if let nl = memchr(base + pos, 0x0A, n - pos) {
                    let end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(nl))
                    if carry.isEmpty {
                        process(base + pos, end - pos)
                    } else {
                        carry.append(contentsOf: UnsafeBufferPointer(start: base + pos, count: end - pos))
                        carry.withUnsafeBufferPointer { process($0.baseAddress!, $0.count) }
                        carry.removeAll(keepingCapacity: true)
                    }
                    pos = end + 1
                    committed = readOffset + UInt64(pos)
                } else {
                    carry.append(contentsOf: UnsafeBufferPointer(start: base + pos, count: n - pos))
                    pos = n
                }
            }
            readOffset += UInt64(n)
        }
        if carry.capacity > 4 << 20 { carry = [] }
        if committed != st.offset { cacheDirty = true }
        st.offset = committed
        files[path] = st
    }

    /// 读了较多数据后，把 malloc 缓存的空闲页还给系统，降低常驻内存
    private func relieveMemoryIfNeeded() {
        if bytesSinceRelief > 4 << 20 {
            bytesSinceRelief = 0
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    // Claude Code 日志里这些键是 JSON 结构的一部分；正文里的同名文本都带转义（\"），不会误匹配
    private static let kUsage = Array("\"usage\":{".utf8)
    private static let kSynthetic = Array("\"model\":\"<synthetic>\"".utf8)
    private static let kTimestamp = Array("\"timestamp\":\"".utf8)
    private static let kMsgID = Array("\"id\":\"msg_".utf8)
    private static let kRequestID = Array("\"requestId\":\"".utf8)
    private static let kInput = Array("\"input_tokens\":".utf8)
    private static let kOutput = Array("\"output_tokens\":".utf8)
    private static let kCacheCreate = Array("\"cache_creation_input_tokens\":".utf8)
    private static let kCacheRead = Array("\"cache_read_input_tokens\":".utf8)

    /// FNV-1a：稳定的 64 位哈希（Swift 的 Hasher 每次启动种子不同，不能持久化）
    private static func fnv1a(_ parts: String...) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for p in parts { for b in p.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }; h ^= 0x7c; h = h &* 0x100000001b3 }
        return h
    }

    private static func offset(_ base: UnsafePointer<UInt8>, _ len: Int, _ key: [UInt8], from: Int = 0) -> Int? {
        guard from < len, let p = memmem(base + from, len - from, key, key.count) else { return nil }
        return UnsafeRawPointer(base).distance(to: p) + key.count
    }

    private static func string(_ base: UnsafePointer<UInt8>, _ len: Int, after key: [UInt8]) -> String? {
        guard let s = offset(base, len, key), let q = memchr(base + s, 0x22, len - s) else { return nil }
        let e = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(q))
        return String(decoding: UnsafeBufferPointer(start: base + s, count: e - s), as: UTF8.self)
    }

    private static func int(_ base: UnsafePointer<UInt8>, _ len: Int, after key: [UInt8], from: Int, to limit: Int) -> Int {
        guard let s = offset(base, min(len, limit), key, from: from) else { return 0 }
        var v = 0, i = s
        while i < len, base[i] == 0x20 { i += 1 }
        while i < len, base[i] >= 0x30, base[i] <= 0x39 { v = v * 10 + Int(base[i] - 0x30); i += 1 }
        return v
    }

    private func handleClaude(_ base: UnsafePointer<UInt8>, _ len: Int) {
        guard let u = Self.offset(base, len, Self.kUsage), Self.offset(base, len, Self.kSynthetic) == nil,
              let ts = Self.string(base, len, after: Self.kTimestamp).flatMap(parseISODate) else { return }
        let id = Self.string(base, len, after: Self.kMsgID) ?? "", req = Self.string(base, len, after: Self.kRequestID) ?? ""
        if !(id.isEmpty && req.isEmpty) {
            if !claudeSeen.insert(Self.fnv1a(id, req)).inserted { return }
        }
        // usage 对象很小，只在它后面 1.5KB 内找 token 数；含缓存写入和缓存读取（与官方统计口径一致）
        let limit = u + 1500
        let tokens = Self.int(base, len, after: Self.kInput, from: u, to: limit)
            + Self.int(base, len, after: Self.kOutput, from: u, to: limit)
            + Self.int(base, len, after: Self.kCacheCreate, from: u, to: limit)
            + Self.int(base, len, after: Self.kCacheRead, from: u, to: limit)
        add("claude", ts, tokens)
    }

    private func handleCodex(_ line: Data, _ st: inout FileState) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let ts = (obj["timestamp"] as? String).flatMap(parseISODate) else { return }
        // Codex 会重复发送相同累计值的 token_count，用累计总量去重；
        // token 数取累计总量的增量（含缓存命中的输入），与 ChatGPT 个人资料里的统计口径一致
        let last = info["last_token_usage"] as? [String: Any]
        let lastTotal = Int(jnum(last?["total_tokens"]) ?? (jnum(last?["input_tokens"]) ?? 0) + (jnum(last?["output_tokens"]) ?? 0))
        let total = Int(jnum((info["total_token_usage"] as? [String: Any])?["total_tokens"]) ?? -1)
        var tokens = lastTotal
        if total >= 0 {
            if total == st.lastTotal { return }
            if st.lastTotal >= 0, total >= st.lastTotal { tokens = total - st.lastTotal }
            st.lastTotal = total
        }
        add("codex", ts, tokens)
    }

    private func add(_ tool: String, _ ts: Date, _ tokens: Int) {
        let minute = Int(ts.timeIntervalSince1970 / 60)
        var s = stats[tool]?[minute] ?? MinuteStat()
        s.requests += 1
        s.tokens += tokens
        stats[tool, default: [:]][minute] = s
    }

    // MARK: Gemini / Qwen CLI 会话

    private static func isChatFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("session-") && (name.hasSuffix(".json") || name.hasSuffix(".jsonl"))
    }

    private func scanChatTree(_ root: String, tool: String, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(keepMinutes) * 60)
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in e where Self.isChatFile(url.path) {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            noteWrite(tool, url.path, mtime, now: now)
            if mtime > cutoff { parseChatFile(url.path, tool: tool, now: now) }
        }
    }

    /// 会话文件：.json 是整个会话一个对象；.jsonl 第一行是会话信息，之后每行是一次更新（$set 等）
    private func parseChatFile(_ path: String, tool: String, now: Date) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            noteWrite(tool, path, (attrs[.modificationDate] as? Date) ?? now, now: now)
            if (attrs[.size] as? Int ?? 0) > 50 << 20 { return }
        }
        guard let data = FileManager.default.contents(atPath: path) else { return }
        bytesSinceRelief += data.count
        var byID: [String: [String: Any]] = [:]
        var anonymous: [[String: Any]] = []
        func collect(_ v: Any?) {
            if let arr = v as? [[String: Any]] { arr.forEach { collect($0) }; return }
            guard let m = v as? [String: Any] else { return }
            if m["timestamp"] != nil, m["type"] != nil {
                if let id = m["id"] as? String { byID[id] = m } else { anonymous.append(m) }
            }
            if let msgs = m["messages"] { collect(msgs) }
        }
        autoreleasepool {
            if path.hasSuffix(".jsonl") {
                for line in data.split(separator: 0x0A) where !line.isEmpty {
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                    collect(obj)
                    for (k, v) in obj where k.hasPrefix("$") { collect(v) }
                }
            } else if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                collect(obj)
            }
        }
        var minutes: [Int: MinuteStat] = [:]
        for m in Array(byID.values) + anonymous {
            guard let ts = jdate(m["timestamp"]) else { continue }
            let minute = Int(ts.timeIntervalSince1970 / 60)
            var s = minutes[minute] ?? MinuteStat()
            let type = (m["type"] as? String ?? "").lowercased()
            if ["gemini", "model", "assistant", "qwen"].contains(type) {
                s.requests += 1
                if let t = m["tokens"] as? [String: Any] {
                    s.tokens += Int(jnum(t["total"]) ?? ((jnum(t["input"]) ?? 0) + (jnum(t["output"]) ?? 0)
                                                        + (jnum(t["thoughts"]) ?? 0) + (jnum(t["tool"]) ?? 0)))
                }
            }
            minutes[minute] = s
        }
        chatFiles[path] = (tool, minutes)
    }

    // MARK: Cursor

    private static func cursorIDERunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "") == "com.todesktop.230313mzl4w4u92" || $0.localizedName == "Cursor"
        }
    }

    // MARK: 扫描缓存

    private struct ScanCache: Codable {
        var version: Int
        var savedAt: Date
        var files: [String: [Int]]          // 路径: [已读偏移, 累计总量]
        var stats: [String: [[Int]]]        // 工具: [[分钟, 请求数, tokens]]
        var seen: [UInt64]
    }
    /// 统计口径变化时加 1，旧缓存自动作废
    private static let cacheVersion = 2

    private func loadCache() {
        guard let d = try? Data(contentsOf: Self.storeDir.appendingPathComponent("scan-cache.plist")),
              let c = try? PropertyListDecoder().decode(ScanCache.self, from: d),
              c.version == Self.cacheVersion, Date().timeIntervalSince(c.savedAt) < 7 * 86400 else { return }
        for (p, v) in c.files where v.count == 2 { files[p] = FileState(offset: UInt64(max(0, v[0])), lastTotal: v[1]) }
        for (t, rows) in c.stats {
            var m: [Int: MinuteStat] = [:]
            for r in rows where r.count == 3 { m[r[0]] = MinuteStat(requests: r[1], tokens: r[2]) }
            stats[t] = m
        }
        claudeSeen = Set(c.seen)
    }

    private func saveCache() {
        cacheDirty = false
        lastCacheSave = Date()
        let fm = FileManager.default
        let c = ScanCache(version: Self.cacheVersion, savedAt: Date(),
                          files: files.filter { fm.fileExists(atPath: $0.key) }.mapValues { [Int($0.offset), $0.lastTotal] },
                          stats: stats.mapValues { $0.map { [$0.key, $0.value.requests, $0.value.tokens] } },
                          seen: Array(claudeSeen))
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        if let d = try? enc.encode(c) { try? d.write(to: Self.storeDir.appendingPathComponent("scan-cache.plist"), options: .atomic) }
    }

    // MARK: 持久化（使用时长 / Cursor 采样）

    private static var storeDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func loadPresence() -> [String: Set<Int>] {
        var out: [String: Set<Int>] = [:]
        if let d = try? Data(contentsOf: storeDir.appendingPathComponent("presence.json")),
           let obj = try? JSONDecoder().decode([String: [Int]].self, from: d) {
            for (k, v) in obj { out[k] = Set(v) }
        }
        // 旧版只记录了 Cursor
        if let d = try? Data(contentsOf: storeDir.appendingPathComponent("cursor-activity.json")),
           let arr = try? JSONDecoder().decode([Int].self, from: d) {
            out["cursor", default: []].formUnion(arr)
        }
        return out
    }

    private func savePresence() {
        presenceDirty = false
        lastPresenceSave = Date()
        let obj = presence.mapValues { $0.sorted() }
        if let d = try? JSONEncoder().encode(obj) {
            try? d.write(to: Self.storeDir.appendingPathComponent("presence.json"), options: .atomic)
            try? FileManager.default.removeItem(at: Self.storeDir.appendingPathComponent("cursor-activity.json"))
        }
    }

    // MARK: 汇总

    private func snapshot(now: Date) -> ActivitySnapshot {
        let cutoffMinute = Int(now.timeIntervalSince1970 / 60) - keepMinutes
        for t in stats.keys where (stats[t]?.keys.contains { $0 < cutoffMinute }) == true {
            stats[t] = stats[t]?.filter { $0.key >= cutoffMinute }
        }
        for t in presence.keys where (presence[t]?.contains { $0 < cutoffMinute }) == true {
            presence[t] = presence[t]?.filter { $0 >= cutoffMinute }
            presenceDirty = true
        }
        for t in recentWrites.keys { recentWrites[t] = recentWrites[t]?.filter { now.timeIntervalSince($0.value) < 120 } }

        var snap = buildColumns(now: now)
        for id in tools {
            var s = LiveStatus()
            s.installed = true
            s.lastActive = id == front ? now : latest[id]
            s.lastOutput = lastOutput[id]
            s.running = running.contains(id)
            s.sessions = recentWrites[id]?.values.filter { now.timeIntervalSince($0) < 60 }.count ?? 0
            let p = Provider(id: id)
            snap.live[p] = s
            snap.states[p] = s.state(now: now)
        }
        snap.scannedAt = scanned ? now : nil
        return snap
    }

    /// 汇总成 24 小时 / 7 天的柱子。全部用整数分钟运算，不为每条记录调用日期函数（这是最耗电的地方）
    private func buildColumns(now: Date) -> ActivitySnapshot {
        let cal = Calendar.current
        let hourStart = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let dayStart = cal.startOfDay(for: now)
        var hours = (0..<24).map { ActivityColumn(id: $0, start: cal.date(byAdding: .hour, value: $0 - 23, to: hourStart)!) }
        var days = (0..<7).map { ActivityColumn(id: $0, start: cal.date(byAdding: .day, value: $0 - 6, to: dayStart)!) }
        let hourBaseMinute = Int(hours[0].start.timeIntervalSince1970 / 60)
        // 每天的起始分钟（考虑夏令时，只算 8 次）
        let dayStarts = days.map { Int($0.start.timeIntervalSince1970 / 60) }
        let dayBaseMinute = dayStarts[0]
        let nowMinute = Int(now.timeIntervalSince1970 / 60)

        func dayIndex(_ m: Int) -> Int {
            var i = 6
            while i > 0 && m < dayStarts[i] { i -= 1 }
            return i
        }

        // 每个工具：日志里的请求/tokens + 所有信号的活跃分钟并集
        var perTool: [String: [Int: MinuteStat]] = [:]
        for (t, m) in stats { perTool[t] = m.filter { $0.key >= dayBaseMinute } }
        for (_, f) in chatFiles {
            for (m, s) in f.minutes where m >= dayBaseMinute {
                var cur = perTool[f.tool]?[m] ?? MinuteStat()
                cur.requests += s.requests; cur.tokens += s.tokens
                perTool[f.tool, default: [:]][m] = cur
            }
        }
        for (t, set) in presence {
            for m in set where m >= dayBaseMinute && perTool[t]?[m] == nil { perTool[t, default: [:]][m] = MinuteStat() }
        }

        for (tool, minutes) in perTool {
            // 超过 8 个色槽的工具归入「其他」
            let p = ToolRegistry.slots[tool].map { $0 < Palette.slots.count ? Provider(id: tool) : .other } ?? .other
            var h = [Totals](repeating: Totals(), count: 24)
            var d = [Totals](repeating: Totals(), count: 7)
            for (minute, s) in minutes where minute <= nowMinute {
                if minute >= hourBaseMinute {
                    let i = min(23, (minute - hourBaseMinute) / 60)
                    h[i].minutes += 1; h[i].requests += s.requests; h[i].tokens += s.tokens
                }
                let j = dayIndex(minute)
                d[j].minutes += 1; d[j].requests += s.requests; d[j].tokens += s.tokens
            }
            for i in 0..<24 where h[i].minutes > 0 { hours[i].values[p, default: Totals()].add(h[i]) }
            for i in 0..<7 where d[i].minutes > 0 { days[i].values[p, default: Totals()].add(d[i]) }
        }
        return ActivitySnapshot(hours: hours, days: days)
    }
}
