import XCTest

@testable import ClaudeHerder

final class NewSessionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFolder(_ path: String, cowSource: URL? = nil) throws -> URL {
        let folder = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        if let cowSource {
            let marker = folder.appendingPathComponent(".git/cow-source")
            try (cowSource.path + "\n").write(to: marker, atomically: true, encoding: .utf8)
        }
        return folder
    }

    func testListsOnlyCowsOfThisRepo() throws {
        let repo = try makeFolder("repo")
        let other = try makeFolder("other")
        let b = try makeFolder("cows/tommo-b", cowSource: repo)
        let a = try makeFolder("cows/tommo-a", cowSource: repo)
        _ = try makeFolder("cows/tommo-other", cowSource: other)
        _ = try makeFolder("cows/plain-clone")

        let cows = try NewSession.cows(of: repo)

        XCTAssertEqual(cows.map(\.lastPathComponent), [a, b].map(\.lastPathComponent))
    }

    func testNoCowsFolderMeansNoCows() throws {
        XCTAssertEqual(try NewSession.cows(of: try makeFolder("repo")), [])
    }

    func testNameRules() {
        let existing = [URL(fileURLWithPath: "/x/cows/tommo-store")]
        XCTAssertNil(NewSession.problem(withName: "", existing: existing))
        XCTAssertNil(NewSession.problem(withName: "new-thing_2.0", existing: existing))
        XCTAssertNotNil(NewSession.problem(withName: "store", existing: existing))
        for bad in ["a b", "a/b", "Caps", "-flag", "a..b", "x'y", "é"] {
            XCTAssertNotNil(NewSession.problem(withName: bad, existing: existing), bad)
        }
        XCTAssertEqual(NewSession.folderName(for: "store"), "tommo-store")
    }

    func testNewCowRunsCowFromTheRepo() {
        let (directory, input) = NewSession.command(
            for: .newCow, name: "thing", promptFile: URL(fileURLWithPath: "/tmp/p.txt"))
        XCTAssertEqual(directory, NewSession.repo)
        XCTAssertTrue(input.hasPrefix("cow 'tommo/thing' && "), input)
    }

    /// Runs the typed line in a real zsh with `claude` stubbed out, as Ghostty would.
    func testPromptReachesClaudeIntact() throws {
        let prompt = "Fix the \"quote\" bug, it's $HOME and `ls`\nsecond line"
        let promptFile = dir.appendingPathComponent("prompt.txt")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)
        let cow = try makeFolder("cows/tommo-x", cowSource: dir)
        let received = dir.appendingPathComponent("received.txt")

        let (directory, input) = NewSession.command(
            for: .cow(cow), name: "", promptFile: promptFile)
        let stub = "claude() { print -rn -- \"$1\" > \(NewSession.shellQuoted(received.path)) }"
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-f", "-c", "\(stub); \(input)"]
        zsh.currentDirectoryURL = directory
        try zsh.run()
        zsh.waitUntilExit()

        XCTAssertEqual(zsh.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), prompt)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: promptFile.path), "prompt file left behind")
    }

    private func session(cwd: String?, branch: String?) -> Session {
        Session(
            id: "abc-123", cwd: cwd, gitBranch: branch, title: "t", recap: nil, firstPrompt: nil,
            firstAt: .now, lastAt: .now, messageCount: 1, costUSD: nil)
    }

    func testRecreatesOnlyCowsOfTheRepo() {
        let repo = dir.appendingPathComponent("repo")
        let cows = dir.appendingPathComponent("cows").path
        func check(_ cwd: String?, _ branch: String?) -> String? {
            NewSession.recreation(of: session(cwd: cwd, branch: branch), repo: repo)?.branch
        }
        XCTAssertEqual(check("\(cows)/tommo-store", "tommo/store"), "tommo/store")
        XCTAssertEqual(check("\(cows)/tommo-store/ugc_editor", "tommo/store"), "tommo/store")
        XCTAssertNil(check("\(cows)/tommo-store", "tommo/other"), "branch doesn't name the folder")
        XCTAssertNil(check("\(cows)/tommo-store", nil), "no branch recorded")
        XCTAssertNil(check("\(cows)/HEAD", "HEAD"), "detached")
        XCTAssertNil(check("\(cows)", "cows"), "the cows folder itself")
        XCTAssertNil(check(repo.path, "repo"), "the repo, not a cow")
        XCTAssertNil(check("/elsewhere/cows/tommo-store", "tommo/store"), "another repo's cows")
        XCTAssertNil(check(nil, "tommo/store"))
    }

    /// Runs the typed line in a real zsh with `cow` and `claude` stubbed out.
    func testRecreateResumesInTheOriginalSubfolder() throws {
        let repo = try makeFolder("repo")
        let cwd = dir.appendingPathComponent("cows/tommo-it's/ugc_editor")
        let log = dir.appendingPathComponent("log.txt")
        let recreation = try XCTUnwrap(
            NewSession.recreation(of: session(cwd: cwd.path, branch: "tommo/it's"), repo: repo))

        let q = NewSession.shellQuoted(log.path)
        let cowFolder = NewSession.shellQuoted(cwd.deletingLastPathComponent().path)
        let stubs = [
            "cow() { print -r -- \"cow $1\" >> \(q); mkdir -p \(cowFolder)/ugc_editor }",
            "claude() { print -r -- \"claude $* in $PWD\" >> \(q) }",
        ]
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-f", "-c", (stubs + [recreation.input]).joined(separator: "; ")]
        zsh.currentDirectoryURL = recreation.directory
        try zsh.run()
        zsh.waitUntilExit()

        XCTAssertEqual(zsh.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: log, encoding: .utf8),
            "cow tommo/it's\nclaude --resume abc-123 in \(cwd.path)\n")
    }
}
