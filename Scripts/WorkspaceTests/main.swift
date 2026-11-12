import AppKit
import PDFKit

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw AutomationError(message: message) }
}
@MainActor func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
@MainActor func save(_ document: InklineDocument, to url: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        document.save(to: url, ofType: document.format.rawValue, for: .saveOperation) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
}
@MainActor func export(_ document: InklineDocument, to url: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        do {
            try document.workspace.automationExportPDF(to: url) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        } catch { continuation.resume(throwing: error) }
    }
}
@MainActor func exercise() async throws {
    let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Fixtures")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("chapters"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("figures"), withIntermediateDirectories: true)
    AppPreferences.set(false, forKey: "autosaveEnabled")
    AppPreferences.set(1.0, forKey: "autosaveDelay")
    ProjectWorkspace.shared.close()
    let document = try InklineDocument.openUntitled(format: .markdown, source: "# Original\n")
    let note = root.appendingPathComponent("chapters/note.md")
    try await save(document, to: note)
    try require(!document.isDocumentEdited, "New save remains dirty")
    try document.automationReplace("# Manual\n")
    await pause(1.5)
    try require(try String(contentsOf: note) == "# Original\n", "Autosave wrote while disabled")
    AppPreferences.set(true, forKey: "autosaveEnabled")
    await pause(1.8)
    try require(try String(contentsOf: note) == "# Manual\n", "Autosave did not save")
    try require(!document.isDocumentEdited, "Autosave remains dirty")
    try document.automationReplace("# Pending\n")
    AppPreferences.set(false, forKey: "autosaveEnabled")
    await pause(1.5)
    try require(try String(contentsOf: note) == "# Manual\n", "Disabling autosave failed to cancel")
    try document.automationReplace("# Stable\n")
    try await save(document, to: note)
    let revision = document.revision
    for theme in ColorTheme.allCases {
        for mode in [AppAppearance.dark, .light] {
            AppPreferences.set(theme.rawValue, forKey: "colorTheme")
            AppPreferences.set(mode.rawValue, forKey: "appearance")
            AppPreferences.set(8.0, forKey: "editorLineSpacing")
            try require(document.revision == revision && !document.isDocumentEdited, "Settings changed document text/dirty status")
        }
    }
    try document.automationReplace("# Undo changed\n")
    document.undoManager?.undo()
    try require(document.source == "# Stable\n", "Preferences broke native Undo")
    document.undoManager?.redo()
    try require(document.source == "# Undo changed\n", "Preferences broke native Redo")
    func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
    SettingsWindowController.shared.show(section: .appearance)
    let settings = SettingsWindowController.shared.window!
    func choose(_ key: String, _ title: String) throws {
        let picker = allViews(settings.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == key }!
        picker.selectItem(withTitle: title)
        try require(NSApp.sendAction(picker.action!, to: picker.target, from: picker), "Settings action not handled")
    }
    try choose("colorTheme", "Ocean")
    try choose("appearance", "Dark")
    try require(AppPreferences.theme == .ocean && AppPreferences.appearance == .dark && AppPreferences.isDark, "Settings dropdowns did not apply")
    try require(document.revision == revision || document.source == "# Undo changed\n", "Settings action changed source")
    SettingsWindowController.shared.show(section: .fonts)
    settings.contentView!.layoutSubtreeIfNeeded()
    for row in allViews(settings.contentView!).compactMap({ $0 as? NSStackView }) where row.arrangedSubviews.count == 3 {
        let children = row.arrangedSubviews
        if children[1] is NSPopUpButton, children[2] is NSPopUpButton {
            try require(children[1].frame.minX >= children[0].frame.maxX + 5, "Font selector overlaps its label")
            try require(children[2].frame.minX >= children[1].frame.maxX + 5, "Font size selector overlaps family")
        }
    }
    settings.close()
    document.workspace.view.layoutSubtreeIfNeeded()
    let split = allViews(document.workspace.view).compactMap { $0 as? NSSplitView }.first!
    try require(abs(split.frame.width - document.workspace.view.bounds.width) < 2, "Editor did not fill available width")
    print("Autosave opt-in, cancellation, settings actions, full-width layout, native Undo/Redo passed.")

    let untitled = try InklineDocument.openUntitled(format: .markdown, source: "Untitled changes")
    AppPreferences.set(true, forKey: "autosaveEnabled")
    await pause(1.5)
    try require(untitled.fileURL == nil && untitled.windowControllers.first?.window?.attachedSheet == nil, "Untitled autosave prompted")
    AppPreferences.set(false, forKey: "autosaveEnabled")

    var table = TableDraft()
    table[0, 0] = "A | B"
    table[1, 0] = "<cell>&\""
    table[1, 1] = "price $5_&%"
    table[2, 2] = "preserved"
    table.columns = 1; table.rows = 1
    table.columns = 3; table.rows = 3
    try require(table[2,2] == "preserved", "Table resize lost cells")
    try require(table.source(for: .markdown).contains("A \\| B"), "Markdown table escape failed")
    try require(table.source(for: .html).contains("&lt;cell&gt;&amp;&quot;"), "HTML table escape failed")
    try require(table.source(for: .latex).contains(#"price \$5\_\&\%"#), "TeX table escape failed: " + table.source(for: .latex))
    let tableTex = "\\documentclass{article}\n\\begin{document}\n" + table.source(for: .latex) + "\\end{document}\n"
    let compiledTable = LatexCompiler.compile(LatexInput(source: tableTex, fileURL: nil, engine: .pdfLaTeX))
    try require(compiledTable.pdf != nil, "Generated table compilation failed: " + compiledTable.log)
    let builder = TableBuilder(format: .markdown)
    builder.present(on: document.windowControllers.first!.window!) { _ in }
    builder.window!.contentView!.layoutSubtreeIfNeeded()
    let cells = allViews(builder.window!.contentView!).compactMap { $0 as? NSTextField }
    let firstCell = cells.first { $0.identifier?.rawValue == "0,0" }!
    let rowCount = cells.first { $0.accessibilityLabel() == "Table rows" }!
    try require(NSApp.sendAction(rowCount.action!, to: rowCount.target, from: rowCount), "Row action failed")
    try require(firstCell.window === builder.window, "Unchanged dimensions rebuilt cells and lost focus")
    let cancel = allViews(builder.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!
    NSApp.sendAction(cancel.action!, to: cancel.target, from: cancel)
    print("All table formats, cell preservation, escaping, stable cell focus, and native LaTeX table compilation passed.")

    let imageURL = root.appendingPathComponent("figures/plot.png")
    let image = NSImage(size: NSSize(width: 64, height: 32))
    image.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 64, height: 32).fill(); image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
    try ProjectWorkspace.shared.select(root)
    try require(document.projectRoot == root, "Document project root failed")
    try require(previewAsset(at: "../figures/plot.png", in: note.deletingLastPathComponent(), projectRoot: root) == imageURL, "Parent-relative asset failed")
    try require(previewAsset(at: "figures/plot.png", in: note.deletingLastPathComponent(), projectRoot: root) == imageURL, "Root-relative asset failed")
    try require(previewAsset(at: "../../../../etc/passwd", in: note.deletingLastPathComponent(), projectRoot: root) == nil, "Project escape allowed")
    try require(ProjectWorkspace.relativePath(of: imageURL, from: note.deletingLastPathComponent()) == "../figures/plot.png", "Figure path failed")
    try "Project input found".write(to: root.appendingPathComponent("shared.tex"), atomically: true, encoding: .utf8)
    let tex = #"\documentclass{article}\usepackage{graphicx}\begin{document}\input{shared}\includegraphics{figures/plot.png}\end{document}"#
    let compiled = LatexCompiler.compile(LatexInput(source: tex, fileURL: root.appendingPathComponent("chapters/main.tex"), engine: .pdfLaTeX, projectURL: root))
    try require(compiled.pdf != nil, "Project LaTeX references failed: " + compiled.log)
    document.workspace.view.layoutSubtreeIfNeeded()
    try require(abs(split.frame.width - (document.workspace.view.bounds.width - 220)) < 2, "Project sidebar layout failed")
    let latex = try InklineDocument.openUntitled(format: .latex, source: tableTex)
    let latexWindow = latex.windowControllers.first!.window!
    latexWindow.makeKeyAndOrderFront(nil)
    latexWindow.makeFirstResponder(latex.workspace.textView)
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                windowNumber: latexWindow.windowNumber, context: nil, characters: "\r",
                                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    try require(latexWindow.performKeyEquivalent(with: event), "Command Return was not handled")
    await pause(3)
    let renderedPDF = allViews(latex.workspace.view).compactMap { $0 as? PDFView }.first!
    try require(renderedPDF.document != nil, "Command Return did not compile LaTeX")
    print("Project paths, boundary checks, LaTeX input/image references, and Command Return compilation passed.")

    try LocalFonts.shared.importFiles([URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Georgia.ttf")])
    try require(LocalFonts.shared.font(for: "Georgia") != nil, "Local font import failed")
    AppPreferences.set("Georgia", forKey: FontPreference.source.familyKey)
    AppPreferences.set("Georgia", forKey: FontPreference.preview.familyKey)
    try require(document.workspace.textView.font?.familyName == "Georgia", "Source font not applied")
    try document.automationReplace("# Imported font proof\n\nGeorgia preview with project figure.\n\n![Project figure](../figures/plot.png)\n")
    try await export(document, to: root.appendingPathComponent("markdown.pdf"))
    let pdf = PDFDocument(url: root.appendingPathComponent("markdown.pdf"))
    try require(pdf?.string?.contains("Georgia preview") == true, "Markdown export text failed")
    let html = try InklineDocument.openUntitled(format: .html, source: "<h1>HTML project asset</h1><img src='../figures/plot.png'>")
    try await save(html, to: root.appendingPathComponent("chapters/page.html"))
    try await export(html, to: root.appendingPathComponent("html.pdf"))
    try require(PDFDocument(url: root.appendingPathComponent("html.pdf"))?.string?.contains("HTML project asset") == true, "HTML export failed")
    print("Imported source font, Markdown PDF, and HTML project exports passed.\nFixtures: " + root.path)
}

final class TestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await exercise(); print("WORKSPACE TESTS PASSED"); fflush(stdout); exit(0) }
            catch { print("WORKSPACE TESTS FAILED: \(error)"); fflush(stdout); exit(1) }
        }
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}
let app = NSApplication.shared
let delegate = TestDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = InklineApplication().makeMenu()
app.run()
