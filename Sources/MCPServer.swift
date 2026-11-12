import AppKit
import CoreFoundation
import CryptoKit

func canonicalAutomationURL(_ url: URL) throws -> URL {
    func existing(_ path: String) -> URL? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
    if let resolved = existing(url.path) { return resolved }
    var info = stat()
    guard lstat(url.path, &info) != 0, errno == ENOENT,
          let parent = existing(url.deletingLastPathComponent().path) else {
        throw AutomationError(message: "The path is inaccessible, has a broken symlink, or its parent folder does not exist.")
    }
    return parent.appendingPathComponent(url.lastPathComponent)
}

struct AutomationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AutomationScope {
    let readRoots: [URL]
    let writeRoots: [URL]

    init(read: [String], write: [String]) throws {
        func roots(_ paths: [String]) throws -> [URL] {
            try paths.map { path in
                guard path.hasPrefix("/") else { throw AutomationError(message: "Automation roots must be absolute paths.") }
                let url = try canonicalAutomationURL(URL(fileURLWithPath: path))
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    throw AutomationError(message: "Automation root is not an existing directory: \(path)")
                }
                return url
            }
        }
        let writes = try roots(write)
        writeRoots = writes
        readRoots = try roots(read).filter { !writes.contains($0) } + writes
    }

    func permits(_ url: URL, write: Bool) -> Bool {
        guard let resolved = try? canonicalAutomationURL(url) else { return false }
        let path = resolved.pathComponents
        return (write ? writeRoots : readRoots).contains { root in
            path.count > root.pathComponents.count && path.starts(with: root.pathComponents)
        }
    }

    func require(_ url: URL, write: Bool) throws {
        guard permits(url, write: write) else {
            throw AutomationError(message: "Path is outside the configured automation \(write ? "write" : "read") roots.")
        }
    }
}

enum MCPServer {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let version = "1.4"

