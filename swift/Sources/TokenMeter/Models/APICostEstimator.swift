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
    // 用量发生日：按这一天已生效的价格计价；nil 时沿用汇总的 referenceDate
    var usageDate: String? = nil
    // 采集来源：同名模型在不同工具里分开列金额
    var source: HistorySource? = nil
}

struct APIReferenceCostSummary: Equatable {
    struct Amount: Equatable, Identifiable {
        let currency: String
        let total: Double

        var id: String { currency }
    }

    // 单个"来源 + 模型"的等价金额，已折算到汇总币种；按金额降序
    struct ModelAmount: Equatable, Identifiable {
        let source: HistorySource?
        let model: String          // 去掉推理强度后缀、保留原大小写
        let total: Double
        let tokens: Int

        var id: String { "\(source?.rawValue ?? "")|\(model.lowercased())" }
    }

    let total: Double
    let currency: String
    let amounts: [Amount]
    let modelAmounts: [ModelAmount]
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
        var modelTotals: [String: ModelAmount] = [:]
        var sources = Set<String>()
        var matched = 0
        var all = 0
        var missing: [String: String] = [:]   // 规范名 → 展示名，避免大小写重复

        for sample in samples where sample.tokens.totalTokens > 0 {
            all += sample.tokens.totalTokens
            let canonical = APICostEstimator.canonicalModel(sample.model)
            guard let estimate = estimator.estimate(
                model: sample.model,
                usageDate: sample.usageDate ?? referenceDate,
                tokens: sample.tokens
            ) else {
                missing[canonical] = missing[canonical] ?? APICostEstimator.baseModel(sample.model)
                continue
            }
            totalsByCurrency[estimate.currency, default: 0] += estimate.total
            sources.insert(estimate.priceSource.label)
            matched += sample.tokens.totalTokens

            guard let converted = Self.convert(
                estimate.total, from: estimate.currency, to: currency, rates: conversionRates
            ) else { continue }
            let key = "\(sample.source?.rawValue ?? "")|\(canonical)"
            let previous = modelTotals[key]
            modelTotals[key] = ModelAmount(
                source: sample.source,
                model: previous?.model ?? APICostEstimator.baseModel(sample.model),
                total: (previous?.total ?? 0) + converted,
                tokens: (previous?.tokens ?? 0) + sample.tokens.totalTokens
            )
        }

        amounts = totalsByCurrency.map { Amount(currency: $0.key, total: $0.value) }
            .sorted {
                if $0.currency == currency { return true }
                if $1.currency == currency { return false }
                return $0.currency < $1.currency
            }
        total = totalsByCurrency.reduce(into: 0.0) { result, entry in
            result += Self.convert(
                entry.value, from: entry.key, to: currency, rates: conversionRates
            ) ?? 0
        }
        modelAmounts = modelTotals.values.sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.id < $1.id
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
        unpricedModels = missing.values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    // 缺汇率的币种返回 nil：宁可不计入合计，也不按 1:1 混算
    private static func convert(
        _ amount: Double,
        from source: String,
        to target: String,
        rates: [String: Double]
    ) -> Double? {
        if source == target { return amount }
        guard let rate = rates[source], rate > 0 else { return nil }
        return amount * rate
    }
}

struct APICostEstimator {
    let snapshots: [APIPriceSnapshot]
    // 规范名 → 快照：按天 × 模型重算时每个样本都要查价，避免每次线性扫描
    private let index: [String: [APIPriceSnapshot]]

    init(snapshots: [APIPriceSnapshot]) {
        self.snapshots = snapshots
        var index: [String: [APIPriceSnapshot]] = [:]
        for snapshot in snapshots {
            let names = Set([Self.canonicalModel(snapshot.model)]
                + snapshot.aliases.map(Self.canonicalModel))
            for name in names { index[name, default: []].append(snapshot) }
        }
        self.index = index
    }

    // 匹配规则与 estimate 相同（生效日 ≤ date、来源优先级、同优先级取
    // 最新生效日），但返回价格快照本身，供需要展示单价而不只是金额的调用方
    func priceSnapshot(model: String, on date: String) -> APIPriceSnapshot? {
        let matching = (index[Self.canonicalModel(model)] ?? []).filter {
            $0.effectiveFrom <= date
        }
        return matching.max(by: {
            if $0.source.priority != $1.source.priority {
                return $0.source.priority < $1.source.priority
            }
            return $0.effectiveFrom < $1.effectiveFrom
        })
    }

