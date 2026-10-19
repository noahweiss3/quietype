import Foundation

/// Who said a stretch of a meeting. The microphone is you; the computer's audio output (the call)
/// is everyone else.
public enum MeetingSpeaker: String, Codable, Sendable, CaseIterable {
    case me
    case others

    public var label: String {
        switch self {
        case .me: return "You"
        case .others: return "Others"
        }
    }
}

public struct MeetingSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var speaker: MeetingSpeaker
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(id: Int, speaker: MeetingSpeaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    /// "[03:12] You: Let's ship on Thursday."
    public var line: String { "[\(MeetingTranscript.timestamp(start))] \(speaker.label): \(text)" }
}

/// The running transcript of a meeting, ordered by start time.
public struct MeetingTranscript: Codable, Equatable, Sendable {
    public private(set) var segments: [MeetingSegment] = []

    public init(segments: [MeetingSegment] = []) {
        for segment in segments { add(segment) }
    }

    public var wordCount: Int { segments.reduce(0) { $0 + Self.wordCount($1.text) } }

    public static func wordCount(_ text: String) -> Int { words(text).count }

    /// Adds a segment in start-time order. Returns false when it was dropped: empty, or the
    /// microphone picking up the call's audio from the speakers.
    @discardableResult
    public mutating func add(_ segment: MeetingSegment) -> Bool {
        var segment = segment
        segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.words(segment.text).isEmpty else { return false }

        let calls = segments.filter { $0.speaker == .others }
        switch segment.speaker {
        case .me:
            if Self.isEcho(mic: segment, among: calls) { return false }
        case .others:
            segments.removeAll { $0.speaker == .me && Self.isEcho(mic: $0, among: calls + [segment]) }
        }

        let index = segments.firstIndex { $0.start > segment.start } ?? segments.endIndex
        segments.insert(segment, at: index)
        return true
    }

    /// Without headphones the microphone also hears the other people, so their words arrive
    /// twice. A mic segment is that echo when it happens at the same time as call audio (most of
    /// it overlaps call segments, which may be cut differently) and repeats their words in the
    /// same order. A reply that reuses a few of their words ("Thursday at three works") comes
    /// after them, not on top of them, and is kept.
    static func isEcho(mic: MeetingSegment, among calls: [MeetingSegment]) -> Bool {
        let slack: TimeInterval = 0.75
        let overlapping = calls
            .filter { $0.start - slack < mic.end && mic.start < $0.end + slack }
            .sorted { $0.start < $1.start }
        let micWords = words(mic.text)
        guard !overlapping.isEmpty, micWords.count >= 3 else { return false }

        let overlap = overlapping.reduce(0.0) { total, call in
            total + max(0, min(mic.end, call.end + slack) - max(mic.start, call.start - slack))
        }
        guard overlap >= 0.5 * max(mic.end - mic.start, 0.1) else { return false }

        let repeated = commonSubsequenceLength(micWords, overlapping.flatMap { words($0.text) })
        return Double(repeated) >= 0.6 * Double(micWords.count)
    }

    /// Length of the longest sequence of words that appears, in order, in both.
    static func commonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for word in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, other) in b.enumerated() {
                current[j + 1] = word == other ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    /// "04:05", or "1:02:03" past an hour.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Notes followed by the full transcript, for saving or sharing.
    public func markdown(title: String, notes: String) -> String {
        var lines = ["# \(title)", ""]
        if !notes.isEmpty { lines += [notes, ""] }
        lines += ["## Transcript", ""]
        lines += segments.map { "**[\(Self.timestamp($0.start))] \($0.speaker.label):** \($0.text)\n" }
        return lines.joined(separator: "\n")
    }
}
