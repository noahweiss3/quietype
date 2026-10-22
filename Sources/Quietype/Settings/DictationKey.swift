import AppKit

/// The key you hold (or double-tap) to dictate.
enum DictationKey: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case rightControl
    case fn

    var id: String { rawValue }

    /// The hardware key code, as in Carbon's `kVK_*` constants.
    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61 // kVK_RightOption
        case .rightCommand: return 54 // kVK_RightCommand
        case .rightControl: return 62 // kVK_RightControl
        case .fn: return 63 // kVK_Function
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