    static var portName: String {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return "com.inkline.mcp.\(geteuid()).\(digest)"
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            var read: [String] = []
            var write: [String] = []
            var index = 0
            while index < arguments.count {
                let option = arguments[index]
                guard index + 1 < arguments.count else { throw AutomationError(message: "Missing path for \(option).") }
                switch option {
                case "--automation-read-root": read.append(arguments[index + 1])
                case "--automation-write-root": write.append(arguments[index + 1])
                default: throw AutomationError(message: "Unknown MCP option: \(option)")
                }
                index += 2
            }
            _ = try AutomationScope(read: read, write: write)
            var initialized = false
            while let line = readLine() {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                var requestID: Any = NSNull()
                do {
                    guard let data = line.data(using: .utf8), data.count <= 16 * 1024 * 1024 else {
                        throw RPCError(code: -32600, message: "Request exceeds the 16 MB limit.")
                    }
                    let decoded: Any
                    do {
                        decoded = try JSONSerialization.jsonObject(with: data)
                    } catch {
                        throw RPCError(code: -32700, message: "Invalid JSON.")
                    }
                    guard let request = decoded as? [String: Any],
                          request["jsonrpc"] as? String == "2.0",
                          let method = request["method"] as? String else {
                        throw RPCError(code: -32600, message: "Invalid JSON-RPC request.")
                    }
                    guard let id = request["id"] else { continue }
                    let numericID = (id as? NSNumber).map {
                        CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue
                    } ?? false
                    guard id is String || numericID else {
                        throw RPCError(code: -32600, message: "Request IDs must be strings or integers.")
                    }
                    requestID = id
                    let params = request["params"] as? [String: Any] ?? [:]
                    let result: [String: Any]
                    if method == "initialize" {
                        guard !initialized else { throw RPCError(code: -32600, message: "Already initialized.") }
                        let requested = params["protocolVersion"] as? String ?? ""
                        let negotiated = protocolVersions.contains(requested) ? requested : protocolVersions[0]
                        initialized = true
                        result = [
                            "protocolVersion": negotiated, "capabilities": ["tools": [:], "resources": [:]],
                            "serverInfo": ["name": "inkline", "title": "Inkline", "version": version],
                            "instructions": "Use list_documents to find open documents. Read before editing and pass the returned revision. Content edits support Inkline Undo. Only configured file roots are accessible. Format changes preserve saved documents by opening an untitled copy."
                        ]
                    } else if method == "ping" {
                        result = [:]
                    } else {
                        guard initialized else { throw RPCError(code: -32000, message: "Initialize the server first.") }
                        switch method {
                        case "tools/list": result = ["tools": tools]
                        case "resources/templates/list": result = ["resourceTemplates": []]
                        case "tools/call":
                            guard let name = params["name"] as? String,
                                  tools.contains(where: { $0["name"] as? String == name }) else {
                                throw RPCError(code: -32602, message: "Unknown tool name.")
                            }
                            result = try forward(["method": method, "params": params, "readRoots": read, "writeRoots": write])
                        case "resources/list", "resources/read":
                            result = try forward(["method": method, "params": params, "readRoots": read, "writeRoots": write])
                        default: throw RPCError(code: -32601, message: "Method not found: \(method)")
                        }
                    }
                    try send(["jsonrpc": "2.0", "id": id, "result": result])
                } catch let error as RPCError {
                    try send(["jsonrpc": "2.0", "id": requestID,
                              "error": ["code": error.code, "message": error.message]])
                } catch {
                    try send(["jsonrpc": "2.0", "id": requestID,
                              "error": ["code": -32603, "message": error.localizedDescription]])
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data(("Inkline MCP: " + error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    private struct RPCError: Error {
        let code: Int
        let message: String
    }

    private static func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func forward(_ request: [String: Any]) throws -> [String: Any] {
        var remote = CFMessagePortCreateRemote(nil, portName as CFString)
        if remote == nil {
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launch.arguments = ["-g", Bundle.main.bundleURL.path]
            launch.standardOutput = FileHandle.standardError
            launch.standardError = FileHandle.standardError
            try launch.run()
            launch.waitUntilExit()
            guard launch.terminationStatus == 0 else { throw AutomationError(message: "Could not launch Inkline.") }
            let deadline = Date().addingTimeInterval(10)
            while remote == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                remote = CFMessagePortCreateRemote(nil, portName as CFString)
            }
        }
        guard let remote else {
            throw AutomationError(message: "Inkline's MCP bridge is unavailable. Open this Inkline build and enable MCP Access in its MCP menu.")
        }
        let data = try JSONSerialization.data(withJSONObject: request)
        var response: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(remote, 1, data as CFData, 3, 55,
                                             CFRunLoopMode.defaultMode.rawValue, &response)
        guard status == kCFMessagePortSuccess, let response else {
            throw AutomationError(message: "Inkline did not finish the MCP request (status \(status)). Read the document before retrying an edit.")
        }
        guard let value = try JSONSerialization.jsonObject(with: response.takeRetainedValue() as Data) as? [String: Any] else {
            throw AutomationError(message: "Invalid response from Inkline.")
        }
        if let error = value["error"] as? String { throw AutomationError(message: error) }
        return value
    }

    static func toolResult(_ object: [String: Any]) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                "structuredContent": object, "isError": false]
    }

    static func toolError(_ error: Error) -> [String: Any] {
        ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
    }

    static let tools: [[String: Any]] = {
        let string: [String: Any] = ["type": "string"]
        let boolean: [String: Any] = ["type": "boolean"]
        let format: [String: Any] = ["type": "string", "enum": ["markdown", "latex", "html"]]
        let doc: [String: Any] = ["type": "string", "description": "Document ID returned by list_documents or create_document."]
        let revision: [String: Any] = ["type": "string", "description": "Revision from the most recent read_document. Stale revisions are rejected."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:],
                  required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> [String: Any] {
            [
                "name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false]
            ]
        }
        return [
            tool("list_documents", "List Inkline documents accessible within this connection's file roots, plus untitled documents. Includes active-document status.", readOnly: true),
            tool("read_document", "Read the current in-memory source, revision, selection, and metadata, including unsaved changes.", ["document_id": doc], required: ["document_id"], readOnly: true),
            tool("close_document", "Close a clean document. Refuses documents with unsaved changes, which must be saved first.",
                 ["document_id": doc], required: ["document_id"]),
            tool("create_document", "Create and display an untitled document. Omit source to use the format's starter. Save with save_document.",
                 ["format": format, "source": string], required: ["format"]),
            tool("open_document", "Open an existing Markdown, LaTeX, or HTML file within an automation read root.",
                 ["path": string], required: ["path"]),
            tool("replace_document", "Replace the entire document source as one undoable edit. Read first and supply expected_revision.",
                 ["document_id": doc, "expected_revision": revision, "source": string], required: ["document_id", "expected_revision", "source"], destructive: true),
            tool("edit_document", "Replace one unique exact occurrence of old_text as one undoable edit. Ambiguous matches and stale revisions are rejected.",
                 ["document_id": doc, "expected_revision": revision, "old_text": string, "new_text": string],
                 required: ["document_id", "expected_revision", "old_text", "new_text"], destructive: true),
            tool("save_document", "Save a document within an automation write root. Supply an absolute path for an untitled document. Existing unrelated files require overwrite=true.",
                 ["document_id": doc, "path": string, "overwrite": boolean], required: ["document_id"], destructive: true),
            tool("set_view", "Choose Source, Split, or Preview layout for a document.",
                 ["document_id": doc, "view": ["type": "string", "enum": ["source", "split", "preview"]]], required: ["document_id", "view"]),
            tool("set_format", "Change an untitled document's format. A saved document opens as an untitled copy in the selected format. Source is preserved.",
                 ["document_id": doc, "format": format], required: ["document_id", "format"]),
            tool("compile_latex", "Compile a LaTeX document using the installed TeX engine. Return the compile log and whether the PDF is current.",
                 ["document_id": doc, "engine": ["type": "string", "enum": ["pdflatex", "xelatex"]]], required: ["document_id"]),
            tool("export_pdf", "Export the rendered document to an absolute PDF path within a write root. LaTeX is compiled first. Read first and supply expected_revision. Existing PDFs require overwrite=true.",
                 ["document_id": doc, "expected_revision": revision, "path": string, "overwrite": boolean],
                 required: ["document_id", "expected_revision", "path"], destructive: true)
        ]
    }()
}
