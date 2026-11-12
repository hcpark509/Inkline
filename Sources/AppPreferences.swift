import AppKit

enum AppAppearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"
}

enum ColorTheme: String, CaseIterable {
    case orchid = "Orchid", ocean = "Ocean", forest = "Forest", graphite = "Graphite"

    func colors(dark: Bool) -> [Palette.Role: UInt32] {
        let base: [Palette.Role: UInt32]
        switch self {
        case .orchid:
            base = dark
                ? [.chrome: 0x25202e, .source: 0x24202c, .paper: 0x211e28, .ink: 0xeee6f6, .muted: 0xbdb1cc,
                   .line: 0x42374f, .purple: 0xc9a8fd, .lavender: 0x382c48, .teal: 0x8bdcca,
                   .blue: 0xaabfff, .orange: 0xffb991, .rose: 0xffa9d3]
                : [.chrome: 0xf7f5fb, .source: 0xfbf9fd, .paper: 0xffffff, .ink: 0x29253b, .muted: 0x625b75,
                   .line: 0xe4dced, .purple: 0x6741a5, .lavender: 0xece4fa, .teal: 0x126e66,
                   .blue: 0x314e9d, .orange: 0x9b4425, .rose: 0x963c67]
        case .ocean:
            base = dark
                ? [.chrome: 0x172630, .source: 0x14212a, .paper: 0x15232c, .ink: 0xe0edf5, .muted: 0xa2bac9,
                   .line: 0x334c5a, .purple: 0x80c5fb, .lavender: 0x253d50, .teal: 0x81dccc,
                   .blue: 0xb3b8ff, .orange: 0xffc18e, .rose: 0xf3a6cb]
                : [.chrome: 0xf0f6fa, .source: 0xf6fafc, .paper: 0xffffff, .ink: 0x203647, .muted: 0x526d80,
                   .line: 0xd5e3ec, .purple: 0x175f9e, .lavender: 0xdcecf9, .teal: 0x087767,
                   .blue: 0x554ba5, .orange: 0x99521e, .rose: 0x9b386d]
        case .forest:
            base = dark
                ? [.chrome: 0x202b25, .source: 0x1b2720, .paper: 0x1c2821, .ink: 0xe1efe4, .muted: 0xadc4b3,
                   .line: 0x3b5143, .purple: 0x9cdaad, .lavender: 0x304b38, .teal: 0x81d5df,
                   .blue: 0xa9bdff, .orange: 0xf8c08b, .rose: 0xefa6c2]
                : [.chrome: 0xf1f7f2, .source: 0xf7faf7, .paper: 0xffffff, .ink: 0x263d2d, .muted: 0x526d59,
                   .line: 0xd4e4d8, .purple: 0x27673b, .lavender: 0xddeee1, .teal: 0x126b78,
                   .blue: 0x414f9d, .orange: 0x98501d, .rose: 0x913b67]
        case .graphite:
            base = dark
                ? [.chrome: 0x25272c, .source: 0x1f2126, .paper: 0x222429, .ink: 0xe8e9ed, .muted: 0xb3b8c4,
                   .line: 0x42464f, .purple: 0xb8c9f5, .lavender: 0x343f56, .teal: 0x89d6c9,
                   .blue: 0xacbcfa, .orange: 0xf0bd92, .rose: 0xeaa8c8]
                : [.chrome: 0xf3f4f6, .source: 0xf9fafb, .paper: 0xffffff, .ink: 0x2b303a, .muted: 0x5b6577,
                   .line: 0xdce0e6, .purple: 0x465d8e, .lavender: 0xe2e8f5, .teal: 0x17766b,
                   .blue: 0x3d56a0, .orange: 0x985522, .rose: 0x923d6a]
        }
        return base
    }

    func previewColors(dark: Bool) -> [String: String] {
        let colors = colors(dark: dark)
        let keys: [String: Palette.Role] = [
            "--paper": .paper, "--text": .ink, "--heading": .ink, "--subheading": .purple,
            "--muted": .muted, "--purple": .purple, "--teal": .teal, "--code": .orange,
            "--wash": .lavender, "--line": .line, "--quote": .purple
        ]
        return keys.mapValues { String(format: "#%06x", colors[$0]!) }
    }
}

enum AppPreferences {
    static let didChange = Notification.Name("InklineSettingsChanged")
    static var autosaveEnabled: Bool { UserDefaults.standard.bool(forKey: "autosaveEnabled") }
    static var autosaveDelay: Double {
        let value = UserDefaults.standard.double(forKey: "autosaveDelay")
        return value > 0 ? min(60, max(1, value)) : 2
    }
    static var appearance: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }
    static var theme: ColorTheme {
        ColorTheme(rawValue: UserDefaults.standard.string(forKey: "colorTheme") ?? "") ?? .orchid
    }
    static var showsLineNumbers: Bool {
        UserDefaults.standard.object(forKey: "showLineNumbers") as? Bool ?? true
    }
    static var lineSpacing: Double {
        let value = UserDefaults.standard.object(forKey: "editorLineSpacing") as? Double ?? 5
        return min(16, max(0, value))
    }
    static var defaultEngine: LatexEngine {
        LatexEngine(rawValue: UserDefaults.standard.string(forKey: "defaultLatexEngine") ?? "") ?? .pdfLaTeX
    }
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func set(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        applyAppearance()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NSDocumentController.shared.autosavingDelay = 0
    }
}
