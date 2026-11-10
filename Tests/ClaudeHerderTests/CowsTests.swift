import XCTest

@testable import ClaudeHerder

final class CowsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func git(_ repo: URL, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
    }

    /// A cow with one commit (never pushed) and one uncommitted file.
    private func makeCow(_ name: String) throws -> URL {
        let cow = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: cow, withIntermediateDirectories: true)
        try git(cow, "init", "-q", "-b", "feature")
        try "a".write(to: cow.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(cow, "add", "a.txt")
        try git(cow, "commit", "-q", "-m", "a")
        try "/src".write(to: cow.appendingPathComponent(".git/cow-source"), atomically: true, encoding: .utf8)
        try "b".write(to: cow.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        return cow
    }

    private func session(_ id: String, cwd: String) -> Session {
        Session(
            id: id, cwd: cwd, gitBranch: nil, title: id, recap: nil, firstPrompt: nil,
            firstAt: .now, lastAt: .now, messageCount: 1, costUSD: nil)
    }

    func testStatusCountsUnsavedWork() async throws {
        let cow = try makeCow("feature")

        let status = try await Cows.status(of: cow)

        XCTAssertEqual(status.branch, "feature")
        XCTAssertEqual(status.uncommittedFiles, 1)
        XCTAssertEqual(status.unpushedCommits, 1)
    }

    func testFindsSessionsInTheSameCow() throws {
        let cow = try makeCow("feature")
        let sub = cow.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let sessions = [
            session("root", cwd: cow.path), session("sub", cwd: sub.path),
            session("elsewhere", cwd: dir.path),
        ]

        let found = Cows.sessions(in: try XCTUnwrap(Cows.root(containing: sub.path)), among: sessions)

        XCTAssertEqual(found.map(\.id).sorted(), ["root", "sub"])
    }

    func testDeleteRefusesUnmarkedFolders() async throws {
        let plain = dir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        do {
            try await Cows.delete(plain)
            XCTFail("deleted a folder without .git/cow-source")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))
    }

    func testDeleteRemovesCow() async throws {
        let cow = try makeCow("feature")

        try await Cows.delete(cow)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cow.path))
    }
}
