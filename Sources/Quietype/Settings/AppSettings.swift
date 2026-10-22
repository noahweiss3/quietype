import Combine
import Foundation
import QuietypeCore
import QuietypeKit

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    private enum Key {
        static let dictationKey = "dictationKey"
        static let speechModel = "speechModel"
        static let cleanupMode = "cleanupMode"
        static let cleanupModelID = "cleanupModelID"
        static let dictionaryText = "dictionaryText"
        static let snippets = "snippets"
        static let appendTrailingSpace = "appendTrailingSpace"
        static let playSounds = "playSounds"
        static let keepHistory = "keepHistory"
        static let speculativeDecoding = "speculativeDecoding"
        static let hasCompletedSetup = "hasCompletedSetup"
    }

    private let defaults = UserDefaults.standard

    @Published var dictationKey: DictationKey {
        didSet { defaults.set(dictationKey.rawValue, forKey: Key.dictationKey) }
    }
    @Published var speechModel: ParakeetTranscriber.Variant {
        didSet { defaults.set(speechModel.rawValue, forKey: Key.speechModel) }
    }
    @Published var cleanupMode: CleanupMode { didSet { defaults.set(cleanupMode.rawValue, forKey: Key.cleanupMode) } }
    @Published var cleanupModelID: String { didSet { defaults.set(cleanupModelID, forKey: Key.cleanupModelID) } }
    @Published var dictionaryText: String { didSet { defaults.set(dictionaryText, forKey: Key.dictionaryText) } }
    @Published var snippets: [Snippet] {
        didSet { defaults.set(try? JSONEncoder().encode(snippets), forKey: Key.snippets) }
    }
    @Published var appendTrailingSpace: Bool {
        didSet { defaults.set(appendTrailingSpace, forKey: Key.appendTrailingSpace) }
    }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    /// Off: new dictations aren't written to the history file. Entries already there stay until cleared.
    @Published var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: Key.keepHistory) } }
    @Published var speculativeDecoding: Bool {
        didSet { defaults.set(speculativeDecoding, forKey: Key.speculativeDecoding) }
    }
    @Published var hasCompletedSetup: Bool { didSet { defaults.set(hasCompletedSetup, forKey: Key.hasCompletedSetup) } }

    init() {
        dictationKey = DictationKey(rawValue: defaults.string(forKey: Key.dictationKey) ?? "") ?? .rightOption
        speechModel = ParakeetTranscriber.Variant(rawValue: defaults.string(forKey: Key.speechModel) ?? "") ?? .ultra
        cleanupMode = CleanupMode(rawValue: defaults.string(forKey: Key.cleanupMode) ?? "") ?? .smart
        cleanupModelID = defaults.string(forKey: Key.cleanupModelID) ?? CleanupModel.qwen3_4B.id
        dictionaryText = defaults.string(forKey: Key.dictionaryText) ?? ""
        snippets =
            defaults.data(forKey: Key.snippets).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        appendTrailingSpace = defaults.object(forKey: Key.appendTrailingSpace) as? Bool ?? true
        playSounds = defaults.object(forKey: Key.playSounds) as? Bool ?? true
        keepHistory = defaults.object(forKey: Key.keepHistory) as? Bool ?? true
        speculativeDecoding = defaults.object(forKey: Key.speculativeDecoding) as? Bool ?? true
        hasCompletedSetup = defaults.bool(forKey: Key.hasCompletedSetup)
    }

    var cleanupModel: CleanupModel { CleanupModel.with(id: cleanupModelID) ?? .qwen3_4B }
    var dictionary: PersonalDictionary { PersonalDictionary(parsing: dictionaryText) }
}
