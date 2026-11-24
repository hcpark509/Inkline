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
    try require(document.projectRoot?.path == root.path, "Document project root failed")
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
    try await paperSizes(root: root, markdown: pdf!, html: html)
    try await projectPaths(root: root)
}

@MainActor func projectPaths(root: URL) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("figures/results"), withIntermediateDirectories: true)
    try fm.copyItem(at: root.appendingPathComponent("figures/plot.png"), to: root.appendingPathComponent("figures/results/chart one.png"))
    try "Chapter text.\n".write(to: root.appendingPathComponent("chapters/intro.tex"), atomically: true, encoding: .utf8)
    try "@misc{k, title={T}}\n".write(to: root.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
    let nested = root.appendingPathComponent("chapters/main.tex")
    let body = #"\documentclass{article}\usepackage{graphicx}\begin{document}\input{../shared}\include{intro}"#
        + #"\includegraphics[width=1cm]{../figures/plot.png}\includegraphics[width=1cm]{figures/results/chart one.png}\end{document}"#
    let relative = LatexCompiler.compile(LatexInput(source: body, fileURL: nested, engine: .pdfLaTeX, projectURL: root))
    try require(relative.pdf != nil, "../, \\include, and root-relative paths failed: " + relative.message)
    try require(!fm.fileExists(atPath: root.appendingPathComponent("chapters/main.aux").path), "LaTeX wrote auxiliary files into the project")
    let missing = LatexCompiler.compile(LatexInput(source: "\\documentclass{article}\n\\usepackage{graphicx}\n\\begin{document}\n\\includegraphics{../nope.png}\n\\end{document}\n",
                                                   fileURL: nested, engine: .pdfLaTeX, projectURL: root))
    try require(missing.errors.first?.file == "main.tex" && missing.errors.first?.line == 4, "Missing figure error was not located: " + missing.message)

    let text = #"\includegraphics[width=2cm]{../fig"# as NSString
    let context = PathCompletion.context(in: text, caret: text.length, format: .latex)
    try require(context?.partial == "../fig" && context?.kind == .graphic, "LaTeX path context failed")
    let files = PathCompletion.files(under: root)
    let graphics = PathCompletion.suggestions(for: context!, base: root.appendingPathComponent("chapters"), files: files)
    try require(graphics.first == "../figures/plot.png" && graphics.contains("../figures/results/chart one.png"), "Graphic suggestions: \(graphics)")
    let include = PathCompletion.context(in: #"\include{in"# as NSString, caret: 11, format: .latex)!
    try require(PathCompletion.suggestions(for: include, base: root.appendingPathComponent("chapters"), files: files) == ["intro"], "\\include suggestion kept .tex")
    let bib = PathCompletion.context(in: #"\bibliography{a,re"# as NSString, caret: 18, format: .latex)!
    try require(PathCompletion.suggestions(for: bib, base: root, files: files) == ["refs"], "Bibliography suggestion failed")
    let image = PathCompletion.context(in: "![Chart](../figures/res" as NSString, caret: 23, format: .markdown)!
    try require(PathCompletion.suggestions(for: image, base: root.appendingPathComponent("chapters"), files: files) == ["../figures/results/chart%20one.png"], "Markdown suggestion failed")
    try require(PathCompletion.context(in: "<img src=\"https://x" as NSString, caret: 19, format: .html) == nil, "Remote URL was treated as a path")
    try require(PathCompletion.context(in: "Plain {text" as NSString, caret: 11, format: .latex) == nil, "Plain braces were treated as a path")

    let document = try InklineDocument.openUntitled(format: .latex, source: "")
    try await save(document, to: nested)
    let window = document.windowControllers.first!.window!
    window.makeKeyAndOrderFront(nil)
    let editor = document.workspace.textView
    window.makeFirstResponder(editor)
    editor.insertText(#"\includegraphics{../figures/pl"#, replacementRange: editor.selectedRange())
    try require(document.workspace.suggestedPaths == ["../figures/plot.png"], "Editor did not suggest the figure: \(document.workspace.suggestedPaths)")
    _ = document.workspace.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    try require(editor.string == #"\includegraphics{../figures/plot.png"#, "Accepting a suggestion failed: " + editor.string)
    try require(document.workspace.suggestedPaths.isEmpty, "Suggestions stayed open after accepting")
    editor.insertText("}", replacementRange: editor.selectedRange())
    try require(document.workspace.suggestedPaths.isEmpty, "Suggestions reopened after the closing brace")
    print("Overleaf-style relative paths, located missing-file errors, and path suggestions passed.")

    let scope = try AutomationScope(read: [root.path], write: [root.path])
    let report = root.appendingPathComponent("chapters/report.tex")
    try body.write(to: report, atomically: true, encoding: .utf8)
    let built = try LatexBuild.run(["path": report.path, "project_root": root.path], scope: scope)
    try require(built["success"] as? Bool == true && (built["pages"] as? Int ?? 0) > 0 && built["paper"] as? String == "A4", "build_latex_pdf failed: \(built)")
    try require(fm.fileExists(atPath: root.appendingPathComponent("chapters/report.pdf").path), "build_latex_pdf wrote no PDF")
    do {
        _ = try LatexBuild.run(["path": report.path], scope: scope)
        throw AutomationError(message: "build_latex_pdf replaced a PDF without overwrite")
    } catch let error as AutomationError where error.message.contains("overwrite=true") {}
    try "\\documentclass{article}\n\\begin{document}\n\\oops\n\\end{document}\n".write(to: root.appendingPathComponent("broken.tex"), atomically: true, encoding: .utf8)
    let broken = try LatexBuild.run(["path": root.appendingPathComponent("broken.tex").path], scope: scope)
    let firstError = (broken["errors"] as? [[String: Any]])?.first
    try require(broken["success"] as? Bool == false && firstError?["line"] as? Int == 3, "build_latex_pdf error summary failed: \(broken)")
    let outside = try AutomationScope(read: [root.appendingPathComponent("figures").path], write: [])
    do {
        _ = try LatexBuild.run(["path": report.path, "overwrite": true], scope: outside)
        throw AutomationError(message: "build_latex_pdf read a file outside its roots")
    } catch let error as AutomationError where error.message.hasPrefix("Path is outside") {}
    print("Headless build_latex_pdf summaries, overwrite protection, and file roots passed.")
}

@MainActor func pageSize(_ pdf: PDFDocument?, _ index: Int = 0) -> CGSize {
    pdf?.page(at: index)?.bounds(for: .mediaBox).size ?? .zero
}
func near(_ size: CGSize, _ width: CGFloat, _ height: CGFloat) -> Bool {
    abs(size.width - width) < 1.5 && abs(size.height - height) < 1.5
}

@MainActor func paperSizes(root: URL, markdown: PDFDocument, html: InklineDocument) async throws {
    try require(PaperSize.css("letter landscape") == PaperSize(width: 792, height: 612), "CSS letter landscape failed")
    try require(near(PaperSize.css("A5")!.size, 419.5, 595.3), "CSS A5 failed")
    try require(PaperSize.css("8.5in 11in") == PaperSize(width: 612, height: 792), "CSS lengths failed")
    try require(PaperSize.css("auto") == nil && PaperSize.css("bogus") == nil, "CSS auto/invalid failed")
    let stated = [
        #"\documentclass[letterpaper]{article}"#, #"\documentclass[a5paper,11pt]{article}"#,
        #"\documentclass{scrartcl}\KOMAoptions{paper=letter}"#, #"\documentclass{beamer}"#,
        "\\documentclass{article}\n\\usepackage[margin=1in, paper=legalpaper]{geometry}",
        #"\documentclass{article}\geometry{paperwidth=5in,paperheight=7in}"#,
        #"\documentclass{memoir}\setstocksize{9in}{6in}"#
    ]
    for source in stated { try require(LatexPaper.statesPaperSize(source + "\n\\begin{document}x\\end{document}"), "Missed stated size: " + source) }
    let unstated = [
        #"\documentclass[11pt]{article}"#, "% \\documentclass[letterpaper]{article}\n\\documentclass{report}",
        "\\documentclass{article}\n\\begin{document}\nletterpaper \\paperwidth=1in\n"
    ]
    for source in unstated { try require(!LatexPaper.statesPaperSize(source), "Invented a stated size: " + source) }
    try require(LatexPaper.prepare("\\documentclass{report}\nx").hasPrefix(#"\PassOptionsToClass{a4paper}{report}"#), "A4 class option missing")
    try require(!LatexPaper.prepare("\\documentclass[letterpaper]{report}\n").contains("a4paper"), "A4 overrode a stated size")
    try require(!LatexPaper.prepare("\\documentclass{report}\nx").contains("\n\\documentclass") , "LaTeX prefix moved source lines")

    try require(near(pageSize(markdown), 595.3, 841.9), "Markdown export is not A4: \(pageSize(markdown))")
    try require(near(pageSize(PDFDocument(url: root.appendingPathComponent("html.pdf"))), 595.3, 841.9), "HTML export is not A4")

    let paragraphs = (1...140).map { "<p>Paragraph \($0) for pagination.</p>" }.joined()
    try html.automationReplace("<style>@page { size: letter landscape; }</style>" + paragraphs)
    try await export(html, to: root.appendingPathComponent("html-letter.pdf"))
    let letter = PDFDocument(url: root.appendingPathComponent("html-letter.pdf"))
    try require(near(pageSize(letter), 792, 612), "HTML @page size ignored: \(pageSize(letter))")
    try require((letter?.pageCount ?? 0) > 1, "HTML export did not paginate")
    try html.automationReplace(paragraphs)
    try await export(html, to: root.appendingPathComponent("html-a4.pdf"))
    let a4 = PDFDocument(url: root.appendingPathComponent("html-a4.pdf"))
    try require(near(pageSize(a4), 595.3, 841.9) && (a4?.pageCount ?? 0) > 1, "HTML default A4 pagination failed")

    let body = "\n\\begin{document}\nPaper\n\\end{document}\n"
    for engine in LatexEngine.allCases {
        let plain = LatexCompiler.compile(LatexInput(source: #"\documentclass{article}"# + body, fileURL: nil, engine: engine))
        try require(near(pageSize(plain.pdf.flatMap(PDFDocument.init(data:))), 595.3, 841.9), "\(engine.title) default is not A4: " + plain.log)
        let letter = LatexCompiler.compile(LatexInput(source: #"\documentclass[letterpaper]{article}"# + body, fileURL: nil, engine: engine))
        try require(near(pageSize(letter.pdf.flatMap(PDFDocument.init(data:))), 612, 792), "\(engine.title) ignored letterpaper")
        let geometry = LatexCompiler.compile(LatexInput(source: #"\documentclass{article}\usepackage[paperwidth=5in,paperheight=7in]{geometry}"# + body, fileURL: nil, engine: engine))
        try require(near(pageSize(geometry.pdf.flatMap(PDFDocument.init(data:))), 360, 504), "\(engine.title) ignored geometry")
    }
    let broken = LatexCompiler.compile(LatexInput(source: "\\documentclass{article}\n\\begin{document}\n\\undefinedmacro\n\\end{document}\n", fileURL: nil, engine: .pdfLaTeX))
    try require(broken.message.hasPrefix("main.tex:3:"), "LaTeX error line moved: " + broken.message)
    print("A4 defaults, CSS @page sizes, HTML pagination, and stated LaTeX paper sizes passed.")

    try html.automationReplace("<style>@page { size: letter landscape; }</style><p>Print me</p>")
    try await printPanel(html, expecting: CGSize(width: 792, height: 612))
    let latex = try InklineDocument.openUntitled(format: .latex, source: "\\documentclass{article}" + body)
    try await printPanel(latex, expecting: CGSize(width: 595.3, height: 841.9))
    print("Print panels open on the default printer with the exported paper size.")
}

/// Opens File > Print, checks the panel's printer and paper, then cancels it.
@MainActor func printPanel(_ document: InklineDocument, expecting paper: CGSize) async throws {
    let window = document.windowControllers.first!.window!
    window.makeKeyAndOrderFront(nil)
    let item = NSMenuItem(title: "Print…", action: #selector(WorkspaceController.printDocument(_:)), keyEquivalent: "")
    try require(document.workspace.validateUserInterfaceItem(item), "Print is unavailable")
    document.workspace.printDocument(nil)
    var waited = 0.0
    while window.attachedSheet == nil, waited < 30 { await pause(0.2); waited += 0.2 }
    guard let sheet = window.attachedSheet else {
        throw AutomationError(message: "Print panel did not open for \(document.format.title)")
    }
    guard let operation = document.workspace.activePrintOperation else {
        throw AutomationError(message: "Print sheet \(type(of: sheet)) has no current operation")
    }
    let info = operation.printInfo
    try require(info.printer.name == NSPrintInfo().printer.name, "Print panel did not start on the default printer")
    try require(info.jobDisposition == .spool, "Print job is not sent to a printer")
    let size = info.orientation == .landscape && info.paperSize.width < info.paperSize.height
        ? CGSize(width: info.paperSize.height, height: info.paperSize.width) : info.paperSize
    try require(near(size, paper.width, paper.height), "Print paper is \(size), expected \(paper)")
    window.endSheet(sheet, returnCode: .cancel)
    waited = 0
    while !document.workspace.validateUserInterfaceItem(item), waited < 10 { await pause(0.2); waited += 0.2 }
    try require(document.workspace.validateUserInterfaceItem(item), "Print stayed busy after cancel")
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
