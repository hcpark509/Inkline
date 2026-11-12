import AppKit

enum FontPreference: String {
    case source, preview

    static let didChange = AppPreferences.didChange

    var familyKey: String { rawValue + "FontFamily" }
    var sizeKey: String { rawValue + "FontSize" }
    private var defaultSize: Int { self == .source ? 13 : 15 }

    var family: String { UserDefaults.standard.string(forKey: familyKey) ?? "" }
    var size: Int {
        let stored = UserDefaults.standard.object(forKey: sizeKey) as? Int ?? defaultSize
        return min(48, max(9, stored))
    }

    var sourceFont: NSFont {
        if let imported = LocalFonts.shared.font(for: family),
           let font = NSFont(name: imported.postScriptName, size: CGFloat(size)) {
            return font
        }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: CGFloat(size))
            ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    func choose(in window: NSWindow) {
        SettingsWindowController.shared.show(section: .fonts)
    }
}
