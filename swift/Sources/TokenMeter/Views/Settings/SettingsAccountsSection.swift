import SwiftUI

struct SettingsAccountsSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var interaction: SettingsAccountsController
    private let store = ConfigStore.shared

    // MARK: - 平台账户与额度

    // 四个连接共用一张卡、同一套行结构：标题行（图标 + 名称 + 连接状态徽章 +
    // 展开箭头）点击展开输入区。已配置的默认收起，避免整页空输入框。
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: Binding(
                    get: { state.deepseekEnabled },
                    set: { state.setDeepseekEnabled($0) }
                )) {
                    HStack(spacing: 9) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 27, height: 27)
                            .background(
                                Theme.brand.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DeepSeek 开放平台")
                                .font(.system(size: 12, weight: .semibold))
                            Text("余额与 API 消费 · 不计入 Coding 合计")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        // 与数据来源行一致：文字撑满，开关统一靠右
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel("DeepSeek 开放平台")
                .accessibilityHint("余额与 API 消费，不计入 Coding 合计")
                .padding(.vertical, 7)

                Divider().padding(.leading, 36)
                connectionBalance
                Divider().padding(.leading, 36)
                connectionUsage
                Divider().padding(.leading, 36)
                connectionKimi
                Divider().padding(.leading, 36)
                connectionZhipu
            }
        }
    }

    private var connectionBalance: some View {
        AccountConnectionRow(
            icon: "key",
            tint: Theme.brand,
            title: "余额查询",
            detail: "API Key 查询平台余额，只存本机 Keychain",
            configured: store.apiKeyConfigured,
            readError: store.apiKeyRead.error,
            statusText: store.apiKeyRead.error?.errorDescription ?? interaction.apiStatus,
            expanded: $interaction.expandBalanceKey
        ) {
            SecureField("sk-...", text: $interaction.apiKeyInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("验证并保存") { interaction.saveApiKey() }
                    .disabled(interaction.busy || interaction.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("清除") { interaction.clearApiKey() }
                    .disabled(interaction.busy || !store.apiKeyConfigured)
                Spacer()
            }
        }
    }

    private var connectionUsage: some View {
        AccountConnectionRow(
            icon: "chart.bar.doc.horizontal",
            tint: Theme.brand,
            title: "平台消费查询",
            detail: "需网页登录授权；Token 仍只存本机",
            configured: store.usageTokenConfigured,
            readError: store.usageTokenRead.error,
            statusText: store.usageTokenRead.error?.errorDescription ?? interaction.usageStatus,
            expanded: $interaction.expandUsageToken
        ) {
            HStack(spacing: 10) {
                Button(interaction.syncing ? "等待登录完成…" : "网页登录授权") { interaction.startSync() }
                    .disabled(interaction.syncing)
                Button(interaction.showManualPaste ? "收起手动输入" : "手动输入 Token") {
                    interaction.showManualPaste.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.brand)
                .accessibilityIdentifier("TokenMeter.Settings.DeepSeek.ManualToken")
            }
            if interaction.showManualPaste {
                Text("浏览器控制台执行 JSON.parse(localStorage.userToken).value 后复制结果")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField("粘贴 Token", text: $interaction.usageTokenInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("验证并保存") { interaction.saveUsageToken() }
                        .disabled(
                            interaction.busy || interaction.usageTokenInput
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    Button("清除") { interaction.clearUsageToken() }
                        .disabled(interaction.busy || !store.usageTokenConfigured)
                    Spacer()
                }
            }
        }
    }

    private var connectionKimi: some View {
        AccountConnectionRow(
            icon: "key.viewfinder",
            tint: Theme.kimi,
            title: "Kimi Coding 订阅额度",
            detail: "官方 5 小时 / 周额度查询；本地用量无需 Key",
            configured: store.kimiCodeKeyConfigured,
            readError: store.kimiCodeKeyRead.error,
            statusText: store.kimiCodeKeyRead.error?.errorDescription ?? interaction.kimiCodeKeyStatus,
            expanded: $interaction.expandKimiKey
        ) {
            Text("仅用于官方 5 小时、周额度与 Extra Usage；请求只发往 Kimi 官方，不读取 Kimi.app 或 CC Switch 私有配置。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("粘贴 Kimi For Coding Key", text: $interaction.kimiCodeKeyInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("验证并保存") { interaction.saveKimiCodeKey() }
                    .disabled(
                        interaction.busy || interaction.kimiCodeKeyInput
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                Button("清除") { interaction.clearKimiCodeKey() }
                    .disabled(interaction.busy || !store.kimiCodeKeyConfigured)
                Spacer()
            }
        }
    }

    private var connectionZhipu: some View {
        AccountConnectionRow(
            icon: "key.viewfinder",
            tint: Theme.zhipu,
            title: "智谱 GLM 订阅额度",
            detail: "Coding Plan 额度与工具调用次数查询",
            configured: store.zhipuKeyConfigured,
            readError: store.zhipuKeyRead.error,
            statusText: store.zhipuKeyRead.error?.errorDescription ?? interaction.zhipuKeyStatus,
            expanded: $interaction.expandZhipuKey
        ) {
            Text("Key 只存本机 Keychain，只发往所选域名的官方接口。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(
                "接口域名",
                selection: Binding(
                    get: { store.zhipuQuotaDomain },
                    set: { domain in
                        guard domain != store.zhipuQuotaDomain else { return }
                        state.setZhipuQuotaDomain(domain)
                        interaction.zhipuKeyStatus = store.zhipuKeyConfigured
                            ? "已配置 \(store.zhipuKeyPreview() ?? "")（\(store.zhipuQuotaDomain.title)）"
                            : "未配置（\(store.zhipuQuotaDomain.title)）"
                    }
                )
            ) {
                Text("国内版").tag(ZhipuQuotaDomain.china)
                Text("国际版").tag(ZhipuQuotaDomain.international)
            }
            .pickerStyle(.segmented)
            SecureField("粘贴智谱 API Key", text: $interaction.zhipuKeyInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("验证并保存") { interaction.saveZhipuKey() }
                    .disabled(
                        interaction.busy || interaction.zhipuKeyInput
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                Button("清除") { interaction.clearZhipuKey() }
                    .disabled(interaction.busy || !store.zhipuKeyConfigured)
                Spacer()
            }
        }
    }


}

// 账户连接行：整行可点展开/收起；未连接的引导输入，已连接的收起成一行状态。
private struct AccountConnectionRow<Fields: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let configured: Bool
    let readError: CredentialStoreError?
    let statusText: String
    @Binding var expanded: Bool
    let fields: Fields

    init(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        configured: Bool,
        readError: CredentialStoreError? = nil,
        statusText: String,
        expanded: Binding<Bool>,
        @ViewBuilder fields: () -> Fields
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.detail = detail
        self.configured = configured
        self.readError = readError
        self.statusText = statusText
        self._expanded = expanded
        self.fields = fields()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 27, height: 27)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Text(readError != nil ? "暂不可读" : (configured ? "已连接" : "未连接"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(readError != nil ? Color.orange : (configured ? Color.green : Color.secondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (readError != nil ? Color.orange : (configured ? Color.green : Color.secondary)).opacity(0.12),
                            in: Capsule()
                        )
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .hoverHighlight()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(expanded ? "收起输入区" : "展开输入区")

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    fields
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 36)
                .transition(.opacity)
            }
        }
    }
}
