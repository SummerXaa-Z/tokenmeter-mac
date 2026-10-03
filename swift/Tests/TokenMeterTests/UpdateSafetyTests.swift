import Foundation
import XCTest
@testable import TokenMeter

final class UpdateSafetyTests: XCTestCase {
    private let signing = UpdateSigningIdentity(requirement: "identifier fixture", leafCertificate: Data([1, 2, 3]), isAdHoc: false)

    private func identity(bundleID: String = UpdateSafety.bundleID, version: String = "4.0.0", architectures: Set<String> = ["arm64"], signing: UpdateSigningIdentity? = nil) -> UpdateBundleIdentity {
        UpdateBundleIdentity(bundleID: bundleID, version: version, architectures: architectures, signing: signing ?? self.signing)
    }

    func testRejectsWrongBundleVersionArchitectureAndPublisher() throws {
        let current = identity(version: "3.0.0")
        let candidates = [
            identity(bundleID: "com.example.other"),
            identity(version: "9.0.0"),
            identity(architectures: ["x86_64"]),
            identity(signing: UpdateSigningIdentity(requirement: "identifier fixture", leafCertificate: Data([9]), isAdHoc: false))
        ]
        for candidate in candidates {
            XCTAssertThrowsError(try UpdateSafety.validate(current: current, candidate: candidate, releaseVersion: "4.0.0", architecture: "arm64", matchesRequirement: { _ in true }))
        }
        XCTAssertThrowsError(try UpdateSafety.validate(current: current, candidate: identity(), releaseVersion: "4.0.0", architecture: "arm64", matchesRequirement: { _ in false }))
    }

    func testAdHocAndUnsignedCurrentBuildRequireManualDownload() {
        for signature in [nil, UpdateSigningIdentity(requirement: "identifier fixture", leafCertificate: Data(), isAdHoc: true)] {
            let current = UpdateBundleIdentity(bundleID: UpdateSafety.bundleID, version: "3.0.0", architectures: ["arm64"], signing: signature)
            XCTAssertThrowsError(try UpdateSafety.trustAnchor(for: current)) { error in
                guard case UpdateSafetyError.manualDownload = error else {
                    return XCTFail("Unknown publisher must require manual download")
                }
            }
        }
    }

    func testStableCertificateAndRequirementCanUpdate() throws {
        let current = identity(version: "3.0.0")
        var requirementWasChecked = false
        try UpdateSafety.validate(current: current, candidate: identity(), releaseVersion: "4.0.0", architecture: "arm64") { requirement in
            requirementWasChecked = requirement.contains("certificate leaf")
            return true
        }
        XCTAssertTrue(requirementWasChecked)
    }

