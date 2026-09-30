import SwiftUI

// 设置页「订阅与费用」卡片内容：逐行填写订阅名称、月费、币种与归属来源。
// 行绑定按 id 取值，删除任意一行都不会让其余行的输入框错位。
struct SubscriptionPlansEditor: View {
    @Binding var plans: [SubscriptionPlan]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label("订阅月费", systemImage: "creditcard")
                    .font(.system(size: 12, weight: .semibold))
                Text("填写正在付费的 AI 订阅；总览按所选范围折算回本倍数，指定归属来源后对应来源页同步显示；两处均附近 13 个完整周的回本走势折线，周报与导出 CSV 同口径。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(plans) { plan in
                row(binding(for: plan.id))
            }
            HStack {
                Button {
                    plans.append(SubscriptionPlan())
                } label: {
                    Label("添加订阅", systemImage: "plus")
                }
                .controlSize(.small)
                Spacer()
                if !plans.isEmpty {
                    Text("合计每月约 \(Fmt.usd(SubscriptionPlan.monthlyTotalUSD(plans)))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Text("金额只存本机、不联网，只用于回本倍数对比；人民币按固定参考汇率 $1 = ¥\(String(format: "%.2f", APIReferencePricingCatalog.cnyPerUSD)) 折算，不联网更新。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("折算口径小抄")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                // 各处天数口径与代码一一对应:总览 OverviewSnapshot、来源页
                // SourceAPICostCard、周报 WeeklyDigest、导出 UsageCSVExport
                Group {
                    Text("· 折算订阅费 = 月费 × 12 ÷ 365 × 天数；回本倍数 = 同窗口 API 等价 ÷ 折算订阅费，低于 1 倍表示按 API 用量付费更省。")
                    Text("· API 等价按用量当日生效的价格快照重算，缺价模型不计入——倍数只会偏低，不会虚高。")
                    Text("· 天数 = 所选窗口的自然日，并从本机按天明细留存的第一天起算（更早的天没有金额，不摊订阅费）：")
                    Text("· 　总览：始终计入全部订阅；1D/7D/30D 为滚动窗口，「全部」自留存起点到今天。")
                    Text("· 　来源页：只计入归属该来源的订阅；「周」自本周一到今天、「近7天」为滚动 7 天、「月」自本月 1 日到今天。")
                    Text("· 　周报与「导出上周 CSV」：上周整周（周一到周日）。")
                    Text("· 　导出「全部/近 N 天」按导出数据的首末行日期；「自定义起止」按所选整段自然日。")
                    Text("· 周走势折线（总览卡、来源页、周报小抄、导出周明细同一条公式）：只取已结束的完整周，含今天的本周不计；折线在单周超 5 倍时纵轴封顶并在脚注说明，周报小抄与 CSV 的数字不封顶。")
                    Text("· 　来源页折线只算归属该来源的订阅与该来源明细；周报小抄取最近几个有数据的周（不足两个不显示）；导出周明细固定最近 13 个完整周、不随导出范围截取。")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ plan: Binding<SubscriptionPlan>) -> some View {
        HStack(spacing: 6) {
            TextField("名称，如 Claude Max", text: plan.name)
                .textFieldStyle(.roundedBorder)
            TextField(
                "月费",
                value: plan.monthlyFee,
                format: .number.precision(.fractionLength(0...2))
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            Picker("", selection: plan.currency) {
                ForEach(SubscriptionPlan.currencies, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 62)
            Picker("归属", selection: plan.source) {
                Text("不指定").tag(HistorySource?.none)
                ForEach(HistorySource.codingAgents, id: \.self) { source in
                    Text(source.overviewName).tag(HistorySource?.some(source))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 96)
            Button {
                let id = plan.wrappedValue.id
                plans.removeAll { $0.id == id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除这条订阅")
        }
        .controlSize(.small)
    }

    private func binding(for id: UUID) -> Binding<SubscriptionPlan> {
        Binding(
            get: { plans.first { $0.id == id } ?? SubscriptionPlan(id: id) },
            set: { newValue in
                guard let index = plans.firstIndex(where: { $0.id == id }) else { return }
                plans[index] = newValue
            }
        )
    }
}
