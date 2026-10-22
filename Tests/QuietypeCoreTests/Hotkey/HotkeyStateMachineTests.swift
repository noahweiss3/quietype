import XCTest

@testable import QuietypeCore

final class HotkeyStateMachineTests: XCTestCase {
    func testHoldToTalk() {
        var m = HotkeyStateMachine()
        XCTAssertEqual(m.keyDown(at: 0), [.startRecording])
        XCTAssertEqual(m.keyDown(at: 0.1), []) // key repeat
        XCTAssertEqual(m.keyUp(at: 1.5), [.finishRecording])
        XCTAssertEqual(m.state, .idle)
    }

    func testSingleTapIsDiscarded() {
        var m = HotkeyStateMachine()
        XCTAssertEqual(m.keyDown(at: 0), [.startRecording])
        XCTAssertEqual(m.keyUp(at: 0.1), [])
        XCTAssertEqual(m.deadline!, 0.45, accuracy: 1e-9)
        XCTAssertEqual(m.timeout(at: 0.3), [])
        XCTAssertEqual(m.timeout(at: 0.5), [.cancelRecording])
        XCTAssertFalse(m.isRecording)
    }

    func testDoubleTapStartsHandsFreeUntilNextTap() {
        var m = HotkeyStateMachine()
        _ = m.keyDown(at: 0)
        _ = m.keyUp(at: 0.1)
        XCTAssertEqual(m.keyDown(at: 0.3), [.enterHandsFree])
        XCTAssertEqual(m.keyUp(at: 0.35), [])
        XCTAssertEqual(m.state, .handsFree)
        XCTAssertEqual(m.timeout(at: 30), [])
        XCTAssertEqual(m.keyDown(at: 30), [.finishRecording])
        XCTAssertFalse(m.isRecording)
        XCTAssertEqual(m.keyUp(at: 30.1), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testSlowSecondTapStartsFresh() {
        var m = HotkeyStateMachine()
        _ = m.keyDown(at: 0)
        _ = m.keyUp(at: 0.1)
        XCTAssertEqual(m.keyDown(at: 1.0), [.cancelRecording, .startRecording])
    }

    func testEscapeCancels() {
        var m = HotkeyStateMachine()
        XCTAssertEqual(m.cancel(), [])
        _ = m.keyDown(at: 0)
        XCTAssertEqual(m.cancel(), [.cancelRecording])
        XCTAssertEqual(m.keyUp(at: 2), [])
    }
}
