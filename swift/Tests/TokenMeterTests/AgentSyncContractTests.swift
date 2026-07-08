import XCTest
@testable import TokenMeter

final class AgentSyncContractTests: XCTestCase {
    func testScanJSONDecodesCurrentProfileShape() throws {
        let json = """
        {
          "profiles": [
            {
              "key": "claude",
              "label": "Claude Code",
              "variant": "default",
              "mcp_state": "present",
              "mcp_count": 2,
              "has_rules": true,
              "memory": "CLAUDE.md",
              "skills": "5",
              "commands": "2",
              "agents": "1",
              "hooks": "3"
            },
            {
              "key": "codex",
              "label": "Codex",
              "variant": "default",
              "mcp_state": "absent",
              "mcp_count": null,
              "has_rules": false,
              "memory": "AGENTS.md",
              "skills": "—"
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(ConfigScanResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.profiles.count, 2)
        let claude = try XCTUnwrap(result.profiles.first)
        XCTAssertEqual(claude.key, "claude")
        XCTAssertEqual(claude.mcpDisplay, "2")
        XCTAssertTrue(claude.hasRules)
        XCTAssertTrue(claude.hasSkills)
        XCTAssertTrue(claude.hasCommands)
        XCTAssertTrue(claude.hasAgents)
        XCTAssertTrue(claude.hasHooks)
        XCTAssertTrue(claude.hasSyncableLayer)

        let codex = result.profiles[1]
        XCTAssertEqual(codex.mcpDisplay, "absent")
        XCTAssertFalse(codex.hasSkills)
        XCTAssertFalse(codex.hasCommands)
        XCTAssertFalse(codex.hasAgents)
        XCTAssertFalse(codex.hasHooks)
        XCTAssertFalse(codex.hasSyncableLayer)
    }
}
