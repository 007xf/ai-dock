import SwiftUI

/// 一个工具的额度卡片：每个时间窗口一行（名称 · 进度条 · 百分比 · 重置时间）
struct ProviderCard: View {
    var provider: Provider
    var usage: ProviderUsage?
    var live: LiveStatus?
    /// 弹窗里显示金额等细节；菜单里只显示一行
    var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProviderLogo(provider: provider, size: 15)
                Text(provider.name).font(.system(size: 12.5, weight: .semibold))
                if let plan = usage?.plan { PlanBadge(text: plan, color: provider.color) }
                Spacer(minLength: 4)
                if let live {
                    LiveDot(provider: provider, state: live.state(), size: 6)
                    Text(live.text()).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help(helpText)

            if let usage, !usage.windows.isEmpty {
                ForEach(usage.windows) { w in
                    WindowLine(window: w, color: provider.color, showDetail: showDetails)
                }
            } else if usage == nil {
                Text(L("正在读取…")).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if let err = usage?.error {
                Label {
                    Text(usage?.stale == true ? L("显示的是上次的数据。%@", "\(err)") : err)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusSerious)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let note = usage?.note, showDetails || usage?.source == .localLog {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if let a = usage?.account { parts.append(a) }
        if let u = usage, u.source != .none { parts.append(L("来源：%@ · 更新于 %@", "\(u.source.label)", "\(Fmt.ago(u.updatedAt))")) }
        return parts.joined(separator: "\n")
    }
}

struct WindowLine: View {
    var window: UsageWindow
    var color: Color
    var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(L(window.short))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading).lineLimit(1)
                UsageBar(percent: window.usedPercent, color: color)
                HStack(spacing: 2) {
                    if let s = statusColor(for: window.usedPercent) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(s)
                    }
                    Text(Fmt.pct(window.usedPercent)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                }
                .frame(width: 48, alignment: .trailing)
                Text(Fmt.resetCompact(window.resetsAt) ?? "")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 70, alignment: .trailing).lineLimit(1)
            }
            if showDetail, let detail = window.detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .padding(.leading, 46)
            }
        }
        .help([L(window.label), Fmt.pct(window.usedPercent), window.detail, Fmt.reset(window.resetsAt)]
            .compactMap { $0 }.joined(separator: " · "))
    }
}

struct ActivityCard: View {
    var activity: ActivitySnapshot
    @ObservedObject var settings: AppSettings
    var chartHeight: CGFloat = 70

    private var columns: [ActivityColumn] { settings.activityRange == 0 ? activity.hours : activity.days }

    var body: some View {
        let providers = activity.tools(in: columns).filter { settings.isVisible($0.id) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(L("AI 活动")).font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help(L("柱子 = 每小时（或每天）的活跃分钟：会话日志里有模型响应的分钟，加上 AI App 在前台使用的分钟。\nTokens 含缓存（与 ChatGPT、Claude 官方统计口径一致）。按本地时间 0 点切分每天；ChatGPT 个人资料按 UTC（北京时间早上 8 点）切分，所以单日数字会有出入。"))
                Spacer()
                Picker("", selection: $settings.activityRange) {
                    Text(L("24 小时")).tag(0)
                    Text(L("7 天")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(width: 116)
            }

            if activity.scannedAt == nil {
                Text(L("正在读取本地会话日志…")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if providers.isEmpty {
                Text(settings.activityRange == 0 ? L("近 24 小时没有 AI 活动") : L("近 7 天没有 AI 活动"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                StackedBarChart(columns: columns, providers: providers,
                                unit: settings.activityRange == 0 ? .hour : .day, height: chartHeight)
                    .padding(.top, 12)

                // 图例 + 数据表
                VStack(spacing: 4) {
                    HStack(spacing: 0) {
                        Spacer()
                        Text(L("活跃")).frame(width: 56, alignment: .trailing)
                        Text(L("请求")).frame(width: 46, alignment: .trailing)
                        Text("Tokens").frame(width: 52, alignment: .trailing)
                    }
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    ForEach(providers) { p in
                        let t = activity.totals(columns, p)
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 2).fill(p.color).frame(width: 8, height: 8)
                                .padding(.trailing, 5)
                            Text(p.short).lineLimit(1)
                            LiveDot(provider: p, state: activity.states[p] ?? .idle, size: 5)
                                .help((activity.live[p] ?? LiveStatus()).text())
                            Spacer()
                            Text(t.minutes > 0 ? Fmt.minutesCompact(t.minutes) : "—").frame(width: 56, alignment: .trailing)
                            Text(t.requests > 0 ? "\(t.requests)" : "—").frame(width: 46, alignment: .trailing)
                            Text(t.tokens > 0 ? Fmt.tokens(t.tokens) : "—").frame(width: 52, alignment: .trailing)
                        }
                        .font(.system(size: 11)).monospacedDigit()
                    }
                }
            }
        }
    }
}

/// 本地模型卡片（Ollama / LM Studio）
struct LocalModelsCard: View {
    var provider: Provider
    var info: LocalModelsInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderLogo(provider: provider, size: 15)
                Text(provider.name).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let info {
                    Text(info.running ? L("运行中 · 已加载 %@ / %@", "\(info.loadedCount)", "\(info.models.count)") : L("未运行 · %@ 个模型", "\(info.models.count)"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let info {
                if info.models.isEmpty {
                    Text(L("没有找到已下载的模型")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(info.models.prefix(6)) { m in
                    HStack(spacing: 6) {
                        Circle().fill(m.loaded ? provider.color : .clear)
                            .overlay(Circle().strokeBorder(m.loaded ? .clear : Color.secondary.opacity(0.55), lineWidth: 1))
                            .frame(width: 6, height: 6)
                        Text(m.id).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(m.detail ?? m.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(m.loaded ? L("已加载到内存") : L("未加载"))
                }
                if info.models.count > 6 {
                    Text(L("还有 %@ 个模型", "\(info.models.count - 6)")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } else {
                Text(L("正在读取…")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
