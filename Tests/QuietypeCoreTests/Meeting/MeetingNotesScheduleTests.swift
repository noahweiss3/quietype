import XCTest

@testable import QuietypeCore

final class MeetingNotesScheduleTests: XCTestCase {
    private let schedule = MeetingNotesSchedule(minNewWords: 60, minInterval: 45, burstWords: 350)

    func testRetryWaitDoublesWithEachFailureUpToSixteenTimes() {
        XCTAssertEqual(schedule.retryInterval(afterFailures: 1), 90)
        XCTAssertEqual(schedule.retryInterval(afterFailures: 2), 180)
        XCTAssertEqual(schedule.retryInterval(afterFailures: 3), 360)
        XCTAssertEqual(schedule.retryInterval(afterFailures: 4), 720)
        XCTAssertEqual(schedule.retryInterval(afterFailures: 9), 720)
    }

    func testAfterAFailureAnyNewWordsAreDueOnceTheRetryWaitHasPassed() {
        XCTAssertFalse(schedule.isDue(pendingWords: 5, secondsSinceLastUpdate: 89, failures: 1))
        XCTAssertTrue(schedule.isDue(pendingWords: 5, secondsSinceLastUpdate: 90, failures: 1))
        XCTAssertFalse(schedule.isDue(pendingWords: 5, secondsSinceLastUpdate: 179, failures: 2))
        XCTAssertTrue(schedule.isDue(pendingWords: 5, secondsSinceLastUpdate: 180, failures: 2))
    }

    func testAfterAFailureABurstDoesNotCutTheWaitShort() {
        XCTAssertTrue(schedule.isDue(pendingWords: 400, secondsSinceLastUpdate: 5))
        XCTAssertFalse(schedule.isDue(pendingWords: 400, secondsSinceLastUpdate: 5, failures: 1))
    }

    func testAfterAFailureNothingNewIsNeverDue() {
        XCTAssertFalse(schedule.isDue(pendingWords: 0, secondsSinceLastUpdate: 10_000, failures: 3))
    }

    func testNoFailuresMeansTheRegularSchedule() {
        XCTAssertEqual(
            schedule.isDue(pendingWords: 100, secondsSinceLastUpdate: 50, failures: 0),
            schedule.isDue(pendingWords: 100, secondsSinceLastUpdate: 50)
        )
        XCTAssertFalse(schedule.isDue(pendingWords: 5, secondsSinceLastUpdate: 1_000, failures: 0))
    }

    func testUpdateIsDueAfterEnoughWordsAndTimeOrAFloodOfWords() {
        let defaultSchedule = MeetingNotesSchedule()
        XCTAssertFalse(defaultSchedule.isDue(pendingWords: 40, secondsSinceLastUpdate: 300))
        XCTAssertFalse(defaultSchedule.isDue(pendingWords: 100, secondsSinceLastUpdate: 20))
        XCTAssertTrue(defaultSchedule.isDue(pendingWords: 100, secondsSinceLastUpdate: 50))
        XCTAssertTrue(defaultSchedule.isDue(pendingWords: 400, secondsSinceLastUpdate: 5))
    }
}
