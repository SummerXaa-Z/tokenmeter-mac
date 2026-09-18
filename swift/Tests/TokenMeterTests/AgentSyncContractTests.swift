import XCTest
@testable import TokenMeter

final class AgentSyncContractTests: XCTestCase {
    func testProcessPipeReaderDrainsLargeStderrWithoutDeadlock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/usr/bin/head -c 1048576 /dev/zero >&2; printf done"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let output = ProcessPipeReader.read(stdout: stdout, stderr: stderr, process: process)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "done")
        XCTAssertEqual(output.stderr.count, 1_048_576)
    }

    func testProcessFailuresDoNotEchoRawCLIDetails() {
        XCTAssertEqual(
            AgentSyncError.nonZeroExit(code: 17).errorDescription,
            "agentsync 执行失败（退出码 17）。请检查安装状态后重试。"
        )
        XCTAssertEqual(
            AgentSyncError.decodeFailed.errorDescription,
            "agentsync 返回了无法识别的数据。请更新 agentsync 后重试。"
        )
        XCTAssertEqual(
            AgentSyncError.timedOut.errorDescription,
            "agentsync 执行超时，未继续等待。"
        )
    }

    func testAgentSyncProcessRunnerTimesOutWithoutWaitingForever() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while :; do :; done"]

        XCTAssertThrowsError(try AgentSyncProcessRunner.run(
            process: process,
            timeout: 0.05,
            maximumStdoutBytes: 1024,
            maximumStderrBytes: 1024
        )) { error in
            guard let agentError = error as? AgentSyncError,
                  case .timedOut = agentError else {
                return XCTFail("expected timedOut")
            }
        }
    }

    func testAgentSyncProcessRunnerRejectsOversizedOutput() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/usr/bin/head -c 4096 /dev/zero"]

        XCTAssertThrowsError(try AgentSyncProcessRunner.run(
            process: process,
            timeout: 2,
            maximumStdoutBytes: 32,
            maximumStderrBytes: 32
        )) { error in
            guard let agentError = error as? AgentSyncError,
                  case .outputTooLarge = agentError else {
                return XCTFail("expected outputTooLarge")
            }
        }
    }

    func testDisabledConfigSyncBlocksMutatingEntryPoints() throws {
        XCTAssertNoThrow(try ConfigSyncAccess.requireEnabled(true))
        XCTAssertThrowsError(try ConfigSyncAccess.requireEnabled(false)) { error in
            XCTAssertEqual(
                (error as? AgentSyncError)?.errorDescription,
                "配置同步面板已关闭。请先在设置中重新开启。"
            )
        }
    }

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
              "writable_layers": ["mcp", "rules", "skills", "commands", "agents", "hooks"],
              "supported_layers": ["mcp", "rules", "skills", "commands", "agents", "hooks"],
              "syncable_layers": ["mcp", "rules", "skills", "commands", "agents", "hooks"],
              "adapter_coverage": {"mcp":"read_write","rules":"read_write"},
              "unsupported": {},
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
        XCTAssertEqual(claude.writableLayers, ["mcp", "rules", "skills", "commands", "agents", "hooks"])
        XCTAssertEqual(claude.supportedLayers, ["mcp", "rules", "skills", "commands", "agents", "hooks"])
        XCTAssertEqual(claude.declaredSyncableLayers, ["mcp", "rules", "skills", "commands", "agents", "hooks"])
        XCTAssertEqual(claude.adapterCoverage?["mcp"], "read_write")
        XCTAssertEqual(claude.unsupportedLayers, [:])

        let codex = result.profiles[1]
        XCTAssertEqual(codex.mcpDisplay, "absent")
        XCTAssertFalse(codex.hasSkills)
        XCTAssertFalse(codex.hasCommands)
        XCTAssertFalse(codex.hasAgents)
        XCTAssertFalse(codex.hasHooks)
        XCTAssertFalse(codex.hasSyncableLayer)
        XCTAssertNil(codex.declaredWritableLayers)
        XCTAssertEqual(codex.writableLayers, [])
    }

    func testPushJSONDecodesSkipEntryWithoutPath() throws {
        let json = """
        {
          "ok": true,
          "apply": false,
          "any_change": false,
          "backup_ts": null,
          "targets": [
            {
              "key": "codex",
              "label": "Codex",
              "layer": "memory",
              "change": "skip",
              "skip_reason": "该层只读",
              "written": false
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(PushResult.self, from: Data(json.utf8))
        let target = try XCTUnwrap(result.targets.first)

        XCTAssertNil(target.path)
        XCTAssertNil(target.exists)
        XCTAssertEqual(target.skipReason, "该层只读")
    }

    func testPreviewMarksMissingRequestedTargetLayersAndIgnoresSkipForWrites() throws {
        let json = """
        {
          "ok": true,
          "apply": false,
          "any_change": true,
          "backup_ts": null,
          "targets": [
            {
              "key": "claude",
              "label": "Claude Code",
              "layer": "mcp",
              "path": "/tmp/claude.json",
              "exists": true,
              "change": "modify",
              "written": false
            },
            {
              "key": "codex",
              "label": "Codex",
              "layer": "rules",
              "change": "skip",
              "skip_reason": "该层只读",
              "written": false
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(PushResult.self, from: Data(json.utf8))
        let missing = ConfigPreview.missingTargetLayers(
            targets: ["claude", "codex"],
            layers: ["mcp", "rules"],
            result: result
        )

        XCTAssertEqual(
            missing,
            [
                ConfigSyncTargetLayer(target: "claude", layer: "rules"),
                ConfigSyncTargetLayer(target: "codex", layer: "mcp")
            ]
        )
        XCTAssertEqual(ConfigPreview.writableTargetKeys(in: result), ["claude"])
        XCTAssertFalse(
            ConfigPreview.canApply(
                targets: ["claude", "codex"],
                layers: ["mcp", "rules"],
                result: result
            )
        )
        XCTAssertTrue(
            ConfigPreview.canApply(
                targets: ["claude"],
                layers: ["mcp"],
                result: result
            )
        )
    }

    func testReconcileJSONDecodesLayerGroupsAndRulesConflict() throws {
        let json = """
        {
          "ok": true,
          "apply": true,
          "applied": true,
          "source": "codex",
          "label": "Codex",
          "layers": [
            {"layer":"mcp","target_count":2,"targets":["claude","cursor"]},
            {"layer":"rules","target_count":1,"targets":["claude"]}
          ],
          "target_count": 2,
          "any_change": true,
          "backup_ts": "20300101T000000-abc123",
          "targets": [
            {
              "key":"cursor","label":"Cursor","layer":"mcp",
              "path":"/tmp/mcp.json","exists":false,"change":"create","written":true
            },
            {
              "key":"claude","label":"Claude Code","layer":"rules",
              "path":"/tmp/CLAUDE.md","exists":true,"change":"skip","written":false,
              "conflict":true,"skip_reason":"目标规则已存在且不同"
            }
          ],
          "error": null
        }
        """

        let result = try JSONDecoder().decode(AgentAssetSyncResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.source, "codex")
        XCTAssertEqual(result.targetCount, 2)
        XCTAssertEqual(result.layers.map(\.layer), ["mcp", "rules"])
        XCTAssertEqual(result.layers[0].targets, ["claude", "cursor"])
        XCTAssertEqual(result.conflicts.map(\.key), ["claude"])
    }
}
