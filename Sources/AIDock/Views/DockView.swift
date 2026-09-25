import SwiftUI
import AppKit

struct DockMetrics: Equatable {
    var icon: CGFloat
    var widgetsCompact: Bool
    var magnify: Bool
    /// 放大倍数（放大后大小 / 图标大小）
    var magnification: CGFloat = 1.4

    var spacing: CGFloat { max(4, (icon * 0.13).rounded()) }
    var dotRow: CGFloat { 11 }
    var padTop: CGFloat { 7 }
    var padBottom: CGFloat { 3 }
    var padH: CGFloat { 9 }
    var barHeight: CGFloat { padTop + icon + dotRow + padBottom }
    var maxScale: CGFloat { magnify ? max(1, magnification) : 1 }
    /// 放大影响的半径（约左右各 2.8 个图标）
    var radius: CGFloat { (icon + spacing) * 2.8 }
    /// 放大时两侧最多被推开的距离
    var growMax: CGFloat { (maxScale - 1) * radius / 2 }
    /// 图标上方留给名称标签和放大效果的透明空间
    var headroom: CGFloat { 36 + icon * (maxScale - 1) }
    var totalHeight: CGFloat { headroom + barHeight }
    var corner: CGFloat { min(26, icon * 0.42 + 4) }
}

@MainActor
final class DockUIState: ObservableObject {
    @Published var hovered: String?
    @Published var hoveredIndex: Int?
    @Published var overDock = false
    @Published var popoverCount = 0
    /// 鼠标在 Dock 条里的横坐标（驱动鱼眼放大）
    @Published var pointerX: CGFloat?
    /// 显示 / 隐藏
    @Published var revealed = false
    /// 正在被拖动的图标
    @Published var dragID: String?
    /// 拖动时的插入位置（按「去掉被拖图标后的固定列表」计算）
    @Published var dropIndex: Int?
    /// 文件拖到哪个图标上（App 的 id，或 "trash"）
    @Published var dropTarget: String?
    /// 小组件拖到废纸篓右边时的插入位置
    @Published var tailDropIndex: Int?
    /// 每个小组件在 Dock 条里的位置（排版时测量，拖放和右键菜单用）
    var tileFrames: [String: CGRect] = [:]
    /// Dock 菜单打开期间：放大保持不动、不显示名称标签、被点的图标变暗（和系统 Dock 一样）
    @Published var menuOpen = false
    @Published var menuTarget: String?
    /// 透明背景时 Dock 背后是否偏亮：true 用深色文字，false 用浅色文字，nil 跟随系统
    @Published var backdropLight: Bool?
    /// 菜单打开那一刻的鼠标位置（放大按它冻结）
    var menuPointer: CGFloat?
    var metrics: DockMetrics?
    /// 最近一次排版的图标位置（Dock 条坐标），给拖放计算用
    var layout: DockLayoutInfo?
    private var endWork: DispatchWorkItem?

    func hover(_ id: String, index: Int?, _ inside: Bool) {
        if inside {
            hovered = id; hoveredIndex = index
        } else if hovered == id {
            hovered = nil; hoveredIndex = nil
        }
    }

    /// 鼠标移动：立即更新；离开时稍等一下再收回，避免在放大的图标间隙里来回闪
    func pointer(_ x: CGFloat?) {
        if menuOpen { return }
        endWork?.cancel()
        if let x {
            if pointerX != x { pointerX = x }
        } else {
            let w = DispatchWorkItem { [weak self] in self?.pointerX = nil }
            endWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
        }
    }
}

/// 鱼眼放大：离光标越近放得越大（余弦曲线平滑过渡），并按积分把两边的图标推开
struct Fisheye {
    let pointer: CGFloat?
    let lower: CGFloat   // 可放大区域（App 图标 + 废纸篓）
    let upper: CGFloat
    let metrics: DockMetrics

    private var active: Bool {
        guard metrics.maxScale > 1, let p = pointer else { return false }
        return p >= lower - metrics.icon / 2 && p <= upper + metrics.icon / 2
    }

    private func f(_ d: CGFloat) -> CGFloat {
        let t = min(1, abs(d) / metrics.radius)
        return (1 + cos(.pi * t)) / 2
    }

    /// ∫₀ᵘ f(v) dv
    private func h(_ u: CGFloat) -> CGFloat {
        let r = metrics.radius
        if u <= 0 { return 0 }
        if u >= r { return r / 2 }
        return u / 2 + r / (2 * .pi) * sin(.pi * u / r)
    }

    func scale(at x: CGFloat) -> CGFloat {
        guard active, let p = pointer, x >= lower, x <= upper else { return 1 }
        return 1 + (metrics.maxScale - 1) * f(x - p)
    }

    /// 放大后这个位置被推开的距离
    func shift(at x: CGFloat) -> CGFloat {
        guard active, let p = pointer else { return 0 }
        let k = metrics.maxScale - 1
        if x >= p { return k * h(min(x, upper) - max(p, lower)) }
        return -k * h(min(p, upper) - max(x, lower))
    }
}

