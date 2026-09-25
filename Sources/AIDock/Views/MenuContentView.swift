import SwiftUI
import ServiceManagement

/// 菜单栏面板：紧凑的总览
struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    var openSettings: () -> Void = {}
    /// 超过这个高度时中间内容改为滚动
    var maxHeight: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L("AI 用量")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let t = store.lastRefresh {
                    Text(Fmt.ago(t)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L("立即刷新")).disabled(store.refreshing)
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help(L("设置（⌘,）"))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            if let maxHeight {
                ScrollView { sections }.frame(height: maxHeight - 80)
            } else {
                sections
            }

            Divider()
            HStack {
                Button(L("设置…"), action: openSettings)
                Spacer()
                Button(L("退出 AI Dock")) { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 320)
        .focusEffectDisabled()
    }

    @ViewBuilder private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !settings.visibleProviders.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(settings.visibleProviders) { p in
                        ProviderCard(provider: p, usage: store.usages[p], live: store.activity.live[p])
                    }
                }
                .padding(14)
            }

            if !settings.visibleLocalTools.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(settings.visibleLocalTools) { p in LocalModelsCard(provider: p, info: store.localModels[p]) }
                }
                .padding(14)
            }

            if !store.apiKeys.isEmpty {
                Divider()
                APIBalanceCard(keys: store.apiKeys, balances: store.apiBalances).padding(14)
            }

            Divider()
            ActivityCard(activity: store.activity, settings: settings)
                .padding(14)
        }
    }
}