    func estimate(
        model: String,
        usageDate: String,
        tokens: APITokenBreakdown
    ) -> APICostEstimate? {
        guard let price = priceSnapshot(model: model, on: usageDate) else {
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
        baseModel(raw).lowercased()
    }

    // 去掉首尾空白与推理强度后缀、保留原大小写，用于展示
    static func baseModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: " ", options: .backwards),
           trimmed[range.upperBound...].first == "(",
           trimmed.hasSuffix(")") {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }
}

// API 公开价的本地参考快照：优先使用 OpenRouter；目录缺失时才允许采用
// 模型官方公开 API 单价。运行时不联网更新价格，任何新增条目都随版本审查。
//
// 目录刷新只追加、不改旧价：调价模型新增一条自本次观测日起生效的快照，
// 此前的用量继续按当日价格计算。新收录模型的生效日取 OpenRouter 上架日
// 与首个观测日的较晚者，上架之前的用量保持缺价，不向前套用。
//
// 刷新流程：`make price-check` 拉取 OpenRouter 实时目录与内置快照逐一比对，
// 调价模型输出可直接粘贴的 snapshot 行；核对后更新 observedAt 随版本发布。
// 快照的生效日一律写显式日期字面量，不引用 observedAt——否则 bump 观测日
// 会悄悄平移已有调价的生效日。
enum APIReferencePricingCatalog {
    // 首个价格快照的观测日；早于它的用量按这一天的价格参考
    static let firstObservedAt = "2026-08-12"
    // 最近一次核对 OpenRouter 目录的日期
    static let observedAt = "2026-09-30"
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
        snapshot("openai/gpt-5.6-sol", from: "2026-09-25", input: 2, cached: 0.2,
                 cacheWrite: 2.5, output: 10),
        snapshot("openai/gpt-5.6-terra", input: 1, cached: 0.1,
                 cacheWrite: 1.25, output: 6),
        snapshot("openai/gpt-5.6-terra", from: "2026-09-25", input: 2, cached: 0.2,
                 cacheWrite: 2.5, output: 12),
        snapshot("openai/gpt-5.6-luna", input: 0.2, cached: 0.02,
                 cacheWrite: 0.25, output: 1.2),

        // Kimi Code 本地 journal 使用产品别名；这里按官方模型映射到
        // OpenRouter 公开价。OpenRouter 未提供 cache write 时沿用普通输入价。
        snapshot("moonshotai/kimi-k3", aliases: ["kimi-k3", "k3-agent", "k3-256k"],
                 input: 3, cached: 0.3, output: 15),
        snapshot("moonshotai/kimi-k2.6", aliases: ["kimi-k2.6", "k2d6-agent"],
                 input: 0.5795, cached: 0.0976, output: 2.44),
        snapshot("moonshotai/kimi-k2.6", aliases: ["kimi-k2.6", "k2d6-agent"],
                 from: "2026-09-25", input: 0.95, cached: 0.16, output: 4),
        snapshot("moonshotai/kimi-k2.6", aliases: ["kimi-k2.6", "k2d6-agent"],
                 from: "2026-09-30", input: 0.65, cached: 0.15, output: 3.41),
        snapshot("moonshotai/kimi-k2.7-code", input: 0.6562, cached: 0.18, output: 3.3),
        snapshot("moonshotai/kimi-k2.7-code", from: "2026-09-30",
                 input: 0.6712, cached: 0.18, output: 3.35),

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
        snapshot("anthropic/claude-sonnet-5.5", from: "2026-09-28",
                 input: 2, cached: 0.2, cacheWrite: 2.5, output: 10),
        // 已从 OpenRouter 目录下架；历史用量仍按此价计算，保留
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
        snapshot("anthropic/claude-opus-5.5", from: "2026-09-22", input: 4, cached: 0.2,
                 cacheWrite: 5, output: 20),
        snapshot("anthropic/claude-fable-5", input: 10, cached: 1,
                 cacheWrite: 12.5, output: 50),
        snapshot("anthropic/claude-fable-5.1", from: "2026-09-01", input: 10, cached: 0.25,
                 cacheWrite: 12.5, output: 50),

