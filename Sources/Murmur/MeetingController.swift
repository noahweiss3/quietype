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
    /// Something the user should know: no call audio, no notes model, a failed update.
    @Published private(set) var warning: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var savedFile: URL?

    /// Supplies the notes model when a meeting starts; nil means transcript only.
    var notesGenerator: () async -> TextGenerator? = { nil }

    private let transcriber: SpeechTranscriber
    private let microphone = AudioRecorder()
    private let systemAudio = SystemAudioCapture()
    private let schedule = MeetingNotesSchedule()
    private var session: MeetingSession?
    private var writer: MeetingNotesWriter?
    private var feeders: [Task<Void, Never>] = []
    private var ticker: Task<Void, Never>?
    private var lastNotesUpdate = Date()

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
        state = .starting
        transcript = MeetingTranscript()
        notes = ""
        warning = nil
        savedFile = nil

        let session = MeetingSession(transcriber: transcriber)
        await session.setOnUpdate { [weak self] transcript in
            Task { @MainActor in self?.transcript = transcript }
        }
        self.session = session

        do {
            let mic = try microphone.start()
            feeders.append(Task.detached { for await chunk in mic { await session.append(chunk, from: .me) } })
        } catch {
            warning = "Microphone error: \(error.localizedDescription)"
            state = .idle
            return
        }
        do {
            let call = try await systemAudio.start()
            feeders.append(Task.detached { for await chunk in call { await session.append(chunk, from: .others) } })
        } catch {
            warning = "Can't hear the call, so only your microphone is transcribed. Allow Murmur in System Settings › Privacy & Security › Screen & System Audio Recording, then start again."
        }

        if let generator = await notesGenerator() {
            writer = MeetingNotesWriter(generator: generator)
        } else {
            writer = nil
            warning = (warning.map { $0 + "\n" } ?? "") + "Live notes need the cleanup model (Settings › General). The transcript still works."
        }

        startedAt = Date()
        lastNotesUpdate = Date()
        state = .recording
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refreshNotesIfDue()
            }
        }
    }

    func stop() async {
        guard state == .recording else { return }
        state = .finishing
        ticker?.cancel()
        ticker = nil
        microphone.stop()
        await systemAudio.stop()
        for feeder in feeders { await feeder.value }
        feeders = []

        guard let session else { return }
        transcript = await session.finish()
        if let writer {
            isUpdatingNotes = true
            await writer.update(with: transcript, final: true)
            notes = await writer.notes
            isUpdatingNotes = false
        }
        savedFile = save()
        self.session = nil
        state = .finished
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

    /// Folds new talk into the notes when the schedule says it's time.
    private func refreshNotesIfDue() async {
        guard state == .recording, let writer, let session else { return }
        guard !(await writer.isUpdating) else { return }
        let current = await session.current
        let pending = await writer.pendingWords(in: current)
        guard schedule.isDue(pendingWords: pending, secondsSinceLastUpdate: Date().timeIntervalSince(lastNotesUpdate)) else { return }

        lastNotesUpdate = Date()
        isUpdatingNotes = true
        await writer.update(with: current)
        notes = await writer.notes
        if let error = await writer.lastError { warning = "Notes update failed: \(error)" }
        isUpdatingNotes = false
    }

    private func save() -> URL? {
        let url = Self.folder.appendingPathComponent("\(title).md")
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try transcript.markdown(title: title, notes: notes).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            warning = "Couldn't save the meeting: \(error.localizedDescription)"
            return nil
        }
    }
}
