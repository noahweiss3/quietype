import Foundation

/// Turns 16 kHz mono audio into text.
public protocol SpeechTranscriber: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Transcribes a recording in pieces while it is still being made.
///
/// Audio is fed in as it arrives. Whenever the speaker pauses after a long enough stretch, that
/// stretch is transcribed in the background. `finish()` only has to transcribe what came after the
/// last pause, so release-to-text time stays flat no matter how long you talk.
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
    private var samples: [Float] = []
    private var texts: [Int: String] = [:]
    private var tail: Task<Void, Error>?
    private var segmentCount = 0
    private var failure: Error?

    public init(transcriber: SpeechTranscriber, segmenter: SpeechSegmenter = SpeechSegmenter()) {
        self.transcriber = transcriber
        self.segmenter = segmenter
    }

    public func append(_ chunk: [Float]) {
        samples += chunk
        for range in segmenter.append(chunk) { enqueue(range) }
    }

    public func finish() async throws -> Result {
        let started = Date()
        if segmenter.openSegmentStart < samples.count {
            enqueue(segmenter.openSegmentStart..<samples.count)
        }
        try await tail?.value
        if let failure { throw failure }
        let text = (0..<segmentCount).compactMap { texts[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
        return Result(
            text: text,
            audioSeconds: Double(samples.count) / Double(segmenter.sampleRate),
            finishSeconds: Date().timeIntervalSince(started),
            segments: segmentCount
        )
    }

    /// Segments run one at a time, in order, so the model is never asked for two at once.
    private func enqueue(_ range: Range<Int>) {
        let index = segmentCount
        segmentCount += 1
        let audio = Array(samples[range])
        let previous = tail
        tail = Task {
            try await previous?.value
            guard SpeechSegmenter.containsSpeech(audio) else { return }
            do {
                let text = try await self.transcriber.transcribe(audio)
                self.store(text, at: index)
            } catch {
                self.fail(error)
            }
        }
    }

    private func store(_ text: String, at index: Int) { texts[index] = text }
    private func fail(_ error: Error) { failure = failure ?? error }
}
