import AppKit
import Combine
import MurmurCore
import MurmurKit

/// Owns the models and runs one dictation at a time:
/// key down → record → key up → transcribe → clean up → paste.
@MainActor
final class AppController: ObservableObject {
    enum ModelState: Equatable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    let settings: Settings
    let hud = RecordingHUD()
    let meeting: MeetingController

    @Published private(set) var speechState: ModelState = .notLoaded
    @Published private(set) var cleanupState: ModelState = .notLoaded
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var isRecording = false
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted

    private let transcriber: ParakeetTranscriber
    private var cleaner: LlamaCleaner?
    private let hotkey: HotkeyMonitor
    private let recorder = AudioRecorder()
    private let historyStore: HistoryStore
    private var cancellables: Set<AnyCancellable> = []

    // The dictation in progress.
    private var live: LiveTranscription?
    private var feeder: Task<Void, Never>?
    private var targetBundleID: String?
    private var recordingStarted = Date()
    private var dictationTask: Task<Void, Never>?

    init(settings: Settings) {
        self.settings = settings
        let transcriber = ParakeetTranscriber()
        self.transcriber = transcriber
        meeting = MeetingController(transcriber: transcriber)
        hotkey = HotkeyMonitor(key: settings.dictationKey)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        historyStore = HistoryStore(url: support.appendingPathComponent("Murmur/history.json"))
        history = historyStore.load()

        hotkey.onAction = { [weak self] action in self?.handle(action) }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.model.push(level: level) }
        }

        settings.$dictationKey.dropFirst().sink { [weak self] key in self?.hotkey.key = key }.store(in: &cancellables)
        settings.$speechModel.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { await self?.loadSpeechModel() }
        }.store(in: &cancellables)
        settings.$cleanupModelID.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.cleaner = nil
            self?.cleanupState = .notLoaded
            Task { await self?.loadCleanupModelIfDownloaded() }
        }.store(in: &cancellables)
        settings.$cleanupMode.dropFirst().sink { [weak self] _ in
            Task { await self?.loadCleanupModelIfDownloaded() }
        }.store(in: &cancellables)
        settings.$speculativeDecoding.sink { [weak self] on in self?.cleaner?.speculative = on }.store(in: &cancellables)
        meeting.notesGenerator = { [weak self] in await self?.notesGenerator() }
    }

    func start() {
        hotkey.start()
        watchAccessibility()
        Task {
            if !Permissions.microphoneGranted { _ = await Permissions.requestMicrophone() }
            await loadSpeechModel()
            await loadCleanupModelIfDownloaded()
        }
    }

    // MARK: Models

    func loadSpeechModel() async {
        speechState = .downloading(0)
        do {
            try await transcriber.load(settings.speechModel) { fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.speechState { self?.speechState = .downloading(fraction) }
                }
            }
            speechState = .ready
        } catch {
            speechState = .failed(error.localizedDescription)
        }
    }

    var cleanupModelDownloaded: Bool { ModelStore.isDownloaded(settings.cleanupModel) }

    func loadCleanupModelIfDownloaded() async {
        guard settings.cleanupMode != .rulesOnly, cleaner == nil, cleanupModelDownloaded else { return }
        if cleanupState == .loading { return }
        let model = settings.cleanupModel
        cleanupState = .loading
        do {
            let loaded = try await LlamaCleaner.load(model, path: ModelStore.path(for: model))
            guard model == settings.cleanupModel else { return } // changed while loading
            loaded.speculative = settings.speculativeDecoding
            cleaner = loaded
            cleanupState = .ready
        } catch {
            cleanupState = .failed("\(error)")
        }
    }

    /// Meeting notes run on the cleanup model, in a context of their own. Rules-only mode doesn't
    /// load the model for dictation, so load it here if it's on disk.
    private func notesGenerator() async -> TextGenerator? {
        if cleaner == nil, cleanupModelDownloaded, cleanupState != .loading {
            let model = settings.cleanupModel
            cleanupState = .loading
            do {
                let loaded = try await LlamaCleaner.load(model, path: ModelStore.path(for: model))
                loaded.speculative = settings.speculativeDecoding
                cleaner = loaded
                cleanupState = .ready
            } catch {
                cleanupState = .failed("\(error)")
            }
        }
        return try? await cleaner?.makeGenerator()
    }

    func downloadCleanupModel() {
        let model = settings.cleanupModel
        cleanupState = .downloading(0)
        Task {
            do {
                _ = try await ModelStore.download(model) { fraction in
                    Task { @MainActor [weak self] in self?.cleanupState = .downloading(fraction) }
                }
                cleanupState = .notLoaded
                await loadCleanupModelIfDownloaded()
            } catch {
                cleanupState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Permissions

    /// Global key monitors registered before Accessibility is granted never fire, so re-register
    /// once it is.
    private func watchAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                let granted = Permissions.accessibilityGranted
                if granted, !self.accessibilityGranted { self.hotkey.start() }
                self.accessibilityGranted = granted
            }
        }
    }

    // MARK: Dictation

    private func handle(_ action: HotkeyStateMachine.Action) {
        switch action {
        case .startRecording: startRecording()
        case .enterHandsFree: if isRecording { hud.show(.recording(handsFree: true)) }
        case .finishRecording: finishRecording()
        case .cancelRecording: cancelRecording()
        }
    }

    private func startRecording() {
        guard dictationTask == nil else { return hotkey.reset() } // still pasting the previous one
        guard !meeting.isActive else {
            hotkey.reset()
            return hud.flash("Meeting notes are recording")
        }
        guard speechState == .ready else {
            hotkey.reset()
            return hud.flash(speechState == .loading || speechState.isDownloading ? "Speech model is loading…" : "Speech model not ready")
        }
        guard !Permissions.microphoneDenied else {
            hotkey.reset()
            return hud.flash("Microphone access is off")
        }

        targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let live = LiveTranscription(transcriber: transcriber)
        do {
            let stream = try recorder.start()
            feeder = Task.detached {
                for await chunk in stream { await live.append(chunk) }
            }
        } catch {
            hotkey.reset()
            return hud.flash("Mic error: \(error.localizedDescription)")
        }
        self.live = live
        recordingStarted = Date()
        isRecording = true
        hud.model.levels = hud.model.levels.map { _ in 0 }
        hud.show(.recording(handsFree: false))
        if settings.playSounds { NSSound(named: "Tink")?.play() }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        recorder.stop()
        feeder?.cancel()
        feeder = nil
        live = nil
        isRecording = false
        hud.show(.hidden)
    }

    private func finishRecording() {
        guard isRecording, let live, let feeder else { return }
        let released = Date()
        recorder.stop()
        isRecording = false
        self.live = nil
        self.feeder = nil
        if settings.playSounds { NSSound(named: "Pop")?.play() }

        guard released.timeIntervalSince(recordingStarted) > 0.25 else { return hud.show(.hidden) }
        hud.show(.processing)

        let context = DictationContext(
            style: AppStyles.style(forBundleID: targetBundleID),
            mode: settings.cleanupMode,
            dictionary: settings.dictionary,
            snippets: Snippets(settings.snippets),
            appendTrailingSpace: settings.appendTrailingSpace
        )
        let processor = DictationProcessor(cleaner: settings.cleanupMode == .rulesOnly ? nil : cleaner)
        let bundleID = targetBundleID

        dictationTask = Task {
            defer { dictationTask = nil }
            do {
                await feeder.value // all audio delivered
                let transcript = try await live.finish()
                guard !transcript.text.isEmpty else { return hud.show(.hidden) }

                let processed = await processor.process(transcript.text, context: context)
                if !processed.text.isEmpty { Paster.paste(processed.text) }
                hud.show(.hidden)

                let entry = HistoryEntry(
                    appBundleID: bundleID,
                    audioSeconds: transcript.audioSeconds,
                    transcribeSeconds: transcript.finishSeconds,
                    totalSeconds: Date().timeIntervalSince(released),
                    result: processed
                )
                history = (try? historyStore.add(entry)) ?? [entry] + history
            } catch {
                hud.flash("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: History

    func pasteLast() {
        guard let last = history.first else { return }
        Paster.paste(last.result.text)
    }

    func clearHistory() {
        try? historyStore.clear()
        history = []
    }
}

extension AppController.ModelState {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .notLoaded: return "Not loaded"
        case let .downloading(fraction): return "Downloading \(Int(fraction * 100))%"
        case .loading: return "Loading…"
        case .ready: return "Ready"
        case let .failed(message): return "Error: \(message)"
        }
    }
}
