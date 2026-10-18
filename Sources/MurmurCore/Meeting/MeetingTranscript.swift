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

        switch segment.speaker {
        case .me:
            if segments.contains(where: { $0.speaker == .others && Self.isEcho(mic: segment, of: $0) }) { return false }
        case .others:
            segments.removeAll { $0.speaker == .me && Self.isEcho(mic: $0, of: segment) }
        }

        let index = segments.firstIndex { $0.start > segment.start } ?? segments.endIndex
        segments.insert(segment, at: index)
        return true
    }

    /// Without headphones the microphone also hears the other people, so the same words arrive
    /// twice. A mic segment that overlaps a call segment in time and mostly repeats its words is
    /// that echo.
    static func isEcho(mic: MeetingSegment, of call: MeetingSegment) -> Bool {
        let slack: TimeInterval = 1.5
        guard mic.start < call.end + slack, call.start < mic.end + slack else { return false }
        let micWords = words(mic.text)
        guard !micWords.isEmpty else { return false }
        let callWords = Set(words(call.text))
        let repeated = micWords.filter(callWords.contains).count
        return Double(repeated) >= 0.6 * Double(micWords.count)
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
