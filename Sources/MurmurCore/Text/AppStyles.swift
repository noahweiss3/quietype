/// Maps the app you're dictating into to a writing style.
public enum AppStyles {
    public static let defaults: [String: WritingStyle] = [
        // Chat
        "com.tinyspeck.slackmacgap": .chat,
        "com.apple.MobileSMS": .chat,
        "com.hnc.Discord": .chat,
        "net.whatsapp.WhatsApp": .chat,
        "ru.keepcoder.Telegram": .chat,
        "com.microsoft.teams2": .chat,
        "com.facebook.archon": .chat,
        // Email
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email,
        // Code
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "com.todesktop.230313mzl4w4u92": .code, // Cursor
        "dev.zed.Zed": .code,
        "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code,
        "com.mitchellh.ghostty": .code,
        "dev.warp.Warp-Stable": .code,
        "com.jetbrains.intellij": .code,
        "com.sublimetext.4": .code,
    ]

    public static func style(forBundleID bundleID: String?, overrides: [String: WritingStyle] = [:]) -> WritingStyle {
        guard let bundleID else { return .standard }
        return overrides[bundleID] ?? defaults[bundleID] ?? .standard
    }
}