        // 智谱 GLM：Claude Code / OpenCode 本地会话里直接出现 glm-* 模型名
        snapshot("z-ai/glm-4.6", input: 0.43, cached: 0.08, output: 1.75),
        snapshot("z-ai/glm-4.7", input: 0.6, cached: 0.11, output: 2.2),
        snapshot("z-ai/glm-5", input: 0.6, cached: 0.12, output: 1.92),
        snapshot("z-ai/glm-5-turbo", input: 1.2, cached: 0.24, output: 4),
        snapshot("z-ai/glm-5.1", input: 0.9646, cached: 0.17914, output: 3.0316),
        snapshot("z-ai/glm-5.1", from: "2026-09-30", input: 1.4, cached: 0.26, output: 4.4),
        snapshot("z-ai/glm-5.2", input: 0.6496, cached: 0.12064, output: 2.0416),
        snapshot("z-ai/glm-5.2", from: "2026-09-30", input: 0.41, cached: 0.26, output: 3.99),
        snapshot("z-ai/glm-5.3", from: "2026-08-18", input: 1.4, cached: 0.26, output: 4.4),
        snapshot("z-ai/glm-5.3-flash", from: "2026-08-26",
                 input: 0.045, cached: 0.01, output: 0.14),
        snapshot("z-ai/glm-5.3-flash", from: "2026-09-30",
                 input: 0.15, cached: 0.03, output: 0.5),
        snapshot("z-ai/glm-5.3-flashx", from: "2026-09-18",
                 input: 0.37, cached: 0.09, output: 1.25),
        snapshot("z-ai/glm-5.3-prime", from: "2026-09-23",
                 input: 2.8, cached: 0.56, output: 8.8),

        // Google Gemini：OpenRouter 单列 reasoning 价（与输出同价）
        snapshot("google/gemini-3.1-pro-preview", input: 2, cached: 0.2,
                 cacheWrite: 0.375, output: 12, reasoning: 12),
        snapshot("google/gemini-3.5-flash", input: 1.5, cached: 0.15,
                 cacheWrite: 0.083333, output: 9, reasoning: 9),
        snapshot("google/gemini-3.5-flash-lite", input: 0.3, cached: 0.03,
                 cacheWrite: 0.083333, output: 2.5, reasoning: 2.5),
        snapshot("google/gemini-3.6-flash", input: 0.75, cached: 0.075,
                 cacheWrite: 0.041667, output: 3.75, reasoning: 3.75),
        snapshot("google/gemini-3.7-flash", from: "2026-08-13", input: 0.75, cached: 0.075,
                 cacheWrite: 0.041667, output: 3.75, reasoning: 3.75),
        snapshot("google/gemini-3.8-flash", from: "2026-09-02", input: 0.75, cached: 0.075,
                 cacheWrite: 0.041667, output: 3.75, reasoning: 3.75),

        // Qwen Code 常见模型
        snapshot("qwen/qwen3-coder", input: 0.3, cached: 0.1, output: 1),
        snapshot("qwen/qwen3-coder-plus", input: 0.65, cached: 0.13,
                 cacheWrite: 0.8125, output: 3.25),
        snapshot("qwen/qwen3.7-plus", input: 0.32, cached: 0.064,
                 cacheWrite: 0.4, output: 1.28),
        snapshot("qwen/qwen3.7-max", input: 1.475, cached: 0.295,
                 cacheWrite: 1.84375, output: 4.425),
        snapshot("qwen/qwen3.8-flash", from: "2026-08-26", input: 0.15, cached: 0.016,
                 cacheWrite: 0.2, output: 0.47),
        snapshot("qwen/qwen3.8-max-0902", from: "2026-09-03", input: 2, cached: 0.25,
                 cacheWrite: 2.5, output: 6),

        // MiniMax
        snapshot("minimax/minimax-m2.7", input: 0.3, cached: 0.06, output: 1.2),
        snapshot("minimax/minimax-m2.7", from: "2026-09-27",
                 input: 0.21, cached: 0.042, output: 0.84),
        snapshot("minimax/minimax-m3", input: 0.3, cached: 0.06, output: 1.2),

