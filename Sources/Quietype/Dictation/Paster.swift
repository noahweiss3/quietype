import AppKit

/// Puts text into whatever app has focus: clipboard + simulated ⌘V, then restores the clipboard.
enum Paster {
    /// A paste whose clipboard restore hasn't run yet.
    private struct Pending {
        var original: [NSPasteboardItem]
        var ourChange: Int
        var restore: Task<Void, Never>
    }

    /// Pastes in quick succession share one restore of the clipboard from before the first, so a
    /// second paste doesn't save the first dictation as if it were the user's clipboard.
    @MainActor private static var pending: Pending?

    @MainActor static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pending?.restore.cancel()
        // If the clipboard still holds the previous paste, what to restore is what came before it;
        // if anything was copied since, that is.
        let original =
            pending.flatMap { $0.ourChange == pasteboard.changeCount ? $0.original : nil }
            ?? snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tells clipboard managers not to record this temporary entry.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        sendCommandV()

        // Give the target app time to read the clipboard before putting the old contents back.
        let restore = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return } // a newer paste took over the restore
            pending = nil
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == ourChange else { return } // something else copied meanwhile
            pasteboard.clearContents()
            if !original.isEmpty { pasteboard.writeObjects(original) }
        }
        pending = Pending(original: original, ourChange: ourChange, restore: restore)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        // Only ⌘, even if the dictation key (a modifier) is still physically held.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
