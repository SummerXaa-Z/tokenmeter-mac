import Foundation

// API 等价成本估算底座。它与平台返回费用、订阅费是三个不同口径：
// - 平台返回费用：DeepSeek/Cursor 接口直接提供；
// - API 等价估算：本结构按公开 API 单价快照计算；
// - 订阅费：用户实际购买计划的固定支出，不从 token 反推。
//
// 价格按生效日期保存为不可变快照，历史用量只匹配当日已经生效的价格，
// 后续调价不会改写过去。未知模型返回 nil，禁止静默按 0 元计算。
struct APITokenBreakdown: Equatable {
    let newInputTokens: Int
    let cachedInputTokens: Int
    let cacheCreationTokens: Int
    let outputTokens: Int           // 不含 reasoning 的可见输出
    let reasoningOutputTokens: Int

    var totalTokens: Int {
        max(newInputTokens, 0)
            + max(cachedInputTokens, 0)
            + max(cacheCreationTokens, 0)
            + max(outputTokens, 0)
            + max(reasoningOutputTokens, 0)
    }
}

struct APIPriceSnapshot: Equatable {
    struct PerMillion: Equatable {
        let newInput: Double
        let cachedInput: Double
        let cacheCreation: Double
        let output: Double
        // nil 表示该模型没有独立 reasoning 价，沿用 output 单价。
        let reasoningOutput: Double?
    }

    let model: String
    let aliases: [String]
    let effectiveFrom: String       // YYYY-MM-DD
    let currency: String            // ISO 4217，如 USD / CNY
    let perMillion: PerMillion
    let source: Source

    struct Source: Equatable {
        let label: String
        let url: String?
        let priority: Int

        init(label: String, url: String?, priority: Int = 0) {
            self.label = label
            self.url = url
            self.priority = priority
        }

        static let openRouter = Source(
            label: "OpenRouter",
            url: "https://openrouter.ai/api/v1/models",
            priority: 100
        )
    }

    init(
        model: String,
        aliases: [String],
        effectiveFrom: String,
        currency: String,
        perMillion: PerMillion,
        source: Source = .openRouter
    ) {
        self.model = model
        self.aliases = aliases
        self.effectiveFrom = effectiveFrom
        self.currency = currency
        self.perMillion = perMillion
        self.source = source
    }
}

struct APICostEstimate: Equatable {
    struct Components: Equatable {
        let newInput: Double
        let cachedInput: Double
        let cacheCreation: Double
        let output: Double
        let reasoningOutput: Double

        var total: Double {
            newInput + cachedInput + cacheCreation + output + reasoningOutput
        }
    }

    let model: String
    let usageDate: String
    let priceEffectiveFrom: String
    let currency: String
    let priceSource: APIPriceSnapshot.Source
    let components: Components

    var total: Double { components.total }
}

struct APICostSample: Equatable {
    let model: String
    let tokens: APITokenBreakdown
}

struct APIReferenceCostSummary: Equatable {
    struct Amount: Equatable, Identifiable {
        let currency: String
        let total: Double

        var id: String { currency }
    }

    let total: Double
    let currency: String
    let amounts: [Amount]
    let conversionRates: [String: Double]
    let sourceLabels: [String]
    let matchedTokens: Int
    let totalTokens: Int
    let unpricedModels: [String]

    var coverage: Double? {
        guard totalTokens > 0 else { return nil }
        return Double(matchedTokens) / Double(totalTokens)
    }

