import XCTest
@testable import TokenMeter

final class APICostEstimatorTests: XCTestCase {
    func testFiveTokenClassesUseIndependentRates() throws {
        let estimator = APICostEstimator(snapshots: [
            price(
                model: "model-a",
                effectiveFrom: "2026-01-01",
                rates: .init(
                    newInput: 1,
                    cachedInput: 0.1,
                    cacheCreation: 1.25,
                    output: 5,
                    reasoningOutput: 6
                )
            ),
        ])

        let estimate = try XCTUnwrap(estimator.estimate(
            model: "model-a",
            usageDate: "2026-08-12",
            tokens: .init(
                newInputTokens: 1_000_000,
                cachedInputTokens: 2_000_000,
                cacheCreationTokens: 3_000_000,
                outputTokens: 4_000_000,
                reasoningOutputTokens: 5_000_000
            )
        ))

        XCTAssertEqual(estimate.components.newInput, 1, accuracy: 0.0001)
        XCTAssertEqual(estimate.components.cachedInput, 0.2, accuracy: 0.0001)
        XCTAssertEqual(estimate.components.cacheCreation, 3.75, accuracy: 0.0001)
        XCTAssertEqual(estimate.components.output, 20, accuracy: 0.0001)
        XCTAssertEqual(estimate.components.reasoningOutput, 30, accuracy: 0.0001)
        XCTAssertEqual(estimate.total, 54.95, accuracy: 0.0001)
    }

    func testReasoningFallsBackToOutputRateWhenNoSeparateRateExists() throws {
        let estimator = APICostEstimator(snapshots: [
            price(
                model: "model-a",
                effectiveFrom: "2026-01-01",
                rates: .init(
                    newInput: 0,
                    cachedInput: 0,
                    cacheCreation: 0,
                    output: 7,
                    reasoningOutput: nil
                )
            ),
        ])

        let estimate = try XCTUnwrap(estimator.estimate(
            model: "model-a",
            usageDate: "2026-08-12",
            tokens: .init(
                newInputTokens: 0,
                cachedInputTokens: 0,
                cacheCreationTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 2_000_000
            )
        ))

        XCTAssertEqual(estimate.components.reasoningOutput, 14, accuracy: 0.0001)
    }

    func testHistoricalUsageKeepsThePriceEffectiveOnThatDate() throws {
        let estimator = APICostEstimator(snapshots: [
            price(model: "model-a", effectiveFrom: "2026-01-01", input: 2),
            price(model: "model-a", effectiveFrom: "2026-07-01", input: 1),
        ])
        let tokens = APITokenBreakdown(
            newInputTokens: 1_000_000,
            cachedInputTokens: 0,
            cacheCreationTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0
        )

        let june = try XCTUnwrap(estimator.estimate(
            model: "model-a", usageDate: "2026-06-30", tokens: tokens
        ))
        let july = try XCTUnwrap(estimator.estimate(
            model: "model-a", usageDate: "2026-07-01", tokens: tokens
        ))

        XCTAssertEqual(june.total, 2, accuracy: 0.0001)
        XCTAssertEqual(june.priceEffectiveFrom, "2026-01-01")
        XCTAssertEqual(july.total, 1, accuracy: 0.0001)
        XCTAssertEqual(july.priceEffectiveFrom, "2026-07-01")
    }

    func testModelMatchingNormalizesCaseAndCodexEffortSuffix() {
        let estimator = APICostEstimator(snapshots: [
            price(model: "Model-A", effectiveFrom: "2026-01-01", input: 1),
        ])

        let result = estimator.estimate(
            model: " model-a (xhigh) ",
            usageDate: "2026-08-12",
            tokens: .init(
                newInputTokens: 1,
                cachedInputTokens: 0,
                cacheCreationTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0
            )
        )

        XCTAssertNotNil(result)
    }

