import Foundation
import XCTest
@testable import TokenMeter

final class LongHistoryPerformanceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-long-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    func testThreeYearsEightSourcesAndFiveThousandModelsReadCompletelyOncePerRevision() async throws {
        let today = try XCTUnwrap(DateUtil.date(from: "2025-12-31"))
        let first = try XCTUnwrap(DateUtil.date(from: "2023-01-01"))
        let dayCount = (Calendar.current.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        let sources = HistorySource.codingAgents
        XCTAssertEqual(sources.count, 8)
        let slotCount = dayCount * sources.count
        let modelEntryCount = 5_000
        let dailyStore = HistoryFileStore(fileURL: directory.appendingPathComponent("history.json"))
        let modelStore = ModelUsageHistoryStore(directory: directory.appendingPathComponent("models"))
        var expectedDailyTotal = 0
        var expectedModelTotal = 0
        let dates = (0..<dayCount).map { DateUtil.key(DateUtil.addDays(first, $0)) }

        // 5,000 条模型明细均匀分布在完整三年、八个来源中；100 个模型名轮换。
        // 规模固定，避免将每日报告成百上千模型造成硬件相关的 CI 负担。
        for (sourceIndex, source) in sources.enumerated() {
            var daily: [HistoryPersistenceCoordinator.Day] = []
            var models: [String: SourceDayDetail] = [:]
            for (dayIndex, date) in dates.enumerated() {
                let index = dayIndex * sources.count + sourceIndex
                let tokens = index % 50 + 1
                daily.append((date: date, totalTokens: tokens, cost: nil))
                expectedDailyTotal += tokens
                let selected = (index + 1) * modelEntryCount / slotCount > index * modelEntryCount / slotCount
                if selected {
                    models[date] = .init(models: ["synthetic-model-\(index % 100)": .init(input: tokens)], sessions: 1)
                    expectedModelTotal += tokens
                }
            }
            XCTAssertTrue(try dailyStore.recordChecked(source, days: daily))
            XCTAssertTrue(try modelStore.writeChecked(source, windowDates: dates, days: models, deletesEmptyDays: false))
        }

        var readCount = 0
        let reader = HistorySnapshotReader(read: {
            readCount += 1
            return try await Task.detached(priority: .utility) {
                HistorySnapshotReader.Snapshot(daily: try dailyStore.allChecked(now: today),
                                               models: try modelStore.allChecked())
            }.value
        })
        let started = ProcessInfo.processInfo.systemUptime
        await reader.refresh(revision: 42)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        XCTAssertNil(reader.error)
        XCTAssertTrue(reader.hasSuccessfulRead)
        XCTAssertEqual(reader.snapshot.daily.count, dayCount)
        XCTAssertEqual(reader.snapshot.daily.first?.date, "2023-01-01")
        XCTAssertEqual(reader.snapshot.daily.last?.date, "2025-12-31")
        XCTAssertTrue(reader.snapshot.daily.allSatisfy { $0.bySource.count == sources.count })
        XCTAssertEqual(reader.snapshot.daily.reduce(0) { $0 + $1.total }, expectedDailyTotal)
        let details = reader.snapshot.models.flatMap { $0.bySource.values }
        XCTAssertEqual(details.reduce(0) { $0 + $1.models.count }, modelEntryCount)
        XCTAssertEqual(details.flatMap { $0.models.values }.reduce(0) { $0 + $1.total }, expectedModelTotal)
        XCTAssertEqual(reader.snapshot.models.count, dayCount)

        await reader.refresh(revision: 42)
        XCTAssertEqual(readCount, 1, "Repeated requests for this long-history revision must reuse the snapshot")
        let report = "LongHistory baseline: \(dayCount) days, \(sources.count) sources, \(modelEntryCount) model entries; strict snapshot read \(String(format: "%.3f", seconds)) s."
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "Synthetic three-year history read baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
        // 留下可对比记录，不用某台机器的耗时阈值判定功能正确性。
    }
}
