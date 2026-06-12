import SwiftUI

// Cursor 用量面板：账户信息 + 本月按模型请求数/配额。
// 数据来自 cursor.com 官方用量接口（本地 token 鉴权），刷新即重查。
struct CursorView: View {
    var onSettings: () -> Void
    @State private var result: CursorUsageResult?
    @State private var proc = ProcessStatus.Snapshot(running: false, count: 0)
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let r = result {
                    accountCard(r)
                    modelsCard(r)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if let errorText {
                    Text(errorText)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 60).padding(.horizontal, 20)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .task { await reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.cursor)
            Text("Cursor Monitor")
                .font(.system(size: 15, weight: .bold))
            RunningBadge(snapshot: proc, showCount: false)
            Spacer()
            iconButton("arrow.clockwise") { Task { await reload() } }
            iconButton("gearshape") { onSettings() }
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    func reload() async {
        loading = true
        proc = ProcessStatus.cursor()
        errorText = nil
        do {
            result = try await CursorUsage.load()
        } catch {
            result = nil
            errorText = (error as? CursorUsageError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    // MARK: - 账户
    private func accountCard(_ r: CursorUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("账户", systemImage: "person.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let plan = r.membership {
                        Text(plan.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.cursor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.cursor)
                    }
                }
                if let email = r.email {
                    Text(email).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let start = r.startOfMonth {
                    Text("计费周期自 \(Self.mmdd(start)) 起 · 本月 \(r.totalRequests) 次请求")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 模型用量
    private func modelsCard(_ r: CursorUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("本月模型用量", systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                if r.models.allSatisfy({ $0.numRequests == 0 }) {
                    Text("本月暂无用量")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(r.models) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(m.model)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                Spacer()
                                if let quota = m.maxRequests {
                                    Text("\(m.numRequests) / \(quota) 次")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                } else {
                                    Text("\(m.numRequests) 次")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            if let quota = m.maxRequests, quota > 0 {
                                ProgressView(value: Double(m.numRequests), total: Double(quota))
                                    .tint(Theme.cursor)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func mmdd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
}
