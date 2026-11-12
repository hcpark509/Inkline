import AppKit
import CryptoKit

enum DocumentFormat: String, CaseIterable {
    case markdown = "net.daringfireball.markdown"
    case latex = "org.tug.tex"
    case html = "public.html"

    var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .latex: return "LaTeX"
        case .html: return "HTML"
        }
    }

    var starter: String {
        switch self {
        case .markdown: return ""
        case .latex: return LatexCompiler.template
        case .html: return HTMLPreviewController.template
        }
    }

    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "tex", "html", "htm"]
}

@objc(InklineDocument)
final class InklineDocument: NSDocument {
    private static let byteOrderMarks: [(bytes: Data, encoding: String.Encoding)] = [
        (Data([0x00, 0x00, 0xFE, 0xFF]), .utf32BigEndian),
        (Data([0xFF, 0xFE, 0x00, 0x00]), .utf32LittleEndian),
        (Data([0xEF, 0xBB, 0xBF]), .utf8),
        (Data([0xFE, 0xFF]), .utf16BigEndian),
        (Data([0xFF, 0xFE]), .utf16LittleEndian)
    ]

    var source = "" {
        didSet { if oldValue != source { queueAutosave() } }
    }
    let automationID = UUID().uuidString
    var revision: String {
        SHA256.hash(data: Data(((fileType ?? "") + "\0" + source).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    var format: DocumentFormat { DocumentFormat(rawValue: fileType ?? "") ?? .markdown }
    private var encoding: String.Encoding = .utf8
    private var byteOrderMark = Data()
    private weak var editorController: WorkspaceController?
    private var pendingAutosave: DispatchWorkItem?
    private var autosaveInProgress = false
    private(set) var autosaveError: String?
    static let saveStatusDidChange = Notification.Name("InklineSaveStatusChanged")
    var projectRoot: URL? { ProjectWorkspace.shared.root(for: fileURL) }

    override class var autosavesInPlace: Bool { AppPreferences.autosaveEnabled }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: AppPreferences.didChange, object: nil)
    }

    @objc private func settingsChanged() { queueAutosave() }

    func queueAutosave() {
        pendingAutosave?.cancel()
        guard AppPreferences.autosaveEnabled, fileURL != nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, AppPreferences.autosaveEnabled, self.isDocumentEdited, !self.autosaveInProgress else { return }
            self.autosave(withImplicitCancellability: true) { _ in }
        }
        pendingAutosave = task
        DispatchQueue.main.asyncAfter(deadline: .now() + AppPreferences.autosaveDelay, execute: task)
    }

    override func autosave(withImplicitCancellability cancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        guard AppPreferences.autosaveEnabled, fileURL != nil else { completionHandler(nil); return }
        guard !autosaveInProgress else { completionHandler(nil); return }
        autosaveInProgress = true
        super.autosave(withImplicitCancellability: cancellable) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { completionHandler(error); return }
                self.autosaveInProgress = false
                self.autosaveError = error?.localizedDescription
                NotificationCenter.default.post(name: Self.saveStatusDidChange, object: self)
                completionHandler(error)
                if error == nil, self.isDocumentEdited { self.queueAutosave() }
            }
        }
    }

    override func close() {
        pendingAutosave?.cancel()
        super.close()
    }

    override var fileURL: URL? {
        didSet {
            editorController?.setDocumentURL(fileURL)
            queueAutosave()
        }
    }

    override var fileType: String? {
        didSet {
            if oldValue != fileType { editorController?.updateFormat() }
        }
    }

    @discardableResult
    static func openUntitled(format: DocumentFormat, source: String) throws -> InklineDocument {
        let controller = NSDocumentController.shared
        let document = try controller.makeUntitledDocument(ofType: format.rawValue) as! InklineDocument
        document.source = source
        if !source.isEmpty { document.updateChangeCount(.changeDone) }
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        return document
    }

    var workspace: WorkspaceController {
        if editorController == nil { makeWindowControllers() }
        return editorController!
    }

    func checkRevision(_ expected: String) throws {
        guard expected == revision else {
            throw AutomationError(message: "The document changed since it was read. Read it again before editing or exporting.")
        }
    }

    func automationSnapshot(includeSource: Bool = false) -> [String: Any] {
        var value: [String: Any] = [
            "document_id": automationID, "title": displayName ?? "Untitled", "revision": revision,
            "format": format.title.lowercased(), "modified": isDocumentEdited,
            "resource_uri": "inkline://document/" + automationID,
            "active": NSDocumentController.shared.currentDocument === self
        ]
        if let fileURL { value["path"] = fileURL.path }
        if let projectRoot { value["project_root"] = projectRoot.path }
        value["autosave_enabled"] = AppPreferences.autosaveEnabled
        if let editorController {
            let selection = editorController.textView.selectedRange()
            value["selection"] = ["utf16_location": selection.location, "utf16_length": selection.length]
            value["view"] = editorController.automationView
        }
        if includeSource { value["source"] = source }
        return value
    }

    func automationReplace(_ text: String) throws {
        guard text != source else { return }
        let editor = workspace.textView
        guard !editor.hasMarkedText() else {
            throw AutomationError(message: "Text input is in progress. Finish the current input before editing through MCP.")
        }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.isEditable else {
            throw AutomationError(message: "The editor could not accept this change.")
        }
        editor.breakUndoCoalescing()
        editor.insertText(text, replacementRange: range)
        editor.breakUndoCoalescing()
        undoManager?.setActionName("MCP Edit")
    }

    override func makeWindowControllers() {
        let editor = WorkspaceController(document: self)
        editorController = editor
        let frame = NSRect(x: 0, y: 0, width: 1120, height: 700)
        let window = InklineWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 680, height: 420)
        window.tabbingMode = .disallowed
        window.contentViewController = editor
        window.initialFirstResponder = editor.textView
        addWindowController(NSWindowController(window: window))
        window.center()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let format = Self.byteOrderMarks.first { data.starts(with: $0.bytes) }
        let mark = format?.bytes ?? Data()
        let detectedEncoding = format?.encoding ?? .utf8
        guard let text = String(data: data.dropFirst(mark.count), encoding: detectedEncoding) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        source = text
        encoding = detectedEncoding
        byteOrderMark = mark
        editorController?.replaceDocumentText(text)
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let encoded = source.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return byteOrderMark + encoded
    }
}
