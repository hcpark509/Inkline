import AppKit
import CoreFoundation

final class AutomationBridge {
    var isEnabled = !UserDefaults.standard.bool(forKey: "MCPAccessPaused") {
        didSet { UserDefaults.standard.set(!isEnabled, forKey: "MCPAccessPaused") }
    }
    private(set) var lastAction = "No requests yet"
    private var port: CFMessagePort?
    private let queue = DispatchQueue(label: "com.inkline.automation")

    func start() {
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, MCPServer.portName as CFString, { _, _, input, info in
            guard let input, let info else { return nil }
            let bridge = Unmanaged<AutomationBridge>.fromOpaque(info).takeUnretainedValue()
            let output = bridge.receive(input as Data)
            return Unmanaged.passRetained(output as CFData)
        }, &context, nil)
        if let port { CFMessagePortSetDispatchQueue(port, queue) }
        else { NSLog("Inkline MCP bridge could not start for this app instance.") }
    }

    func stop() {
        if let port { CFMessagePortInvalidate(port) }
        port = nil
    }

    private func receive(_ data: Data) -> Data {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var output: [String: Any] = ["error": "Inkline timed out. Read the document before retrying."]
        let deadline = Date().addingTimeInterval(53)
        DispatchQueue.main.async {
            guard Date() < deadline else { done.signal(); return }
            self.handle(data) { result in
                lock.lock()
                output = result
                lock.unlock()
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + .seconds(53))
        lock.lock()
        defer { lock.unlock() }
        return (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
    }

    private func handle(_ data: Data, completion: @escaping ([String: Any]) -> Void) {
        var isTool = false
        do {
            guard data.count <= 16 * 1024 * 1024,
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String,
                  let params = request["params"] as? [String: Any],
                  let read = request["readRoots"] as? [String],
                  let write = request["writeRoots"] as? [String] else {
                throw AutomationError(message: "Invalid automation request.")
            }
            isTool = method == "tools/call"
            guard isEnabled else { throw AutomationError(message: "MCP access is paused in Inkline's MCP menu.") }
            let scope = try AutomationScope(read: read, write: write)
            switch method {
            case "resources/list":
                completion(["resources": documents(scope).map { document -> [String: Any] in
                    ["uri": "inkline://document/" + document.automationID, "name": document.displayName ?? "Untitled",
                     "mimeType": "text/plain", "description": "Current editor source, including unsaved changes."]
                }])
            case "resources/read":
                let uri = try string("uri", in: params)
                guard let url = URL(string: uri), url.scheme == "inkline", url.host == "document" else {
                    throw AutomationError(message: "Unknown Inkline resource.")
                }
                let document = try findDocument(String(url.path.dropFirst()), scope: scope)
                completion(["contents": [["uri": uri, "mimeType": "text/plain", "text": document.source]]])
            case "tools/call":
                let name = try string("name", in: params)
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                lastAction = name.replacingOccurrences(of: "_", with: " ")
                try call(name, arguments: arguments, scope: scope) { result in
                    switch result {
                    case .success(let value): completion(MCPServer.toolResult(value))
                    case .failure(let error): completion(MCPServer.toolError(error))
                    }
                }
            default:
                throw AutomationError(message: "Unknown automation method.")
            }
        } catch {
            completion(isTool ? MCPServer.toolError(error) : ["error": error.localizedDescription])
        }
    }

    private func documents(_ scope: AutomationScope) -> [InklineDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? InklineDocument }
            .filter { document in document.fileURL.map { scope.permits($0, write: false) } ?? true }
    }

    private func findDocument(_ id: String, scope: AutomationScope, write: Bool = false) throws -> InklineDocument {
        guard let document = documents(scope).first(where: { $0.automationID == id }) else {
            throw AutomationError(message: "Document is closed or outside the configured read roots. Run list_documents again.")
        }
        if write, let url = document.fileURL { try scope.require(url, write: true) }
        return document
    }

    private func string(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String else { throw AutomationError(message: "Missing string argument: \(key)") }
        return value
    }

    private func format(in arguments: [String: Any]) throws -> DocumentFormat {
        switch try string("format", in: arguments) {
        case "markdown": return .markdown
        case "latex": return .latex
        case "html": return .html
        default: throw AutomationError(message: "Format must be markdown, latex, or html.")
        }
    }

    private func path(_ value: String, scope: AutomationScope, write: Bool) throws -> URL {
        guard value.hasPrefix("/"), !value.contains("\0") else { throw AutomationError(message: "Use an absolute file path.") }
        let url = try canonicalAutomationURL(URL(fileURLWithPath: value))
        try scope.require(url, write: write)
        return url
    }

    private func checkDestination(_ url: URL, current: URL?, overwrite: Bool) throws {
        guard (try? url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw AutomationError(message: "The destination folder must already exist.")
        }
        let current = try current.map(canonicalAutomationURL)
        let others = NSDocumentController.shared.documents.filter {
            let file = $0.fileURL.flatMap { try? canonicalAutomationURL($0) }
            return file == url && file != current
        }
        guard others.isEmpty else { throw AutomationError(message: "The destination is open in another document.") }
        if FileManager.default.fileExists(atPath: url.path), url != current {
            guard overwrite, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw AutomationError(message: "The destination already exists. Choose another path or explicitly pass overwrite=true.")
            }
        }
    }

    private func call(_ name: String, arguments: [String: Any], scope: AutomationScope,
                      completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        func success(_ document: InklineDocument) { completion(.success(document.automationSnapshot())) }
        switch name {
        case "list_documents":
            completion(.success(["documents": documents(scope).map { $0.automationSnapshot() },
                                 "read_roots": scope.readRoots.map(\.path), "write_roots": scope.writeRoots.map(\.path),
                                 "app_path": Bundle.main.bundleURL.path, "app_version": MCPServer.version]))
        case "create_document":
            let selected = try format(in: arguments)
            let source = try arguments["source"].map { _ in try string("source", in: arguments) } ?? selected.starter
            success(try InklineDocument.openUntitled(format: selected, source: source))
        case "open_document":
            let url = try path(string("path", in: arguments), scope: scope, write: false)
            guard DocumentFormat.extensions.contains(url.pathExtension.lowercased()) else {
                throw AutomationError(message: "Inkline opens Markdown, LaTeX, and HTML files.")
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let error { completion(.failure(error)) }
                else if let document = document as? InklineDocument { success(document) }
                else { completion(.failure(AutomationError(message: "Could not open the document."))) }
            }
        case "read_document":
            let document = try findDocument(string("document_id", in: arguments), scope: scope)
            completion(.success(document.automationSnapshot(includeSource: true)))
        case "close_document":
            let document = try findDocument(string("document_id", in: arguments), scope: scope)
            guard !document.isDocumentEdited else {
                throw AutomationError(message: "The document has unsaved changes. Save it before closing through MCP.")
            }
            document.close()
            completion(.success(["closed": true, "document_id": document.automationID]))
        case "replace_document", "edit_document":
            let document = try findDocument(string("document_id", in: arguments), scope: scope, write: true)
            try document.checkRevision(string("expected_revision", in: arguments))
            var source: String
            if name == "replace_document" {
                source = try string("source", in: arguments)
            } else {
                let old = try string("old_text", in: arguments)
                let replacement = try string("new_text", in: arguments)
                guard !old.isEmpty, let match = document.source.range(of: old),
                      document.source.range(of: old, range: document.source.index(after: match.lowerBound)..<document.source.endIndex) == nil else {
                    throw AutomationError(message: "old_text must match exactly one occurrence. Read the document and use a larger exact match.")
                }
                source = document.source
                source.replaceSubrange(match, with: replacement)
            }
            try document.automationReplace(source)
            success(document)
        case "set_view":
            let document = try findDocument(string("document_id", in: arguments), scope: scope)
            try document.workspace.automationSetView(string("view", in: arguments))
            success(document)
        case "set_format":
            let document = try findDocument(string("document_id", in: arguments), scope: scope)
            let selected = try format(in: arguments)
            if selected == document.format { success(document) }
            else if document.fileURL != nil {
                success(try InklineDocument.openUntitled(format: selected, source: document.source))
            } else {
                document.fileType = selected.rawValue
                success(document)
            }
        case "save_document":
            let document = try findDocument(string("document_id", in: arguments), scope: scope, write: true)
            let url: URL
            if let supplied = arguments["path"] as? String { url = try path(supplied, scope: scope, write: true) }
            else if let existing = document.fileURL { url = try canonicalAutomationURL(existing) }
            else { throw AutomationError(message: "An untitled document needs an absolute save path.") }
            let ext = url.pathExtension.lowercased()
            let valid = document.format == .markdown ? ["md", "markdown", "mdown", "mkd", "mkdn"]
                : (document.format == .latex ? ["tex"] : ["html", "htm"])
            guard valid.contains(ext) else { throw AutomationError(message: "The filename extension must match the document format.") }
            try checkDestination(url, current: document.fileURL, overwrite: arguments["overwrite"] as? Bool ?? false)
            document.save(to: url, ofType: document.format.rawValue,
                          for: document.fileURL == url ? .saveOperation : .saveAsOperation) { error in
                if let error { completion(.failure(error)) } else { success(document) }
            }
        case "compile_latex":
            let document = try findDocument(string("document_id", in: arguments), scope: scope)
            let engine: LatexEngine?
            if let value = arguments["engine"] as? String {
                guard let selected = LatexEngine(rawValue: value) else { throw AutomationError(message: "Unknown LaTeX engine.") }
                engine = selected
            } else { engine = nil }
            try document.workspace.automationCompile(engine: engine) { value in completion(.success(value)) }
        case "export_pdf":
            let document = try findDocument(string("document_id", in: arguments), scope: scope)
            try document.checkRevision(string("expected_revision", in: arguments))
            let url = try path(string("path", in: arguments), scope: scope, write: true)
            guard url.pathExtension.lowercased() == "pdf" else { throw AutomationError(message: "The export path must end in .pdf.") }
            try checkDestination(url, current: nil, overwrite: arguments["overwrite"] as? Bool ?? false)
            try document.workspace.automationExportPDF(to: url) { error in
                if let error { completion(.failure(error)) }
                else { completion(.success(["path": url.path, "document": document.automationSnapshot()])) }
            }
        default:
            throw AutomationError(message: "Unknown Inkline tool: \(name)")
        }
    }
}