/// 设置窗口：顶部分页，每页只显示一类设置（⌘1–⌘4 切换）
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, dock, widgets, data
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return L("通用")
            case .dock: return "Dock"
            case .widgets: return L("AI 工具")
            case .data: return L("数据")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .dock: return "dock.rectangle"
            case .widgets: return "sparkles"
            case .data: return "arrow.triangle.2.circlepath"
            }
        }
    }

    @ObservedObject var settings: AppSettings
    let model: DockModel
    @ObservedObject var store: UsageStore
    @StateObject private var pane = Box(Pane.general)
    @StateObject private var launchAtLogin = Box(SMAppService.mainApp.status == .enabled)
    @StateObject private var launchError = Box<String?>(nil)
    @StateObject private var keyDraft = Box<[String: String]>([:])
    @StateObject private var addingKey = Box(false)

    init(settings: AppSettings, model: DockModel, store: UsageStore, pane: Pane = .general) {
        self.settings = settings
        self.model = model
        self.store = store
        _pane = StateObject(wrappedValue: Box(pane))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(Pane.allCases.enumerated()), id: \.element) { i, p in
                    Button { pane.value = p } label: {
                        VStack(spacing: 3) {
                            Image(systemName: p.symbol).font(.system(size: 17))
                            Text(p.title).font(.system(size: 11))
                        }
                        .frame(width: 72, height: 46)
                        .foregroundStyle(pane.value == p ? Color.accentColor : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(pane.value == p ? 0.08 : 0)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .help(L("%@（⌘%@）", "\(p.title)", "\(i + 1)"))
                }
            }
            .padding(.vertical, 8)
            Divider()

            Form { content }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .id(settings.language)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .focusEffectDisabled()
    }

    @ViewBuilder private var content: some View {
        switch pane.value {
        case .general:
            Section {
                Picker(L("语言"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
            }
            Section {
                Toggle(L("使用 AI Dock"), isOn: $settings.dockEnabled)
                Toggle(isOn: $settings.hideSystemDock) {
                    Text(L("隐藏系统 Dock"))
                    Text(L("退出 AI Dock 时会自动恢复"))
                }
                .disabled(!settings.dockEnabled)
                Toggle(L("在菜单栏显示图标"), isOn: $settings.showMenuBarIcon)
                Toggle(L("登录时自动启动"), isOn: $launchAtLogin.value)
                    .onChange(of: launchAtLogin.value) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchError.value = nil
                        } catch {
                            launchError.value = L("设置失败：%@", "\(error.localizedDescription)")
                            launchAtLogin.value = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let err = launchError.value {
                    Text(err).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent(L("快捷键")) {
                    Text(L("⌘, 设置 · ⌘W 关闭 · ⌘Q 退出")).foregroundStyle(.secondary)
                }
                Button(L("退出 AI Dock")) { NSApp.terminate(nil) }
            }

        case .dock:
            Section {
                Toggle(L("自动隐藏（鼠标移到屏幕底部时出现）"), isOn: $settings.autoHide)
                LabeledContent(L("图标大小")) {
                    Slider(value: $settings.iconSize, in: 36...80, step: 2).frame(width: 180)
                }
                Toggle(L("悬停放大"), isOn: $settings.magnify)
                LabeledContent(L("放大后大小")) {
                    Slider(value: $settings.magnifySize, in: max(40, settings.iconSize + 4)...128, step: 2).frame(width: 180)
                }
                .disabled(!settings.magnify)
                Picker(L("Dock 背景"), selection: $settings.dockBackground) {
                    ForEach(DockBackground.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(L("空间不够时会自动缩小图标，并把小组件切换成只显示圆环。")).font(.caption).foregroundStyle(.secondary)
            }
            Section { Button(L("从系统 Dock 重新导入 App")) { model.importFromSystemDock() } }

        case .widgets:
            Section {
                if store.tools.isEmpty {
                    Text(L("没有检测到 AI 工具")).foregroundStyle(.secondary)
                }
                ForEach(store.tools) { t in
                    Toggle(isOn: settings.binding(for: Provider(id: t.id))) {
                        HStack(spacing: 8) {
                            ProviderLogo(provider: Provider(id: t.id), size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(Provider(id: t.id).name)
                                    ForEach(t.capabilities, id: \.self) { c in CapabilityChip(text: c.title) }
                                }
                                Text(t.sources).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } header: {
                Text(L("本机检测到 %@ 个 AI 工具", "\(store.tools.count)"))
            } footer: {
                Text(L("关掉的工具不会出现在 Dock、菜单和活动统计里。支持识别 %@ 种工具，包括 Claude、ChatGPT、Cursor、Gemini、Copilot、Windsurf、Trae、Kiro、豆包、Kimi、DeepSeek、元宝、Ollama、LM Studio 等。", "\(ToolCatalog.all.count)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("在 Dock 显示 AI 活动"), isOn: $settings.showActivityTile)
                Picker(L("活动小组件显示"), selection: $settings.activityMetric) {
                    Text(L("使用时长")).tag(0)
                    Text(L("Token 用量")).tag(1)
                }
                .disabled(!settings.showActivityTile)
                Picker(L("小组件样式"), selection: $settings.widgetStyle) {
                    ForEach(WidgetStyle.allCases) { Text($0.label).tag($0) }
                }
                Button(L("重新检测")) { store.redetect() }
            }

        case .data:
            // 和「AI 工具」页一样，按本机检测到的工具生成
            Section {
                ForEach(store.tools.filter { settings.isVisible($0.id) }) { t in
                    let p = Provider(id: t.id)
                    HStack(alignment: .top, spacing: 8) {
                        ProviderLogo(provider: p, size: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Provider(id: t.id).name)
                            ForEach(dataLines(t), id: \.self) { line in
                                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            } header: {
                Text(L("各工具的数据"))
            }

            Section {
                ForEach(store.apiKeys) { e in
                    LabeledContent {
                        HStack(spacing: 8) {
                            if let b = store.apiBalances[e.id] {
                                Text(b.error ?? b.amountText).foregroundStyle(.secondary).help(b.detail ?? "")
                            } else {
                                Text(L("查询中…")).foregroundStyle(.tertiary)
                            }
                            Button(L("移除")) { store.removeAPIKey(e) }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.service.name)
                            Text(e.masked).font(.caption).foregroundStyle(.secondary).monospaced()
                        }
                    }
                }
                // 一开始只有一个输入框；保存后收起，需要时再点「添加另一个 Key」
                if store.apiKeys.isEmpty || addingKey.value {
                    apiKeyInput
                } else {
                    Button { addingKey.value = true } label: { Label(L("添加另一个 Key"), systemImage: "plus") }
                }
            } header: {
                Text(L("API 余额"))
            } footer: {
                Text(L("粘贴任意大模型平台的 API Key，会按格式自动识别平台。支持查余额：DeepSeek、Kimi、硅基流动、OpenRouter；OpenAI、Anthropic、Gemini 等官方没有余额接口。Key 只保存在本机钥匙串里，只发给它所属的平台。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker(L("刷新间隔"), selection: $settings.refreshMinutes) {
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text(L("%@ 分钟", "\($0)")).tag($0) }
                }
                LabeledContent(L("上次刷新")) {
                    HStack {
                        Text(store.lastRefresh.map { Fmt.ago($0) } ?? "—").foregroundStyle(.secondary)
                        Button(L("立即刷新")) { store.refreshNow() }.disabled(store.refreshing)
                    }
                }
            }
        }
    }

    /// 每个工具在「数据」页里显示的内容，只列出它真正有的数据
    private func dataLines(_ t: DetectedTool) -> [String] {
        let p = Provider(id: t.id)
        var lines: [String] = []
        let caps = t.capabilities
        if caps.contains(.quota) {
            if let u = store.usages[p] {
                if let e = u.error, u.windows.isEmpty { lines.append(L("额度：%@", "\(e)")) }
                else {
                    let tight = u.tightest.map { "\($0.short) \(Fmt.pct($0.usedPercent))" } ?? ""
                    lines.append(L("额度：%@ · %@ · %@更新", "\(tight)", "\(u.source.label)", "\(Fmt.ago(u.updatedAt))"))
                }
            } else {
                lines.append(L("额度：读取中…"))
            }
        }
        if caps.contains(.activity) || caps.contains(.usageTime) {
            let today = store.activity.today[p] ?? Totals()
            var parts = [L("今日活跃 %@", "\(today.minutes > 0 ? Fmt.minutes(today.minutes) : L("0 分"))")]
            if today.requests > 0 { parts.append(L("%@ 次请求", "\(today.requests)")) }
            if today.tokens > 0 { parts.append("\(Fmt.tokens(today.tokens)) tokens") }
            let src = [caps.contains(.activity) ? L("会话日志") : nil, caps.contains(.usageTime) ? L("前台使用时长") : nil].compactMap { $0 }
            lines.append(parts.joined(separator: " · ") + L("（来自%@）", "\(src.joined(separator: L("、")))"))
        }
        if caps.contains(.localModels) {
            if let info = store.localModels[p] {
                lines.append(info.running ? L("本地模型：运行中 · 已加载 %@ / %@", "\(info.loadedCount)", "\(info.models.count)") : L("本地模型：未运行 · %@ 个已下载", "\(info.models.count)"))
            } else {
                lines.append(L("本地模型：读取中…"))
            }
        }
        return lines
    }

    /// 通用的 API Key 输入：粘贴后按格式识别平台
    @ViewBuilder private var apiKeyInput: some View {
        let draft = keyDraft.value["new"] ?? ""
        let detection = KeyDetection.detect(draft)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(L("粘贴任意大模型的 API Key"), text: Binding(get: { keyDraft.value["new"] ?? "" },
                                                            set: { keyDraft.value["new"] = $0; keyDraft.value["service"] = nil }))
                    .onSubmit { saveDraftKey() }
                Button(L("添加")) { saveDraftKey() }.disabled(chosenService == nil)
                if !store.apiKeys.isEmpty {
                    Button(L("取消")) { keyDraft.value = [:]; addingKey.value = false }
                }
            }
            if !draft.isEmpty {
                switch detection {
                case .supported(let s, let ambiguous):
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(L("识别为"))
                        if ambiguous {
                            // 同样格式的 Key 可能属于别家，允许改
                            Picker("", selection: Binding(get: { chosenService ?? s },
                                                          set: { keyDraft.value["service"] = $0.rawValue })) {
                                ForEach(APIService.allCases) { Text($0.name).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        } else {
                            Text(s.name).fontWeight(.medium)
                        }
                    }
                    .font(.caption)
                case .unsupported(let vendor):
                    Label(L("这是 %@ 的 Key：官方没有提供余额查询接口，暂时无法显示余额", "\(vendor)"), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                case .unknown:
                    Label(L("没认出这是哪家平台的 Key"), systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chosenService: APIService? {
        if let raw = keyDraft.value["service"], let s = APIService(rawValue: raw) { return s }
        if case .supported(let s, _) = KeyDetection.detect(keyDraft.value["new"] ?? "") { return s }
        return nil
    }

    private func saveDraftKey() {
        guard let s = chosenService, let key = keyDraft.value["new"], !key.isEmpty else { return }
        store.addAPIKey(key, service: s)
        keyDraft.value = [:]
        addingKey.value = false
    }
}

/// 能力标签：套餐额度 / 活动日志 / 使用时长 / 本地模型
struct CapabilityChip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// API 余额卡片
struct APIBalanceCard: View {
    var keys: [APIKeyEntry]
    var balances: [String: APIBalance]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("API 余额")).font(.system(size: 12.5, weight: .semibold))
            ForEach(keys) { e in
                let b = balances[e.id]
                HStack(spacing: 6) {
                    Text(e.service.name).font(.system(size: 11))
                    Text(e.masked).font(.system(size: 10)).foregroundStyle(.tertiary).monospaced()
                    Spacer()
                    if let err = b?.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text(b?.amountText ?? "…").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                }
                .help(b?.detail ?? "")
            }
        }
    }
}
