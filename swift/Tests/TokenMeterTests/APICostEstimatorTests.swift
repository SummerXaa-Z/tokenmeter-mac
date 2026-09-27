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
            usageDate: APIReferencePricingCatalog.firstObservedAt,
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
            referenceDate: APIReferencePricingCatalog.firstObservedAt,
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

    // MARK: - 价格目录刷新（2026-09-25）

    private func million(
        input: Int = 0, cached: Int = 0, cacheWrite: Int = 0, output: Int = 0, reasoning: Int = 0
    ) -> APITokenBreakdown {
        .init(newInputTokens: input * 1_000_000, cachedInputTokens: cached * 1_000_000,
              cacheCreationTokens: cacheWrite * 1_000_000, outputTokens: output * 1_000_000,
              reasoningOutputTokens: reasoning * 1_000_000)
    }

    private func catalogTotal(_ model: String, on date: String, _ tokens: APITokenBreakdown) -> Double? {
        APIReferencePricingCatalog.estimator.estimate(model: model, usageDate: date, tokens: tokens)?.total
    }

    func testRepricedModelsKeepTheOldPriceBeforeTheObservationDay() throws {
        let tokens = million(input: 1, output: 1)
        XCTAssertEqual(try XCTUnwrap(catalogTotal("gpt-5.6-sol", on: "2026-09-24", tokens)), 35, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(catalogTotal("gpt-5.6-sol", on: "2026-09-25", tokens)), 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(catalogTotal("gpt-5.6-terra", on: "2026-09-25", tokens)), 14, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(catalogTotal("k2d6-agent", on: "2026-09-25", tokens)), 4.95, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(catalogTotal("V4 Flash", on: "2026-09-24", tokens)), 0.42, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(catalogTotal("V4 Flash", on: "2026-09-25", tokens)), 0.147, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(catalogTotal("V4 Pro", on: "2026-09-25", tokens)), 2.349, accuracy: 1e-9)
    }

    func testLocalClaudeCodeModelIdsResolveToTheRefreshedCatalog() throws {
        let tokens = million(input: 1, cached: 1, cacheWrite: 1, output: 1)
        // ClaudeUsage.displayModel 去掉 claude- 前缀后是 opus-5-5
        XCTAssertEqual(try XCTUnwrap(catalogTotal("opus-5-5", on: "2026-09-25", tokens)), 29.2, accuracy: 1e-9)
        XCTAssertNotNil(catalogTotal("claude-opus-5-5", on: "2026-09-25", tokens))
        XCTAssertNotNil(catalogTotal("claude-opus-5.5", on: "2026-09-25", tokens))
        // 未单列 cache write 价的 GLM 按普通输入计缓存创建
        XCTAssertEqual(try XCTUnwrap(catalogTotal("glm-5.3", on: "2026-09-19", tokens)), 7.46, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(catalogTotal("GLM-5.3-Flash", on: "2026-09-19", tokens)), 0.24, accuracy: 1e-9)
        XCTAssertNotNil(catalogTotal("fable-5-1", on: "2026-09-25", tokens))
        XCTAssertNotNil(catalogTotal("qwen3-coder", on: "2026-09-25", tokens))
        XCTAssertNotNil(catalogTotal("gemini-3.8-flash", on: "2026-09-25", tokens))
    }

    func testNewlyListedModelsStayUnpricedBeforeTheirListingDate() {
        let tokens = million(input: 1)
        XCTAssertNil(catalogTotal("opus-5-5", on: "2026-09-21", tokens))
        XCTAssertNotNil(catalogTotal("opus-5-5", on: "2026-09-22", tokens))
        XCTAssertNil(catalogTotal("glm-5.3", on: "2026-08-17", tokens))
        XCTAssertNotNil(catalogTotal("glm-5.3", on: "2026-08-18", tokens))
        XCTAssertNil(catalogTotal("glm-5.3-flash", on: "2026-08-25", tokens))
        // 已收录的老模型在首个观测日前也不外推
        XCTAssertNil(catalogTotal("glm-4.6", on: "2026-08-11", tokens))
    }

    func testGeminiReasoningUsesItsOwnListedRate() throws {
        let estimate = try XCTUnwrap(APIReferencePricingCatalog.estimator.estimate(
            model: "gemini-3.8-flash", usageDate: "2026-09-25", tokens: million(reasoning: 2)))
        XCTAssertEqual(estimate.components.reasoningOutput, 7.5, accuracy: 1e-9)
        XCTAssertEqual(estimate.components.output, 0)
    }

    func testSummaryPricesEachSampleOnItsOwnUsageDateAndGroupsByModel() throws {
        let summary = APIReferenceCostSummary(
            samples: [
                .init(model: "gpt-5.6-sol (xhigh)", tokens: million(input: 1),
                      usageDate: "2026-09-24", source: .codex),
                .init(model: "GPT-5.6-sol", tokens: million(input: 1),
                      usageDate: "2026-09-25", source: .codex),
                .init(model: "gpt-5.6-sol", tokens: million(input: 1),
                      usageDate: "2026-09-25", source: .opencode),
                .init(model: "private-model (high)", tokens: million(input: 1),
                      usageDate: "2026-09-25", source: .codex),
                .init(model: "Private-Model", tokens: million(input: 1),
                      usageDate: "2026-09-25", source: .qwen),
            ],
            estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD
        )

        XCTAssertEqual(summary.total, 5 + 2 + 2, accuracy: 1e-9)
        XCTAssertEqual(summary.matchedTokens, 3_000_000)
        XCTAssertEqual(summary.totalTokens, 5_000_000)
        XCTAssertEqual(summary.unpricedModels, ["private-model"])
        XCTAssertEqual(summary.modelAmounts.map(\.source), [.codex, .opencode])
        let codex = try XCTUnwrap(summary.modelAmounts.first)
        XCTAssertEqual(codex.model, "gpt-5.6-sol")
        XCTAssertEqual(codex.total, 7, accuracy: 1e-9)
        XCTAssertEqual(codex.tokens, 2_000_000)
    }

    func testModelAmountsConvertCurrencyAndSkipAmountsWithoutRate() throws {
        let samples: [APICostSample] = [
            .init(model: "agent-plan/doubao-seed-evolving", tokens: million(input: 1), source: .kimi),
        ]
        let converted = APIReferenceCostSummary(
            samples: samples, estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
        XCTAssertEqual(try XCTUnwrap(converted.modelAmounts.first).total, 6 / 6.9, accuracy: 1e-9)

        let noRate = APIReferenceCostSummary(
            samples: samples, estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt)
        XCTAssertEqual(noRate.modelAmounts, [])
        XCTAssertEqual(noRate.amounts, [.init(currency: "CNY", total: 6)])
        XCTAssertEqual(noRate.total, 0)
    }

    func testBaseModelStripsEffortButKeepsCase() {
        XCTAssertEqual(APICostEstimator.baseModel("  GPT-5.6-Sol (xhigh) "), "GPT-5.6-Sol")
        XCTAssertEqual(APICostEstimator.canonicalModel("  GPT-5.6-Sol (xhigh) "), "gpt-5.6-sol")
        XCTAssertEqual(APICostEstimator.baseModel("model(x)"), "model(x)")
    }

    // MARK: - 价格目录保鲜（快照不变量，防止刷新悄悄劣化）

    private func assertValidDateKey(_ key: String, _ context: String) {
        XCTAssertNotNil(
            key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression),
            "\(context) 生效日 \(key) 不是 YYYY-MM-DD（字典序比较依赖它）"
        )
        let parts = key.split(separator: "-").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3, "\(context) \(key)")
        if parts.count == 3 {
            XCTAssertTrue((1...12).contains(parts[1]), "\(context) \(key) 月份越界")
            XCTAssertTrue((1...31).contains(parts[2]), "\(context) \(key) 日期越界")
        }
    }

    func testCatalogEffectiveDatesStayWithinObservationWindow() {
        let catalog = APIReferencePricingCatalog.self
        assertValidDateKey(catalog.firstObservedAt, "firstObservedAt")
        assertValidDateKey(catalog.observedAt, "observedAt")
        XCTAssertLessThanOrEqual(catalog.firstObservedAt, catalog.observedAt)

        for snapshot in catalog.estimator.snapshots {
            assertValidDateKey(snapshot.effectiveFrom, snapshot.model)
            // 不向前外推到首个观测日之前，也不出现晚于最近核对日的未来价
            XCTAssertGreaterThanOrEqual(
                snapshot.effectiveFrom, catalog.firstObservedAt,
                "\(snapshot.model) 早于首个观测日，会向更早的用量外推价格")
            XCTAssertLessThanOrEqual(
                snapshot.effectiveFrom, catalog.observedAt,
                "\(snapshot.model) 晚于最近核对日，属于未观测的未来价")
        }
    }

    func testCatalogHasNoDuplicateEffectiveDatesPerModel() {
        var seen: [String: Set<String>] = [:]
        for snapshot in APIReferencePricingCatalog.estimator.snapshots {
            let dates = seen[snapshot.model, default: []]
            XCTAssertFalse(
                dates.contains(snapshot.effectiveFrom),
                "\(snapshot.model) 在 \(snapshot.effectiveFrom) 有两条快照，max 选择不确定，其中一条永远选不中"
            )
            seen[snapshot.model] = dates.union([snapshot.effectiveFrom])
        }
    }

    func testRepricedRowsKeepAliasParity() {
        // 调价追加的新快照行必须与旧行同别名集合：漏一个别名，
        // 该别名的近期用量会永远查到旧价（kimi-k2.6 曾踩过的静默劣化）
        var aliasesByModel: [String: Set<String>] = [:]
        for snapshot in APIReferencePricingCatalog.estimator.snapshots {
            if let existing = aliasesByModel[snapshot.model] {
                XCTAssertEqual(
                    existing, Set(snapshot.aliases),
                    "\(snapshot.model) 的多条快照别名不一致；请把别名复制到新行"
                )
            } else {
                aliasesByModel[snapshot.model] = Set(snapshot.aliases)
            }
        }
    }

    func testCatalogCoversEverySupportedToolsModelBasket() {
        // 覆盖下限：各采集器实际会写出的代表模型名，在最近核对日必须全部有价。
        // 以后收录新工具/新模型时往这里加，只增不减。
        let basket = [
            // Claude Code（displayModel 去前缀 + 连字符版本号两种写法）
            "claude-opus-5.5", "opus-5-5", "claude-sonnet-5", "haiku-4-5",
            "claude-fable-5-1", "fable-5.1",
            // Codex（可能带推理强度后缀）
            "gpt-5.5 (xhigh)", "gpt-5.4-mini", "gpt-5.6-terra",
            // Kimi Code（产品别名）
            "kimi-k3", "k3-agent", "k2d6-agent", "kimi-k2.7-code",
            // Claude Code / OpenCode 里的 GLM
            "glm-5.3", "glm-5.3-flash", "glm-5.1",
            // Qwen Code / Gemini CLI / MiniMax
            "qwen3-coder", "qwen3.8-flash", "gemini-3.8-flash", "minimax-m3",
            // DeepSeek 平台（官方展示名）与火山方舟（CNY 官方价）
            "V4 Flash", "V4 Pro", "agent-plan/doubao-seed-evolving",
        ]
        let tokens = million(input: 1)
        for model in basket {
            XCTAssertNotNil(
                APIReferencePricingCatalog.estimator.estimate(
                    model: model,
                    usageDate: APIReferencePricingCatalog.observedAt,
                    tokens: tokens
                ),
                "\(model) 在最近核对日缺价；刷新目录时不要删掉既有条目或别名"
            )
        }
    }
}