/// Dock 条里各项目的位置（条坐标，未放大、未拖动时）。固定区里 App 和小组件混排，宽度各不相同
struct DockLayoutInfo {
    var icon: CGFloat
    var spacing: CGFloat
    var finderID: String?
    var finderCenter: CGFloat?
    /// 固定区：App 路径或 "widget:…"
    var pinnedIDs: [String]
    var pinnedCenters: [CGFloat]
    var pinnedWidths: [CGFloat]
    var extraIDs: [String]
    var extraCenters: [CGFloat]
    var trashCenter: CGFloat
    /// 废纸篓右边的小组件（按显示顺序）
    var tailIDs: [String]

    /// 所有图标（id, 原始中心, 宽度），含访达和废纸篓
    var allIcons: [(String, CGFloat, CGFloat)] {
        var all: [(String, CGFloat, CGFloat)] = []
        if let f = finderID, let c = finderCenter { all.append((f, c, icon)) }
        for i in pinnedIDs.indices { all.append((pinnedIDs[i], pinnedCenters[i], pinnedWidths[i])) }
        all += zip(extraIDs, extraCenters).map { ($0, $1, icon) }
        all.append(("trash", trashCenter, icon))
        return all
    }

    /// 条坐标 x 处的项目（不考虑放大）
    func item(at x: CGFloat, includeFinder: Bool = true) -> String? {
        let all = allIcons.filter { includeFinder || $0.0 != finderID }
        guard let best = all.min(by: { abs($0.1 - x) < abs($1.1 - x) }), abs(best.1 - x) <= best.2 / 2 + 2 else { return nil }
        return best.0
    }

    /// 废纸篓右边从哪里开始
    var tailStart: CGFloat { trashCenter + icon / 2 + spacing }

    /// 在固定区里的插入位置（按去掉被拖项目后的顺序）；x 在废纸篓或它右边时返回 nil
    func insertionIndex(at x: CGFloat, excluding id: String?) -> Int? {
        guard x <= trashCenter - icon / 2 else { return nil }
        return zip(pinnedIDs, pinnedCenters).filter { $0.0 != id && $0.1 < x }.count
    }

    /// 在废纸篓右边的插入位置
    func tailInsertionIndex(at x: CGFloat, excluding id: String?, frames: [String: CGRect]) -> Int? {
        guard x >= trashCenter + icon / 2 else { return nil }
        return tailIDs.filter { $0 != id }.filter { (frames[$0]?.midX ?? .infinity) < x }.count
    }
}

/// 测量每个小组件在 Dock 条里的位置
struct TileFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func reportTileFrame(_ id: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: TileFramesKey.self, value: [id: g.frame(in: .named("dockbar"))])
        })
    }
}