    func testUnknownOrNotYetPricedModelDoesNotSilentlyBecomeFree() {
        let estimator = APICostEstimator(snapshots: [
            price(model: "model-a", effectiveFrom: "2026-09-01", input: 1),
        ])
        let tokens = APITokenBreakdown(
            newInputTokens: 1,
            cachedInputTokens: 0,
            cacheCreationTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0
        )

        XCTAssertNil(estimator.estimate(
            model: "unknown", usageDate: "2026-08-12", tokens: tokens
        ))
        XCTAssertNil(estimator.estimate(
            model: "model-a", usageDate: "2026-08-12", tokens: tokens
        ))
    }

    private func price(
        model: String,
        effectiveFrom: String,
        input: Double
    ) -> APIPriceSnapshot {
        price(
            model: model,
            effectiveFrom: effectiveFrom,
            rates: .init(
                newInput: input,
                cachedInput: 0,
                cacheCreation: 0,
                output: 0,
                reasoningOutput: nil
            )
        )
    }

    private func price(
        model: String,
        effectiveFrom: String,
        rates: APIPriceSnapshot.PerMillion
    ) -> APIPriceSnapshot {
        APIPriceSnapshot(
            model: model,
            aliases: [],
            effectiveFrom: effectiveFrom,
            currency: "USD",
            perMillion: rates
        )
    }

    func testOpenRouterCatalogMatchesLocalClaudeAndCodexNames() {
        let tokens = APITokenBreakdown(
            newInputTokens: 1,
            cachedInputTokens: 0,
            cacheCreationTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0
        )

        XCTAssertNotNil(APIReferencePricingCatalog.estimator.estimate(
            model: "opus-4-8",
            usageDate: APIReferencePricingCatalog.observedAt,
            tokens: tokens
        ))
        XCTAssertNotNil(APIReferencePricingCatalog.estimator.estimate(
            model: "gpt-5.6-sol (xhigh)",
            usageDate: APIReferencePricingCatalog.observedAt,
            tokens: tokens
        ))
        XCTAssertNotNil(APIReferencePricingCatalog.estimator.estimate(
            model: "k3-256k",
            usageDate: APIReferencePricingCatalog.observedAt,
            tokens: tokens
        ))
    }

    func testOpenRouterCatalogMatchesKimiCodeProductAliases() throws {
        let k3 = try XCTUnwrap(APIReferencePricingCatalog.estimator.estimate(
            model: "k3-agent",
            usageDate: APIReferencePricingCatalog.observedAt,
            tokens: .init(
                newInputTokens: 1_000_000,
                cachedInputTokens: 1_000_000,
                cacheCreationTokens: 1_000_000,
                outputTokens: 1_000_000,
                reasoningOutputTokens: 0
            )
        ))
        let k26 = try XCTUnwrap(APIReferencePricingCatalog.estimator.estimate(
            model: "k2d6-agent",
            usageDate: APIReferencePricingCatalog.observedAt,
            tokens: .init(
                newInputTokens: 1_000_000,
                cachedInputTokens: 0,
                cacheCreationTokens: 0,
                outputTokens: 1_000_000,
                reasoningOutputTokens: 0
            )
        ))

        XCTAssertEqual(k3.total, 21.3, accuracy: 0.0001)
        XCTAssertEqual(k26.total, 3.0195, accuracy: 0.0001)
    }

    func testOfficialFallbackKeepsDoubaoPriceInCNY() throws {
        let estimate = try XCTUnwrap(APIReferencePricingCatalog.estimator.estimate(
            model: "agent-plan/doubao-seed-evolving",
            usageDate: APIReferencePricingCatalog.observedAt,
            tokens: .init(
                newInputTokens: 1_000_000,
                cachedInputTokens: 1_000_000,
                cacheCreationTokens: 1_000_000,
                outputTokens: 1_000_000,
                reasoningOutputTokens: 0
            )
        ))

        XCTAssertEqual(estimate.currency, "CNY")
        XCTAssertEqual(estimate.priceSource.label, "火山方舟")
        XCTAssertEqual(estimate.total, 43.2, accuracy: 0.0001)
    }