    init(
        samples: [APICostSample],
        estimator: APICostEstimator,
        referenceDate: String,
        currency: String = "USD",
        conversionRates: [String: Double] = [:]
    ) {
        var totalsByCurrency: [String: Double] = [:]
        var sources = Set<String>()
        var matched = 0
        var all = 0
        var missing = Set<String>()

        for sample in samples where sample.tokens.totalTokens > 0 {
            all += sample.tokens.totalTokens
            guard let estimate = estimator.estimate(
                model: sample.model,
                usageDate: referenceDate,
                tokens: sample.tokens
            ) else {
                missing.insert(sample.model)
                continue
            }
            totalsByCurrency[estimate.currency, default: 0] += estimate.total
            sources.insert(estimate.priceSource.label)
            matched += sample.tokens.totalTokens
        }

        amounts = totalsByCurrency.map { Amount(currency: $0.key, total: $0.value) }
            .sorted {
                if $0.currency == currency { return true }
                if $1.currency == currency { return false }
                return $0.currency < $1.currency
            }
        total = totalsByCurrency.reduce(into: 0.0) { result, entry in
            if entry.key == currency {
                result += entry.value
            } else if let rate = conversionRates[entry.key], rate > 0 {
                result += entry.value * rate
            }
        }
        self.currency = currency
        self.conversionRates = conversionRates
        sourceLabels = sources.sorted {
            if $0 == "OpenRouter" { return true }
            if $1 == "OpenRouter" { return false }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        matchedTokens = matched
        totalTokens = all
        unpricedModels = missing.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}

struct APICostEstimator {
    let snapshots: [APIPriceSnapshot]

    func estimate(
        model: String,
        usageDate: String,
        tokens: APITokenBreakdown
    ) -> APICostEstimate? {
        let canonical = Self.canonicalModel(model)
        let matching = snapshots.filter {
            ([Self.canonicalModel($0.model)] + $0.aliases.map(Self.canonicalModel))
                .contains(canonical)
                && $0.effectiveFrom <= usageDate
        }
        guard let price = matching.max(by: {
            if $0.source.priority != $1.source.priority {
                return $0.source.priority < $1.source.priority
            }
            return $0.effectiveFrom < $1.effectiveFrom
        }) else {
            return nil
        }

        func cost(_ count: Int, _ perMillion: Double) -> Double {
            Double(max(count, 0)) / 1_000_000 * max(perMillion, 0)
        }

        let rates = price.perMillion
        let components = APICostEstimate.Components(
            newInput: cost(tokens.newInputTokens, rates.newInput),
            cachedInput: cost(tokens.cachedInputTokens, rates.cachedInput),
            cacheCreation: cost(tokens.cacheCreationTokens, rates.cacheCreation),
            output: cost(tokens.outputTokens, rates.output),
            reasoningOutput: cost(
                tokens.reasoningOutputTokens,
                rates.reasoningOutput ?? rates.output
            )
        )
        return APICostEstimate(
            model: price.model,
            usageDate: usageDate,
            priceEffectiveFrom: price.effectiveFrom,
            currency: price.currency,
            priceSource: price.source,
            components: components
        )
    }

    // Codex 模型名可能带推理强度后缀，如 "gpt-x (xhigh)"；强度不是单独
    // 的计价模型。大小写与首尾空白也不应造成价格表匹配分裂。
    static func canonicalModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: " ", options: .backwards),
           trimmed[range.upperBound...].first == "(",
           trimmed.hasSuffix(")") {
            return String(trimmed[..<range.lowerBound]).lowercased()
        }
        return trimmed.lowercased()
    }
}

// API 公开价的本地参考快照：优先使用 OpenRouter；目录缺失时才允许采用
// 模型官方公开 API 单价。运行时不联网更新价格，任何新增条目都随版本审查。
enum APIReferencePricingCatalog {
    static let observedAt = "2026-08-12"
    static let sourceURL = "https://openrouter.ai/api/v1/models"
    static let cnyPerUSD = 6.9
    // 目标币种是 USD：1 CNY = 1 / 6.9 USD。它是产品固定参考汇率，
    // 不是运行时外汇报价，避免为费用卡增加联网与历史漂移。
    static let conversionRatesToUSD = ["CNY": 1 / cnyPerUSD]

