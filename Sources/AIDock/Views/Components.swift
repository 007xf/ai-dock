import SwiftUI
import AppKit

// MARK: - Glass

enum RenderEnv {
    /// 预览渲染时截图拿不到玻璃效果，用半透明底色代替
    static var preview = false
}

/// 系统当前的浅色 / 深色外观（Dock 透明时内部统一用深色外观，弹窗要换回系统外观）
enum SystemScheme {
    @MainActor static var current: ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

/// 透明 Dock 背景：像系统 Dock 的玻璃一样，背后的壁纸清楚可见；
/// 浅色模式压一层很淡的白、深色模式压一层很淡的黑，边缘一圈高光勾出轮廓
struct ClearDockBackground: View {
    let shape: RoundedRectangle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        // 不加外阴影：阴影会透过半透明的底色把整条 Dock 压灰
        ZStack {
            shape.fill(dark ? Color.black.opacity(0.1) : Color.white.opacity(0.08))
            shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.05 : 0.1), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.35 : 0.55), .white.opacity(dark ? 0.08 : 0.15),
                                                       .white.opacity(dark ? 0.18 : 0.3)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
            shape.strokeBorder(Color.black.opacity(dark ? 0.3 : 0.1), lineWidth: 0.5).padding(-0.5)
        }
    }
}

/// 透明背景下给小组件文字和指示灯加一圈和文字反色的描边：浅色模式深字配浅描边，深色模式浅字配深描边，
/// 背后是亮的窗口还是暗的壁纸都看得清
struct DockInkShadow: ViewModifier {
    var on: Bool
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if on {
            let halo = scheme == .dark ? Color.black : Color.white
            content.shadow(color: halo.opacity(0.85), radius: 1).shadow(color: halo.opacity(0.45), radius: 2.5)
        } else { content }
    }
}

/// 透明 Dock 背后亮就用浅色外观（深色字），背后暗就用深色外观（浅色字）
struct BackdropScheme: ViewModifier {
    var light: Bool?
    func body(content: Content) -> some View {
        if let light { content.environment(\.colorScheme, light ? .light : .dark) } else { content }
    }
}

struct ForceDarkScheme: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.environment(\.colorScheme, .dark) } else { content }
    }
}

extension View {
    @MainActor func systemColorScheme() -> some View {
        environment(\.colorScheme, SystemScheme.current)
    }

    @ViewBuilder
    func dockGlass(cornerRadius: CGFloat, style: DockBackground = .glass) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if style == .clear {
            self.background { ClearDockBackground(shape: shape) }
        } else if RenderEnv.preview {
            self.background(shape.fill(Color.primary.opacity(0.07)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            // 系统 Dock 用的是更通透的「清透」玻璃（.regular 带磨砂，看起来发实）
            self.glassEffect(.clear, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
    }
}

// MARK: - Logos

/// 官方品牌标志
struct ProviderLogo: View {
    var provider: Provider
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let img = provider.logo(dark: scheme == .dark) {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Text(String(provider.short.prefix(1)))
                .font(.system(size: size * 0.7, weight: .bold, design: .rounded))
                .foregroundStyle(provider.color)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Rings

/// 双环仪表：外环 = 第一个窗口（如 5 小时），内环 = 第二个窗口（如本周）
struct DualRing<Center: View>: View {
    var outer: Double?
    var inner: Double?
    var color: Color
    var size: CGFloat = 42
    var line: CGFloat = 4
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            ring(value: outer, inset: 0, opacity: 1)
            if inner != nil {
                ring(value: inner, inset: line + 1.5, opacity: 0.55)
            }
            center()
        }
        .frame(width: size, height: size)
    }

    private func ring(value: Double?, inset: CGFloat, opacity: Double) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: line)
            if let value {
                Circle()
                    .trim(from: 0, to: max(0.012, min(1, value / 100)))
                    .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(inset + line / 2)
    }
}

// MARK: - Bars

struct UsageBar: View {
    var percent: Double
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if percent > 0 {
                    Capsule().fill(color)
                        .frame(width: max(height, geo.size.width * min(1, percent / 100)))
                }
            }
        }
        .frame(height: height)
    }
}

struct PlanBadge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// 状态点（静态，不做循环动画以节省电量）：工作中 = 实心 + 光圈，最近活跃 = 半透明，空闲 = 空心
struct LiveDot: View {
    var provider: Provider
    var state: LiveStatus.State
    var size: CGFloat = 7

    var body: some View {
        ZStack {
            if state == .working {
                Circle().fill(provider.color.opacity(0.28)).frame(width: size * 1.9, height: size * 1.9)
            }
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(state == .idle || state == .missing ? Color.secondary.opacity(0.55) : .clear, lineWidth: 1))
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.9, height: size * 1.9)
    }

    private var fill: Color {
        switch state {
        case .working: return provider.color
        case .recent: return provider.color.opacity(0.45)
        case .idle, .missing: return .clear
        }
    }
}

// MARK: - Menu bar icon

