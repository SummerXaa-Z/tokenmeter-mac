import SwiftUI
import Charts

// 余额卡：总余额 + 今日/本月消费
struct BalanceCard: View {
    let balance: Balance?
    let state: LoadState
    let todayCost: Double?
    let monthCost: Double?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("账户余额", systemImage: "creditcard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    statusBadge
                }
                switch state {
                case .ok:
                    if let b = balance {
                        Text("\(b.symbol)\(b.totalBalance)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.brand)
                    }
                case .loading:
                    Text("查询中…").font(.title3).foregroundStyle(.secondary)
                case .noKey:
                    Text("未配置 API Key").font(.callout).foregroundStyle(.secondary)
                case .error(let msg):
                    Text(msg).font(.callout).foregroundStyle(.orange).lineLimit(2)
                }
                if todayCost != nil || monthCost != nil {
                    HStack(spacing: 16) {
                        if let t = todayCost { metric("今日", Fmt.money(t)) }
                        if let m = monthCost { metric("本月", Fmt.money(m)) }
                    }
                }
            }
        }
    }

    private var statusBadge: some View {
        Group {
            if case .ok = state, let b = balance {
                Text(b.isAvailable ? "可用" : "余额不足")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((b.isAvailable ? Color.green : Color.orange).opacity(0.18),
                                in: Capsule())
                    .foregroundStyle(b.isAvailable ? .green : .orange)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold))
        }
    }
}

// 模型用量行：徽标 + 名称 + token 进度条 + 消费
struct UsageRow: View {
    let modelKey: String
    let data: UsageModelSummary?
    let maxTokens: Int
    let state: LoadState
    var onTap: () -> Void

    private var isFlash: Bool { modelKey == "flash" }
    private var accent: Color { isFlash ? Theme.flash : Theme.pro }
    private var name: String { isFlash ? "V4 Flash" : "V4 Pro" }

    private var tokensText: String {
        if let d = data { return "\(Fmt.int(d.totalTokens)) Tokens" }
        switch state {
        case .loading: return "查询中…"
        case .noKey: return "未配置 Token"
        case .error: return "用量不可用"
        default: return "—"
        }
    }

    var body: some View {
        Button(action: onTap) {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: isFlash ? "bolt.fill" : "brain")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 34, height: 34)
                        .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).font(.system(size: 13, weight: .semibold))
                        Text(tokensText).font(.system(size: 11)).foregroundStyle(.secondary)
                        progressBar
                        if let d = data, let rate = d.cacheHitRate {
                            Text("缓存命中 \(Int(rate))%")
                                .font(.system(size: 10)).foregroundStyle(accent)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(data.map { Fmt.money($0.cost) } ?? "—")
                            .font(.system(size: 14, weight: .bold))
                        if let d = data, d.cost > 0 {
                            Text("\(Fmt.tokensShort(Int(Double(d.totalTokens) / d.cost))) T/¥")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                Capsule().fill(accent)
                    .frame(width: data.map {
                        max(4, CGFloat($0.totalTokens) / CGFloat(maxTokens) * geo.size.width)
                    } ?? 0, height: 4)
            }
        }
        .frame(height: 4)
    }
}

// 7 天缓存命中明细堆叠柱状图（Swift Charts）
struct UsageChartCard: View {
    let usage: UsageResult?
    let state: LoadState

    private struct Seg: Identifiable {
        let id = UUID()
        let date: String
        let kind: String   // 命中/未命中/输出
        let value: Int
    }

    private var days: [UsageDay] { DateUtil.recentDays(usage?.days ?? []) }

    private var segments: [Seg] {
        days.flatMap { d -> [Seg] in
            let hit = d.flashCacheHit + d.proCacheHit
            let miss = d.flashCacheMiss + d.proCacheMiss
            let resp = d.flashResponse + d.proResponse
            return [
                Seg(date: Fmt.mmdd(d.date), kind: "命中", value: hit),
                Seg(date: Fmt.mmdd(d.date), kind: "未命中", value: miss),
                Seg(date: Fmt.mmdd(d.date), kind: "输出", value: resp),
            ]
        }
    }

    private var summary: String {
        let hit = days.reduce(0) { $0 + $1.flashCacheHit + $1.proCacheHit }
        let miss = days.reduce(0) { $0 + $1.flashCacheMiss + $1.proCacheMiss }
        let total = segments.reduce(0) { $0 + $1.value }
        let rate = (hit + miss) > 0 ? Int(Double(hit) / Double(hit + miss) * 100) : 0
        return "命中率 \(rate)% · 合计 \(Fmt.tokensShort(total))"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("缓存命中明细", systemImage: "chart.bar.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(state == .ok ? summary : "—")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if state == .ok {
                    chart
                } else {
                    Text(placeholder).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
    }

    private var placeholder: String {
        switch state {
        case .loading: return "查询中…"
        case .noKey: return "未配置用量 Token"
        case .error(let m): return m
        default: return "暂无数据"
        }
    }

    @ViewBuilder private var chart: some View {
        Chart(segments) { seg in
            BarMark(
                x: .value("日期", seg.date),
                y: .value("Tokens", seg.value))
            .foregroundStyle(by: .value("类型", seg.kind))
            .cornerRadius(2)
        }
        .chartForegroundStyleScale([
            "命中": Theme.hit, "未命中": Theme.miss, "输出": Theme.response,
        ])
        .chartLegend(position: .bottom, spacing: 6)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let n = v.as(Int.self) { Text(Fmt.tokensShort(n)) }
                }
            }
        }
        .frame(height: 150)
    }
}
