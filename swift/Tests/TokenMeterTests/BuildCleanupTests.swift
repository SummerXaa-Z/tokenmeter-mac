import Foundation
import XCTest

final class BuildCleanupTests: XCTestCase {
    func testRemovesOnlyRecognizedBuildDirectoryAndPreservesSources() throws {
        try withFixture { root in
            let swift = root.appendingPathComponent("swift")
            let build = swift.appendingPathComponent("build")
            try createDerivedData(at: build)
            let sources = swift.appendingPathComponent("Sources")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            let sentinel = sources.appendingPathComponent("keep.txt")
            try "source fixture".write(to: sentinel, atomically: true, encoding: .utf8)

            XCTAssertEqual(try runCleanup(root: root, value: "build"), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: build.path))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "source fixture")
        }
    }

    func testSupportsKnownDerivedDataDirectoryAndMissingDirectory() throws {
        try withFixture { root in
            let build = root.appendingPathComponent("swift/DerivedData")
            try createDerivedData(at: build)
            XCTAssertEqual(try runCleanup(root: root, value: "DerivedData"), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: build.path))
            XCTAssertEqual(try runCleanup(root: root, value: "DerivedData"), 0)
        }
    }

    func testRejectsTraversalAbsoluteEmptySourceAndShellArguments() throws {
        try withFixture { root in
            let build = root.appendingPathComponent("swift/build")
            try createDerivedData(at: build)
            for value in ["", ".", "..", "../..", "/", root.path, "Sources", "build/..", "build with spaces", "build; touch injected", "$(touch injected)"] {
                XCTAssertNotEqual(try runCleanup(root: root, value: value), 0, value)
                XCTAssertTrue(FileManager.default.fileExists(atPath: build.path), value)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
        }
    }

    func testRejectsSymlinkAndUnrecognizedDirectoryWithoutRemovingContents() throws {
        try withFixture { root in
            let outside = root.appendingPathComponent("outside")
            try createDerivedData(at: outside)
            let build = root.appendingPathComponent("swift/build")
            try FileManager.default.createSymbolicLink(at: build, withDestinationURL: outside)
            XCTAssertNotEqual(try runCleanup(root: root, value: "build"), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
            try FileManager.default.removeItem(at: build)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            let sentinel = build.appendingPathComponent("keep.txt")
            try "not build data".write(to: sentinel, atomically: true, encoding: .utf8)
            XCTAssertNotEqual(try runCleanup(root: root, value: "build"), 0)
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "not build data")
        }
    }

    func testRejectsRegularFileTargetWithoutRemovingIt() throws {
        try withFixture { root in
            let build = root.appendingPathComponent("swift/build")
            try "not a directory".write(to: build, atomically: true, encoding: .utf8)
            XCTAssertNotEqual(try runCleanup(root: root, value: "build"), 0)
            XCTAssertEqual(try String(contentsOf: build, encoding: .utf8), "not a directory")
        }
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter clean-tests-\(UUID().uuidString)")
        let scripts = root.appendingPathComponent("swift/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/clean-build.sh")
        try FileManager.default.copyItem(at: source, to: scripts.appendingPathComponent("clean-build.sh"))
        try body(root)
    }

    private func createDerivedData(at directory: URL) throws {
        for name in ["Build", "Logs"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "fixture".write(to: directory.appendingPathComponent("info.plist"), atomically: true, encoding: .utf8)
    }

    private func runCleanup(root: URL, value: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("swift/scripts/clean-build.sh").path]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["DERIVED_DATA"] = value
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
