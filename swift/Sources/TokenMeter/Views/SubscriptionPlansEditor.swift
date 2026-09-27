import SwiftUI

// 设置页「订阅与费用」卡片内容：逐行填写订阅名称、月费与币种。
// 行绑定按 id 取值，删除任意一行都不会让其余行的输入框错位。
struct SubscriptionPlansEditor: View {
    @Binding var plans: [SubscriptionPlan]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label("订阅月费", systemImage: "creditcard")
                    .font(.system(size: 12, weight: .semibold))
                Text("填写正在付费的 AI 订阅；总览按所选范围折算，与 API 等价参考对比回本倍数。")
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
            Text("金额只存本机、不联网，只用于总览的回本倍数；人民币按固定参考汇率 $1 = ¥\(String(format: "%.2f", APIReferencePricingCatalog.cnyPerUSD)) 折算。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            .frame(width: 72)
            Picker("", selection: plan.currency) {
                ForEach(SubscriptionPlan.currencies, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 72)
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
