import Foundation

/// Turns 16 kHz mono audio into text.
public protocol SpeechTranscriber: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Transcribes a recording in pieces while it is still being made.
///
/// Audio is fed in as it arrives. Whenever the speaker pauses after a long enough stretch, that
/// stretch is transcribed in the background. `finish()` only has to transcribe what came after the
/// last pause, plus any earlier stretch still queued if transcription has fallen behind, so while
/// transcription keeps up, release-to-text time doesn't grow with the length of the recording.
///
/// Audio already handed to the transcriber is dropped from the buffer; a stretch waiting in the
/// queue keeps its audio until it has been transcribed.
public actor LiveTranscription {
    public struct Result: Sendable {
        public var text: String
        public var audioSeconds: Double
        /// Time from `finish()` to the full transcript.
        public var finishSeconds: Double
        public var segments: Int
    }

    private let transcriber: SpeechTranscriber
    private var segmenter: SpeechSegmenter
    /// Samples from `bufferStart` on; everything before has been handed to the transcriber.
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var texts: [Int: String] = [:]
    private var tail: Task<Void, Error>?
    /// Segments not yet finished, so `cancel()` can reach them.
    private var pending: [Int: Task<Void, Error>] = [:]
    private var segmentCount = 0
    private var failure: Error?
    private var cancelled = false

    public init(transcriber: SpeechTranscriber, segmenter: SpeechSegmenter = SpeechSegmenter()) {
        self.transcriber = transcriber
        self.segmenter = segmenter
    }

    private var received: Int { bufferStart + buffer.count }

    /// Audio held in memory, for tests: the stretch still being spoken.
    var bufferedSamples: Int { buffer.count }

    public func append(_ chunk: [Float]) {
        guard !cancelled else { return }
        buffer += chunk
        for range in segmenter.append(chunk) { enqueue(range) }
    }

    /// Throws `CancellationError` after `cancel()`.
    public func finish() async throws -> Result {
        let started = Date()
        if !cancelled, segmenter.openSegmentStart < received {
            enqueue(segmenter.openSegmentStart..<received)
        }
        try await tail?.value
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
        let text = (0..<segmentCount).compactMap { texts[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
        return Result(
            text: text,
            audioSeconds: Double(received) / Double(segmenter.sampleRate),
            finishSeconds: Date().timeIntervalSince(started),
            segments: segmentCount
        )
    }

    /// Abandons the recording: queued segments never start, the one being transcribed is
    /// cancelled (if the transcriber checks for cancellation), and buffered audio is released.
    /// Later `append` calls are ignored.
    public func cancel() {
        cancelled = true
        for task in pending.values { task.cancel() }
        pending = [:]
        buffer = []
    }

    /// Segments run one at a time, in order, so the model is never asked for two at once.
    private func enqueue(_ range: Range<Int>) {
        let index = segmentCount
        segmentCount += 1
        let audio = take(range)
        let previous = tail
        let task = Task {
            try await previous?.value
            defer { self.pending[index] = nil }
            guard !self.cancelled, SpeechSegmenter.containsSpeech(audio) else { return }
            do {
                let text = try await self.transcriber.transcribe(audio)
                self.store(text, at: index)
            } catch {
                if !self.cancelled { self.fail(error) }
            }
        }
        pending[index] = task
        tail = task
    }

    /// Copies `range` (absolute sample positions) out of the buffer and drops everything before
    /// its end.
    private func take(_ range: Range<Int>) -> [Float] {
        let lower = max(0, range.lowerBound - bufferStart)
        let upper = min(buffer.count, range.upperBound - bufferStart)
        guard lower < upper else { return [] }
        let audio = Array(buffer[lower..<upper])
        buffer.removeFirst(upper)
        bufferStart += upper
        return audio
    }

    private func store(_ text: String, at index: Int) { texts[index] = text }
    private func fail(_ error: Error) { failure = failure ?? error }
}
