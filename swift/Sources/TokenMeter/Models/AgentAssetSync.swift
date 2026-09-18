import Foundation

/// 一键资产同步使用的真源选择结果。
///
/// 推荐项只负责帮 UI 预选，不能等同于用户已经授权开启自动写入。
struct AgentAssetSyncSourceChoice: Equatable {
    enum Origin: Equatable {
        case saved
        case recommended
    }

    let sourceKey: String
    let origin: Origin

    var requiresUserConfirmation: Bool {
        origin == .recommended
    }
}

/// 一层资产及当前所有可接收这一层的目标。
///
/// 不把多个层先求交集：不同 Agent 可以各自只接收自己支持的层。
struct AgentAssetSyncLayerTargets: Equatable {
    let layer: String
    let targetKeys: [String]
}

enum AgentAssetSyncSelection {
    private static let supportedLayers = ["mcp", "rules", "skills", "commands", "agents", "hooks"]

    /// 真源中当前确实有内容、可以被拉取的层。
    ///
    /// agentsync 可能把空 MCP 配置报告为 present；只有 count > 0 才把它当作
    /// 非空真源。memory 是只读展示层，永远不进入自动同步。
    static func extractableLayers(for profile: ConfigProfile) -> [String] {
        let reported = Set(profile.syncableLayers)
        return supportedLayers.filter { layer in
            guard reported.contains(layer) else { return false }
            if layer == "mcp" {
                return (profile.mcpCount ?? 0) > 0
            }
            return true
        }
    }

    static func isValidSource(_ profile: ConfigProfile) -> Bool {
        !extractableLayers(for: profile).isEmpty
    }

    /// 优先保留仍然有效的已保存真源；否则只给出推荐预选，等待用户通过开关确认。
    static func sourceChoice(
        savedSourceKey: String?,
        profiles: [ConfigProfile]
    ) -> AgentAssetSyncSourceChoice? {
        let normalizedSaved = savedSourceKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedSaved,
           !normalizedSaved.isEmpty,
           let saved = profiles.first(where: { $0.key == normalizedSaved }),
           isValidSource(saved) {
            return AgentAssetSyncSourceChoice(sourceKey: saved.key, origin: .saved)
        }

        let recommended = profiles.enumerated()
            .compactMap { index, profile -> (
                index: Int, profile: ConfigProfile, layerCount: Int, assetCount: Int
            )? in
                let layerCount = extractableLayers(for: profile).count
                guard layerCount > 0 else { return nil }
                return (index, profile, layerCount, estimatedAssetCount(profile))
            }
            .sorted { lhs, rhs in
                if lhs.layerCount != rhs.layerCount {
                    return lhs.layerCount > rhs.layerCount
                }
                if lhs.assetCount != rhs.assetCount {
                    return lhs.assetCount > rhs.assetCount
                }
                return lhs.index < rhs.index
            }
            .first?
            .profile

        guard let recommended else { return nil }
        return AgentAssetSyncSourceChoice(sourceKey: recommended.key, origin: .recommended)
    }

    /// scan 只暴露数量摘要，不读取资产正文；同层数时用数量更完整者作 UI 推荐。
    /// 这仍只是预选，用户打开开关才构成写入授权。
    private static func estimatedAssetCount(_ profile: ConfigProfile) -> Int {
        var count = max(profile.mcpCount ?? 0, 0)
        if profile.hasRules { count += 1 }
        for summary in [profile.skills, profile.commands, profile.agents, profile.hooks] {
            guard let summary else { continue }
            let digits = summary.prefix { $0.isNumber }
            count += Int(digits) ?? 0
        }
        return count
    }

    /// 按层生成目标，不要求任何一个目标同时支持真源的全部层。
    static func layerTargets(
        sourceKey: String,
        profiles: [ConfigProfile]
    ) -> [AgentAssetSyncLayerTargets] {
        guard let source = profiles.first(where: { $0.key == sourceKey }),
              isValidSource(source) else {
            return []
        }

        return extractableLayers(for: source).map { layer in
            let targets = profiles.compactMap { profile -> String? in
                guard profile.key != sourceKey else { return nil }
                guard profile.writableLayers.contains(layer) else { return nil }
                return profile.key
            }
            return AgentAssetSyncLayerTargets(layer: layer, targetKeys: targets)
        }
    }
}
