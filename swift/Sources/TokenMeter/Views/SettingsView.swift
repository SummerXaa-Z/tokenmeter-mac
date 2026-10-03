import SwiftUI

// 页面只拥有导航和各分区交互对象；分区隐藏后草稿、授权监听与导出反馈仍保留。
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void

    enum ExportPreset: Hashable {
        case all, d30, d90, custom
    }

    enum SettingsSection: String, CaseIterable, Identifiable {
        case dataSources = "数据来源"
        case accounts = "平台账户与额度"
        case subscriptions = "订阅与费用"
        case alerts = "菜单栏与提醒"
        case runtime = "刷新与启动"
        case tools = "工具与维护"
        var id: String { rawValue }
    }

    @State private var activeSection: SettingsSection?
    @StateObject private var accounts = SettingsAccountsController()
    @StateObject private var subscriptions = SettingsSubscriptionsInteraction()
    @StateObject private var alerts: SettingsAlertsInteraction
    @StateObject private var runtime = SettingsRuntimeInteraction()
    @StateObject private var maintenance: SettingsMaintenanceInteraction

    init(
        onBack: @escaping () -> Void,
        initialExportPreset: ExportPreset = .all,
        initialSection: SettingsSection? = nil,
        initialSampleStatus: String = ""
    ) {
        self.onBack = onBack
        _activeSection = State(initialValue: initialSection)
        _alerts = StateObject(wrappedValue: SettingsAlertsInteraction(initialSampleStatus: initialSampleStatus))
        _maintenance = StateObject(wrappedValue: SettingsMaintenanceInteraction(initialExportPreset: initialExportPreset))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .frame(height: 44)
            Divider()
            sectionBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if shows(.dataSources) {
                        sectionTitle("数据来源")
                        SettingsSourcesSection()
                    }
                    if shows(.accounts) {
                        sectionTitle("平台账户与额度")
                        SettingsAccountsSection(interaction: accounts)
                    }
                    if shows(.subscriptions) {
                        sectionTitle("订阅与费用")
                        SettingsSubscriptionsSection(interaction: subscriptions)
                    }
                    if shows(.alerts) {
                        sectionTitle("菜单栏与提醒")
                        SettingsAlertsSection(interaction: alerts)
                    }
                    if shows(.runtime) {
                        sectionTitle("刷新与启动")
                        SettingsRuntimeSection(interaction: runtime)
                    }
                    if shows(.tools) {
                        sectionTitle("工具与维护")
                        SettingsMaintenanceSection(interaction: maintenance)
                    }
                    footer
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            accounts.bind(to: state)
            runtime.prepare()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .bold))
    }

    private func shows(_ section: SettingsSection) -> Bool {
        activeSection == nil || activeSection == section
    }

    // 「全部」+ 六个分区胶囊；超出宽度可横滑，选中态与来源徽章同款配色
    private var sectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                sectionChip(nil, label: "全部")
                ForEach(SettingsSection.allCases) { section in
                    sectionChip(section, label: section.rawValue)
                }
            }
        }
    }

    private func sectionChip(_ section: SettingsSection?, label: String) -> some View {
        let selected = activeSection == section
        return Button {
            activeSection = section
        } label: {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.brand : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    selected
                        ? Theme.brand.opacity(0.12)
                        : Color.primary.opacity(0.05),
                    in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("只看\(label)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            SourceDashboardIconButton(name: "chevron.left", help: "返回上一页", action: onBack)
            Text("设置").font(.system(size: 15, weight: .bold))
            Spacer()
        }
    }


    private var footer: some View {
        Text("TokenMeter v\(Updater.currentVersion) · 凭据只存本机 Keychain · 用量绝不上报")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }


}
