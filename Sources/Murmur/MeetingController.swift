import AppKit
import MurmurCore

/// Runs one meeting at a time: records the microphone (you) and the Mac's audio output (the
/// call), transcribes both as the meeting goes, refreshes the notes with the local LLM every
/// minute or so, and saves notes plus transcript as Markdown when it ends.
@MainActor
final class MeetingController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case recording
        case finishing
        case finished
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = MeetingTranscript()
    @Published private(set) var notes = ""
    @Published private(set) var isUpdatingNotes = false
    /// Things the user should know: no call audio, no notes model, a stream that stopped.
    @Published private(set) var warnings: [String] = []
    /// Why the last notes update failed; cleared by the next one that works.
    @Published private(set) var notesError: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var savedFile: URL?

    var warning: String? { warnings.isEmpty ? nil : warnings.joined(separator: "\n") }

    /// Why a meeting can't start right now (the speech model is still loading), or nil.
    var speechNotReady: () -> String? = { nil }
    /// Supplies the notes model when a meeting starts; nil means there is none, so transcript only.
    var notesGenerator: () async throws -> TextGenerator? = { nil }
    /// Called after a meeting is saved, so the app can release a model it loaded just for notes.
    var onFinished: () -> Void = {}

    private let transcriber: SpeechTranscriber
    private let microphone = AudioRecorder()
    private let systemAudio = SystemAudioCapture()
    private let schedule = MeetingNotesSchedule()
    private var session: MeetingSession?
    private var writer: MeetingNotesWriter?
    private var feeders: [Task<Void, Never>] = []
    private var ticker: Task<Void, Never>?
    private var lastNotesUpdate = Date()
    private var notesFailures = 0
    private var lastSave = Date.distantPast
    private var fileURL: URL?
    /// Stop was pressed while the meeting was still starting (loading the notes model can take a while).
    private var stopRequested = false

    init(transcriber: SpeechTranscriber) {
        self.transcriber = transcriber
    }

    var isActive: Bool { state == .starting || state == .recording || state == .finishing }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Meetings", isDirectory: true)
    }

    func start() async {
        guard !isActive else { return }
        warnings = []
        if let reason = speechNotReady() {
            warnings = [reason]
            return
        }
        state = .starting
        transcript = MeetingTranscript()
        notes = ""
        notesError = nil
        notesFailures = 0
        savedFile = nil
        let began = Date()
        startedAt = began
        fileURL = Self.unusedURL(named: title)

        let session = MeetingSession(transcriber: transcriber)
        let id = ObjectIdentifier(session)
        await session.setOnUpdate { [weak self] transcript in
            Task { @MainActor in
                // Ignore updates that land after Stop has taken the final transcript.
                guard let self, let current = self.session, ObjectIdentifier(current) == id else { return }
                self.transcript = transcript
            }
        }
        self.session = session

        // Each stream is padded by how late it started, so You and Others share one clock.
        var sources = 0
        if Permissions.microphoneDenied {
            warn("Microphone access is off, so only the call is transcribed. Turn it on in System Settings › Privacy & Security › Microphone.")
        } else {
            do {
                let mic = try microphone.start()
                await session.appendSilence(seconds: Date().timeIntervalSince(began), to: .me)
                feeders.append(feed(mic, into: session, as: .me))
                sources += 1
            } catch {
                warn("Microphone error: \(error.localizedDescription)")
            }
        }
        do {
            let call = try await systemAudio.start()
            await session.appendSilence(seconds: Date().timeIntervalSince(began), to: .others)
            feeders.append(feed(call, into: session, as: .others))
            sources += 1
        } catch {
            warn("Can't hear the call, so only your microphone is transcribed. Allow Murmur in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Murmur.")
        }
        guard sources > 0 else {
            self.session = nil
            stopRequested = false
            state = .idle
            return
        }

        do {
            if let generator = try await notesGenerator() {
                writer = MeetingNotesWriter(generator: generator)
            } else {
                writer = nil
                warn("Live notes need the cleanup model (Settings › General). The transcript still works.")
            }
        } catch {
            writer = nil
            warn("Live notes are off: \(error.localizedDescription). The transcript still works.")
        }

        lastNotesUpdate = Date()
        lastSave = Date()
        state = .recording
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.tick()
            }
        }
        if stopRequested {
            stopRequested = false
            await stop()
        }
    }

    func stop() async {
        if state == .starting { return stopRequested = true }
        guard state == .recording else { return }
        state = .finishing
        ticker?.cancel()
        ticker = nil
        microphone.stop()
        await systemAudio.stop()
        for feeder in feeders { await feeder.value }
        feeders = []

        guard let session else {
            state = .idle
            return
        }
        transcript = await session.finish()
        self.session = nil
        if let writer {
            isUpdatingNotes = true
            await writer.update(with: transcript, final: true)
            notes = await writer.notes
            notesError = await writer.lastError
            isUpdatingNotes = false
        }
        // The notes context holds most of a gigabyte of KV cache; let it go.
        writer = nil
        savedFile = save()
        state = .finished
        onFinished()
    }

    /// Writes what there is so far; called when the app quits mid-meeting.
    func saveNow() {
        guard state == .recording || state == .finishing else { return }
        savedFile = save()
    }

    func copyNotes() {
        Paster.copy(transcript.markdown(title: title, notes: notes))
    }

    func showInFinder() {
        guard let savedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedFile])
    }

    // MARK: Private

    private var title: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Meeting \(formatter.string(from: startedAt ?? Date()))"
    }

    private func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    private func feed(_ stream: AsyncStream<[Float]>, into session: MeetingSession, as speaker: MeetingSpeaker) -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await chunk in stream { await session.append(chunk, from: speaker) }
            await self?.streamEnded(speaker)
        }
    }

    /// A stream that ends on its own while recording (sharing stopped, device unplugged) would
    /// otherwise leave one side of the meeting silently missing.
    private func streamEnded(_ speaker: MeetingSpeaker) {
        guard state == .recording else { return }
        warn(speaker == .me
            ? "Your microphone stopped, so the rest of the meeting only has the call's side."
            : "Call audio stopped (sharing ended or the display changed), so the rest of the meeting only has your side.")
    }

    private func tick() async {
        await refreshNotesIfDue()
        if let session, let error = await session.takeError() {
            warn("Some speech couldn't be transcribed: \(error)")
        }
        autosave()
    }

    /// Folds new talk into the notes when the schedule says it's time.
    private func refreshNotesIfDue() async {
        guard state == .recording, let writer, let session else { return }
        guard !(await writer.isUpdating) else { return }
        let current = await session.current
        let pending = await writer.pendingWords(in: current)
        let since = Date().timeIntervalSince(lastNotesUpdate)
        if notesFailures > 0 {
            // After a failure wait longer each time and ignore bursts, so a request that keeps
            // failing doesn't keep the GPU busy for the rest of the meeting.
            guard pending > 0, since >= schedule.minInterval * Double(1 << min(notesFailures, 4)) else { return }
        } else {
            guard schedule.isDue(pendingWords: pending, secondsSinceLastUpdate: since) else { return }
        }

        lastNotesUpdate = Date()
        isUpdatingNotes = true
        await writer.update(with: current)
        notes = await writer.notes
        notesError = await writer.lastError
        notesFailures = notesError == nil ? 0 : notesFailures + 1
        // If Stop was pressed meanwhile, the final pass is running and owns the flag.
        if state == .recording { isUpdatingNotes = false }
    }

    /// Saves every half minute while recording, so quitting or a crash loses little.
    private func autosave() {
        guard state == .recording, Date().timeIntervalSince(lastSave) >= 30 else { return }
        lastSave = Date()
        savedFile = save()
    }

    /// The meeting's own file, chosen once, so a second meeting in the same minute doesn't
    /// overwrite the first.
    private static func unusedURL(named name: String) -> URL {
        var url = folder.appendingPathComponent("\(name).md")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(number).md")
            number += 1
        }
        return url
    }

    private func save() -> URL? {
        let url = fileURL ?? Self.unusedURL(named: title)
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try transcript.markdown(title: title, notes: notes).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            warn("Couldn't save the meeting: \(error.localizedDescription)")
            return nil
        }
    }
}
