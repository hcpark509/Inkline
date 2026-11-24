import Foundation
import PDFKit

/// Headless LaTeX → PDF builds for MCP clients. It runs inside the MCP helper, so no Inkline window opens, and it
/// returns a short summary instead of the whole compiler log.
enum LatexBuild {
    static let toolName = "build_latex_pdf"
    static let description = "Compile a .tex file on disk to PDF without opening a window, like a deliverable build. "
        + "Paths resolve from the file's folder (../ and subfolders work) and from project_root. A4 unless the preamble states a size. "
        + "Returns pages, paper, errors with line numbers, and warning counts; set include_log for the log tail."

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Absolute path of the .tex file within a read root."],
            "output": ["type": "string", "description": "Absolute .pdf path within a write root. Defaults to the .tex path with .pdf."],
            "engine": ["type": "string", "enum": ["pdflatex", "xelatex"]],
            "project_root": ["type": "string", "description": "Optional folder within a read root searched for inputs and figures."],
            "overwrite": ["type": "boolean", "description": "Required to replace an existing PDF."],
            "include_log": ["type": "boolean", "description": "Also return the last 6,000 characters of the final pass log."]
        ],
        "required": ["path"],
        "additionalProperties": false
    ]

    static func run(_ arguments: [String: Any], scope: AutomationScope) throws -> [String: Any] {
        guard let rawPath = arguments["path"] as? String, rawPath.hasPrefix("/") else {
            throw AutomationError(message: "path must be an absolute .tex path.")
        }
        let file = try canonicalAutomationURL(URL(fileURLWithPath: rawPath))
        guard file.pathExtension.lowercased() == "tex" else { throw AutomationError(message: "path must end in .tex.") }
        try scope.require(file, write: false)
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw AutomationError(message: "The .tex file does not exist.")
        }
        let outputPath = arguments["output"] as? String ?? file.deletingPathExtension().appendingPathExtension("pdf").path
        guard outputPath.hasPrefix("/") else { throw AutomationError(message: "output must be an absolute .pdf path.") }
        let output = try canonicalAutomationURL(URL(fileURLWithPath: outputPath))
        guard output.pathExtension.lowercased() == "pdf" else { throw AutomationError(message: "output must end in .pdf.") }
        try scope.require(output, write: true)
        if FileManager.default.fileExists(atPath: output.path), arguments["overwrite"] as? Bool != true {
            throw AutomationError(message: "The PDF already exists. Pass overwrite=true to replace it.")
        }
        var project: URL?
        if let root = arguments["project_root"] as? String {
            let url = try canonicalAutomationURL(URL(fileURLWithPath: root))
            // A configured root is itself a valid project folder.
            if !scope.readRoots.contains(url) { try scope.require(url, write: false) }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw AutomationError(message: "project_root must be a folder.")
            }
            project = url
        }
        let engine: LatexEngine
        if let name = arguments["engine"] as? String {
            guard let selected = LatexEngine(rawValue: name) else { throw AutomationError(message: "engine must be pdflatex or xelatex.") }
            engine = selected
        } else {
            engine = .pdfLaTeX
        }
        let source = try readSource(file)
        let started = Date()
        let result = LatexCompiler.compile(LatexInput(source: source, fileURL: file, engine: engine, projectURL: project))
        let seconds = Decimal(string: String(format: "%.1f", Date().timeIntervalSince(started))) ?? 0
        var summary = summarize(result.finalLog, errors: result.errors)
        summary["engine"] = engine.rawValue
        summary["seconds"] = seconds
        if arguments["include_log"] as? Bool == true { summary["log"] = String(result.finalLog.suffix(6000)) }
        guard let pdf = result.pdf, let document = PDFDocument(data: pdf), let first = document.page(at: 0) else {
            summary["success"] = false
            if result.errors.isEmpty { summary["message"] = result.message }
            return summary
        }
        try pdf.write(to: output, options: .atomic)
        let box = first.bounds(for: .mediaBox).size
        summary["success"] = true
        summary["pdf"] = output.path
        summary["pages"] = document.pageCount
        summary["paper"] = paperName(box)
        return summary
    }

    private static func readSource(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) { return text }
        for encoding in [String.Encoding.utf8, .utf16, .utf32] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw AutomationError(message: "The .tex file is not UTF-8, UTF-16, or UTF-32 text.")
    }

    /// Error locations and warning counts from the final pass only, so resolved first-pass warnings are not counted.
    static func summarize(_ log: String, errors diagnostics: [LatexCompiler.Diagnostic]) -> [String: Any] {
        let errors = diagnostics.prefix(5).map { error -> [String: Any] in
                var value: [String: Any] = ["message": error.message]
                if let file = error.file { value["file"] = file }
                if let line = error.line { value["line"] = line }
                return value
            }
        let lines = log.split(whereSeparator: \.isNewline)
        func count(_ test: (Substring) -> Bool) -> Int { lines.filter(test).count }
        var warnings: [String: Int] = [
            "undefined_references": count { $0.contains("LaTeX Warning: Reference") || $0.contains("LaTeX Warning: Citation") },
            "missing_files": count { $0.contains("not found") && $0.contains("Warning") },
            "overfull_boxes": count { $0.hasPrefix("Overfull \\") },
            "underfull_boxes": count { $0.hasPrefix("Underfull \\") },
            "other": count { $0.contains("Warning:") && !$0.contains("Reference") && !$0.contains("Citation") && !$0.contains("not found") }
        ]
        warnings = warnings.filter { $0.value > 0 }
        var summary: [String: Any] = [:]
        if !errors.isEmpty { summary["errors"] = Array(errors) }
        if !warnings.isEmpty { summary["warnings"] = warnings }
        var examples: [String] = []
        for line in lines where line.contains("Warning:") {
            let text = String(line.trimmingCharacters(in: .whitespaces).prefix(140))
            if !examples.contains(text) { examples.append(text) }
            if examples.count == 3 { break }
        }
        if !examples.isEmpty { summary["warning_examples"] = examples }
        if log.contains("Rerun to get") || log.contains("Rerun LaTeX") { summary["needs_rerun"] = true }
        return summary
    }

    private static func paperName(_ size: CGSize) -> String {
        let named: [(String, CGFloat, CGFloat)] = [
            ("A4", 595.28, 841.89), ("Letter", 612, 792), ("Legal", 612, 1008), ("A5", 419.53, 595.28),
            ("A3", 841.89, 1190.55), ("B5", 498.9, 708.66)
        ]
        let short = min(size.width, size.height), long = max(size.width, size.height)
        let orientation = size.width > size.height ? " landscape" : ""
        if let match = named.first(where: { abs($0.1 - short) < 1.5 && abs($0.2 - long) < 1.5 }) {
            return match.0 + orientation
        }
        return String(format: "%.0f×%.0f mm", size.width * 25.4 / 72, size.height * 25.4 / 72)
    }
}
