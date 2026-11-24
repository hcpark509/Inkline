import Foundation

enum LatexEngine: String, CaseIterable {
    case pdfLaTeX = "pdflatex"
    case xeLaTeX = "xelatex"

    var title: String { self == .pdfLaTeX ? "pdfLaTeX" : "XeLaTeX" }

    func executable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let searchPath = [
            "/Library/TeX/texbin", "/usr/local/bin", "/opt/homebrew/bin",
            NSHomeDirectory() + "/Library/TinyTeX/bin/universal-darwin"
        ] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return searchPath.filter { $0.hasPrefix("/") }.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(self.rawValue) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

struct LatexInput: Equatable {
    let source: String
    let fileURL: URL?
    let engine: LatexEngine
    var projectURL: URL? = nil
}

enum LatexCompiler {
    static let template = #"""
    \documentclass[11pt]{article}
    \usepackage{amsmath}
    \usepackage{graphicx}

    \title{A LaTeX document}
    \author{}
    \date{}

    \begin{document}
    \maketitle

    \section{Introduction}
    Write your document here. Press \textbf{Recompile} to update the PDF.

    \section{An equation}
    \[
      \int_0^1 x^2\,dx = \frac{1}{3}
    \]

    \end{document}
    """# + "\n"

    struct Output {
        let pdf: Data?
        let message: String
        let log: String
        /// The last pass only, for warning summaries.
        var finalLog = ""
        var errors: [Diagnostic] = []
    }

    static func compile(_ input: LatexInput) -> Output {
        guard let executable = input.engine.executable() else {
            let message = "\(input.engine.title) is unavailable. Install a TeX distribution such as MacTeX or TinyTeX, then recompile."
            return Output(pdf: nil, message: message, log: message)
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("inkline-tex-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: work) }
            let name = input.fileURL?.lastPathComponent ?? "main.tex"
            let source = work.appendingPathComponent(name)
            try LatexPaper.prepare(input.source).write(to: source, atomically: true, encoding: .utf8)
            // TeX runs in the document's folder, as on Overleaf, so ../ and subfolder paths resolve from the
            // document. Output goes to the temporary folder, which mirrors the subfolders \include writes into.
            let folder = input.fileURL?.deletingLastPathComponent() ?? input.projectURL
            let base = folder ?? work
            if let folder { mirrorFolders(of: folder, into: work) }

            var environment = ProcessInfo.processInfo.environment
            let texBin = executable.deletingLastPathComponent().path
            let distributionBin = executable.resolvingSymlinksInPath().deletingLastPathComponent().path
            environment["PATH"] = [texBin, distributionBin, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            environment["TEXINPUTS"] = [".", folder?.path, input.projectURL?.path, environment["TEXINPUTS"] ?? ""].compactMap { $0 }.joined(separator: ":")
            environment["openout_any"] = "p"
            // Long temporary paths would otherwise wrap at 79 columns and split file:line errors.
            environment["max_print_line"] = "10000"

            let deadline = DispatchTime.now() + .seconds(45)
            var log = ""
            var finalLog = ""
            // The second pass resolves ordinary cross-references and the table of contents.
            for pass in 1...2 {
                let output = try run(executable, source: source, directory: base, output: work,
                                     environment: environment, deadline: deadline)
                log += "Pass \(pass)\n\(output.log)\n"
                finalLog = output.log
                if !output.succeeded {
                    let errors = diagnostics(in: output.log, work: work)
                    let message = output.timedOut ? "Compilation exceeded 45 seconds."
                        : (errors.first?.description ?? "Compilation failed. Open the log for details.")
                    return Output(pdf: nil, message: message, log: log, finalLog: finalLog, errors: errors)
                }
            }
            let pdfURL = source.deletingPathExtension().appendingPathExtension("pdf")
            guard let pdf = try? Data(contentsOf: pdfURL), !pdf.isEmpty else {
                return Output(pdf: nil, message: "The document produced no PDF pages.", log: log, finalLog: finalLog)
            }
            return Output(pdf: pdf, message: "Compiled", log: log, finalLog: finalLog)
        } catch {
            return Output(pdf: nil, message: error.localizedDescription, log: error.localizedDescription)
        }
    }

    struct Diagnostic: CustomStringConvertible {
        let file: String?
        let line: Int?
        let message: String
        var description: String {
            guard let file else { return message }
            return line.map { "\(file):\($0): \(message)" } ?? "\(file): \(message)"
        }
    }

    /// Compiler errors in file-line-error form, with the temporary folder removed from the main file's path.
    static func diagnostics(in log: String, work: URL) -> [Diagnostic] {
        let prefixes = [work.path + "/", work.resolvingSymlinksInPath().path + "/", "./"]
        var found: [Diagnostic] = []
        for raw in log.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if line.hasPrefix("! ") {
                if found.isEmpty { found.append(Diagnostic(file: nil, line: nil, message: String(line.dropFirst(2)))) }
                continue
            }
            guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { continue }
            line.removeFirst(prefix.count)
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { continue }
            let message = parts[2].trimmingCharacters(in: .whitespaces)
            if message.hasPrefix("==>") { continue }
            found.removeAll { $0.file == nil }
            found.append(Diagnostic(file: String(parts[0]), line: number, message: message))
        }
        return found
    }

    /// Recreates the document folder's subfolders so TeX can write auxiliary files for \include{dir/file}.
    private static func mirrorFolders(of folder: URL, into work: URL) {
        let skipped: Set<String> = ["node_modules", "build", ".git", ".next"]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var created = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if skipped.contains(url.lastPathComponent) || walker.level > 4 { walker.skipDescendants(); continue }
            let relative = ProjectWorkspace.relativePath(of: url, from: folder)
            try? FileManager.default.createDirectory(at: work.appendingPathComponent(relative), withIntermediateDirectories: true)
            created += 1
            if created >= 500 { return }
        }
    }

    private static func run(_ executable: URL, source: URL, directory: URL, output: URL,
                            environment: [String: String], deadline: DispatchTime)
        throws -> (succeeded: Bool, timedOut: Bool, log: String) {
        let logURL = output.appendingPathComponent("inkline-console-\(UUID().uuidString).txt")
        try Data().write(to: logURL)
        let logFile = try FileHandle(forUpdating: logURL)
        defer { try? logFile.close() }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.environment = environment
        process.arguments = [
            "-no-shell-escape", "-no-parse-first-line", "-interaction=nonstopmode",
            "-halt-on-error", "-file-line-error", "-output-directory=" + output.path, source.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logFile
        process.standardError = logFile
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let timedOut = exited.wait(timeout: deadline) == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
        let length = try logFile.seekToEnd()
        let maxLogBytes: UInt64 = 96 * 1024
        try logFile.seek(toOffset: length > maxLogBytes ? length - maxLogBytes : 0)
        let log = String(decoding: try logFile.readToEnd() ?? Data(), as: UTF8.self)
        return (!timedOut && process.terminationStatus == 0, timedOut, log)
    }
}
