import AppKit

final class InklineApplication: NSObject, NSApplicationDelegate {
    private let automation = AutomationBridge()

    func applicationWillFinishLaunching(_ notification: Notification) {
        LocalFonts.shared.load()
        AppPreferences.applyAppearance()
    }
    func applicationDidFinishLaunching(_ notification: Notification) { automation.start() }
    func applicationWillTerminate(_ notification: Notification) { automation.stop() }

    @objc private func toggleMCP(_ sender: NSMenuItem) {
        automation.isEnabled.toggle()
        sender.state = automation.isEnabled ? .on : .off
    }

    @objc private func showMCPInfo(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Inkline MCP"
        alert.informativeText = """
        MCP access is \(automation.isEnabled ? "enabled" : "paused").
        Last request — \(automation.lastAction)

        Codex can read and edit shared documents through the local MCP connection. File access follows the read and write folders configured for the server. Edits support Undo.

        Server command
        \(Bundle.main.executableURL!.path) mcp
        """
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if !UserDefaults.standard.bool(forKey: "hasOpenedInkline") {
            newExample(nil)
            UserDefaults.standard.set(true, forKey: "hasOpenedInkline")
            return true
        }
        do {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
            return true
        } catch {
            sender.presentError(error)
            return false
        }
    }

    @objc private func newExample(_ sender: Any?) {
        do {
            let url = Bundle.main.url(forResource: "Welcome", withExtension: "md")!
            let source = try String(contentsOf: url, encoding: .utf8)
            try InklineDocument.openUntitled(format: .markdown, source: source)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc private func newLatex(_ sender: Any?) {
        do {
            try InklineDocument.openUntitled(format: .latex, source: LatexCompiler.template)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc private func newHTML(_ sender: Any?) {
        do {
            try InklineDocument.openUntitled(format: .html, source: DocumentFormat.html.starter)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc private func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = ProjectWorkspace.shared.rootURL
        if panel.runModal() == .OK, let url = panel.url {
            do { try ProjectWorkspace.shared.select(url) }
            catch { NSApp.presentError(error) }
        }
    }

    @objc private func closeProject(_ sender: Any?) { ProjectWorkspace.shared.close() }

    func makeMenu() -> NSMenu {
        let bar = NSMenu()

        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            bar.addItem(item)
            item.submenu = submenu
            return submenu
        }

        let app = menu("Inkline")
        app.command("About Inkline", "orderFrontStandardAboutPanel:")
        app.command("Settings…", "showSettings:", ",").target = self
        app.addItem(.separator())
        app.command("Hide Inkline", "hide:", "h")
        app.command("Hide Others", "hideOtherApplications:", "h", [.command, .option])
        app.command("Show All", "unhideAllApplications:")
        app.addItem(.separator())
        app.command("Quit Inkline", "terminate:", "q")

        let file = menu("File")
        file.command("New", "newDocument:", "n")
        file.command("New LaTeX Document", "newLatex:", "n", [.command, .option]).target = self
        file.command("New HTML Document", "newHTML:").target = self
        file.command("New from Example", "newExample:", "n", [.command, .shift]).target = self
        file.command("Open…", "openDocument:", "o")
        file.command("Open Project Folder…", "openProject:", "o", [.command, .option]).target = self
        file.command("Close Project", "closeProject:").target = self
        file.addItem(.separator())
        file.command("Close", "performClose:", "w")
        file.command("Save…", "saveDocument:", "s")
        file.command("Save As…", "saveDocumentAs:", "s", [.command, .option, .shift])
        file.command("Duplicate", "duplicateDocument:")
        file.addItem(.separator())
        file.command("Export PDF…", "exportPDF:", "e", [.command, .shift])

        let edit = menu("Edit")
        edit.command("Undo", "undo:", "z")
        edit.command("Redo", "redo:", "z", [.command, .shift])
        edit.addItem(.separator())
        edit.command("Cut", "cut:", "x")
        edit.command("Copy", "copy:", "c")
        edit.command("Paste", "paste:", "v")
        edit.command("Select All", "selectAll:", "a")
        edit.addItem(.separator())
        edit.command("Find…", "showEditorFind:", "f")

        let format = menu("Format")
        format.command("Heading", "insertHeading:", "h", [.command, .shift])
        format.command("Bold", "insertBold:", "b")
        format.command("Italic", "insertItalic:", "i")
        format.command("Link", "insertLink:", "k")
        format.addItem(.separator())
        format.command("Source Font…", "chooseSourceFont:")
        format.command("Preview Font…", "choosePreviewFont:")

        let insert = menu("Insert")
        insert.command("Table…", "insertTable:", "t", [.command, .option])
        insert.command("Figure…", "insertFigure:", "i", [.command, .option])

        let view = menu("View")
        view.command("Source", "showSource:", "1")
        view.command("Split", "showSplit:", "2")
        view.command("Preview", "showPreview:", "3")
        view.command("Recompile LaTeX", "recompile:", "\r")
        view.command("LaTeX Compile Log…", "showCompileLog:")
        view.addItem(.separator())
        view.command("Enter Full Screen", "toggleFullScreen:", "f", [.command, .control])

        let mcp = menu("MCP")
        let access = mcp.command("MCP Access Enabled", "toggleMCP:")
        access.target = self
        access.state = automation.isEnabled ? .on : .off
        mcp.command("Connection Details…", "showMCPInfo:").target = self

        let windows = menu("Window")
        windows.command("Minimize", "performMiniaturize:", "m")
        windows.command("Zoom", "performZoom:")
        windows.addItem(.separator())
        windows.command("Bring All to Front", "arrangeInFront:")
        NSApp.windowsMenu = windows
        return bar
    }
}

private extension NSMenu {
    @discardableResult
    func command(_ title: String, _ action: String, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
        return item
    }
}

final class InklineWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let compileKey = (modifiers == .command && [36, 76].contains(event.keyCode))
            || (modifiers == [.command, .shift] && event.charactersIgnoringModifiers?.lowercased() == "r")
        if compileKey, let editor = contentViewController as? WorkspaceController {
            editor.recompile(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
