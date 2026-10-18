import Foundation

/// Transcribes a meeting while it happens, from two 16 kHz streams: the microphone (you) and the
/// computer's audio output (everyone else).
///
/// Each stream is cut at pauses, or at its quietest moment when someone talks for a long time
/// without one, and finished stretches are transcribed one at a time in the background. Only the
/// audio of the stretch still being spoken is kept in memory, so a long meeting doesn't grow it.
public actor MeetingSession {
    private struct Channel {
        var segmenter: SpeechSegmenter
        /// Samples from `bufferStart` on; everything before has been handed to the transcriber.
        var buffer: [Float] = []
        var bufferStart = 0
        var received: Int { bufferStart + buffer.count }
    }

    private let transcriber: SpeechTranscriber
    private let sampleRate: Int
    private var channels: [MeetingSpeaker: Channel]
    private var transcript = MeetingTranscript()
    private var tail: Task<Void, Never>?
    private var nextID = 0
    private var onUpdate: (@Sendable (MeetingTranscript) -> Void)?
    public private(set) var lastError: String?

    public init(
        transcriber: SpeechTranscriber,
        segmenter: SpeechSegmenter = SpeechSegmenter(minPause: 0.6, minSegment: 3, maxSegment: 20)
    ) {
        self.transcriber = transcriber
        sampleRate = segmenter.sampleRate
        channels = Dictionary(uniqueKeysWithValues: MeetingSpeaker.allCases.map { ($0, Channel(segmenter: segmenter)) })
    }

    /// Called with the whole transcript each time a segment lands.
    public func setOnUpdate(_ handler: @escaping @Sendable (MeetingTranscript) -> Void) {
        onUpdate = handler
    }

    public var current: MeetingTranscript { transcript }

    public func append(_ samples: [Float], from speaker: MeetingSpeaker) {
        guard var channel = channels[speaker] else { return }
        channel.buffer += samples
        let closed = channel.segmenter.append(samples)
        for range in closed {
            enqueue(take(range, from: &channel), speaker: speaker, range: range)
        }
        channels[speaker] = channel
    }

    /// Transcribes what is left in both streams and returns the final transcript.
    public func finish() async -> MeetingTranscript {
        for speaker in MeetingSpeaker.allCases {
            guard var channel = channels[speaker] else { continue }
            let range = channel.segmenter.openSegmentStart..<channel.received
            if !range.isEmpty { enqueue(take(range, from: &channel), speaker: speaker, range: range) }
            channels[speaker] = channel
        }
        await tail?.value
        return transcript
    }

    /// Cuts `range` (absolute sample positions) out of the channel's buffer and drops everything
    /// before its end.
    private func take(_ range: Range<Int>, from channel: inout Channel) -> [Float] {
        let lower = max(0, range.lowerBound - channel.bufferStart)
        let upper = min(channel.buffer.count, range.upperBound - channel.bufferStart)
        guard lower < upper else { return [] }
        let audio = Array(channel.buffer[lower..<upper])
        channel.buffer.removeFirst(upper)
        channel.bufferStart += upper
        return audio
    }

    /// Segments are transcribed one at a time so the speech model is never asked for two at once.
    private func enqueue(_ audio: [Float], speaker: MeetingSpeaker, range: Range<Int>) {
        guard let speech = SpeechSegmenter.firstSpeech(in: audio, sampleRate: sampleRate) else { return }
        // A stretch can open with up to `maxSegment` of silence; skip it (keeping a little lead-in)
        // so the timestamp says when talking started and the model has less to chew through.
        let lead = max(0, speech - sampleRate / 5)
        let speechAudio = Array(audio[lead...])
        let id = nextID
        nextID += 1
        let start = Double(range.lowerBound + lead) / Double(sampleRate)
        let end = Double(range.upperBound) / Double(sampleRate)
        let previous = tail
        tail = Task {
            await previous?.value
            do {
                let text = try await self.transcriber.transcribe(speechAudio)
                self.store(MeetingSegment(id: id, speaker: speaker, start: start, end: end, text: text))
            } catch {
                // One bad stretch shouldn't end the meeting; note it and keep going.
                self.lastError = "\(error)"
            }
        }
    }

    private func store(_ segment: MeetingSegment) {
        guard transcript.add(segment) else { return }
        onUpdate?(transcript)
    }
}
