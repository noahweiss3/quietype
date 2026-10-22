import Combine
import Foundation
import QuietypeCore
import QuietypeKit

/// Where a model is between "not on this Mac" and "ready".
enum ModelState: Equatable {
    case notLoaded
    case downloading(Double)
    case loading
    case ready
    /// The download didn't finish or didn't verify. Anything already on disk is left as it was.
    case downloadFailed(String)
    /// The files are on disk but the model wouldn't load from them.
    case loadFailed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isFailed: Bool {
        switch self {
        case .downloadFailed, .loadFailed: return true
        default: return false
        }
    }

    var summary: String {
        switch self {
        case .notLoaded: return "Not loaded"
        case let .downloading(fraction): return "Downloading \(Int(fraction * 100))%"
        case .loading: return "Loading…"
        case .ready: return "Ready"
        case let .downloadFailed(message): return "Download failed: \(message)"
        case let .loadFailed(message): return "Couldn't load: \(message)"
        }
    }
}

/// Downloads and loads the cleanup model selected in settings. Dictation and meeting notes share
/// the one loaded model.
@MainActor
final class CleanupModelLoader: ObservableObject {
    /// Describes the selected model, so work on a model that is no longer selected never reports here.
    @Published private(set) var state: ModelState = .notLoaded
    /// The loaded model, if any.
    private(set) var cleaner: LlamaCleaner?

    private let settings: AppSettings
    private let isMeetingActive: () -> Bool
    /// The model being loaded, if any. Everything that needs the cleaner waits on this one task.
    private var load: (model: CleanupModel, task: Task<LlamaCleaner?, Error>)?
    /// Set when the model was loaded only for meeting notes (rules-only mode).
    private var loadedForNotes = false
    /// Ids of the models being downloaded, so selecting one again shows its progress rather than
    /// offering a second download of the same file.
    private var downloads: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings, isMeetingActive: @escaping () -> Bool) {
        self.settings = settings
        self.isMeetingActive = isMeetingActive

        settings.$cleanupModelID.dropFirst().removeDuplicates().sink { [weak self] id in
            guard let self else { return }
            self.cleaner = nil
            self.state = self.downloads.contains(id) ? .downloading(0) : .notLoaded
            Task { [weak self] in await self?.loadIfNeeded() }
        }.store(in: &cancellables)
        settings.$cleanupMode.dropFirst().sink { [weak self] _ in
            Task { await self?.loadIfNeeded() }
        }.store(in: &cancellables)
        settings.$speculativeDecoding
            .sink { [weak self] on in self?.cleaner?.speculative = on }
            .store(in: &cancellables)
    }

    var isDownloaded: Bool { ModelStore.isDownloaded(settings.cleanupModel) }

    /// False when the load-time check found that batched decoding is too slow on this Mac for
    /// speculative decoding to help, so it stays off whatever the setting says. Nil until loaded.
    var speculationPaysOff: Bool? { cleaner?.speculationPaysOff }

    /// Loads the model for dictation, if it is downloaded and the mode uses it.
    func loadIfNeeded() async {
        guard settings.cleanupMode != .rulesOnly else { return }
        _ = try? await loadCleaner() // a failure shows in `state`
    }

    /// Clears a load failure and tries again. In rules-only mode the model next loads for meeting notes.
    func retryLoad() {
        guard !state.isDownloading else { return }
        state = .notLoaded
        Task { await loadIfNeeded() }
    }

    /// Downloads the selected model. `replacing` fetches it again even when a file of the right
    /// size is on disk, for a copy that no longer loads; the new file is checked against the
    /// model's SHA-256 before it replaces the old one.
    func download(replacing: Bool = false) {
        let model = settings.cleanupModel
        state = .downloading(0)
        guard downloads.insert(model.id).inserted else { return }
        Task {
            defer { downloads.remove(model.id) }
            do {
                _ = try await ModelStore.download(model, replacing: replacing) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.settings.cleanupModel == model, self.state.isDownloading else { return }
                        self.state = .downloading(fraction)
                    }
                }
                guard settings.cleanupModel == model else { return }
                if replacing { cleaner = nil }
                state = .notLoaded
                await loadIfNeeded()
            } catch {
                if settings.cleanupModel == model { state = .downloadFailed(error.localizedDescription) }
            }
        }
    }

    /// Meeting notes run on the cleanup model, in a context of their own. Returns nil when the
    /// model isn't downloaded. Rules-only mode doesn't load the model for dictation, so it is
    /// loaded here.
    func notesGenerator() async throws -> TextGenerator? {
        try Task.checkCancellation()
        guard let loaded = try await loadCleaner() else { return nil }
        try Task.checkCancellation() // the meeting was stopped while starting
        return try await loaded.makeGenerator()
    }

    /// After a meeting in rules-only mode, drop the model that was loaded just for its notes.
    func releaseIfLoadedOnlyForNotes() {
        guard loadedForNotes, settings.cleanupMode == .rulesOnly else { return }
        loadedForNotes = false
        cleaner = nil
        state = .notLoaded
    }

    /// The loaded model, loading it first if needed. A load already running is joined, so
    /// dictation and meeting notes never load it twice. Returns nil when the model isn't downloaded
    /// or a different one was selected while it loaded. Cancelling the caller ends its wait, not the
    /// load.
    private func loadCleaner() async throws -> LlamaCleaner? {
        if let cleaner { return cleaner }
        guard isDownloaded else { return nil }
        let model = settings.cleanupModel
        state = .loading
        if let load, load.model == model { return try await load.task.join() }
        let forNotes = settings.cleanupMode == .rulesOnly // dictation doesn't use the model in this mode
        let task = Task { try await finishLoading(model, forNotes: forNotes) }
        load = (model, task)
        return try await task.join()
    }

    /// Loads `model` and installs it as the cleaner. Runs once per load, as the task `loadCleaner`
    /// hands to everyone waiting.
    private func finishLoading(_ model: CleanupModel, forNotes: Bool) async throws -> LlamaCleaner? {
        defer { if load?.model == model { load = nil } }
        do {
            let loaded = try await LlamaCleaner.load(model, path: ModelStore.path(for: model))
            guard model == settings.cleanupModel else { return nil } // changed while loading
            loaded.speculative = settings.speculativeDecoding
            cleaner = loaded
            state = .ready
            if forNotes {
                loadedForNotes = true
                if !isMeetingActive() { releaseIfLoadedOnlyForNotes() } // the meeting was stopped while it loaded
            }
            return loaded
        } catch {
            if model == settings.cleanupModel { state = .loadFailed(error.localizedDescription) }
            throw error
        }
    }
}
