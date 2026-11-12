import AppKit
import PDFKit
import UniformTypeIdentifiers

final class WorkspaceController: NSViewController, NSTextViewDelegate, NSUserInterfaceValidations {
    private enum Mode: Int { case source, split, preview }

    let textView = SourceEditor()
    private let preview = PreviewController()
    private let htmlPreview = HTMLPreviewController()
    private let pdfView = PDFView()
    private let split = NSSplitViewController()
    private let projectBrowser = ProjectBrowser()
    private var projectWidth: NSLayoutConstraint!
    private var tableBuilder: TableBuilder?
    private weak var document: InklineDocument?
    private var sourceItem: NSSplitViewItem!
    private var previewItem: NSSplitViewItem!
    private var mode = Mode.split
    private var didSetDivider = false
    private var sourceFraction: CGFloat = 0.5
    private var refreshTask: DispatchWorkItem?
    private var isExporting = false
    private var isCompiling = false
    private var compiledInput: LatexInput?
    private var compileLog = ""
    private var compileMessage = ""
    private var engine = AppPreferences.defaultEngine
    private var format: DocumentFormat { document?.format ?? .markdown }
    private var latexInput: LatexInput {
        LatexInput(source: textView.string, fileURL: document?.fileURL, engine: engine, projectURL: document?.projectRoot)
    }
    private var hasCurrentPDF: Bool { compiledInput == latexInput && pdfView.document != nil }

    var automationView: String { ["source", "split", "preview"][mode.rawValue] }

    func automationSetView(_ name: String) throws {
        guard let index = ["source", "split", "preview"].firstIndex(of: name), let mode = Mode(rawValue: index) else {
            throw AutomationError(message: "View must be source, split, or preview.")
        }
        setMode(mode)
    }

    func automationCompile(engine selected: LatexEngine?, completion: @escaping ([String: Any]) -> Void) throws {
        guard format == .latex else { throw AutomationError(message: "Only LaTeX documents can be compiled.") }
        guard !isCompiling, !isExporting else { throw AutomationError(message: "The document is compiling or exporting. Try again after it finishes.") }
        if let selected {
            engine = selected
            enginePicker.selectItem(withTitle: selected.title)
        }
        compileLatex { [weak self] _ in
            guard let self else { return }
            completion(["success": self.compileMessage.isEmpty && self.hasCurrentPDF,
                        "message": self.compileMessage, "log": self.compileLog,
                        "pages": self.pdfView.document?.pageCount ?? 0])
        }
    }

    func automationExportPDF(to url: URL, completion: @escaping (Error?) -> Void) throws {
        guard !isCompiling, !isExporting else { throw AutomationError(message: "The document is compiling or exporting. Try again after it finishes.") }
        isExporting = true
        updateLatexStatus()
        let finish: (Error?) -> Void = { [weak self] error in
            self?.isExporting = false
            self?.updateLatexStatus()
            completion(error)
        }
        if format == .latex {
            compileLatex { [weak self] data in
                guard let self else { return }
                guard let data else {
                    finish(AutomationError(message: self.compileMessage.isEmpty
                        ? "The source changed during compilation. Read the document and export again." : self.compileMessage))
                    return
                }
                self.writePDF(to: url, latex: data, completion: finish)
            }
        } else {
            writePDF(to: url, latex: nil, completion: finish)
        }
    }

