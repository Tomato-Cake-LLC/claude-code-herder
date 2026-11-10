import XCTest

@testable import ClaudeHerder

final class HumanTimeTests: XCTestCase {
    private let calendar = Calendar.current
    // Midday, so "hours ago" never crosses midnight.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 15))!

    private func ago(_ seconds: TimeInterval) -> String {
        HumanTime.describe(now.addingTimeInterval(-seconds), now: now)
    }

    func testRecentTimes() {
        XCTAssertEqual(ago(30), "just now")
        XCTAssertEqual(ago(3 * 60), "a few min ago")
        XCTAssertEqual(ago(25 * 60), "25 min ago")
        XCTAssertEqual(ago(70 * 60), "an hour ago")
        XCTAssertEqual(ago(2.5 * 3600), "2 hours ago")
    }

    func testOlderTimes() {
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        let october25 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9))!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 3, day: 4, hour: 9))!
        let nine = morning.formatted(date: .omitted, time: .shortened)

        XCTAssertEqual(HumanTime.describe(morning, now: now), "today at \(nine)")
        XCTAssertEqual(HumanTime.describe(yesterday, now: now), "yesterday at \(nine)")
        XCTAssertEqual(HumanTime.describe(october25, now: now), "October 25")
        XCTAssertEqual(HumanTime.describe(lastYear, now: now), "March 4, 2025")
    }

    func testSpan() {
        let october25 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9))!

        XCTAssertEqual(
            HumanTime.span(from: october25, to: now.addingTimeInterval(-120), now: now),
            "October 25 to a few min ago")
        XCTAssertEqual(
            HumanTime.span(from: october25, to: october25.addingTimeInterval(600), now: now),
            "October 25")
    }

    func testSameDaySpanNamesTheDayOnce() {
        let at = { (day: Int, hour: Int, minute: Int) in
            self.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let clock = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }

        XCTAssertEqual(
            HumanTime.span(from: at(27, 9, 1), to: at(27, 9, 31), now: now),
            "today \(clock(at(27, 9, 1))) to \(clock(at(27, 9, 31)))")
        XCTAssertEqual(
            HumanTime.span(from: at(26, 12, 1), to: at(26, 12, 31), now: now),
            "yesterday \(clock(at(26, 12, 1))) to \(clock(at(26, 12, 31)))")
        // A recent end stays relative.
        XCTAssertEqual(
            HumanTime.span(from: at(27, 9, 1), to: at(27, 14, 58), now: now),
            "today at \(clock(at(27, 9, 1))) to a few min ago")
        // Different days keep both.
        XCTAssertEqual(
            HumanTime.span(from: at(26, 12, 1), to: at(27, 9, 1), now: now),
            "yesterday at \(clock(at(26, 12, 1))) to today at \(clock(at(27, 9, 1)))")
    }
}

final class FolderStateTests: XCTestCase {
    func testClassifiesFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cow = root.appendingPathComponent("cows/feature")
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(
            at: cow.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "/src".write(to: cow.appendingPathComponent(".git/cow-source"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: cow.appendingPathComponent("tools/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: plain.appendingPathComponent(".git"), withIntermediateDirectories: true)

        XCTAssertEqual(FolderState.of(cwd: cow.path), .liveCow)
        XCTAssertEqual(FolderState.of(cwd: cow.appendingPathComponent("tools/sub").path), .liveCow)
        XCTAssertEqual(FolderState.of(cwd: plain.path), .present)
        XCTAssertEqual(FolderState.of(cwd: root.appendingPathComponent("cows/deleted").path), .missing)
        XCTAssertEqual(FolderState.of(cwd: nil), .missing)
    }
}

final class DeduplicationTests: XCTestCase {
    private func session(_ id: String, cwd: String, lastAt: TimeInterval) -> Session {
        Session(
            id: id, cwd: cwd, gitBranch: nil, title: id, recap: nil, firstPrompt: nil,
            firstAt: Date(timeIntervalSince1970: 0), lastAt: Date(timeIntervalSince1970: lastAt),
            messageCount: 1, costUSD: nil)
    }

    func testKeepsLatestCopyOfEachSession() {
        let sessions = SessionIndexer.deduplicated([
            session("a", cwd: "/old", lastAt: 10),
            session("b", cwd: "/b", lastAt: 5),
            session("a", cwd: "/new", lastAt: 20),
        ])

        XCTAssertEqual(sessions.map(\.id).sorted(), ["a", "b"])
        XCTAssertEqual(sessions.first { $0.id == "a" }?.cwd, "/new")
    }
}
