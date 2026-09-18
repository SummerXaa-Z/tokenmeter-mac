import XCTest
@testable import TokenMeter

final class AgentAssetSyncSelectionTests: XCTestCase {
    func testEmptyMCPAloneIsNotAValidSource() {
        let source = makeProfile(key: "empty", mcpState: "present", mcpCount: 0)

        XCTAssertEqual(AgentAssetSyncSelection.extractableLayers(for: source), [])
        XCTAssertFalse(AgentAssetSyncSelection.isValidSource(source))
        XCTAssertNil(
            AgentAssetSyncSelection.sourceChoice(savedSourceKey: nil, profiles: [source])
        )
    }

    func testEmptyMCPDoesNotHideOtherExtractableLayersAndMemoryIsExcluded() {
        let source = makeProfile(
            key: "claude",
            mcpState: "present",
            mcpCount: 0,
            hasRules: true,
            memory: "CLAUDE.md",
            skills: "2"
        )

        XCTAssertEqual(
            AgentAssetSyncSelection.extractableLayers(for: source),
            ["rules", "skills"]
        )
        XCTAssertTrue(AgentAssetSyncSelection.isValidSource(source))
    }

    func testSavedSourceIsKeptAndDoesNotRequireFreshConfirmation() throws {
        let profiles = [
            makeProfile(key: "saved", hasRules: true),
            makeProfile(key: "richer", hasRules: true, skills: "2", commands: "1"),
        ]

        let choice = try XCTUnwrap(
            AgentAssetSyncSelection.sourceChoice(savedSourceKey: " saved ", profiles: profiles)
        )

        XCTAssertEqual(choice.sourceKey, "saved")
        XCTAssertEqual(choice.origin, .saved)
        XCTAssertFalse(choice.requiresUserConfirmation)
    }

    func testInvalidSavedSourceFallsBackToRecommendedPreselection() throws {
        let profiles = [
            makeProfile(key: "empty"),
            makeProfile(key: "rules", hasRules: true),
            makeProfile(key: "richer", hasRules: true, skills: "2"),
        ]

        let choice = try XCTUnwrap(
            AgentAssetSyncSelection.sourceChoice(savedSourceKey: "empty", profiles: profiles)
        )

        XCTAssertEqual(choice.sourceKey, "richer")
        XCTAssertEqual(choice.origin, .recommended)
        XCTAssertTrue(choice.requiresUserConfirmation)
    }

    func testRecommendedPreselectionUsesRicherAssetCountWhenLayerCoverageTies() throws {
        let profiles = [
            makeProfile(key: "claude", mcpState: "present", mcpCount: 4,
                        hasRules: true, skills: "27 项"),
            makeProfile(key: "codex", mcpState: "present", mcpCount: 5,
                        hasRules: true, skills: "27 项"),
        ]

        let choice = try XCTUnwrap(
            AgentAssetSyncSelection.sourceChoice(savedSourceKey: nil, profiles: profiles)
        )

        XCTAssertEqual(choice.sourceKey, "codex")
        XCTAssertEqual(choice.origin, .recommended)
    }

    func testTargetsAreBuiltPerLayerInsteadOfRequiringOneTargetToSupportEverything() {
        let profiles = [
            makeProfile(
                key: "source",
                mcpState: "present",
                mcpCount: 2,
                hasRules: true,
                writableLayers: ["mcp", "rules"]
            ),
            makeProfile(key: "mcp-only", writableLayers: ["mcp"]),
            makeProfile(key: "rules-only", writableLayers: ["rules"]),
            makeProfile(key: "both", writableLayers: ["mcp", "rules"]),
            makeProfile(key: "read-only", hasRules: true, writableLayers: []),
            makeProfile(key: "memory-only", writableLayers: ["memory"]),
        ]

        let routes = AgentAssetSyncSelection.layerTargets(
            sourceKey: "source",
            profiles: profiles
        )

        XCTAssertEqual(
            routes,
            [
                AgentAssetSyncLayerTargets(
                    layer: "mcp",
                    targetKeys: ["mcp-only", "both"]
                ),
                AgentAssetSyncLayerTargets(
                    layer: "rules",
                    targetKeys: ["rules-only", "both"]
                ),
            ]
        )
    }

    func testAbsentButDeclaredWritableMCPIsAValidCreateTarget() {
        let profiles = [
            makeProfile(key: "source", mcpState: "present", mcpCount: 1),
            makeProfile(
                key: "empty-target",
                mcpState: "absent",
                mcpCount: nil,
                writableLayers: ["mcp"]
            ),
        ]

        XCTAssertEqual(
            AgentAssetSyncSelection.layerTargets(sourceKey: "source", profiles: profiles),
            [AgentAssetSyncLayerTargets(layer: "mcp", targetKeys: ["empty-target"])]
        )
    }

    private func makeProfile(
        key: String,
        mcpState: String = "none",
        mcpCount: Int? = nil,
        hasRules: Bool = false,
        memory: String = "—",
        skills: String = "—",
        commands: String? = nil,
        agents: String? = nil,
        hooks: String? = nil,
        writableLayers: [String]? = nil
    ) -> ConfigProfile {
        ConfigProfile(
            key: key,
            label: key,
            variant: "default",
            mcpState: mcpState,
            mcpCount: mcpCount,
            hasRules: hasRules,
            memory: memory,
            skills: skills,
            commands: commands,
            agents: agents,
            hooks: hooks,
            declaredWritableLayers: writableLayers
        )
    }
}
