import XCTest

@testable import ClaudeHerder

final class DoneMarksTests: XCTestCase {
    private func session(lastAt: TimeInterval) -> Session {
        Session(
            id: "s", cwd: "/x", gitBranch: nil, title: "s", recap: nil, firstPrompt: nil,
            firstAt: Date(timeIntervalSince1970: 0), lastAt: Date(timeIntervalSince1970: lastAt),
            messageCount: 1, costUSD: nil)
    }

    func testToggleMarksAndUnmarks() {
        var marks = DoneMarks(markedAt: [:])
        let s = session(lastAt: 100)

        marks.toggle(s, now: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(marks.isDone(s))
        marks.toggle(s, now: Date(timeIntervalSince1970: 300))
        XCTAssertFalse(marks.isDone(s))
    }

    func testNewActivityUndoesTheMark() {
        var marks = DoneMarks(markedAt: [:])
        marks.toggle(session(lastAt: 100), now: Date(timeIntervalSince1970: 200))

        XCTAssertFalse(marks.isDone(session(lastAt: 250)))
    }

    func testRoundTripsThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "herder-tests-\(UUID().uuidString)"))
        var marks = DoneMarks(markedAt: [:])
        marks.toggle(session(lastAt: 100), now: Date(timeIntervalSince1970: 200))

        marks.save(to: defaults)

        XCTAssertTrue(DoneMarks.load(from: defaults).isDone(session(lastAt: 100)))
    }
}
