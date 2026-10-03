import Foundation

// 配置代次阻止关/开前的扫描回写；实时接纳代次另行阻止慢历史回填
// 覆盖较新快照。失败或被拒绝的实时读取不构成新权威结果。
struct LocalCollectionVersions {
    struct BackfillTicket: Equatable {
        let source: HistorySource
        let configuration: UInt
        let liveAcceptance: UInt
    }

    private var configuration: [HistorySource: UInt] = [:]
    private var liveAcceptance: [HistorySource: UInt] = [:]

    func configurationRevision(for source: HistorySource) -> UInt {
        configuration[source] ?? 0
    }

    mutating func invalidate(_ source: HistorySource) {
        configuration[source, default: 0] &+= 1
    }

    mutating func acceptedLive(_ source: HistorySource) {
        liveAcceptance[source, default: 0] &+= 1
    }

    func ticket(for source: HistorySource) -> BackfillTicket {
        .init(source: source, configuration: configurationRevision(for: source),
              liveAcceptance: liveAcceptance[source] ?? 0)
    }

    func isCurrent(_ ticket: BackfillTicket) -> Bool {
        ticket == self.ticket(for: ticket.source)
    }
}
