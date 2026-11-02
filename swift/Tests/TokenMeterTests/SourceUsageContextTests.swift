import XCTest
@testable import TokenMeter

@MainActor
final class SourceUsageContextTests: XCTestCase {
    private var estimator: APICostEstimator {
        .init(snapshots: [.init(model: "fixture", aliases: [], effectiveFrom: "2026-01-01",
            currency: "USD", perMillion: .init(newInput: 1, cachedInput: 0,
                cacheCreation: 0, output: 0, reasoningOutput: nil))])
    }

    private func summary(_ models: [String]) -> APIReferenceCostSummary {
        .init(samples: models.map {
            .init(model: $0, tokens: ModelTokenTally(input: 1_000_000).breakdown,
                  usageDate: "2026-10-03", source: .codex)
        }, estimator: estimator, referenceDate: "2026-10-03")
    }

    func testSourceWithoutModelDetailDoesNotClaimZeroAPICost() {
        XCTAssertEqual(ScopedSourceUsageCard.referenceAmount(source: .cursor, cost: summary([])),
                       "无模型明细")
    }

    func testPartlyPricedSourceShowsLowerBound() {
        let cost = summary(["fixture", "unknown-fixture"])
        XCTAssertEqual(cost.coverage, 0.5)
        XCTAssertEqual(ScopedSourceUsageCard.referenceAmount(source: .codex, cost: cost), "至少 $1.00")
    }

    func testAllUnknownPricesAreNotDisplayedAsZero() {
        XCTAssertEqual(ScopedSourceUsageCard.referenceAmount(source: .codex,
                       cost: summary(["unknown-fixture"])), "暂无参考价")
    }

    func testFullyPricedAndConfirmedNoUsageDoNotClaimLowerBound() {
        XCTAssertEqual(ScopedSourceUsageCard.referenceAmount(source: .codex,
                       cost: summary(["fixture"])), "$1.00")
        XCTAssertEqual(ScopedSourceUsageCard.referenceAmount(source: .codex,
                       cost: summary([])), "$0.00")
    }
}
