import Foundation

/// Transcribes a meeting while it happens, from two 16 kHz streams: the microphone (you) and the
/// computer's audio output (everyone else).
///
/// Each stream is cut at pauses, or at its quietest moment when someone talks for a long time
/// without one, and finished stretches are transcribed one at a time in the background. Each
/// stream's buffer only holds the stretch still being spoken, but finished stretches waiting for
/// transcription keep their audio until they are transcribed, so if transcription falls behind,
/// that backlog grows in memory.
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
    /// Quietest level that counts as talking when trimming a stretch: the segmenter's floor, not
    /// a fixed loudness, so a quiet call isn't trimmed away.
    private let speechLevel: Float
    // Two stored properties rather than a dictionary, so appending mutates the buffer in place
    // instead of copying it on every chunk.
    private var mic: Channel
    private var call: Channel
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
        speechLevel = segmenter.silenceFloor
        mic = Channel(segmenter: segmenter)
        call = Channel(segmenter: segmenter)
    }

    /// Called with the whole transcript each time a segment lands.
    public func setOnUpdate(_ handler: @escaping @Sendable (MeetingTranscript) -> Void) {
        onUpdate = handler
    }

    public var current: MeetingTranscript { transcript }

    /// The latest transcription error, once: reading it clears it.
    public func takeError() -> String? {
        defer { lastError = nil }
        return lastError
    }

    public func append(_ samples: [Float], from speaker: MeetingSpeaker) {
        let closed = withChannel(speaker) { (channel: inout Channel) -> [(range: Range<Int>, audio: [Float])] in
            channel.buffer += samples
            return channel.segmenter.append(samples).map { range in (range, Self.take(range, from: &channel)) }
        }
        for segment in closed { enqueue(segment.audio, speaker: speaker, range: segment.range) }
    }

    /// Pads a stream with silence, to line its clock up with the other when it started later.
    public func appendSilence(seconds: TimeInterval, to speaker: MeetingSpeaker) {
        guard seconds > 0 else { return }
        append([Float](repeating: 0, count: Int(seconds * Double(sampleRate))), from: speaker)
    }

    /// Transcribes what is left in both streams and returns the final transcript.
    public func finish() async -> MeetingTranscript {
        for speaker in MeetingSpeaker.allCases {
            let rest = withChannel(speaker) { (channel: inout Channel) -> (range: Range<Int>, audio: [Float])? in
                let range = channel.segmenter.openSegmentStart..<channel.received
                return range.isEmpty ? nil : (range, Self.take(range, from: &channel))
            }
            if let rest { enqueue(rest.audio, speaker: speaker, range: rest.range) }
        }
        await tail?.value
        return transcript
    }

    /// Audio held in the stream buffers, for tests: only the stretches still being spoken.
    var bufferedSamples: Int { mic.buffer.count + call.buffer.count }

    private func withChannel<R>(_ speaker: MeetingSpeaker, _ body: (inout Channel) -> R) -> R {
        switch speaker {
        case .me: return body(&mic)
        case .others: return body(&call)
        }
    }

    /// Cuts `range` (absolute sample positions) out of the channel's buffer and drops everything
    /// before its end.
    private static func take(_ range: Range<Int>, from channel: inout Channel) -> [Float] {
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
        guard let speech = SpeechSegmenter.firstSpeech(in: audio, sampleRate: sampleRate, threshold: speechLevel),
            let speechEnd = SpeechSegmenter.lastSpeech(in: audio, sampleRate: sampleRate, threshold: speechLevel)
        else { return }
        // A stretch can open or close with long silence; trim it (keeping a little margin) so the
        // timestamps say when talking happened and the model has less to chew through.
        let lead = max(0, speech - sampleRate / 5)
        let stop = min(audio.count, speechEnd + sampleRate / 5)
        let speechAudio = Array(audio[lead..<stop])
        let id = nextID
        nextID += 1
        let start = Double(range.lowerBound + lead) / Double(sampleRate)
        let end = Double(range.lowerBound + stop) / Double(sampleRate)
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
