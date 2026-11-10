import XCTest

@testable import ClaudeHerder

final class SessionParserTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ lines: [String], trailingNewline: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let usage = #"{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}"#

    func testSummarizesTranscript() throws {
        let transcript = try write("abc.jsonl", [
            #"{"type":"user","isMeta":true,"timestamp":"2026-10-01T09:00:00.000Z","message":{"role":"user","content":"Caveat"}}"#,
            #"{"type":"user","cwd":"/work/proj","gitBranch":"tommo/x","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"Fix the bug"}}"#,
            // Two streamed blocks of one reply: counted once, usage once.
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:05.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"On it"}],"usage":\#(usage)}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:06.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"usage":\#(usage)}}"#,
            #"{"type":"user","timestamp":"2026-10-01T10:00:07.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            // Tool-only reply: not a message, but billed.
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:08.000Z","message":{"id":"m2","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}],"usage":\#(usage)}}"#,
            // Claude cd'd into a subfolder; resuming still needs the starting folder.
            #"{"type":"user","cwd":"/work/proj/sub","gitBranch":"main","timestamp":"2026-10-01T11:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Thanks"}]}}"#,
            #"{"type":"system","subtype":"away_summary","content":"Fixed the bug. (disable recaps in /config)","timestamp":"2026-10-01T11:30:00.000Z"}"#,
            #"{"type":"ai-title","aiTitle":"Bug fixing"}"#,
            #"{"type":"custom-title","customTitle":"my-bug"}"#,
            #"{"type":"file-history-snapshot","snapshot":{}}"#,
        ])
        let subagent = try write("agent.jsonl", [
            #"{"type":"assistant","timestamp":"2026-10-01T10:30:00.000Z","message":{"id":"s1","model":"claude-haiku-5-5","content":[],"usage":\#(usage)}}"#,
        ])

        let session = try XCTUnwrap(SessionParser.parse(transcript: transcript, subagents: [subagent]))

        XCTAssertEqual(session.id, "abc")
        XCTAssertEqual(session.gitBranch, "tommo/x", "the branch the starting folder was on")
        XCTAssertEqual(session.cwd, "/work/proj")
        XCTAssertEqual(session.title, "my-bug")
        XCTAssertEqual(session.recap, "Fixed the bug.")
        XCTAssertEqual(session.firstPrompt, "Fix the bug")
        XCTAssertEqual(session.messageCount, 3)
        XCTAssertEqual(session.firstAt, try Date("2026-10-01T10:00:00Z", strategy: .iso8601))
        XCTAssertEqual(session.lastAt, try Date("2026-10-01T11:00:00Z", strategy: .iso8601))
        // Two Opus replies at $4/MTok input + one Haiku subagent reply at $0.10.
        XCTAssertEqual(try XCTUnwrap(session.costUSD), 8.10, accuracy: 1e-9)
    }

    func testIgnoresLineStillBeingWritten() throws {
        let transcript = try write("live.jsonl", [
            #"{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"Hi"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:01.000Z","message":{"id":"m1","con"#,
        ], trailingNewline: false)

        let session = try XCTUnwrap(SessionParser.parse(transcript: transcript, subagents: []))

        XCTAssertEqual(session.messageCount, 1)
    }

    func testUnknownModelMakesCostUnknown() throws {
        let transcript = try write("x.jsonl", [
            #"{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"Hi"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:01.000Z","message":{"id":"m1","model":"claude-future-9","content":[],"usage":\#(usage)}}"#,
        ])

        XCTAssertNil(try SessionParser.parse(transcript: transcript, subagents: [])?.costUSD)
    }

    func testCorruptLineFails() throws {
        let transcript = try write("bad.jsonl", [#"{"type":"user", nope}"#])

        XCTAssertThrowsError(try SessionParser.parse(transcript: transcript, subagents: []))
    }

    func testEmptyTranscriptHasNoSession() throws {
        let transcript = try write("empty.jsonl", [#"{"type":"file-history-snapshot"}"#])

        XCTAssertNil(try SessionParser.parse(transcript: transcript, subagents: []))
    }

    /// Smoke test over the real ~/.claude/projects: every transcript must parse.
    func testIndexesRealTranscripts() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: SessionIndexer.projectsRoot.path))
        let start = Date()
        let result = SessionIndexer.index()
        print("indexed \(result.sessions.count) sessions in \(Date().timeIntervalSince(start))s")
        for s in result.sessions.sorted(by: { $0.lastAt > $1.lastAt }).prefix(5) {
            print(s.id, s.projectName, s.title, s.messageCount, s.costUSD ?? -1, s.recap ?? "-")
        }
        XCTAssertEqual(result.failures, [])
        // Duplicate IDs leave holes in the SwiftUI grid.
        XCTAssertEqual(Set(result.sessions.map(\.id)).count, result.sessions.count)
        XCTAssertFalse(result.sessions.isEmpty)
    }

    /// Every word must match somewhere in the session; this session's own ID is a known hit.
    func testSearchesRealTranscripts() async throws {
        let sessionID = try XCTUnwrap(ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"])
        let root = SessionIndexer.projectsRoot

        let hits = try await TranscriptSearch.sessionIDs(matching: "herder GHOSTTY", in: root)
        // A fresh UUID can't be in any transcript, even this session's.
        let misses = try await TranscriptSearch.sessionIDs(
            matching: "herder \(UUID().uuidString)", in: root)

        XCTAssertTrue(hits.contains(sessionID))
        XCTAssertEqual(misses, [])
    }
}