    func testPreparationValidatesStagedCopyAndRejectsWrongIdentityWithoutReplacingOriginal() throws {
        try withInstallerFixture { fixture in
            let job = fixture.root.appendingPathComponent("job")
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
            var detached = false
            var inspectedStaging = false
            XCTAssertThrowsError(try UpdatePreparation.prepare(dmg: job.appendingPathComponent("release.dmg"), jobDirectory: job, target: fixture.target, current: identity(version: "3.0.0"), version: "4.0.0", run: { executable, arguments in
                if executable == "/usr/bin/hdiutil", arguments.first == "attach" {
                    let mount = job.appendingPathComponent("mount")
                    try FileManager.default.createDirectory(at: mount.appendingPathComponent("TokenMeter.app"), withIntermediateDirectories: false)
                    let plist: [String: Any] = ["system-entities": [["mount-point": mount.path, "dev-entry": "/dev/disk42s1"]]]
                    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    return String(decoding: data, as: UTF8.self)
                }
                if executable == "/usr/bin/hdiutil", arguments.first == "detach" { detached = true; return "" }
                if executable == "/usr/bin/ditto" {
                    try FileManager.default.copyItem(atPath: arguments[0], toPath: arguments[1])
                    return ""
                }
                throw UpdateSafetyError.toolFailed("Unexpected fixture command")
            }, inspect: { staged in
                inspectedStaging = staged.deletingLastPathComponent().lastPathComponent.hasPrefix(".TokenMeter-update-")
                return self.identity(bundleID: "com.example.other")
            }, matchesRequirement: { _, _ in true }))
            XCTAssertTrue(inspectedStaging)
            XCTAssertTrue(detached)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("old-marker").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".TokenMeter-update-") })
        }
    }

    func testMountedImageRejectsMultipleAndUnexpectedVolumes() throws {
        let mount = URL(fileURLWithPath: "/tmp/fixture-mount")
        for paths in [["/tmp/other"], [mount.path, "/tmp/other"]] {
            let plist: [String: Any] = ["system-entities": paths.map { ["mount-point": $0, "dev-entry": "/dev/disk42s1"] }]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            XCTAssertThrowsError(try UpdatePreparation.mountedDevice(plist: data, expectedMount: mount))
        }
    }

    func testMachOArchitectureReaderHandlesThinUniversalAndMalformedHeaders() throws {
        try withInstallerFixture { fixture in
            let binary = fixture.root.appendingPathComponent("fixture-mach-o")
            try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]).write(to: binary)
            XCTAssertEqual(try UpdateSafety.architectures(of: binary), ["arm64"])
            var universal: [UInt8] = [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2]
            universal += [1, 0, 0, 7] + Array(repeating: 0, count: 16)
            universal += [1, 0, 0, 12] + Array(repeating: 0, count: 16)
            try Data(universal).write(to: binary)
            XCTAssertEqual(try UpdateSafety.architectures(of: binary), ["x86_64", "arm64"])
            try Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2]).write(to: binary)
            XCTAssertThrowsError(try UpdateSafety.architectures(of: binary))
        }
    }

    func testPreparationRejectsCopyFailureWithoutReplacingOriginal() throws {
        try withInstallerFixture { fixture in
            let job = fixture.root.appendingPathComponent("job")
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
            XCTAssertThrowsError(try UpdatePreparation.prepare(dmg: job.appendingPathComponent("release.dmg"), jobDirectory: job, target: fixture.target, current: identity(version: "3.0.0"), version: "4.0.0", run: { executable, arguments in
                if executable == "/usr/bin/hdiutil", arguments.first == "attach" {
                    let mount = job.appendingPathComponent("mount")
                    try FileManager.default.createDirectory(at: mount.appendingPathComponent("TokenMeter.app"), withIntermediateDirectories: false)
                    let data = try PropertyListSerialization.data(fromPropertyList: ["system-entities": [["mount-point": mount.path, "dev-entry": "/dev/disk42s1"]]], format: .xml, options: 0)
                    return String(decoding: data, as: UTF8.self)
                }
                if executable == "/usr/bin/hdiutil", arguments.first == "detach" { return "" }
                throw UpdateSafetyError.toolFailed("Fixture copy failed")
            }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("old-marker").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".TokenMeter-update-") })
        }
    }

    func testRealSignatureValidationRejectsTamperedAdHocFixture() throws {
        try withInstallerFixture { fixture in
            let app = fixture.root.appendingPathComponent("SignedFixture.app")
            let contents = app.appendingPathComponent("Contents")
            let executableDirectory = contents.appendingPathComponent("MacOS")
            try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executableDirectory.appendingPathComponent("TokenMeter"))
            let info = ["CFBundleIdentifier": UpdateSafety.bundleID, "CFBundleExecutable": "TokenMeter", "CFBundleShortVersionString": "4.0.0", "CFBundleVersion": "1", "CFBundlePackageType": "APPL"]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            let resource = resources.appendingPathComponent("fixture.txt")
            try Data("original".utf8).write(to: resource)
            _ = try UpdateSafety.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            let inspected = try UpdateSafety.inspect(app)
            XCTAssertThrowsError(try UpdateSafety.trustAnchor(for: inspected))
            try Data("tampered".utf8).write(to: resource)
            XCTAssertThrowsError(try UpdateSafety.inspect(app))
        }
    }

    func testStagingVerificationFailurePreservesOriginal() throws {
        try withInstallerFixture { fixture in
            try fixture.run(verifyExit: 9)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("old-marker").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        }
    }

    func testStageOnlyVerificationFailureReopensVerifiedOriginalAndPersistsFailure() throws {
        try withInstallerFixture { fixture in
            try fixture.run(failStageVerifyOnly: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("old-marker").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("opened").path))
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("result"), encoding: .utf8), "failed\n")
        }
    }

    func testResultStoreExposesOnlyWhitelistedFailureState() throws {
        try withInstallerFixture { fixture in
            let store = UpdateResultStore(directory: fixture.root.resolvingSymlinksInPath().appendingPathComponent("Updates"))
            let result = try store.prepareResultFile()
            XCTAssertFalse(store.hasFailure)
            try Data("failed\n".utf8).write(to: result)
            XCTAssertTrue(store.hasFailure)
            try Data("unexpected arbitrary data".utf8).write(to: result)
            XCTAssertFalse(store.hasFailure)
        }
    }

    func testFailedReplacementRollsBackOriginal() throws {
        try withInstallerFixture { fixture in
            try fixture.run(failStageMove: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("old-marker").path))
        }
    }

    func testFailedLaunchRollsBackOriginal() throws {
        try withInstallerFixture { fixture in
            try fixture.run(openExit: 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("old-marker").path))
        }
    }

    func testFailedLaunchRecoversOriginalWhenMoveBackToStageFails() throws {
        try withInstallerFixture { fixture in
            try fixture.run(openExit: 1, failRollbackStageMove: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("old-marker").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("new-marker").path))
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("open-attempts"), encoding: .utf8), "new\nold\n")
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("result"), encoding: .utf8), "failed\n")
            let retainedFiles = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            XCTAssertEqual(retainedFiles.filter { $0.lastPathComponent == "new-marker" }.count, 1)
        }
    }

    func testFailedLaunchPreservesBackupWhenCandidateCannotBeMovedDuringRollback() throws {
        try withInstallerFixture { fixture in
            try fixture.run(openExit: 1, failRollbackStageMove: true, failRollbackRecoveryMove: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("new-marker").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.appendingPathComponent("old-marker").path))
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("open-attempts"), encoding: .utf8), "new\n")
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("result"), encoding: .utf8), "failed\n")
        }
    }

    func testFailedLaunchDoesNotReopenRestoredOriginalWhenVerificationFails() throws {
        try withInstallerFixture { fixture in
            try fixture.run(openExit: 1, failRollbackStageMove: true, failRestoredVerify: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("old-marker").path))
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("open-attempts"), encoding: .utf8), "new\n")
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("result"), encoding: .utf8), "failed\n")
        }
    }

    func testSuccessfulReplacementRetainsRecoveryBackup() throws {
        try withInstallerFixture { fixture in
            try fixture.run()
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("new-marker").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.appendingPathComponent("old-marker").path))
        }
    }

    private func withInstallerFixture(_ body: (InstallerFixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeter-installer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try InstallerFixture(root: root)
        try body(fixture)
    }
}