struct DockView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: DockUIState
    var metrics: DockMetrics
    var openSettings: () -> Void = {}

    // MARK: 小组件

    /// 当前要显示的小组件（默认顺序）：有额度的工具、只有用量的工具、本地模型、API 余额、AI 活动
    static func widgetTokens(settings: AppSettings, store: UsageStore) -> [String] {
        var t = (settings.visibleProviders + settings.visibleUsageTools + settings.visibleLocalTools).map { "widget:\($0.id)" }
        t += store.apiKeys.map { "widget:balance:\($0.id)" }
        if settings.showActivityTile { t.append("widget:activity") }
        var seen = Set<String>()
        return t.filter { seen.insert($0).inserted }
    }

    /// 小组件插在 App 之间时占的宽度（和 App 图标一样大；活动图和余额稍宽）
    static func tileWidth(_ token: String, _ m: DockMetrics) -> CGFloat {
        token == "widget:activity" || token.hasPrefix("widget:balance:") ? (m.icon * 1.25).rounded() : m.icon
    }

    @MainActor @ViewBuilder
    static func widget(_ token: String, store: UsageStore, settings: AppSettings, ui: DockUIState,
                       metrics m: DockMetrics, openSettings: @escaping () -> Void) -> some View {
        let id = String(token.dropFirst("widget:".count))
        if id == "activity" {
            ActivityWidget(activity: store.activity, settings: settings, ui: ui, metrics: m, store: store, openSettings: openSettings)
        } else if id.hasPrefix("balance:"), let e = store.apiKeys.first(where: { "balance:\($0.id)" == id }) {
            BalanceWidget(entry: e, balance: store.apiBalances[e.id], ui: ui, metrics: m)
        } else if settings.visibleLocalTools.contains(Provider(id: id)) {
            LocalModelsWidget(provider: Provider(id: id), info: store.localModels[Provider(id: id)], ui: ui, metrics: m,
                              store: store, openSettings: openSettings)
        } else if settings.visibleProviders.contains(Provider(id: id)),
                  !(store.usages[Provider(id: id)].map { $0.windows.isEmpty && $0.error != nil } ?? false) {
            ProviderWidget(provider: Provider(id: id), usage: store.usages[Provider(id: id)], live: store.activity.live[Provider(id: id)],
                           ui: ui, metrics: m, store: store, openSettings: openSettings)
        } else {
            // 没有额度接口、或读不到额度（账号没有套餐、App 没开等）：显示使用时长，不显示报错
            UsageWidget(provider: Provider(id: id), activity: store.activity, ui: ui, metrics: m,
                        store: store, openSettings: openSettings)
        }
    }

    // MARK: 排版

    var body: some View {
        let m = metrics
        let dividerW: CGFloat = 5
        let available = Self.widgetTokens(settings: settings, store: store)
        let availableSet = Set(available)
        let apps = Dictionary(model.pinned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 固定区：访达 + App 和拖进来的小组件，按用户排的顺序
        let finderTile: [(id: String, app: DockModel.Item?)] = model.finder.map { [($0.id, $0)] } ?? []
        let pinnedTiles: [(id: String, app: DockModel.Item?)] = model.order.compactMap { id in
            DockModel.isWidget(id) ? (availableSet.contains(id) ? (id, nil) : nil) : apps[id].map { (id, $0) }
        }
        let lead = finderTile + pinnedTiles
        let hasFinder = !finderTile.isEmpty
        // 废纸篓右边的小组件：没拖进固定区的，按用户排的顺序，新出现的排在后面
        let rank = Dictionary(model.tailOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let tail = available.filter { !model.order.contains($0) }.enumerated()
            .sorted { (rank[$0.element] ?? 10_000 + $0.offset) < (rank[$1.element] ?? 10_000 + $1.offset) }.map(\.element)
        let extra = model.extraRunning

        // 按实际宽度算出每个项目的中心位置（放大作用于固定区、最近使用和废纸篓）
        let leadWidths = lead.map { $0.app != nil ? m.icon : Self.tileWidth($0.id, m) }
        let leadCenters: [CGFloat] = {
            var x = m.padH, out: [CGFloat] = []
            for w in leadWidths { out.append(x + w / 2); x += w + m.spacing }
            return out
        }()
        let afterLead = m.padH + leadWidths.reduce(0) { $0 + $1 + m.spacing }
        let extraStart = afterLead + (extra.isEmpty ? 0 : dividerW + m.spacing)
        let extraCenters = extra.indices.map { extraStart + CGFloat($0) * (m.icon + m.spacing) + m.icon / 2 }
        let dividerAfterApps = afterLead + dividerW / 2
        let trashDivider = (extraCenters.last.map { $0 + m.icon / 2 + m.spacing } ?? afterLead) + dividerW / 2
        let trashCenter = trashDivider + dividerW / 2 + m.spacing + m.icon / 2
        let lower = m.padH, upper = trashCenter + m.icon / 2
        let fe = Fisheye(pointer: ui.menuOpen ? ui.menuPointer : ui.pointerX, lower: lower, upper: upper, metrics: m)

        // 拖动：被拖的项目隐藏，插入位置让出一个同样宽的空位；整条 Dock 以中心为准向两侧伸缩
        let dragID = ui.dragID
        let unit = (dragID.map { DockModel.isWidget($0) ? Self.tileWidth($0, m) : m.icon } ?? m.icon) + m.spacing
        let dragPinned = dragID.flatMap { id in pinnedTiles.firstIndex { $0.id == id } }
        let dragTail = dragID.flatMap { tail.firstIndex(of: $0) }
        let gap = ui.dropIndex, tailGap = ui.tailDropIndex
        let pinnedNet = CGFloat((gap != nil ? 1 : 0) - (dragPinned != nil ? 1 : 0)) * unit
        let tailNet = CGFloat((tailGap != nil ? 1 : 0) - (dragTail != nil ? 1 : 0)) * unit
        let net = pinnedNet + tailNet
        let displaced: (Int, Int?, Int?) -> CGFloat = { k, dragged, gapAt in
            var d: CGFloat = 0
            var disp = k
            if let dr = dragged, k > dr { d -= unit; disp -= 1 }
            if let g = gapAt, disp >= g { d += unit }
            return d
        }
        let afterPinned = pinnedNet - net / 2
        let growL = -fe.shift(at: 0) + net / 2, growR = fe.shift(at: upper + 1) + net / 2
        let _ = { ui.layout = DockLayoutInfo(
            icon: m.icon, spacing: m.spacing,
            finderID: model.finder?.id, finderCenter: hasFinder ? leadCenters.first : nil,
            pinnedIDs: pinnedTiles.map(\.id), pinnedCenters: Array(leadCenters.dropFirst(hasFinder ? 1 : 0)),
            pinnedWidths: Array(leadWidths.dropFirst(hasFinder ? 1 : 0)),
            extraIDs: extra.map(\.id), extraCenters: extraCenters, trashCenter: trashCenter, tailIDs: tail) }()
        let hoveredIndex: Int? = {
            guard let p = ui.pointerX, fe.scale(at: p) > 1 || m.maxScale == 1 else { return nil }
            let all = leadCenters + extraCenters + [trashCenter]
            guard let (i, c) = all.enumerated().min(by: { abs($0.1 - p) < abs($1.1 - p) }).map({ ($0.0, $0.1) }),
                  abs(c - p) <= (m.icon + m.spacing) / 2 else { return nil }
            return i
        }()
        // 插在 App 之间的小组件：和图标一样大、只显示圆环
        var compact = m
        let _ = compact.widgetsCompact = true

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: m.spacing) {
                ForEach(Array(lead.enumerated()), id: \.element.id) { i, tile in
                    let shift = hasFinder && i == 0 ? -net / 2 : displaced(i - (hasFinder ? 1 : 0), dragPinned, gap) - net / 2
                    let scale = fe.scale(at: leadCenters[i])
                    Group {
                        if let item = tile.app {
                            AppIconView(item: item, model: model, metrics: m, scale: scale,
                                        hovered: hoveredIndex == i && dragID == nil && !ui.menuOpen,
                                        hidden: dragID == item.id, highlighted: ui.dropTarget == item.id || ui.menuTarget == item.id,
                                        bouncing: model.launching.contains(item.id))
                        } else {
                            Self.widget(tile.id, store: store, settings: settings, ui: ui, metrics: compact, openSettings: openSettings)
                                .frame(width: Self.tileWidth(tile.id, m))
                                .scaleEffect(scale, anchor: .bottom)
                                .opacity(dragID == tile.id ? 0 : 1)
                                .reportTileFrame(tile.id)
                        }
                    }
                    .offset(x: fe.shift(at: leadCenters[i]) + shift)
                }
                if !extra.isEmpty {
                    DockDivider(metrics: m).offset(x: fe.shift(at: dividerAfterApps) + afterPinned)
                    ForEach(Array(extra.enumerated()), id: \.element.id) { j, item in
                        AppIconView(item: item, model: model, metrics: m, scale: fe.scale(at: extraCenters[j]),
                                    hovered: hoveredIndex == lead.count + j && dragID == nil && !ui.menuOpen,
                                    hidden: dragID == item.id, highlighted: ui.dropTarget == item.id || ui.menuTarget == item.id,
                                    bouncing: model.launching.contains(item.id))
                            .offset(x: fe.shift(at: extraCenters[j]) + afterPinned)
                    }
                }
                DockDivider(metrics: m).offset(x: fe.shift(at: trashDivider) + afterPinned)
                TrashIconView(model: model, metrics: m, scale: fe.scale(at: trashCenter),
                              hovered: hoveredIndex == lead.count + extra.count && dragID == nil && !ui.menuOpen,
                              highlighted: ui.dropTarget == "trash" || ui.menuTarget == "trash")
                    .offset(x: fe.shift(at: trashCenter) + afterPinned)
                // 废纸篓右边的 AI 小组件（可以拖动排序，也可以拖到 App 之间）
                if !tail.isEmpty || tailGap != nil {
                    DockDivider(metrics: m).offset(x: fe.shift(at: upper + 1) + afterPinned)
                    ForEach(Array(tail.enumerated()), id: \.element) { j, token in
                        Self.widget(token, store: store, settings: settings, ui: ui, metrics: m, openSettings: openSettings)
                            .opacity(dragID == token ? 0 : 1)
                            .reportTileFrame(token)
                            .offset(x: fe.shift(at: upper + 1) + pinnedNet + displaced(j, dragTail, tailGap) - net / 2)
                    }
                }
            }
            .padding(.horizontal, m.padH)
            .padding(.top, m.padTop)
            .padding(.bottom, m.padBottom)
            // 玻璃直接挂在内容上（放到单独的背景层里会取不到后面的画面、变成不透明）。
            // 放大时背景变宽：先加宽边距再用负边距抵消，内容位置不变，玻璃向两侧延伸
            .padding(.leading, growL)
            .padding(.trailing, growR)
            .dockGlass(cornerRadius: m.corner, style: settings.dockBackground)
            .padding(.leading, -growL)
            .padding(.trailing, -growR)
            .contentShape(Rectangle())
            .coordinateSpace(name: "dockbar")
            .onPreferenceChange(TileFramesKey.self) { frames in
                MainActor.assumeIsolated { ui.tileFrames = frames }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let loc): ui.pointer(loc.x)
                case .ended: ui.pointer(nil)
                }
            }
            .onHover { ui.overDock = $0 }
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.82, blendDuration: 0.08), value: ui.pointerX)
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: ui.dropIndex)
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: ui.tailDropIndex)
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: ui.dragID)
        }
        .frame(height: m.totalHeight)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, m.growMax + 4)
        // 透明背景：文字、指示灯、分隔线的深浅跟着 Dock 背后的亮度走
        .modifier(BackdropScheme(light: settings.dockBackground == .clear ? ui.backdropLight : nil))
        // 切换语言时整体重建，保证所有文字都换成新语言
        .id(settings.language)
    }
}