enum MenuBarIcon {
    /// 纯黑位图模板：交给系统按菜单栏的实际深浅自动着色，和其他菜单栏图标颜色一致。
    /// 三段同心圆弧，呼应 App 图标
    static let image: NSImage = {
        let pt: CGFloat = 18, scale: CGFloat = 2
        let px = Int(pt * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: px * 4, bitsPerPixel: 32)!
        rep.size = NSSize(width: pt, height: pt)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let c = CGPoint(x: pt / 2, y: pt / 2)
        for (r, frac) in [(7.4, 0.8), (4.6, 0.62), (1.9, 1.0)] as [(CGFloat, CGFloat)] {
            let p = NSBezierPath()
            if frac >= 1 {
                p.appendOval(in: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                NSColor.black.setFill(); p.fill()
            } else {
                p.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
                p.lineWidth = 1.8
                p.lineCapStyle = .round
                NSColor.black.setStroke(); p.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        img.isTemplate = true
        return img
    }()
}

// MARK: - Stacked bar chart（活跃分钟）

struct StackedBarChart: View {
    var columns: [ActivityColumn]
    var providers: [Provider]
    var unit: Calendar.Component   // .hour / .day
    var height: CGFloat = 110
    var interactive = true
    var showAxis = true
    /// 按 Token 用量画（默认按使用时长）
    var tokens = false

    @StateObject private var hoverBox = Box<Int?>(nil)
    private var hover: Int? { hoverBox.value }

    private var maxValue: Double {
        if tokens {
            return max(1_000, columns.map { Double($0.totalTokens(providers)) }.max() ?? 0)
        }
        let m = columns.map { Double($0.total(providers)) }.max() ?? 0
        return max(unit == .hour ? 10 : 60, m)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let n = max(1, columns.count)
                let gap: CGFloat = n > 12 ? (geo.size.width > 200 ? 3 : 1.5) : (geo.size.width > 200 ? 8 : 3)
                let barW = max(1.5, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
                let plotH = geo.size.height

                ZStack(alignment: .bottomLeading) {
                    if showAxis {
                        Rectangle().fill(Color.chartGrid).frame(height: 1)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { i, col in
                            BarStack(column: col, providers: providers, maxValue: maxValue, tokens: tokens,
                                     height: plotH - 2, width: barW,
                                     dimmed: hover != nil && hover != i)
                                .frame(width: barW, height: plotH, alignment: .bottom)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    guard interactive else { return }
                                    if inside { hoverBox.value = i } else if hoverBox.value == i { hoverBox.value = nil }
                                }
                        }
                    }
                    Rectangle().fill(Color.chartAxis).frame(height: 1)
                }
                .overlay(alignment: .topLeading) {
                    if interactive, let h = hover, h < columns.count {
                        let x = CGFloat(h) * (barW + gap)
                        let tipW: CGFloat = 160
                        let left = x + barW + 8 + tipW > geo.size.width ? x - tipW - 8 : x + barW + 8
                        ChartTooltip(column: columns[h], providers: providers, unit: unit)
                            .frame(width: tipW, alignment: .leading)
                            .offset(x: max(0, left), y: 0)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if showAxis {
                        Text(L("%@ 分", "\(Int(maxValue))"))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .offset(y: -12)
                    }
                }
            }
            .frame(height: height)

            if showAxis { axis }
        }
    }

    private var axis: some View {
        HStack {
            ForEach(axisLabels, id: \.self) { label in
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                if label != axisLabels.last { Spacer(minLength: 0) }
            }
        }
    }

    private var axisLabels: [String] {
        guard let first = columns.first, let last = columns.last else { return [] }
        if unit == .hour {
            let mid = columns[columns.count / 2]
            return [Fmt.hour.string(from: first.start), Fmt.hour.string(from: mid.start), L("现在")]
        }
        return columns.map { $0.id == last.id ? L("今天") : Fmt.weekday.string(from: $0.start) }
    }
}

private struct BarStack: View {
    var column: ActivityColumn
    var providers: [Provider]
    var maxValue: Double
    var tokens = false
    var height: CGFloat
    var width: CGFloat
    var dimmed: Bool

    var body: some View {
        let floor: CGFloat = height < 40 ? 1 : 2
        let segs: [(Provider, CGFloat)] = providers.compactMap { p in
            let v = (tokens ? column.values[p]?.tokens : column.values[p]?.minutes) ?? 0
            guard v > 0 else { return nil }
            return (p, max(floor, CGFloat(Double(v) / maxValue) * (height - CGFloat(providers.count) * floor)))
        }
        let r = min(height < 40 ? 1.5 : 4, width / 2)
        VStack(spacing: floor) {
            ForEach(Array(segs.reversed().enumerated()), id: \.offset) { idx, seg in
                UnevenRoundedRectangle(topLeadingRadius: idx == 0 ? r : 0, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: idx == 0 ? r : 0,
                                       style: .continuous)
                    .fill(seg.0.color)
                    .frame(height: seg.1)
            }
        }
        .opacity(dimmed ? 0.4 : 1)
    }
}

private struct ChartTooltip: View {
    var column: ActivityColumn
    var providers: [Provider]
    var unit: Calendar.Component

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold))
            ForEach(providers) { p in
                let v = column.values[p] ?? Totals()
                HStack(spacing: 6) {
                    Circle().fill(p.color).frame(width: 7, height: 7)
                    Text(p.short).font(.system(size: 11))
                    Spacer(minLength: 4)
                    Text(v.minutes > 0 ? Fmt.minutes(v.minutes) : "—")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                if v.requests > 0 {
                    Text(L("%@ 次请求 · %@ tokens", "\(v.requests)", "\(Fmt.tokens(v.tokens))"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.leading, 13)
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private var title: String {
        if unit == .hour {
            let end = column.start.addingTimeInterval(3600)
            return "\(Fmt.hour.string(from: column.start)) – \(Fmt.hour.string(from: end))"
        }
        return "\(Fmt.monthDay.string(from: column.start)) \(Fmt.weekday.string(from: column.start))"
    }
}
