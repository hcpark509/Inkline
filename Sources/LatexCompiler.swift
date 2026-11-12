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
            try input.source.write(to: source, atomically: true, encoding: .utf8)

            var environment = ProcessInfo.processInfo.environment
            let texBin = executable.deletingLastPathComponent().path
            let distributionBin = executable.resolvingSymlinksInPath().deletingLastPathComponent().path
            environment["PATH"] = [texBin, distributionBin, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            let folder = input.fileURL?.deletingLastPathComponent().path
            environment["TEXINPUTS"] = [".", folder, input.projectURL?.path, environment["TEXINPUTS"] ?? ""].compactMap { $0 }.joined(separator: ":")
            environment["openout_any"] = "p"

            let deadline = DispatchTime.now() + .seconds(45)
            var log = ""
            // The second pass resolves ordinary cross-references and the table of contents.
            for pass in 1...2 {
                let output = try run(executable, source: source, directory: work,
                                     environment: environment, deadline: deadline)
                log += "Pass \(pass)\n\(output.log)\n"
                if !output.succeeded {
                    let diagnostic = output.log.split(whereSeparator: \.isNewline)
                        .first { $0.hasPrefix("./\(name):") || $0.hasPrefix("! ") }
                    let message = output.timedOut ? "Compilation exceeded 45 seconds."
                        : (diagnostic.map { String($0).replacingOccurrences(of: "./", with: "", options: .anchored) }
                            ?? "Compilation failed. Open the log for details.")
                    return Output(pdf: nil, message: message, log: log)
                }
            }
            let pdfURL = source.deletingPathExtension().appendingPathExtension("pdf")
            guard let pdf = try? Data(contentsOf: pdfURL), !pdf.isEmpty else {
                return Output(pdf: nil, message: "The document produced no PDF pages.", log: log)
            }
            return Output(pdf: pdf, message: "Compiled", log: log)
        } catch {
            return Output(pdf: nil, message: error.localizedDescription, log: error.localizedDescription)
        }
    }

    private static func run(_ executable: URL, source: URL, directory: URL,
                            environment: [String: String], deadline: DispatchTime)
        throws -> (succeeded: Bool, timedOut: Bool, log: String) {
        let logURL = directory.appendingPathComponent("inkline-console-\(UUID().uuidString).txt")
        try Data().write(to: logURL)
        let logFile = try FileHandle(forUpdating: logURL)
        defer { try? logFile.close() }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.environment = environment
        process.arguments = [
            "-no-shell-escape", "-no-parse-first-line", "-interaction=nonstopmode",
            "-halt-on-error", "-file-line-error", "./" + source.lastPathComponent
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
