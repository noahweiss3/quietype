import Foundation

/// Turns raw key down/up events for the dictation key into recording commands.
///
/// - Hold the key: records while held, transcribes on release.
/// - Double-tap: hands-free mode, which records until the key is tapped again.
/// - A single quick tap does nothing (the recording that started on key down is discarded).
/// - Escape cancels.
///
/// Recording starts on the first key down in every case, so nothing is clipped while we
/// wait to find out whether the press is a hold or the first half of a double-tap.
public struct HotkeyStateMachine: Sendable {
    public enum Action: Equatable, Sendable {
        case startRecording
        case enterHandsFree
        case finishRecording
        case cancelRecording
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Key is down after a fresh press; could become a hold or a tap.
        case pressed(at: TimeInterval)
        /// A quick tap was released; waiting to see whether a second tap follows.
        case awaitingSecondTap(releasedAt: TimeInterval)
        /// Second tap is down; hands-free starts and its release is ignored.
        case secondTapDown
        case handsFree
        /// The tap that ends hands-free is down; its release is ignored.
        case stoppingTapDown
    }

    /// A press shorter than this is a tap; longer is hold-to-talk.
    public var holdThreshold: TimeInterval
    /// Max gap between the first tap's release and the second tap's press.
    public var doubleTapWindow: TimeInterval

    public private(set) var state: State = .idle

    public init(holdThreshold: TimeInterval = 0.3, doubleTapWindow: TimeInterval = 0.35) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    public var isRecording: Bool { state != .idle && state != .stoppingTapDown }

    /// When `timeout(at:)` should next be called, if a timer is needed.
    public var deadline: TimeInterval? {
        if case let .awaitingSecondTap(releasedAt) = state { return releasedAt + doubleTapWindow }
        return nil
    }

    public mutating func keyDown(at time: TimeInterval) -> [Action] {
        switch state {
        case .idle:
            state = .pressed(at: time)
            return [.startRecording]
        case let .awaitingSecondTap(releasedAt):
            if time - releasedAt <= doubleTapWindow {
                state = .secondTapDown
                return [.enterHandsFree]
            }
            // Too slow to be a double-tap: drop the stray tap and treat this as a fresh press.
            state = .pressed(at: time)
            return [.cancelRecording, .startRecording]
        case .handsFree:
            state = .stoppingTapDown
            return [.finishRecording]
        case .pressed, .secondTapDown, .stoppingTapDown:
            return [] // key repeat
        }
    }

    public mutating func keyUp(at time: TimeInterval) -> [Action] {
        switch state {
        case let .pressed(pressedAt):
            if time - pressedAt >= holdThreshold {
                state = .idle
                return [.finishRecording]
            }
            state = .awaitingSecondTap(releasedAt: time)
            return []
        case .secondTapDown:
            state = .handsFree
            return []
        case .stoppingTapDown:
            state = .idle
            return []
        case .idle, .awaitingSecondTap, .handsFree:
            return []
        }
    }

    /// Call when `deadline` passes: a lone quick tap is discarded.
    public mutating func timeout(at time: TimeInterval) -> [Action] {
        guard let deadline, time >= deadline else { return [] }
        state = .idle
        return [.cancelRecording]
    }

    public mutating func cancel() -> [Action] {
        guard state != .idle else { return [] }
        state = .idle
        return [.cancelRecording]
    }
}
