import Foundation

// 个人排行把“工具”和“模型”作为两个独立维度：工具按长期历史聚合，
// 模型按各采集器提供的同一时间窗口聚合。只处理汇总数字，不读取原始内容。
struct PersonalUsageRankings: Equatable {
    struct ToolEntry: Equatable, Identifiable {
        let source: HistorySource
        let totalTokens: Int
        let share: Double
        var id: HistorySource { source }
    }

    struct ModelSample: Equatable {
        let source: HistorySource
        let model: String
        let totalTokens: Int
    }

    struct ModelEntry: Equatable, Identifiable {
        let source: HistorySource
        let model: String
        let totalTokens: Int
        let share: Double
        var id: String { "\(source.rawValue)|\(model)" }
    }

    let tools: [ToolEntry]
    let models: [ModelEntry]

    init(
        history: [HistoryStore.DayPoint],
        enabledSources: [HistorySource],
        modelSamples: [ModelSample]
    ) {
        let selected = Set(enabledSources)
        let codingSources = HistorySource.codingAgents.filter(selected.contains)
        let enabled = Set(codingSources)
        var toolTotals: [HistorySource: Int] = [:]
        for source in codingSources {
            toolTotals[source] = history.reduce(0) {
                $0 + max($1.bySource[source] ?? 0, 0)
            }
        }
        let allToolTokens = toolTotals.values.reduce(0, +)
        tools = codingSources.compactMap { source in
            let tokens = toolTotals[source] ?? 0
            guard tokens > 0, allToolTokens > 0 else { return nil }
            return ToolEntry(
                source: source,
                totalTokens: tokens,
                share: Double(tokens) / Double(allToolTokens)
            )
        }.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return codingSources.firstIndex(of: $0.source) ?? .max
                < codingSources.firstIndex(of: $1.source) ?? .max
        }

        var modelTotals: [String: ModelSample] = [:]
        for sample in modelSamples {
            let model = sample.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard enabled.contains(sample.source), !model.isEmpty, sample.totalTokens > 0 else {
                continue
            }
            let key = "\(sample.source.rawValue)|\(model)"
            if let current = modelTotals[key] {
                modelTotals[key] = ModelSample(
                    source: sample.source,
                    model: model,
                    totalTokens: current.totalTokens + sample.totalTokens
                )
            } else {
                modelTotals[key] = ModelSample(
                    source: sample.source,
                    model: model,
                    totalTokens: sample.totalTokens
                )
            }
        }
        let allModelTokens = modelTotals.values.reduce(0) { $0 + $1.totalTokens }
        models = modelTotals.values.map {
            ModelEntry(
                source: $0.source,
                model: $0.model,
                totalTokens: $0.totalTokens,
                share: allModelTokens > 0
                    ? Double($0.totalTokens) / Double(allModelTokens)
                    : 0
            )
        }.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
    }
}
