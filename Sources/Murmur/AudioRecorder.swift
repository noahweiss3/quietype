import AVFoundation
import MurmurCore

/// Captures the microphone and delivers 16 kHz mono samples, in order, as an async stream.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available." }
    }

    /// Latest input level (RMS), for the overlay. Written on the audio thread.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var configurationObserver: NSObjectProtocol?

    /// Starts recording. Samples arrive on the returned stream until `stop()`.
    func start() throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        do {
            try startEngine()
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
            self?.restartAfterConfigurationChange()
        }
        return stream
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        let converter = AVAudioConverter(from: format, to: target)
        converter?.downmix = true
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
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
            try startEngine()
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

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let continuation else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        continuation.yield(samples)
        onLevel?(SpeechSegmenter.rms(samples))
    }
}
