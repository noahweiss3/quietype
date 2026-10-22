import Foundation

/// When to refresh the notes: after enough new talk, but not more often than the model can keep
/// up with. A burst of talk gets an update sooner.
public struct MeetingNotesSchedule: Sendable {
    /// How often the app asks `isDue` during a meeting.
    public static let tickInterval: TimeInterval = 5

    public var minNewWords: Int
    public var minInterval: TimeInterval
    public var burstWords: Int

    public init(minNewWords: Int = 60, minInterval: TimeInterval = 45, burstWords: Int = 350) {
        self.minNewWords = minNewWords
        self.minInterval = minInterval
        self.burstWords = burstWords
    }

    /// `failures` counts the updates in a row that failed. After a failure the schedule waits
    /// longer each time and ignores bursts, so a request that keeps failing doesn't keep the GPU
    /// busy for the rest of the meeting.
    public func isDue(pendingWords: Int, secondsSinceLastUpdate: TimeInterval, failures: Int = 0) -> Bool {
        if failures > 0 {
            return pendingWords > 0 && secondsSinceLastUpdate >= retryInterval(afterFailures: failures)
        }
        return pendingWords >= burstWords || (pendingWords >= minNewWords && secondsSinceLastUpdate >= minInterval)
    }

    /// `minInterval`, doubled for each failure up to 16 times as long.
    public func retryInterval(afterFailures failures: Int) -> TimeInterval {
        minInterval * Double(1 << min(max(failures, 0), 4))
    }
}