    static let estimator = APICostEstimator(snapshots: [
        // OpenAI / Codex 常见模型
        snapshot("openai/gpt-5", input: 1.25, cached: 0.125, output: 10),
        snapshot("openai/gpt-5.1-codex", input: 1.25, cached: 0.13, output: 10),
        snapshot("openai/gpt-5.1-codex-max", input: 1.25, cached: 0.125, output: 10),
        snapshot("openai/gpt-5.1-codex-mini", input: 0.25, cached: 0.03, output: 2),
        snapshot("openai/gpt-5.2-codex", input: 1.75, cached: 0.175, output: 14),
        snapshot("openai/gpt-5.3-codex", input: 1.75, cached: 0.175, output: 14),
        snapshot("openai/gpt-5.4", input: 2.5, cached: 0.25, output: 15),
        snapshot("openai/gpt-5.4-mini", input: 0.75, cached: 0.075, output: 4.5),
        snapshot("openai/gpt-5.5", input: 5, cached: 0.5, output: 30),
        snapshot("openai/gpt-5.6-sol", input: 5, cached: 0.5,
                 cacheWrite: 6.25, output: 30),
        snapshot("openai/gpt-5.6-terra", input: 1, cached: 0.1,
                 cacheWrite: 1.25, output: 6),

        // Kimi Code 本地 journal 使用产品别名；这里按官方模型映射到
        // OpenRouter 公开价。OpenRouter 未提供 cache write 时沿用普通输入价。
        snapshot("moonshotai/kimi-k3", aliases: ["kimi-k3", "k3-agent", "k3-256k"],
                 input: 3, cached: 0.3, output: 15),
        snapshot("moonshotai/kimi-k2.6", aliases: ["kimi-k2.6", "k2d6-agent"],
                 input: 0.5795, cached: 0.0976, output: 2.44),

        // OpenRouter 暂无 Doubao-Seed-Evolving。这里采用火山方舟公开原价，
        // 保留人民币币种；缓存创建没有独立公开价时按普通输入计。
        officialSnapshot(
            "doubao-seed-evolving",
            aliases: ["agent-plan/doubao-seed-evolving"],
            currency: "CNY",
            input: 6,
            cached: 1.2,
            output: 30,
            source: .init(
                label: "火山方舟",
                url: "https://www.volcengine.com/product/ark"
            )
        ),

        // Anthropic / Claude Code 常见模型
        snapshot("anthropic/claude-haiku-4.5", input: 1, cached: 0.1,
                 cacheWrite: 1.25, output: 5),
        snapshot("anthropic/claude-sonnet-4", input: 3, cached: 0.3,
                 cacheWrite: 3.75, output: 15),
        snapshot("anthropic/claude-sonnet-4.5", input: 3, cached: 0.3,
                 cacheWrite: 3.75, output: 15),
        snapshot("anthropic/claude-sonnet-4.6", input: 3, cached: 0.3,
                 cacheWrite: 3.75, output: 15),
        snapshot("anthropic/claude-sonnet-5", input: 2, cached: 0.2,
                 cacheWrite: 2.5, output: 10),
        snapshot("anthropic/claude-opus-4", input: 15, cached: 1.5,
                 cacheWrite: 18.75, output: 75),
        snapshot("anthropic/claude-opus-4.1", input: 15, cached: 1.5,
                 cacheWrite: 18.75, output: 75),
        snapshot("anthropic/claude-opus-4.5", input: 5, cached: 0.5,
                 cacheWrite: 6.25, output: 25),
        snapshot("anthropic/claude-opus-4.6", input: 5, cached: 0.5,
                 cacheWrite: 6.25, output: 25),
        snapshot("anthropic/claude-opus-4.7", input: 5, cached: 0.5,
                 cacheWrite: 6.25, output: 25),
        snapshot("anthropic/claude-opus-4.8", input: 5, cached: 0.5,
                 cacheWrite: 6.25, output: 25),
        snapshot("anthropic/claude-opus-5", input: 5, cached: 0.5,
                 cacheWrite: 6.25, output: 25),
        snapshot("anthropic/claude-fable-5", input: 10, cached: 1,
                 cacheWrite: 12.5, output: 50),

        // DeepSeek API 等价参考；平台返回费用仍优先作为实际平台口径展示。
        snapshot("deepseek/deepseek-v4-flash", aliases: ["V4 Flash"],
                 input: 0.14, cached: 0.028, output: 0.28),
        snapshot("deepseek/deepseek-v4-pro", aliases: ["V4 Pro"],
                 input: 1.168, cached: 0.09855, output: 2.336),
    ])

    private static func snapshot(
        _ id: String,
        aliases explicitAliases: [String] = [],
        input: Double,
        cached: Double,
        cacheWrite: Double? = nil,
        output: Double
    ) -> APIPriceSnapshot {
        let bare = id.split(separator: "/").last.map(String.init) ?? id
        var aliases = explicitAliases + [bare]
        if bare.hasPrefix("claude-") {
            let short = String(bare.dropFirst("claude-".count))
            aliases += [short, short.replacingOccurrences(of: ".", with: "-")]
        }
        return APIPriceSnapshot(
            model: id,
            aliases: aliases,
            effectiveFrom: observedAt,
            currency: "USD",
            perMillion: .init(
                newInput: input,
                cachedInput: cached,
                // OpenRouter 缺少 input_cache_write 时，按普通输入价处理；
                // 对自动 prompt caching 来说没有额外写入价。
                cacheCreation: cacheWrite ?? input,
                output: output,
                reasoningOutput: nil
            ),
            source: .openRouter
        )
    }

    private static func officialSnapshot(
        _ id: String,
        aliases: [String] = [],
        currency: String,
        input: Double,
        cached: Double,
        cacheWrite: Double? = nil,
        output: Double,
        source: APIPriceSnapshot.Source
    ) -> APIPriceSnapshot {
        APIPriceSnapshot(
            model: id,
            aliases: aliases,
            effectiveFrom: observedAt,
            currency: currency,
            perMillion: .init(
                newInput: input,
                cachedInput: cached,
                cacheCreation: cacheWrite ?? input,
                output: output,
                reasoningOutput: nil
            ),
            source: source
        )
    }
}
