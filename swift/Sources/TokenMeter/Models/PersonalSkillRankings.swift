import Foundation

// Skills 榜只聚合各本地采集器已经确认的调用证据。这里不接触 transcript、
// 工具参数或 SKILL.md 内容，只合并 Skill 名、来源和调用次数。
struct PersonalSkillRankings: Equatable {
    struct Sample: Equatable {
        let source: HistorySource
        let name: String
        let invocationCount: Int
    }

    struct SourceCount: Equatable, Identifiable {
        let source: HistorySource
        let invocationCount: Int
        var id: HistorySource { source }
    }

    struct Entry: Equatable, Identifiable {
        let name: String
        let invocationCount: Int
        let share: Double
        let sources: [SourceCount]
        var id: String { name.lowercased() }
    }

    let entries: [Entry]

    init(samples: [Sample], enabledSources: [HistorySource]) {
        let selected = Set(enabledSources)
        let codingSources = HistorySource.codingAgents.filter(selected.contains)
        let enabled = Set(codingSources)
        let sourceOrder = Dictionary(
            uniqueKeysWithValues: codingSources.enumerated().map { ($0.element, $0.offset) }
        )
        var displayNames: [String: String] = [:]
        var counts: [String: [HistorySource: Int]] = [:]

        for sample in samples {
            let name = sample.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard enabled.contains(sample.source),
                  !name.isEmpty,
                  name.count <= 128,
                  sample.invocationCount > 0,
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { continue }

            let key = name.lowercased()
            displayNames[key] = displayNames[key] ?? name
            counts[key, default: [:]][sample.source, default: 0] += sample.invocationCount
        }

        let total = counts.values.reduce(0) { subtotal, bySource in
            subtotal + bySource.values.reduce(0, +)
        }
        entries = counts.map { key, bySource in
            let invocationCount = bySource.values.reduce(0, +)
            let sources = bySource.map {
                SourceCount(source: $0.key, invocationCount: $0.value)
            }.sorted {
                if $0.invocationCount != $1.invocationCount {
                    return $0.invocationCount > $1.invocationCount
                }
                return sourceOrder[$0.source, default: .max]
                    < sourceOrder[$1.source, default: .max]
            }
            return Entry(
                name: displayNames[key] ?? key,
                invocationCount: invocationCount,
                share: total > 0 ? Double(invocationCount) / Double(total) : 0,
                sources: sources
            )
        }.sorted {
            if $0.invocationCount != $1.invocationCount {
                return $0.invocationCount > $1.invocationCount
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