private struct InstallerFixture {
    let root: URL
    let target: URL
    let stage: URL
    let backup: URL

    init(root: URL) throws {
        self.root = root
        // Exercise shell paths with spaces, quotes and command substitutions as literal data.
        target = root.appendingPathComponent("Original ' $(touch NEVER).app")
        stage = root.appendingPathComponent("Staged.app")
        backup = root.appendingPathComponent("Backup.app")
        for app in [target, stage] {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: target.appendingPathComponent("old-marker"))
        try Data("new".utf8).write(to: stage.appendingPathComponent("new-marker"))
    }

    func run(verifyExit: Int = 0, openExit: Int = 0, failStageMove: Bool = false, failStageVerifyOnly: Bool = false,
             failRollbackStageMove: Bool = false, failRollbackRecoveryMove: Bool = false, failRestoredVerify: Bool = false) throws {
        let verify = try tool("verify", """
        if [ "${@: -1}" = "$TM_STAGE" ] && [ "\(failStageVerifyOnly ? "yes" : "no")" = yes ]; then exit 7; fi
        if [ "${@: -1}" = "$TM_TARGET" ] && [ -e "${TM_RESULT%/*}/open-attempts" ] && [ "\(failRestoredVerify ? "yes" : "no")" = yes ]; then exit 9; fi
        exit \(verifyExit)
        """)
        let open = try tool("open", """
        touch "${TM_RESULT%/*}/opened"
        if [ -e "$1/new-marker" ]; then
          printf 'new\\n' >> "${TM_RESULT%/*}/open-attempts"
          exit \(openExit)
        fi
        if [ -e "$1/old-marker" ]; then
          printf 'old\\n' >> "${TM_RESULT%/*}/open-attempts"
          exit 0
        fi
        exit 1
        """)
        let plist = try tool("plist", "case \"$2\" in *CFBundleIdentifier) echo com.deepseek.monitor.mac;; *CFBundleShortVersionString) echo 4.0.0;; *CFBundleExecutable) echo TokenMeter;; *) exit 1;; esac")
        let arch = try tool("arch", "echo 'Mach-O universal binary x86_64 arm64'")
        let move = try tool("move", """
        if [ "$1" = "$TM_STAGE" ] && [ "\(failStageMove ? "yes" : "no")" = yes ]; then exit 7; fi
        if [ "$1" = "$TM_TARGET" ] && [ "$2" = "$TM_STAGE" ] && [ "\(failRollbackStageMove ? "yes" : "no")" = yes ]; then exit 7; fi
        if [ "$1" = "$TM_TARGET" ] && [ "$2" != "$TM_STAGE" ] && [ "$2" != "$TM_BACKUP" ] && [ "\(failRollbackRecoveryMove ? "yes" : "no")" = yes ]; then exit 7; fi
        exec /bin/mv "$@"
        """)
        let script = root.appendingPathComponent("installer.sh")
        try UpdateInstallerScript.source.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = UpdateInstallerScript.environment(target: target, stagedApp: stage, backup: backup, requirement: "fixture requirement", processID: 0, resultFile: root.appendingPathComponent("result"), verifyCommand: verify.path, moveCommand: move.path, openCommand: open.path, plistCommand: plist.path, architectureCommand: arch.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus == 0, verifyExit == 0 && openExit == 0 && !failStageMove && !failStageVerifyOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("NEVER").path))
    }

    private func tool(_ name: String, _ body: String) throws -> URL {
        let path = root.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
}
