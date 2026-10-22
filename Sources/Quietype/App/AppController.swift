import AppKit
import Combine
import QuietypeCore
import QuietypeKit

/// Runs one dictation at a time: key down → record → key up → transcribe → clean up → paste.
/// Also loads the speech model and watches permissions; the cleanup model has its own loader.
@MainActor
final class AppController: ObservableObject {
    let settings: AppSettings
    let hud = RecordingHUD()
    let meeting: MeetingController
    let cleanup: CleanupModelLoader

    @Published private(set) var speechState: ModelState = .notLoaded
    @Published private(set) var history: [HistoryEntry] = []
    /// Why history couldn't be read, saved or cleared, for the History tab.
    @Published private(set) var historyError: String?
    @Published private(set) var isRecording = false
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var microphoneGranted = Permissions.microphoneGranted

    private let transcriber: ParakeetTranscriber
    /// Counts speech-model loads, so only the latest one reports into `speechState`.
    private var speechLoadGeneration = 0
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
    /// Why the saved history couldn't be read at launch; kept until history is cleared.
    private var historyLoadError: String?
    /// The last text pasted this session, for Paste Last Dictation when history is off.
    private var lastDictation: String?

    init(settings: AppSettings) {
        self.settings = settings
        let transcriber = ParakeetTranscriber()
        self.transcriber = transcriber
        let meeting = MeetingController(transcriber: transcriber)
        self.meeting = meeting
        cleanup = CleanupModelLoader(
            settings: settings, isMeetingActive: { [weak meeting] in meeting?.isActive ?? false })
        hotkey = HotkeyMonitor(key: settings.dictationKey)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        historyStore = HistoryStore(url: support.appendingPathComponent("Quietype/history.json"))
        do {
            history = try historyStore.load()
        } catch {
            historyLoadError = error.localizedDescription
            historyError = historyLoadError
        }

        hotkey.onAction = { [weak self] action in self?.handle(action) }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.model.push(level: level) }
        }

        settings.$dictationKey.dropFirst().sink { [weak self] key in self?.hotkey.key = key }.store(in: &cancellables)
        settings.$speechModel.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { await self?.loadSpeechModel() }
        }.store(in: &cancellables)
        meeting.cannotStart = { [weak self] in self?.meetingBlocker() }
        meeting.notesGenerator = { [weak self] in try await self?.cleanup.notesGenerator() }
        meeting.onFinished = { [weak self] in self?.cleanup.releaseIfLoadedOnlyForNotes() }
    }

    func start() {
        hotkey.start()
        watchPermissions()
        Task {
            if !Permissions.microphoneGranted {
                _ = await Permissions.requestMicrophone()
                refreshPermissions()
            }
            await loadSpeechModel()
            await cleanup.loadIfNeeded()
        }
    }

    // MARK: Models

    /// Loads the selected speech model. Switching models while one loads starts another load;
    /// only the latest one reports, so a slow earlier load can't mark the wrong model ready.
    func loadSpeechModel() async {
        speechLoadGeneration += 1
        let generation = speechLoadGeneration
        let variant = settings.speechModel
        speechState = .downloading(0)
        do {
            try await transcriber.load(variant) { fraction in
                Task { @MainActor [weak self] in
                    // By variant, not generation: asking for the same model again joins the
                    // first request's download, whose progress arrives here.
                    guard let self, self.settings.speechModel == variant, self.speechState.isDownloading else { return }
                    self.speechState = .downloading(fraction)
                }
            }
            guard generation == speechLoadGeneration else { return }
            speechState = .ready
        } catch {
            guard generation == speechLoadGeneration else { return }
            switch error {
            case let TranscriberError.downloadFailed(underlying):
                speechState = .downloadFailed(underlying.localizedDescription)
            case let TranscriberError.loadFailed(underlying): speechState = .loadFailed(underlying.localizedDescription)
            default: speechState = .loadFailed(error.localizedDescription)
            }
        }
    }

    // MARK: Permissions

    func requestMicrophone() async {
        if Permissions.microphoneDenied { Permissions.openMicrophoneSettings() }
        _ = await Permissions.requestMicrophone()
        refreshPermissions()
    }

    /// Re-reads both permissions. System Settings changes them without telling the app, so this
    /// runs on a timer, when the app becomes active and when the menu opens.
    func refreshPermissions() {
        let accessibility = Permissions.accessibilityGranted
        if accessibility != accessibilityGranted {
            // Global key monitors registered without Accessibility never fire, and the same goes
            // for ones registered before access was revoked, so register them again when it returns.
            if accessibility { hotkey.start() }
            accessibilityGranted = accessibility
        }
        let microphone = Permissions.microphoneGranted
        if microphone != microphoneGranted { microphoneGranted = microphone }
    }

    private func watchPermissions() {
        // Scheduled on the main run loop, so it fires on the main thread.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.refreshPermissions() }
        }
        timer.tolerance = 1
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

    /// Why meeting notes can't start now, or nil. Dictation and meetings share the microphone and
    /// the models, so each refuses to start while the other runs; `startRecording` checks the
    /// other direction.
    private func meetingBlocker() -> String? {
        if isRecording || dictationTask != nil {
            return "A dictation is still in progress. Finish or cancel it, then start meeting notes."
        }
        guard speechState != .ready else { return nil }
        return "The speech model isn't ready yet (\(speechState.summary)). Try again when Settings shows it as Ready."
    }

    private func startRecording() {
        guard dictationTask == nil else { return hotkey.reset() } // still pasting the previous one
        guard !meeting.isActive else {
            hotkey.reset()
            return hud.flash("Dictation is paused during meeting notes")
        }
        guard speechState == .ready else {
            hotkey.reset()
            return hud.flash(
                speechState == .loading || speechState.isDownloading
                    ? "Speech model is loading…" : "Speech model not ready")
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
        if let live { Task { await live.cancel() } } // segments already queued would still run
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
        let processor = DictationProcessor(cleaner: settings.cleanupMode == .rulesOnly ? nil : cleanup.cleaner)
        let bundleID = targetBundleID

        dictationTask = Task {
            defer { dictationTask = nil }
            do {
                await feeder.value // all audio delivered
                let transcript = try await live.finish()
                guard !transcript.text.isEmpty else { return hud.show(.hidden) }

                hud.show(.cleaningUp)
                let processed = await processor.process(transcript.text, context: context)
                if !processed.text.isEmpty { Paster.paste(processed.text) }
                hud.show(.hidden)
                lastDictation = processed.text
                guard settings.keepHistory else { return }

                let entry = HistoryEntry(
                    appBundleID: bundleID,
                    audioSeconds: transcript.audioSeconds,
                    transcribeSeconds: transcript.finishSeconds,
                    totalSeconds: Date().timeIntervalSince(released),
                    result: processed
                )
                record(entry)
            } catch {
                hud.flash("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: History

    /// Adds a finished dictation to the history. If the file can't be written it still shows up
    /// for this session.
    private func record(_ entry: HistoryEntry) {
        do {
            history = try historyStore.add(entry)
            historyError = historyLoadError
        } catch {
            history = [entry] + history
            historyError = "Couldn't save this dictation to the history file: \(error.localizedDescription)"
            hud.flash("Couldn't save to history")
        }
    }

    func pasteLast() {
        guard let last = lastDictation ?? history.first?.result.text, !last.isEmpty else { return }
        Paster.paste(last)
    }

    func clearHistory() {
        do {
            try historyStore.clear()
            history = []
            lastDictation = nil
            historyLoadError = nil
            historyError = nil
        } catch {
            historyError = "Couldn't clear the history: \(error.localizedDescription)"
        }
    }
}
