import AppKit
import Combine
import MurmurCore
import MurmurKit

/// The key you hold (or double-tap) to dictate.
enum DictationKey: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case rightControl
    case fn

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        case .fn: return "Fn / Globe 🌐"
        }
    }
}

extension CleanupMode {
    var displayName: String {
        switch self {
        case .rulesOnly: return "Rules only (no LLM)"
        case .smart: return "Smart: LLM only when needed"
        case .always: return "Always use the LLM"
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var dictationKey: DictationKey { didSet { defaults.set(dictationKey.rawValue, forKey: "dictationKey") } }
    @Published var speechModel: ParakeetTranscriber.Variant { didSet { defaults.set(speechModel.rawValue, forKey: "speechModel") } }
    @Published var cleanupMode: CleanupMode { didSet { defaults.set(cleanupMode.rawValue, forKey: "cleanupMode") } }
    @Published var cleanupModelID: String { didSet { defaults.set(cleanupModelID, forKey: "cleanupModelID") } }
    @Published var dictionaryText: String { didSet { defaults.set(dictionaryText, forKey: "dictionaryText") } }
    @Published var snippets: [Snippet] { didSet { defaults.set(try? JSONEncoder().encode(snippets), forKey: "snippets") } }
    @Published var appendTrailingSpace: Bool { didSet { defaults.set(appendTrailingSpace, forKey: "appendTrailingSpace") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var speculativeDecoding: Bool { didSet { defaults.set(speculativeDecoding, forKey: "speculativeDecoding") } }
    @Published var hasCompletedSetup: Bool { didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") } }

    init() {
        dictationKey = DictationKey(rawValue: defaults.string(forKey: "dictationKey") ?? "") ?? .rightOption
        speechModel = ParakeetTranscriber.Variant(rawValue: defaults.string(forKey: "speechModel") ?? "") ?? .ultra
        cleanupMode = CleanupMode(rawValue: defaults.string(forKey: "cleanupMode") ?? "") ?? .smart
        cleanupModelID = defaults.string(forKey: "cleanupModelID") ?? CleanupModel.qwen3_4B.id
        dictionaryText = defaults.string(forKey: "dictionaryText") ?? ""
        snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        appendTrailingSpace = defaults.object(forKey: "appendTrailingSpace") as? Bool ?? true
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        speculativeDecoding = defaults.object(forKey: "speculativeDecoding") as? Bool ?? true
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
    }

    var cleanupModel: CleanupModel { CleanupModel.with(id: cleanupModelID) ?? .qwen3_4B }
    var dictionary: PersonalDictionary { PersonalDictionary(parsing: dictionaryText) }
}
