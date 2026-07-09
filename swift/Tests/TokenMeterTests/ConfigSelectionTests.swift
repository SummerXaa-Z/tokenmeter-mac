import XCTest
@testable import TokenMeter

final class ConfigSelectionTests: XCTestCase {
    func testSyncableProfilesHideEmptyProfiles() {
        let profiles = [
            makeProfile(key: "claude", hasRules: true),
            makeProfile(key: "zed"),
            makeProfile(key: "qoder", commands: "1"),
        ]

        let visible = ConfigSelection.syncableProfiles(profiles).map(\.key)

        XCTAssertEqual(visible, ["claude", "qoder"])
    }

    func testValidTargetsExcludeSourceAndUnsyncableProfiles() {
        let profiles = [
            makeProfile(key: "claude", hasRules: true),
            makeProfile(key: "codex", commands: "2"),
            makeProfile(key: "cursor"),
        ]
        let selected: Set<String> = ["claude", "codex", "cursor", "missing"]

        let targets = ConfigSelection.validTargets(
            selected,
            profiles: profiles,
            source: "claude"
        )

        XCTAssertEqual(targets, ["codex"])
    }

    private func makeProfile(
        key: String,
        hasRules: Bool = false,
        commands: String? = nil,
        agents: String? = nil,
        hooks: String? = nil
    ) -> ConfigProfile {
        ConfigProfile(
            key: key,
            label: key,
            variant: "default",
            mcpState: "none",
            mcpCount: nil,
            hasRules: hasRules,
            memory: "—",
            skills: "—",
            commands: commands,
            agents: agents,
            hooks: hooks
        )
    }
}