    func testReferenceSummaryReportsCoverageAndUnknownModels() {
        let summary = APIReferenceCostSummary(
            samples: [
                .init(
                    model: "gpt-5.6-sol",
                    tokens: .init(
                        newInputTokens: 1_000_000,
                        cachedInputTokens: 0,
                        cacheCreationTokens: 0,
                        outputTokens: 0,
                        reasoningOutputTokens: 0
                    )
                ),
                .init(
                    model: "private-model",
                    tokens: .init(
                        newInputTokens: 1_000_000,
                        cachedInputTokens: 0,
                        cacheCreationTokens: 0,
                        outputTokens: 0,
                        reasoningOutputTokens: 0
                    )
                ),
            ],
            estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD
        )

        XCTAssertEqual(summary.total, 5, accuracy: 0.0001)
        XCTAssertEqual(summary.matchedTokens, 1_000_000)
        XCTAssertEqual(summary.totalTokens, 2_000_000)
        XCTAssertEqual(summary.coverage ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.unpricedModels, ["private-model"])
    }

    func testReferenceSummarySeparatesCurrenciesAndCountsBothAsPriced() {
        let summary = APIReferenceCostSummary(
            samples: [
                .init(
                    model: "k3-agent",
                    tokens: .init(
                        newInputTokens: 1_000_000,
                        cachedInputTokens: 0,
                        cacheCreationTokens: 0,
                        outputTokens: 0,
                        reasoningOutputTokens: 0
                    )
                ),
                .init(
                    model: "agent-plan/doubao-seed-evolving",
                    tokens: .init(
                        newInputTokens: 1_000_000,
                        cachedInputTokens: 0,
                        cacheCreationTokens: 0,
                        outputTokens: 0,
                        reasoningOutputTokens: 0
                    )
                ),
            ],
            estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD
        )

        XCTAssertEqual(summary.amounts, [
            .init(currency: "USD", total: 3),
            .init(currency: "CNY", total: 6),
        ])
        XCTAssertEqual(summary.total, 3 + 6 / 6.9, accuracy: 0.0001)
        XCTAssertEqual(summary.matchedTokens, 2_000_000)
        XCTAssertEqual(summary.coverage ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(summary.unpricedModels, [])
        XCTAssertEqual(summary.sourceLabels, ["OpenRouter", "火山方舟"])
    }

    func testOpenRouterPriceWinsWhenOfficialFallbackSharesAnAlias() throws {
        let official = APIPriceSnapshot(
            model: "provider/model-a",
            aliases: ["local-model"],
            effectiveFrom: "2026-08-12",
            currency: "CNY",
            perMillion: .init(
                newInput: 99,
                cachedInput: 99,
                cacheCreation: 99,
                output: 99,
                reasoningOutput: nil
            ),
            source: .init(label: "模型官方", url: nil)
        )
        let openRouter = APIPriceSnapshot(
            model: "router/model-a",
            aliases: ["local-model"],
            effectiveFrom: "2026-01-01",
            currency: "USD",
            perMillion: .init(
                newInput: 2,
                cachedInput: 0,
                cacheCreation: 0,
                output: 0,
                reasoningOutput: nil
            )
        )
        let estimate = try XCTUnwrap(APICostEstimator(
            snapshots: [official, openRouter]
        ).estimate(
            model: "local-model",
            usageDate: "2026-08-12",
            tokens: .init(
                newInputTokens: 1_000_000,
                cachedInputTokens: 0,
                cacheCreationTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0
            )
        ))

        XCTAssertEqual(estimate.currency, "USD")
        XCTAssertEqual(estimate.total, 2, accuracy: 0.0001)
        XCTAssertEqual(estimate.priceSource.label, "OpenRouter")
    }

    func testAllUnknownModelsHaveNoAmountsInsteadOfLookingFree() {
        let summary = APIReferenceCostSummary(
            samples: [
                .init(
                    model: "unknown-model",
                    tokens: .init(
                        newInputTokens: 10,
                        cachedInputTokens: 0,
                        cacheCreationTokens: 0,
                        outputTokens: 0,
                        reasoningOutputTokens: 0
                    )
                ),
            ],
            estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD
        )

        XCTAssertEqual(summary.amounts, [])
        XCTAssertEqual(summary.matchedTokens, 0)
        XCTAssertEqual(summary.unpricedModels, ["unknown-model"])
    }
}