    private let formatPicker = NSPopUpButton()
    private let enginePicker = NSPopUpButton()
    private let recompileButton = NSButton()
    private let logButton = NSButton()
    private let previewTitle = label("Preview", size: 12, weight: .semibold)
    private let previewMessage = label("Press Recompile to build the PDF.", size: 13, color: Palette.muted)
    private let formatLabel = label("Markdown", size: 11, weight: .medium, color: Palette.purple)
    private let compileStatus = label("", size: 11, weight: .medium, color: Palette.muted)
    private let previewTools = row([], spacing: 6)
    private let latexPlaceholder = Surface(Palette.paper)
    private var linkButton: NSButton!
    private let positionLabel = label("Ln 1, Col 1", size: 11, color: Palette.muted, monospaced: true)
    private let countsLabel = label("0 words", size: 11, color: Palette.muted, monospaced: true)
    private let saveLabel = label("Manual save", size: 11, color: Palette.muted)
    private lazy var modeControl = NSSegmentedControl(labels: ["Source", "Split", "Preview"],
        trackingMode: .selectOne, target: self, action: #selector(changeMode(_:)))

    init(document: InklineDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("WorkspaceController uses programmatic layout") }

    override func loadView() {
        let root = Surface(Palette.chrome)
        root.frame = NSRect(x: 0, y: 0, width: 1120, height: 700)
        view = root

        textView.delegate = self
        let header = makeHeader()
        let footer = makeFooter()
        let sourcePane = NSViewController()
        sourcePane.view = makeSourcePane()
        let previewPane = NSViewController()
        previewPane.view = makePreviewPane()

        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        sourceItem = NSSplitViewItem(viewController: sourcePane)
        previewItem = NSSplitViewItem(viewController: previewPane)
        for item in [sourceItem!, previewItem!] {
            item.minimumThickness = 260
            item.canCollapse = true
            split.addSplitViewItem(item)
        }
        addChild(split)
        addChild(projectBrowser)
        projectBrowser.openDocument = { url in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        let body = NSView()
        for child in [projectBrowser.view, split.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(child)
        }
        projectWidth = projectBrowser.view.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            projectWidth,
            projectBrowser.view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            projectBrowser.view.topAnchor.constraint(equalTo: body.topAnchor),
            projectBrowser.view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            split.view.leadingAnchor.constraint(equalTo: projectBrowser.view.trailingAnchor),
            split.view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: body.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        for child in [header, body, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 63),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30)
        ])
        setDocumentURL(document?.fileURL)
        updateFormat()
        replaceDocumentText(document?.source ?? "")
        NotificationCenter.default.addObserver(self, selector: #selector(updateFonts),
                                               name: FontPreference.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(projectChanged),
                                               name: ProjectWorkspace.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateSaveStatus),
                                               name: InklineDocument.saveStatusDidChange, object: document)
        root.appearanceChanged = { [weak self] in self?.updateFonts() }
        projectChanged()
        updateFonts()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetDivider, mode == .split, split.splitView.bounds.width >= 680 {
            didSetDivider = true
            positionDivider()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateProjectWindow()
    }

    private func makeHeader() -> NSView {
        let header = Surface(Palette.chrome, edge: .bottom)
        let mark = Surface(Palette.lavender, radius: 10)
        let glyph = symbol("text.alignleft", color: Palette.purple, size: 17)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        mark.addSubview(glyph)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 36),
            mark.heightAnchor.constraint(equalToConstant: 36),
            glyph.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: mark.centerYAnchor)
        ])
        let brand = label("Inkline", size: 18, weight: .bold)
        let descriptor = label("DOCUMENT EDITOR", size: 9, weight: .semibold, color: Palette.muted)
        let wordmark = NSStackView(views: [brand, descriptor])
        wordmark.orientation = .vertical
        wordmark.alignment = .leading
        wordmark.spacing = 1
        let identity = row([mark, wordmark], spacing: 10)
        modeControl.selectedSegment = mode.rawValue
        modeControl.segmentStyle = .rounded
        modeControl.setAccessibilityLabel("Editor layout")
        for (index, width) in [70.0, 65.0, 74.0].enumerated() {
            modeControl.setWidth(width, forSegment: index)
        }

        let open = NSButton(title: "Open…", image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!,
                            target: NSDocumentController.shared, action: #selector(NSDocumentController.openDocument(_:)))
        open.imagePosition = .imageLeading
        open.bezelStyle = .rounded
        open.toolTip = "Open a document (⌘O)"
        formatPicker.addItems(withTitles: DocumentFormat.allCases.map(\.title))
        formatPicker.target = self
        formatPicker.action = #selector(changeFormat(_:))
        formatPicker.setAccessibilityLabel("Document format")
        let controls = row([formatPicker, open], spacing: 6)
        for child in [identity, modeControl, controls] {
            child.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(child)
        }
        NSLayoutConstraint.activate([
            identity.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 21),
            identity.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            modeControl.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            modeControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            controls.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }

    private func makeSourcePane() -> NSView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.backgroundColor = Palette.source
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 540)
        scroll.documentView = textView
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = LineRuler(scrollView: scroll, editor: textView)
        scroll.rulersVisible = true

        let title = row([symbol("chevron.left.forwardslash.chevron.right", color: Palette.purple),
                         label("Source", size: 12, weight: .semibold)], spacing: 7)
        linkButton = formatButton("link", title: "Link (⌘K)", action: #selector(insertLink(_:)))
        let tools = row([
            formatButton("number", title: "Heading (⇧⌘H)", action: #selector(insertHeading(_:))),
            formatButton("bold", title: "Bold (⌘B)", action: #selector(insertBold(_:))),
            formatButton("italic", title: "Italic (⌘I)", action: #selector(insertItalic(_:))),
            linkButton!,
            formatButton("tablecells", title: "Insert Table (⌥⌘T)", action: #selector(insertTable(_:)))
        ], spacing: 3)
        return pane(title: title, accessories: tools, content: scroll)
    }

    private func makePreviewPane() -> NSView {
        let title = row([symbol("doc.richtext", color: Palette.purple), previewTitle], spacing: 7)
        let live = row([symbol("circle.fill", color: Palette.teal, size: 6),
                        label("Live", size: 11, weight: .medium, color: Palette.teal)], spacing: 5)
        live.identifier = NSUserInterfaceItemIdentifier("live")
        previewTools.addArrangedSubview(live)
        enginePicker.addItems(withTitles: LatexEngine.allCases.map(\.title))
        enginePicker.selectItem(withTitle: engine.title)
        enginePicker.controlSize = .small
        enginePicker.target = self
        enginePicker.action = #selector(changeEngine(_:))
        enginePicker.setAccessibilityLabel("LaTeX compiler")
        logButton.title = "Log"
        logButton.bezelStyle = .rounded
        logButton.controlSize = .small
        logButton.target = self
        logButton.action = #selector(showCompileLog(_:))
        recompileButton.title = "Recompile"
        recompileButton.bezelStyle = .rounded
        recompileButton.controlSize = .small
        recompileButton.target = self
        recompileButton.action = #selector(recompile(_:))
        recompileButton.toolTip = "Compile LaTeX (⌘Return)"
        for control in [enginePicker, logButton, recompileButton] { previewTools.addArrangedSubview(control) }

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = Palette.chrome
        pdfView.setAccessibilityLabel("Compiled LaTeX PDF")
        let placeholderTitle = label("LaTeX PDF Preview", size: 20, weight: .semibold)
        previewMessage.alignment = .center
        previewMessage.maximumNumberOfLines = 4
        previewMessage.lineBreakMode = .byWordWrapping
        let placeholder = NSStackView(views: [placeholderTitle, previewMessage])
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 9
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        latexPlaceholder.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: latexPlaceholder.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: latexPlaceholder.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: latexPlaceholder.widthAnchor, constant: -36)
        ])

        let content = NSView()
        for child in [preview.webView, htmlPreview.webView, pdfView, latexPlaceholder] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: content.topAnchor),
                child.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
        }
        return pane(title: title, accessories: previewTools, content: content)
    }

    private func pane(title: NSView, accessories: NSView, content: NSView) -> NSView {
        let pane = NSView()
        let bar = Surface(Palette.chrome, edge: .bottom)
        for child in [title, accessories, bar, content] { child.translatesAutoresizingMaskIntoConstraints = false }
        bar.addSubview(title)
        bar.addSubview(accessories)
        pane.addSubview(bar)
        pane.addSubview(content)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: pane.topAnchor),
            bar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            title.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            title.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            accessories.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -17),
            accessories.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor)
        ])
        return pane
    }

    private func makeFooter() -> NSView {
        let footer = Surface(Palette.chrome, edge: .top)
        let type = row([symbol("doc.text", color: Palette.purple, size: 11), formatLabel], spacing: 5)
        let stats = row([saveLabel, compileStatus, countsLabel, positionLabel], spacing: 18)
        for child in [type, stats] {
            child.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(child)
        }
        NSLayoutConstraint.activate([
            type.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            type.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            stats.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -18),
            stats.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        return footer
    }

    private func formatButton(_ name: String, title: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = Palette.muted
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    func setDocumentURL(_ url: URL?) {
        preview.setDocumentURL(url, projectRoot: document?.projectRoot)
        if isViewLoaded {
            updateLatexStatus()
            if format == .html { renderPreview() }
        }
    }

    func updateFormat() {
        guard isViewLoaded else { return }
        let isLatex = format == .latex
        formatPicker.selectItem(withTitle: format.title)
        textView.setAccessibilityLabel("\(format.title) source editor")
        formatLabel.stringValue = format.title
        previewTitle.stringValue = isLatex ? "PDF" : "Preview"
        for control in previewTools.arrangedSubviews {
            control.isHidden = (control.identifier?.rawValue == "live") == isLatex
        }
        linkButton.isHidden = isLatex
        preview.webView.isHidden = format != .markdown
        htmlPreview.webView.isHidden = format != .html
        updateLatexStatus()
        refresh()
    }

    @objc private func changeFormat(_ sender: NSPopUpButton) {
        guard let document, DocumentFormat.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let selected = DocumentFormat.allCases[sender.indexOfSelectedItem]
        guard selected != format else { return }
        let source = textView.string.isEmpty ? selected.starter : textView.string
        if document.fileURL != nil {
            sender.selectItem(withTitle: format.title)
            do {
                try InklineDocument.openUntitled(format: selected, source: source)
            } catch {
                presentError(error)
            }
            return
        }
        document.fileType = selected.rawValue
        if source != textView.string {
            textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
        }
    }

    @objc private func updateFonts() {
        textView.updateFont()
        preview.updateFont()
        pdfView.backgroundColor = Palette.chrome
        refresh()
        updateSaveStatus()
        func redraw(_ node: NSView) {
            node.needsDisplay = true
            for child in node.subviews { redraw(child) }
        }
        redraw(view)
    }

    @objc private func updateSaveStatus() {
        if AppPreferences.autosaveEnabled, let error = document?.autosaveError {
            saveLabel.stringValue = "Autosave failed"
            saveLabel.toolTip = error
        } else {
            saveLabel.stringValue = AppPreferences.autosaveEnabled ? "Autosave on" : "Manual save"
            saveLabel.toolTip = AppPreferences.autosaveEnabled ? "Saved files are written after you stop typing." : "Press ⌘S to save changes."
        }
    }

    @objc private func projectChanged() {
        projectBrowser.view.isHidden = ProjectWorkspace.shared.rootURL == nil
        projectWidth.constant = ProjectWorkspace.shared.rootURL == nil ? 0 : 220
        preview.setDocumentURL(document?.fileURL, projectRoot: document?.projectRoot)
        compiledInput = nil
        updateProjectWindow()
        renderPreview()
        projectBrowser.reload()
    }

    private func updateProjectWindow() {
        guard let window = view.window else { return }
        let hasProject = ProjectWorkspace.shared.rootURL != nil
        window.contentMinSize.width = hasProject ? 920 : 680
        if hasProject, window.frame.width < 920 {
            var frame = window.frame
            frame.size.width = 920
            window.setFrame(frame, display: true)
        }
        window.subtitle = document?.projectRoot?.lastPathComponent ?? ""
    }

    @objc func chooseSourceFont(_ sender: Any?) {
        if let window = view.window { FontPreference.source.choose(in: window) }
    }

    @objc func choosePreviewFont(_ sender: Any?) {
        if let window = view.window { FontPreference.preview.choose(in: window) }
    }

    func replaceDocumentText(_ source: String) {
        refreshTask?.cancel()
        textView.string = source
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.updateLines()
        updatePosition()
        refresh()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { document?.undoManager }

    func textDidChange(_ notification: Notification) {
        document?.source = textView.string
        textView.updateLines()
        updatePosition()
        refreshTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: task)
    }

    func textViewDidChangeSelection(_ notification: Notification) { updatePosition() }

    private func updatePosition() {
        let text = textView.string as NSString
        let offset = min(textView.selectedRange().location, text.length)
        let line = textView.lineIndex(at: offset)
        let start = textView.lineStarts[line]
        guard start <= offset else { return }
        let column = text.substring(with: NSRange(location: start, length: offset - start)).count + 1
        positionLabel.stringValue = "Ln \(line + 1), Col \(column)"
    }

    private func refresh() {
        switch format {
        case .latex:
            LatexHighlight.apply(to: textView)
            updateLatexStatus()
        case .markdown:
            MarkdownHighlight.apply(to: textView)
        case .html:
            HTMLHighlight.apply(to: textView)
        }
        renderPreview()
        let source = textView.string
        var words = 0
        source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: [.byWords, .substringNotRequired]) {
            _, _, _, _ in words += 1
        }
        countsLabel.stringValue = "\(words) \(words == 1 ? "word" : "words")"
    }

    private func renderPreview() {
        guard mode != .source else { return }
        switch format {
        case .markdown:
            preview.render(textView.string)
        case .html:
            htmlPreview.render(textView.string, documentURL: document?.fileURL, projectRoot: document?.projectRoot)
        case .latex:
            break
        }
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        if let selected = Mode(rawValue: sender.selectedSegment) { setMode(selected) }
    }

    @objc func showSource(_ sender: Any?) { setMode(.source) }
    @objc func showSplit(_ sender: Any?) { setMode(.split) }
    @objc func showPreview(_ sender: Any?) { setMode(.preview) }

    private func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        if mode == .split, split.splitView.bounds.width > 0 {
            sourceFraction = sourceItem.viewController.view.frame.width / split.splitView.bounds.width
        }
        mode = newMode
        modeControl.selectedSegment = mode.rawValue
        if mode != .preview { sourceItem.isCollapsed = false }
        if mode != .source { previewItem.isCollapsed = false }
        if mode == .preview { sourceItem.isCollapsed = true }
        if mode == .source { previewItem.isCollapsed = true }
        if mode == .split {
            split.splitView.layoutSubtreeIfNeeded()
            positionDivider()
        }
        renderPreview()
        positionLabel.isHidden = mode == .preview
        let output: NSView
        switch format {
        case .latex: output = pdfView
        case .markdown: output = preview.webView
        case .html: output = htmlPreview.webView
        }
        view.window?.makeFirstResponder(mode == .preview ? output : textView)
    }

    private func positionDivider() {
        let divider = split.splitView
        let available = divider.bounds.width - divider.dividerThickness
        let left = sourceItem.minimumThickness
        let right = available - previewItem.minimumThickness
        divider.setPosition(max(left, min(right, available * sourceFraction)), ofDividerAt: 0)
    }

    private func focusEditor() {
        if mode == .preview { setMode(.split) }
        view.window?.makeFirstResponder(textView)
    }

    @objc func showEditorFind(_ sender: Any?) {
        focusEditor()
        let command = NSMenuItem()
        command.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(command)
    }

    @objc func insertHeading(_ sender: Any?) {
        if format == .latex {
            wrap(#"\section{"#, "}", placeholder: "Section title")
            return
        }
        if format == .html {
            wrap("<h1>", "</h1>", placeholder: "Heading")
            return
        }
        focusEditor()
        let selection = textView.selectedRange()
        let line = textView.lineIndex(at: selection.location)
        let start = textView.lineStarts[line]
        textView.insertText("# ", replacementRange: NSRange(location: start, length: 0))
        textView.setSelectedRange(NSRange(location: selection.location + 2, length: selection.length))
    }

    @objc func insertBold(_ sender: Any?) {
        switch format {
        case .latex: wrap(#"\textbf{"#, "}", placeholder: "bold text")
        case .markdown: wrap("**", "**", placeholder: "bold text")
        case .html: wrap("<strong>", "</strong>", placeholder: "bold text")
        }
    }
    @objc func insertItalic(_ sender: Any?) {
        switch format {
        case .latex: wrap(#"\textit{"#, "}", placeholder: "italic text")
        case .markdown: wrap("*", "*", placeholder: "italic text")
        case .html: wrap("<em>", "</em>", placeholder: "italic text")
        }
    }
    @objc func insertLink(_ sender: Any?) {
        if format == .html {
            wrap(#"<a href="https://example.com">"#, "</a>", placeholder: "link text")
        } else {
            wrap("[", "](https://example.com)", placeholder: "link text")
        }
    }

    @objc func insertTable(_ sender: Any?) {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let builder = TableBuilder(format: format)
        tableBuilder = builder
        builder.present(on: window) { [weak self] source in
            guard let self else { return }
            self.focusEditor()
            let location = self.textView.selectedRange().location
            let prefix = location == 0 ? "" : "\n\n"
            self.textView.insertText(prefix + source + "\n", replacementRange: NSRange(location: location, length: 0))
            self.textView.undoManager?.setActionName("Insert Table")
        }
    }

    @objc func insertFigure(_ sender: Any?) {
        guard let window = view.window else { return }
        guard document?.fileURL != nil || document?.projectRoot != nil else {
            presentError(AutomationError(message: "Save the document or open a project folder before inserting a figure."))
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Insert Figure"
        panel.allowedContentTypes = [.image]
        panel.directoryURL = document?.projectRoot ?? document?.fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let base = self.document?.fileURL?.deletingLastPathComponent() ?? self.document?.projectRoot
            guard let base,
                  previewAsset(at: ProjectWorkspace.relativePath(of: url, from: base), in: base,
                               projectRoot: self.document?.projectRoot) != nil else {
                self.presentError(AutomationError(message: "Choose a figure within the document folder or selected project folder."))
                return
            }
            let path = ProjectWorkspace.relativePath(of: url, from: base)
            if self.format == .latex, path.contains("{") || path.contains("}") {
                self.presentError(AutomationError(message: "Rename this figure to remove braces before inserting it in LaTeX."))
                return
            }
            let markup: String
            switch self.format {
            case .markdown:
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                markup = "![\(url.deletingPathExtension().lastPathComponent)](\(encoded))"
            case .html:
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                markup = #"<img src=""# + TableDraft.htmlEscape(encoded) + #"" alt=""# +
                    TableDraft.htmlEscape(url.deletingPathExtension().lastPathComponent) + #"">"#
            case .latex:
                markup = #"\includegraphics[width=\linewidth]{\detokenize{"# + path + "}}"
            }
            self.focusEditor()
            self.textView.insertText(markup, replacementRange: self.textView.selectedRange())
            self.textView.undoManager?.setActionName("Insert Figure")
        }
    }

    private func wrap(_ prefix: String, _ suffix: String, placeholder: String) {
        focusEditor()
        let selection = textView.selectedRange()
        let original = (textView.string as NSString).substring(with: selection)
        let text = original.isEmpty ? placeholder : original
        textView.insertText(prefix + text + suffix, replacementRange: selection)
        let content = NSRange(location: selection.location + prefix.utf16.count, length: text.utf16.count)
        textView.setSelectedRange(content)
    }

    @objc private func changeEngine(_ sender: NSPopUpButton) {
        let engines = LatexEngine.allCases
        guard engines.indices.contains(sender.indexOfSelectedItem) else { return }
        engine = engines[sender.indexOfSelectedItem]
        compileMessage = ""
        updateLatexStatus()
    }

    private func updateLatexStatus() {
        let isLatex = format == .latex
        compileStatus.isHidden = !isLatex && !isExporting
        latexPlaceholder.isHidden = !isLatex || pdfView.document != nil
        pdfView.isHidden = !isLatex || pdfView.document == nil
        formatPicker.toolTip = document?.fileURL == nil ? "Choose a document format"
            : "Open a copy in a different format"
        formatPicker.isEnabled = !isExporting && !isCompiling
        enginePicker.isEnabled = !isCompiling && !isExporting
        recompileButton.isEnabled = !isCompiling && !isExporting
        logButton.isEnabled = !compileLog.isEmpty && !isExporting
        compileStatus.toolTip = compileMessage.isEmpty ? nil : compileMessage
        if !isLatex {
            compileStatus.stringValue = "Exporting PDF…"
        } else if isCompiling {
            compileStatus.stringValue = "Compiling…"
            previewMessage.stringValue = "Building with \(engine.title)…"
        } else if compileMessage.isEmpty, hasCurrentPDF, let pages = pdfView.document?.pageCount {
            compileStatus.stringValue = "Compiled · \(pages) \(pages == 1 ? "page" : "pages")"
        } else {
            compileStatus.stringValue = !compileMessage.isEmpty ? "Compile failed"
                : (pdfView.document == nil ? "Ready to compile" : "PDF out of date")
            previewMessage.stringValue = compileMessage.isEmpty ? "Press Recompile to build the PDF." : compileMessage
        }
    }

    @objc func recompile(_ sender: Any?) {
        guard format == .latex, !isExporting, !isCompiling else { return }
        if mode == .source { setMode(.split) }
        compileLatex()
    }

    private func compileLatex(completion: ((Data?) -> Void)? = nil) {
        let input = latexInput
        isCompiling = true
        compileMessage = ""
        updateLatexStatus()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LatexCompiler.compile(input)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isCompiling = false
                self.compileLog = result.log
                let data: Data?
                if let rendered = result.pdf, let pdf = PDFDocument(data: rendered), pdf.pageCount > 0 {
                    data = rendered
                    self.compiledInput = input
                    self.pdfView.document = pdf
                    self.pdfView.autoScales = true
                } else {
                    data = nil
                    self.compileMessage = result.pdf == nil ? result.message : "The compiler produced an unreadable PDF."
                }
                self.updateLatexStatus()
                completion?(self.hasCurrentPDF ? data : nil)
            }
        }
    }

    @objc func showCompileLog(_ sender: Any?) {
        guard let window = view.window, !compileLog.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "LaTeX Compile Log"
        alert.addButton(withTitle: "Close")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 530, height: 270)
        let text = scroll.documentView as! NSTextView
        text.string = compileLog
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = false
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard !isExporting, !isCompiling, let document, let window = view.window else { return }
        isExporting = true
        updateLatexStatus()
        if format == .latex {
            compileLatex { [weak self, weak window, weak document] data in
                guard let self, let window, let document else { return }
                if let data {
                    self.choosePDFDestination(window: window, document: document, latex: data)
                } else {
                    let message = self.compileMessage.isEmpty
                        ? "The source changed during compilation. Export again to use the latest text."
                        : self.compileMessage
                    self.finishExport(error: NSError(domain: "Inkline.LaTeX", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message]))
                }
            }
        } else {
            choosePDFDestination(window: window, document: document, latex: nil)
        }
    }

    private func choosePDFDestination(window: NSWindow, document: InklineDocument, latex: Data?) {
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName
        panel.directoryURL = document.fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.finishExport(error: nil)
                return
            }
            self.writePDF(to: url, latex: latex) { [weak self] error in
                self?.finishExport(error: error)
            }
        }
    }

    private func writePDF(to url: URL, latex: Data?, completion: @escaping (Error?) -> Void) {
        if let latex {
            do {
                try latex.write(to: url, options: .atomic)
                completion(nil)
            } catch {
                completion(error)
            }
        } else if format == .html {
            htmlPreview.exportPDF(source: textView.string, documentURL: document?.fileURL, projectRoot: document?.projectRoot,
                                  to: url, completion: completion)
        } else {
            preview.exportPDF(source: textView.string, to: url, completion: completion)
        }
    }

    private func finishExport(error: Error?) {
        isExporting = false
        updateLatexStatus()
        if let error { presentError(error) }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(recompile(_:)):
            return format == .latex && !isCompiling && !isExporting
        case #selector(showCompileLog(_:)):
            return format == .latex && !compileLog.isEmpty && !isExporting
        case #selector(exportPDF(_:)):
            return !isCompiling && !isExporting
        case #selector(choosePreviewFont(_:)):
            return format == .markdown
        case #selector(insertLink(_:)):
            return format != .latex
        default:
            return true
        }
    }
}

private final class Surface: NSView {
    enum Edge { case top, bottom }
    private let color: () -> NSColor
    private let edge: Edge?
    private let radius: CGFloat

    var appearanceChanged: (() -> Void)?

    init(_ color: @autoclosure @escaping () -> NSColor, edge: Edge? = nil, radius: CGFloat = 0) {
        self.color = color
        self.edge = edge
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("Surface uses programmatic layout") }

    override func draw(_ dirtyRect: NSRect) {
        color().setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if let edge {
            Palette.line.setFill()
            let pixel = 1 / (window?.backingScaleFactor ?? 2)
            let y = edge == .top ? bounds.maxY - pixel : bounds.minY
            NSRect(x: bounds.minX, y: y, width: bounds.width, height: pixel).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        appearanceChanged?()
    }
}

private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = Palette.ink, monospaced: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = monospaced ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
        : .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    return label
}

private func symbol(_ name: String, color: NSColor, size: CGFloat = 13) -> NSImageView {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    view.contentTintColor = color
    return view
}
