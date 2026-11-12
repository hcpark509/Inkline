import AppKit
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    enum Section: Int { case general, appearance, fonts }
    static let shared = SettingsWindowController()
    private let tabs = NSTabViewController()
    private var families: [NSPopUpButton] = []
    private let importedLabel = NSTextField(wrappingLabelWithString: "")

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Inkline Settings"
        window.isReleasedWhenClosed = false
        tabs.tabStyle = .toolbar
        for (title, icon, content) in [
            ("General", "gearshape", general()),
            ("Appearance", "paintpalette", appearance()),
            ("Fonts", "textformat", fonts())
        ] {
            let controller = NSViewController()
            controller.view = content
            controller.title = title
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadFonts),
                                               name: AppPreferences.didChange, object: nil)
        reloadFonts()
    }

    required init?(coder: NSCoder) { fatalError("Settings are created programmatically.") }

    func show(section: Section = .general) {
        tabs.selectedTabViewItemIndex = section.rawValue
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func page(_ contents: [NSView]) -> NSView {
        let page = NSView()
        let stack = NSStackView(views: contents)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 25),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -22)
        ])
        return page
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 570
        return label
    }

    private func row(_ title: String, _ controls: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let stack = NSStackView(views: [label] + controls)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func picker(_ key: String, choices: [(String, Any)], selected: Any) -> NSPopUpButton {
        let picker = NSPopUpButton()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.identifier = NSUserInterfaceItemIdentifier(key)
        picker.setAccessibilityLabel(key)
        for (title, value) in choices {
            picker.addItem(withTitle: title)
            picker.lastItem?.representedObject = value
            if String(describing: value) == String(describing: selected) { picker.select(picker.lastItem) }
        }
        picker.target = self
        picker.action = #selector(change(_:))
        return picker
    }

    private func check(_ title: String, key: String, value: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(change(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.state = value ? .on : .off
        return button
    }

    private func general() -> NSView {
        let delay = picker("autosaveDelay", choices: [1, 2, 3, 5, 10, 30].map { ("\($0) seconds", Double($0)) },
                           selected: AppPreferences.autosaveDelay)
        let compiler = picker("defaultLatexEngine", choices: LatexEngine.allCases.map { ($0.title, $0.rawValue) },
                              selected: AppPreferences.defaultEngine.rawValue)
        return page([
            heading("Saving & editing"),
            check("Automatically save changes", key: "autosaveEnabled", value: AppPreferences.autosaveEnabled),
            note("Autosave writes to files that already have a location. Save a new document once to choose its name and folder."),
            row("Save after idle", [delay]),
            check("Show line numbers", key: "showLineNumbers", value: AppPreferences.showsLineNumbers),
            row("Extra line spacing", [picker("editorLineSpacing", choices: [0, 2, 4, 5, 6, 8, 10, 12].map { ("\($0) points", Double($0)) },
                                              selected: AppPreferences.lineSpacing)]),
            row("Default TeX engine", [compiler]),
            heading("Keyboard shortcuts"),
            note("⌘Return  Recompile LaTeX\n⇧⌘R  Recompile LaTeX\n⌥⌘T  Insert a table\n⌥⌘I  Insert a figure\n⌘1 / ⌘2 / ⌘3  Source / Split / Preview\n⌘,  Open Settings")
        ])
    }

    private func appearance() -> NSView {
        let theme = picker("colorTheme", choices: ColorTheme.allCases.map { ($0.rawValue, $0.rawValue) },
                           selected: AppPreferences.theme.rawValue)
        let mode = picker("appearance", choices: AppAppearance.allCases.map { ($0.rawValue, $0.rawValue) },
                          selected: AppPreferences.appearance.rawValue)
        return page([
            heading("Workspace appearance"),
            row("Color theme", [theme]),
            row("Appearance", [mode]),
            note("Every theme has light and dark variants. System follows your Mac’s appearance. Source highlighting and the Markdown preview update together."),
            ThemeSamples(),
            note("PDF exports use the light variant of the selected Markdown theme. HTML pages and LaTeX PDFs use the styling defined in their source.")
        ])
    }

    private func fonts() -> NSView {
        let source = NSPopUpButton()
        let preview = NSPopUpButton()
        families = [source, preview]
        for (control, preference) in zip(families, [FontPreference.source, .preview]) {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.identifier = NSUserInterfaceItemIdentifier(preference.familyKey)
            control.setAccessibilityLabel(preference == .source ? "Source font family" : "Preview font family")
            control.widthAnchor.constraint(equalToConstant: 290).isActive = true
            control.target = self
            control.action = #selector(change(_:))
        }
        let sourceSize = picker(FontPreference.source.sizeKey, choices: (9...48).map { (String($0), $0) },
                                selected: FontPreference.source.size)
        let previewSize = picker(FontPreference.preview.sizeKey, choices: (9...48).map { (String($0), $0) },
                                 selected: FontPreference.preview.size)
        let importButton = NSButton(title: "Import Fonts…", target: self, action: #selector(importFonts(_:)))
        importButton.bezelStyle = .rounded
        importedLabel.font = .systemFont(ofSize: 12)
        importedLabel.textColor = .secondaryLabelColor
        importedLabel.preferredMaxLayoutWidth = 560
        importedLabel.maximumNumberOfLines = 4
        return page([
            heading("Typography"),
            row("Source font", [source, sourceSize]),
            row("Markdown preview", [preview, previewSize]),
            note("The preview font is also used for Markdown PDF exports. LaTeX document fonts are set in the preamble."),
            heading("Your local font library"),
            importButton,
            note("Import .ttf or .otf files. Inkline stores its own copies and makes them available in the source and Markdown font menus."),
            importedLabel
        ])
    }

    @objc private func change(_ sender: NSControl) {
        guard let key = sender.identifier?.rawValue else { return }
        if let picker = sender as? NSPopUpButton, let value = picker.selectedItem?.representedObject {
            AppPreferences.set(value, forKey: key)
        } else if let button = sender as? NSButton {
            AppPreferences.set(button.state == .on, forKey: key)
        }
    }

    @objc private func reloadFonts() {
        let all = LocalFonts.shared.families
        for (picker, preference) in zip(families, [FontPreference.source, .preview]) {
            picker.removeAllItems()
            picker.addItem(withTitle: "Default")
            picker.lastItem?.representedObject = ""
            for family in all {
                picker.addItem(withTitle: family)
                picker.lastItem?.representedObject = family
            }
            if let item = picker.itemArray.first(where: { $0.representedObject as? String == preference.family }) {
                picker.select(item)
            }
        }
        let imported = Array(Set(LocalFonts.shared.fonts.map(\.family))).sorted()
        importedLabel.stringValue = imported.isEmpty ? "No imported fonts yet." : imported.joined(separator: " · ")
    }

    @objc private func importFonts(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Local Fonts"
        panel.allowedContentTypes = ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            do { try LocalFonts.shared.importFiles(panel.urls) }
            catch { NSApp.presentError(error) }
        }
    }
}

private final class ThemeSamples: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 570, height: 180) }

    override func draw(_ dirtyRect: NSRect) {
        for (index, dark) in [false, true].enumerated() {
            let colors = AppPreferences.theme.colors(dark: dark)
            let card = NSRect(x: CGFloat(index) * 280, y: 5, width: 265, height: 165)
            func color(_ role: Palette.Role) -> NSColor {
                let value = colors[role]!
                return NSColor(srgbRed: CGFloat(value >> 16) / 255,
                               green: CGFloat((value >> 8) & 255) / 255,
                               blue: CGFloat(value & 255) / 255, alpha: 1)
            }
            color(.source).setFill()
            NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
            color(.line).setStroke()
            NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).stroke()
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            for (line, text, role) in [(0, dark ? "Dark" : "Light", Palette.Role.muted),
                                       (1, "# A new page", .purple), (2, "**A clear idea**", .blue),
                                       (3, "[A useful link](…)", .teal), (4, "`some code`", .orange)] {
                (text as NSString).draw(at: NSPoint(x: card.minX + 16, y: card.maxY - 30 - CGFloat(line) * 26),
                                        withAttributes: [.font: font, .foregroundColor: color(role)])
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: AppPreferences.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: AppPreferences.didChange, object: nil)
    }
    @objc private func refresh() { needsDisplay = true }
}