// MARK: - 小部件

struct DockDivider: View {
    var metrics: DockMetrics
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.32))
            .frame(width: 1, height: metrics.icon * 0.72)
            .padding(.bottom, metrics.dotRow + metrics.icon * 0.14)
            .padding(.horizontal, 2)
    }
}

/// 图标上方的名称标签（和系统 Dock 一样）
struct DockLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .fixedSize()
    }
}

struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.brightness(configuration.isPressed ? -0.18 : 0)
    }
}

struct AppIconView: View {
    let item: DockModel.Item
    @ObservedObject var model: DockModel
    let metrics: DockMetrics
    let scale: CGFloat
    let hovered: Bool
    var hidden = false
    var highlighted = false
    var bouncing = false
    /// 跳动的起始时间和收尾时间（App 启动完成后把当前这一跳跳完再停）
    @StateObject private var bounce = Box<(start: Date, stop: Date?)?>(nil)

    var body: some View {
        let running = model.running.contains(item.id)
        Button {
            // 和系统 Dock 一样：⌘ 点按在访达中显示；⌥ 点按切换并隐藏刚才的 App；⌘⌥ 点按隐藏其他所有 App
            model.open(item, modifiers: NSEvent.modifierFlags)
        } label: {
            VStack(spacing: 0) {
                // 文件拖到图标上、或打开了这个图标的菜单时，图标变暗（和系统 Dock 一样）
                let icon = Image(nsImage: model.icon(for: item)).resizable().interpolation(.high)
                    .frame(width: metrics.icon, height: metrics.icon)
                    .colorMultiply(Color(white: highlighted ? 0.6 : 1))
                    .scaleEffect(scale, anchor: .bottom)
                // 只在跳动期间逐帧计算位置，平时没有任何动画开销
                if let b = bounce.value {
                    TimelineView(.animation) { ctx in
                        icon.offset(y: -Bounce.height(at: ctx.date, start: b.start, stop: b.stop) * metrics.icon * scale)
                    }
                } else {
                    icon
                }
                // 主程序已退出、子进程还在后台运行的 App：指示灯半透明（和系统 Dock 一样）
                Circle().fill(Color.primary.opacity(!model.showIndicators ? 0 : running ? 0.85
                                                    : model.lingering[item.id] != nil ? 0.35 : 0))
                    .frame(width: 4, height: 4)
                    .frame(height: metrics.dotRow)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .opacity(hidden ? 0 : 1)
        .overlay(alignment: .top) {
            if hovered {
                DockLabel(text: item.name).offset(y: -(34 + metrics.icon * (scale - 1)))
                    .transition(.opacity)
            }
        }
        .zIndex(hovered ? 1 : scale)
        .animation(.easeOut(duration: 0.12), value: highlighted)
        // 启动中：图标像系统 Dock 一样一跳一跳，直到 App 启动完成
        .onChange(of: bouncing) { _, on in
            if on {
                if bounce.value == nil || bounce.value?.stop != nil { bounce.value = (Date(), nil) }
            } else if let b = bounce.value, b.stop == nil {
                let stop = Bounce.landing(after: Date(), start: b.start)
                bounce.value = (b.start, stop)
                DispatchQueue.main.asyncAfter(deadline: .now() + stop.timeIntervalSinceNow) {
                    if bounce.value?.stop == stop { bounce.value = nil }
                }
            }
        }
    }
}

/// 启动跳动：每一跳是一段抛物线——向上逐渐减速，到顶后受重力加速落下（和系统 Dock 一样）
enum Bounce {
    /// 一跳的时长
    static let period: TimeInterval = 0.66
    /// 跳起的最高高度（图标大小的倍数）
    static let peak: CGFloat = 0.5

    /// 当前高度（图标大小的倍数）；过了收尾时间就停在地面
    static func height(at now: Date, start: Date, stop: Date?) -> CGFloat {
        if let stop, now >= stop { return 0 }
        let t = now.timeIntervalSince(start).truncatingRemainder(dividingBy: period) / period
        return peak * CGFloat(4 * t * (1 - t))
    }

    /// 这一跳落地的时间
    static func landing(after now: Date, start: Date) -> Date {
        let n = ceil(now.timeIntervalSince(start) / period)
        return start.addingTimeInterval(max(1, n) * period)
    }
}

struct TrashIconView: View {
    @ObservedObject var model: DockModel
    let metrics: DockMetrics
    let scale: CGFloat
    let hovered: Bool
    var highlighted = false

    var body: some View {
        Button { model.openTrash() } label: {
            VStack(spacing: 0) {
                Image(nsImage: model.trashFull ? model.trashFullIcon : model.trashEmptyIcon).resizable()
                    .frame(width: metrics.icon, height: metrics.icon)
                    .colorMultiply(Color(white: highlighted ? 0.6 : 1))
                    .scaleEffect(scale, anchor: .bottom)
                Color.clear.frame(height: metrics.dotRow)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .overlay(alignment: .top) {
            if hovered { DockLabel(text: L("废纸篓")).offset(y: -(34 + metrics.icon * (scale - 1))) }
        }
        .zIndex(hovered ? 1 : scale)
        .animation(.easeOut(duration: 0.12), value: highlighted)
        .onHover { if $0 { model.refreshTrash() } }
    }
}

// MARK: - AI 小组件

struct ProviderWidget: View {
    var provider: Provider
    var usage: ProviderUsage?
    var live: LiveStatus?
    @ObservedObject var ui: DockUIState
    var metrics: DockMetrics
    let store: UsageStore
    let openSettings: () -> Void

    @StateObject private var showDetail = Box(false)

    /// 圆环只有两圈：窗口多于两个时（Cursor、Antigravity）显示用得最多的两个，保持原来的先后顺序
    private var shownWindows: [UsageWindow] {
        let all = usage?.windows ?? []
        guard all.count > 2 else { return all }
        return all.enumerated().sorted { $0.element.usedPercent > $1.element.usedPercent }
            .prefix(2).sorted { $0.offset < $1.offset }.map(\.element)
    }

    var body: some View {
        let ws = shownWindows
        let ring = metrics.icon * 0.92
        let id = "w-\(provider.rawValue)"
        Button {
            Focus.borrow()
            showDetail.value.toggle()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    DualRing(outer: ws.first?.usedPercent, inner: ws.count > 1 ? ws[1].usedPercent : nil,
                             color: provider.color, size: ring, line: max(3, ring * 0.085)) {
                        ProviderLogo(provider: provider, size: ring * 0.4)
                    }
                    .overlay(alignment: .topTrailing) {
                        // 亮点：正在工作；暗点：打开了但没在工作；空心圈：没打开
                        if let st = live?.state(), st != .missing {
                            LiveDot(provider: provider, state: st, size: 6).offset(x: 4, y: -4)
                        }
                    }
                    if !metrics.widgetsCompact {
                        VStack(alignment: .leading, spacing: 1) {
                            if ws.isEmpty {
                                Text(usage == nil ? L("读取中") : L("未连接")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            ForEach(ws.prefix(2)) { w in
                                HStack(spacing: 3) {
                                    Text(L(w.short)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text(Fmt.pct(w.usedPercent)).font(.system(size: 12, weight: .semibold))
                                    if let s = statusColor(for: w.usedPercent) {
                                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 7)).foregroundStyle(s)
                                    }
                                }
                                .monospacedDigit()
                            }
                        }
                        .frame(width: ws.contains { L($0.short).count > 5 } ? 96 : 66, alignment: .leading)
                    }
                }
                .frame(height: metrics.icon)
                Text(metrics.widgetsCompact ? (usage?.tightest.map { Fmt.pct($0.usedPercent) } ?? (usage?.error != nil ? "!" : "")) : "")
                    .font(.system(size: 8.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(height: metrics.dotRow)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .overlay(alignment: .top) {
            if ui.hovered == id && !showDetail.value && !ui.menuOpen {
                DockLabel(text: labelText).offset(y: -34)
            }
        }
        .zIndex(ui.hovered == id ? 1 : 0)
        .onHover { ui.hover(id, index: nil, $0) }
        .popover(isPresented: $showDetail.value, arrowEdge: .top) {
            ProviderCard(provider: provider, usage: usage, live: live, showDetails: true)
                .padding(14).frame(width: 300)
                .focusEffectDisabled()
                .systemColorScheme()
        }
        .onChange(of: showDetail.value) { _, open in
            ui.popoverCount += open ? 1 : -1
            if !open { Focus.giveBack() }
        }
    }

    private var labelText: String {
        let ws = usage?.windows ?? []
        if ws.isEmpty { return provider.name + (usage?.error != nil ? L(" · 未连接") : "") }
        return ([provider.name] + ws.prefix(2).map { "\(L($0.short)) \(Fmt.pct($0.usedPercent))" }).joined(separator: " · ")
    }
}

struct ActivityWidget: View {
    var activity: ActivitySnapshot
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: DockUIState
    var metrics: DockMetrics
    let store: UsageStore
    let openSettings: () -> Void

    @StateObject private var showDetail = Box(false)

    private var providers: [Provider] {
        activity.tools(in: settings.activityRange == 1 ? activity.days : activity.hours).filter { settings.isVisible($0.id) }
    }

    var body: some View {
        let week = settings.activityRange == 1
        let width = metrics.widgetsCompact ? metrics.icon * 1.25 : 100
        // 正在工作（亮点）和打开着（暗点）的工具，最多 4 个；没打开的不显示
        let lit = providers.filter { [.working, .recent].contains(activity.states[$0] ?? .idle) }.prefix(4)
        Button {
            Focus.borrow()
            showDetail.value.toggle()
        } label: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text(week ? L("7 天") : "24h").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        ForEach(Array(lit)) { p in LiveDot(provider: p, state: activity.states[p] ?? .idle, size: 5) }
                    }
                    StackedBarChart(columns: week ? activity.days : activity.hours, providers: providers,
                                    unit: week ? .day : .hour, height: metrics.icon * (metrics.widgetsCompact ? 0.55 : 0.42),
                                    interactive: false, showAxis: false, tokens: settings.activityMetric == 1)
                    if !metrics.widgetsCompact {
                        Text(summary).font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }
                .frame(width: width, height: metrics.icon)
                Text(metrics.widgetsCompact ? todayMetric : "")
                    .font(.system(size: 8.5, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(height: metrics.dotRow)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .overlay(alignment: .top) {
            if ui.hovered == "w-activity" && !showDetail.value && !ui.menuOpen {
                DockLabel(text: L("AI 活动 · %@", "\(summary)")).offset(y: -34)
            }
        }
        .zIndex(ui.hovered == "w-activity" ? 1 : 0)
        .onHover { ui.hover("w-activity", index: nil, $0) }
        .popover(isPresented: $showDetail.value, arrowEdge: .top) {
            ActivityCard(activity: activity, settings: settings)
                .padding(14).frame(width: 320)
                .focusEffectDisabled()
                .systemColorScheme()
        }
        .onChange(of: showDetail.value) { _, open in
            ui.popoverCount += open ? 1 : -1
            if !open { Focus.giveBack() }
        }
    }

    private var todayTotals: (minutes: Int, tokens: Int) {
        let t = activity.today
        return (providers.reduce(0) { $0 + (t[$1]?.minutes ?? 0) }, providers.reduce(0) { $0 + (t[$1]?.tokens ?? 0) })
    }

    /// 小组件下方的数字：今日使用时长或今日 Token 用量（右键菜单 / 设置里切换）
    private var todayMetric: String {
        guard activity.scannedAt != nil else { return "" }
        let t = todayTotals
        return settings.activityMetric == 1 ? Fmt.tokens(t.tokens) : Fmt.minutesCompact(t.minutes)
    }

    private var summary: String {
        if activity.scannedAt == nil { return L("读取中…") }
        let t = todayTotals
        if t.minutes == 0 { return L("今天暂无活动") }
        return L("今日 %@ · %@", "\(Fmt.minutesCompact(t.minutes))", "\(Fmt.tokens(t.tokens))")
    }
}

/// 本地模型小组件：官方标志 + 已加载的模型数
struct LocalModelsWidget: View {
    var provider: Provider
    var info: LocalModelsInfo?
    @ObservedObject var ui: DockUIState
    var metrics: DockMetrics
    let store: UsageStore
    let openSettings: () -> Void

    @StateObject private var showDetail = Box(false)

    var body: some View {
        let id = "w-\(provider.id)"
        let size = metrics.icon * 0.92
        Button {
            Focus.borrow()
            showDetail.value.toggle()
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.10), lineWidth: max(3, size * 0.085)).padding(size * 0.05)
                    if (info?.loadedCount ?? 0) > 0 {
                        Circle().stroke(provider.color, lineWidth: max(3, size * 0.085)).padding(size * 0.05)
                    }
                    ProviderLogo(provider: provider, size: size * 0.42)
                }
                .frame(width: size, height: size)
                // 亮点：有模型已加载；暗点：服务开着但没加载模型；空心圈：服务没开
                .overlay(alignment: .topTrailing) {
                    if let info {
                        LiveDot(provider: provider, state: info.running ? (info.loadedCount > 0 ? .working : .recent) : .idle, size: 6)
                            .offset(x: 4, y: -4)
                    }
                }
                .frame(height: metrics.icon)
                Text(info.map { $0.running ? L("%@ 已加载", "\($0.loadedCount)") : L("未运行") } ?? "")
                    .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(height: metrics.dotRow)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .overlay(alignment: .top) {
            if ui.hovered == id && !showDetail.value && !ui.menuOpen {
                DockLabel(text: "\(provider.name) · " + (info.map { $0.running ? L("已加载 %@ 个模型", "\($0.loadedCount)") : L("未运行") } ?? L("读取中"))).offset(y: -34)
            }
        }
        .zIndex(ui.hovered == id ? 1 : 0)
        .onHover { ui.hover(id, index: nil, $0) }
        .popover(isPresented: $showDetail.value, arrowEdge: .top) {
            LocalModelsCard(provider: provider, info: info).padding(14).frame(width: 300)
                .focusEffectDisabled()
                .systemColorScheme()
        }
        .onChange(of: showDetail.value) { _, open in
            ui.popoverCount += open ? 1 : -1
            if !open { Focus.giveBack() }
        }
    }
}

/// API 余额小组件：圆环里是余额，下面是平台名（没有官方标志时不自己画）
struct BalanceWidget: View {
    var entry: APIKeyEntry
    var balance: APIBalance?
    @ObservedObject var ui: DockUIState
    var metrics: DockMetrics

    var body: some View {
        let id = "w-api-\(entry.id)"
        let size = metrics.icon * 0.92
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: max(3, size * 0.085)).padding(size * 0.05)
                Text(balance?.error != nil ? "!" : (balance?.amountText ?? "…"))
                    .font(.system(size: size * 0.2, weight: .bold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .padding(.horizontal, size * 0.16)
            }
            .frame(width: size, height: size)
            .frame(height: metrics.icon)
            Text(entry.service.name)
                .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                .frame(height: metrics.dotRow)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if ui.hovered == id && !ui.menuOpen {
                DockLabel(text: L("%@ API 余额 · ", "\(entry.service.name)") + (balance?.error ?? balance?.amountText ?? "—")).offset(y: -34)
            }
        }
        .zIndex(ui.hovered == id ? 1 : 0)
        .onHover { ui.hover(id, index: nil, $0) }
        .help([entry.masked, balance?.detail].compactMap { $0 }.joined(separator: "\n"))
    }
}

/// 没有额度接口的工具（Gemini、Antigravity 等）：圆环 = 占今天 AI 使用时间的比例，下面是今天的使用时长
struct UsageWidget: View {
    var provider: Provider
    var activity: ActivitySnapshot
    @ObservedObject var ui: DockUIState
    var metrics: DockMetrics
    let store: UsageStore
    let openSettings: () -> Void

    @StateObject private var showDetail = Box(false)

    var body: some View {
        let id = "w-\(provider.id)"
        let ring = metrics.icon * 0.92
        let today = activity.today[provider] ?? Totals()
        let total = activity.today.values.reduce(0) { $0 + $1.minutes }
        let share = total > 0 ? Double(today.minutes) / Double(total) * 100 : 0
        Button {
            Focus.borrow()
            showDetail.value.toggle()
        } label: {
            VStack(spacing: 0) {
                DualRing(outer: today.minutes > 0 ? share : nil, inner: nil, color: provider.color,
                         size: ring, line: max(3, ring * 0.085)) {
                    ProviderLogo(provider: provider, size: ring * 0.4)
                }
                .overlay(alignment: .topTrailing) {
                    if let st = activity.states[provider], st != .missing {
                        LiveDot(provider: provider, state: st, size: 6).offset(x: 4, y: -4)
                    }
                }
                .frame(height: metrics.icon)
                Text(Fmt.minutesCompact(today.minutes))
                    .font(.system(size: 8.5, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(height: metrics.dotRow)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .overlay(alignment: .top) {
            if ui.hovered == id && !showDetail.value && !ui.menuOpen {
                DockLabel(text: L("%@ · 今日 %@ · 占今日 AI 时间 %@", "\(provider.name)", "\(Fmt.minutes(today.minutes))", "\(Fmt.pct(share))")).offset(y: -34)
            }
        }
        .zIndex(ui.hovered == id ? 1 : 0)
        .onHover { ui.hover(id, index: nil, $0) }
        .popover(isPresented: $showDetail.value, arrowEdge: .top) {
            UsageCard(provider: provider, activity: activity, quotaNote: store.usages[provider]?.error).padding(14).frame(width: 280)
                .focusEffectDisabled()
                .systemColorScheme()
        }
        .onChange(of: showDetail.value) { _, open in
            ui.popoverCount += open ? 1 : -1
            if !open { Focus.giveBack() }
        }
    }
}

/// 没有额度接口的工具的详情：今天 / 近 7 天的活跃时间、请求、tokens
struct UsageCard: View {
    var provider: Provider
    var activity: ActivitySnapshot
    /// 读不到套餐额度时说明原因
    var quotaNote: String? = nil

    var body: some View {
        let today = activity.today[provider] ?? Totals()
        let week = activity.totals(activity.days, provider)
        let live = activity.live[provider] ?? LiveStatus()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderLogo(provider: provider, size: 15)
                Text(provider.name).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                LiveDot(provider: provider, state: live.state(), size: 6)
                Text(live.text()).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            row(L("今天"), today)
            row(L("近 7 天"), week)
            if let quotaNote {
                Label(quotaNote, systemImage: "info.circle")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let t = ToolRegistry.tool(provider.id) {
                Text(t.sources).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    private func row(_ title: String, _ t: Totals) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(t.minutes > 0 ? Fmt.minutes(t.minutes) : "—").font(.system(size: 11, weight: .semibold))
            Spacer()
            if t.requests > 0 { Text(L("%@ 次", "\(t.requests)")).font(.system(size: 10)).foregroundStyle(.secondary) }
            if t.tokens > 0 { Text("\(Fmt.tokens(t.tokens)) tokens").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .monospacedDigit()
    }
}
