import AVFoundation
import QuietypeCore

/// Captures the microphone and delivers 16 kHz mono samples, in order, as an async stream.
/// Only the tap, which AVAudioEngine runs on its audio thread, leaves the main actor.
@MainActor
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available." }
    }

    /// Latest input level (RMS), for the overlay. Called on the audio thread.
    var onLevel: (@Sendable (Float) -> Void)?

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var configurationObserver: NSObjectProtocol?

    /// Starts recording. Samples arrive on the returned stream until `stop()`.
    func start() throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        do {
            try startEngine(continuation)
        } catch {
            continuation.finish()
            self.continuation = nil
            throw error
        }
        // AirPods connecting or a call app switching the input stops the engine. Dictation is
        // short enough not to care, but a meeting runs for an hour, so pick up the new device.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
        return stream
    }

    private func startEngine(_ continuation: AsyncStream<[Float]>.Continuation) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        let tap = Tap(continuation: continuation, onLevel: onLevel)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in tap.process(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func restartAfterConfigurationChange() {
        guard let continuation else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine(continuation)
        } catch {
            // No usable input any more: end the stream so the caller can say so.
            continuation.finish()
            self.continuation = nil
        }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}

/// The audio-thread half of `AudioRecorder`: one per installed tap, so each (re)started engine
/// begins with a fresh resampler. `@unchecked Sendable` is sound because only the tap block calls
/// `process`, and AVAudioEngine calls a tap's block one buffer at a time.
private final class Tap: @unchecked Sendable {
    private let resampler = Resampler()
    private let continuation: AsyncStream<[Float]>.Continuation
    private let onLevel: (@Sendable (Float) -> Void)?

    init(continuation: AsyncStream<[Float]>.Continuation, onLevel: (@Sendable (Float) -> Void)?) {
        self.continuation = continuation
        self.onLevel = onLevel
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        // Once `stop()` has finished the stream, late buffers are dropped without a level.
        guard let samples = resampler.convert(buffer), case .enqueued = continuation.yield(samples) else { return }
        onLevel?(SpeechSegmenter.rms(samples))
    }
}