        // DeepSeek API 等价参考；平台返回费用仍优先作为实际平台口径展示。
        snapshot("deepseek/deepseek-v4-flash", aliases: ["V4 Flash"],
                 input: 0.14, cached: 0.028, output: 0.28),
        snapshot("deepseek/deepseek-v4-flash", aliases: ["V4 Flash"],
                 from: "2026-09-25", input: 0.049, cached: 0.0098, output: 0.098),
        snapshot("deepseek/deepseek-v4-flash", aliases: ["V4 Flash"],
                 from: "2026-09-27", input: 0.0469, cached: 0.00938, output: 0.0938),
        snapshot("deepseek/deepseek-v4-flash", aliases: ["V4 Flash"],
                 from: "2026-09-30", input: 0.14, cached: 0.028, output: 0.28),
        snapshot("deepseek/deepseek-v4-pro", aliases: ["V4 Pro"],
                 input: 1.168, cached: 0.09855, output: 2.336),
        snapshot("deepseek/deepseek-v4-pro", aliases: ["V4 Pro"],
                 from: "2026-09-25", input: 0.783, cached: 0.06525, output: 1.566),
        snapshot("deepseek/deepseek-v4-pro", aliases: ["V4 Pro"],
                 from: "2026-09-27", input: 0.348, cached: 0.029, output: 0.696),
        snapshot("deepseek/deepseek-v4-pro", aliases: ["V4 Pro"],
                 from: "2026-09-30", input: 0.95526, cached: 0.079605, output: 1.91052),
        snapshot("deepseek/deepseek-v4.1-flash", from: "2026-09-10",
                 input: 0.3, cached: 0.006, output: 1.2),
        snapshot("deepseek/deepseek-v4.1-flash", from: "2026-09-27",
                 input: 0.035, cached: 0.001, output: 0.29),
        snapshot("deepseek/deepseek-v4.1-flash", from: "2026-09-30",
                 input: 0.0198, cached: 0.00291, output: 0.396),
    ])

    private static func snapshot(
        _ id: String,
        aliases explicitAliases: [String] = [],
        from effectiveFrom: String = firstObservedAt,
        input: Double,
        cached: Double,
        cacheWrite: Double? = nil,
        output: Double,
        reasoning: Double? = nil
    ) -> APIPriceSnapshot {
        let bare = id.split(separator: "/").last.map(String.init) ?? id
        var aliases = explicitAliases + [bare]
        // Claude Code 本地记录的模型 id 用连字符写版本号（claude-opus-5-5），
        // 且 displayModel 会去掉 claude- 前缀；四种写法都指向同一条价格。
        if bare.hasPrefix("claude-") {
            let short = String(bare.dropFirst("claude-".count))
            aliases += [
                short,
                short.replacingOccurrences(of: ".", with: "-"),
                bare.replacingOccurrences(of: ".", with: "-"),
            ]
        }
        return APIPriceSnapshot(
            model: id,
            aliases: aliases,
            effectiveFrom: effectiveFrom,
            currency: "USD",
            perMillion: .init(
                newInput: input,
                cachedInput: cached,
                // OpenRouter 缺少 input_cache_write 时，按普通输入价处理；
                // 对自动 prompt caching 来说没有额外写入价。
                cacheCreation: cacheWrite ?? input,
                output: output,
                reasoningOutput: reasoning
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
            effectiveFrom: firstObservedAt,
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

    // `--dump-price-catalog`（Debug）导出的机器可比对形态，供
    // scripts/price-check.sh 与 OpenRouter 实时目录逐一对照。
    // 只输出模型名、别名、生效日与单价，不含任何本地用量数据。
    static func jsonDump() -> String {
        let payload: [String: Any] = [
            "firstObservedAt": firstObservedAt,
            "observedAt": observedAt,
            "cnyPerUSD": cnyPerUSD,
            "snapshots": estimator.snapshots.map { snapshot -> [String: Any] in
                var rates: [String: Any] = [
                    "input": snapshot.perMillion.newInput,
                    "cached": snapshot.perMillion.cachedInput,
                    "cacheWrite": snapshot.perMillion.cacheCreation,
                    "output": snapshot.perMillion.output,
                ]
                if let reasoning = snapshot.perMillion.reasoningOutput {
                    rates["reasoning"] = reasoning
                }
                return [
                    "model": snapshot.model,
                    "aliases": snapshot.aliases,
                    "effectiveFrom": snapshot.effectiveFrom,
                    "currency": snapshot.currency,
                    "source": snapshot.source.label,
                    "perMillion": rates,
                ]
            },
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
