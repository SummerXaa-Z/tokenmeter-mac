import XCTest
@testable import TokenMeter

final class SourceHealthTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    @discardableResult
    private func makeFile(
        _ relativePath: String, modified: Date
    ) throws -> URL {
        let url = workDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testLatestWritePicksNewestFileAcrossNesting() throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        try makeFile("a/one.jsonl", modified: base)
        try makeFile("a/b/c/two.jsonl", modified: base.addingTimeInterval(600))
        try makeFile("d/three.jsonl", modified: base.addingTimeInterval(120))

        let newest = try XCTUnwrap(SourceHealth.latestWrite(roots: [workDir]))

        XCTAssertEqual(newest.timeIntervalSince1970,
                       base.addingTimeInterval(600).timeIntervalSince1970,
                       accuracy: 1)
    }

    func testLatestWriteMissingRootReturnsNil() {
        let missing = workDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertNil(SourceHealth.latestWrite(roots: [missing]))
        XCTAssertNil(SourceHealth.latestWrite(roots: []))
    }

    func testLatestWriteZeroBudgetReturnsNil() throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        try makeFile("one.jsonl", modified: base)

        XCTAssertNil(SourceHealth.latestWrite(roots: [workDir], maxStats: 0))
    }

    func testLatestWriteIgnoresSymlinkedDirectories() throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        try makeFile("real/old.jsonl", modified: base)
        // 更新的文件放在 workDir 之外,只能经由符号链接到达;不该被跟随
        let peer = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-health-peer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: peer) }
        let linked = peer.appendingPathComponent("new.jsonl")
        try Data("{}".utf8).write(to: linked)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(3600)], ofItemAtPath: linked.path)
        try FileManager.default.createSymbolicLink(
            at: workDir.appendingPathComponent("link"), withDestinationURL: peer)

        let newest = try XCTUnwrap(SourceHealth.latestWrite(roots: [workDir]))

        XCTAssertEqual(newest.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 1)
    }

    func testRootsCoverEveryCodingSource() {
        for source in HistorySource.codingAgents {
            XCTAssertFalse(
                SourceHealth.roots(for: source).isEmpty,
                "\(source.rawValue) 缺少健康面板路径映射")
        }
        // DeepSeek 是平台账户,无本地数据路径
        XCTAssertTrue(SourceHealth.roots(for: .deepseek).isEmpty)
    }

    func testShortenedReplacesHomeWithTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(
            SourceHealth.shortened([home.appendingPathComponent(".claude/projects")]),
            "~/.claude/projects")
        // 非家目录路径原样保留
        XCTAssertEqual(
            SourceHealth.shortened([URL(fileURLWithPath: "/var/tmp/x.jsonl")]),
            "/var/tmp/x.jsonl")
        // 多根用顿号连接
        XCTAssertEqual(
            SourceHealth.shortened([
                home.appendingPathComponent("a"),
                home.appendingPathComponent("b"),
            ]),
            "~/a、~/b")
    }

    func testLastWriteTextRelativePhrases() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertNil(SourceHealth.lastWriteText(nil, now: now))
        XCTAssertEqual(
            SourceHealth.lastWriteText(now.addingTimeInterval(-300), now: now),
            "5分钟前")
        XCTAssertEqual(
            SourceHealth.lastWriteText(now.addingTimeInterval(-3 * 86_400), now: now),
            "3天前")
    }
}
