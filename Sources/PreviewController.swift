import AppKit
import PDFKit
import WebKit

final class PreviewController: NSObject, WKNavigationDelegate {
    private static let page = URL(string: "inkline-preview://app/index.html")!
    private static let pdfSize = CGSize(width: 595, height: 842)
    private let files = PreviewFiles()
    private let isExportRenderer: Bool

    init(isExportRenderer: Bool = false) {
        self.isExportRenderer = isExportRenderer
        super.init()
    }

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(files, forURLScheme: "inkline-preview")
        configuration.setURLSchemeHandler(files, forURLScheme: "inkline-image")
        let frame = isExportRenderer ? CGRect(origin: .zero, size: Self.pdfSize) : .zero
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self
        view.underPageBackgroundColor = Palette.paper
        view.setAccessibilityLabel("Rendered Markdown preview")
        view.load(URLRequest(url: Self.page))
        return view
    }()

    private var source = ""
    private var isReady = false
    private var assetRevision = 0
    private var exportRenderer: PreviewController?
    private var whenLoaded: ((Error?) -> Void)?

    func setDocumentURL(_ url: URL?, projectRoot: URL? = nil) {
        let newDirectory = url?.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let directory = newDirectory ?? projectRoot
        guard directory != files.directory || projectRoot != files.projectRoot else { return }
        files.directory = directory
        files.projectRoot = projectRoot
        assetRevision += 1
        updatePage()
    }

    func render(_ source: String) {
        self.source = source
        updatePage()
    }

    func updateFont() {
        guard isReady, let data = try? JSONEncoder().encode(FontPreference.preview.family) else { return }
        let family = String(decoding: data, as: UTF8.self)
        let imported = LocalFonts.shared.font(for: FontPreference.preview.family)
        let url = imported.map { "inkline-preview://app/fonts/" + $0.url.lastPathComponent } ?? ""
        let fontURL = String(decoding: try! JSONEncoder().encode(url), as: UTF8.self)
        webView.evaluateJavaScript("window.setPreviewFont(\(family), \(FontPreference.preview.size), \(fontURL))", completionHandler: nil)
        updateTheme()
    }

    func updateTheme() {
        guard isReady else { return }
        let theme = AppPreferences.theme
        let values: [String: Any] = [
            "light": theme.previewColors(dark: false), "dark": theme.previewColors(dark: true),
            "appearance": isExportRenderer ? "light" : (AppPreferences.isDark ? "dark" : "light")
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return }
        webView.evaluateJavaScript("window.setPreviewTheme(\(String(decoding: data, as: UTF8.self)))", completionHandler: nil)
    }

    private func updatePage() {
        guard isReady, let data = try? JSONEncoder().encode(source) else { return }
        let argument = String(decoding: data, as: UTF8.self)
        let hasDirectory = files.directory != nil
        webView.evaluateJavaScript(
            "window.renderMarkdown(\(argument), \(hasDirectory), \(assetRevision))"
        ) { _, error in
            if let error { NSLog("Inkline preview: %@", error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        updateFont()
        updatePage()
        finishLoading(nil)
    }

    func exportPDF(source: String, to url: URL, completion: @escaping (Error?) -> Void) {
        let renderer = PreviewController(isExportRenderer: true)
        renderer.files.directory = files.directory
        renderer.files.projectRoot = files.projectRoot
        renderer.source = source
        exportRenderer = renderer
        renderer.whenLoaded = { [weak self, weak renderer] loadError in
            if let loadError {
                self?.exportRenderer = nil
                completion(loadError)
            } else {
                renderer?.savePaginatedPDF(to: url) { error in
                    self?.exportRenderer = nil
                    completion(error)
                }
            }
        }
        _ = renderer.webView
    }

    private func savePaginatedPDF(to url: URL, completion: @escaping (Error?) -> Void) {
        webView.callAsyncJavaScript(
            "return await window.preparePDFExport(width, height)",
            arguments: ["width": Self.pdfSize.width, "height": Self.pdfSize.height], in: nil, in: .page,
            completionHandler: { [weak self] result in
                guard let self else { return }
                Task { @MainActor in
                    do {
                        guard let count = try result.get() as? Int, count > 0 else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        let pdf = try await self.capturePages(count)
                        guard let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                        try data.write(to: url, options: .atomic)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            }
        )
    }

    @MainActor private func capturePages(_ count: Int) async throws -> PDFDocument {
        let pdf = PDFDocument()
        for index in 0..<count {
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(origin: CGPoint(x: Self.pdfSize.width * CGFloat(index), y: 0),
                                        size: Self.pdfSize)
            let data = try await webView.pdf(configuration: configuration)
            guard let document = PDFDocument(data: data), let page = document.page(at: 0) else {
                throw CocoaError(.fileWriteUnknown)
            }
            pdf.insert(page, at: index)
        }
        return pdf
    }

    private func finishLoading(_ error: Error?) {
        let action = whenLoaded
        whenLoaded = nil
        action?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        if isExportRenderer {
            finishLoading(URLError(.cannotLoadFromNetwork))
            return
        }
        webView.load(URLRequest(url: Self.page))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url == Self.page || (url.scheme == Self.page.scheme && url.host == "app"
                               && url.path == Self.page.path && url.fragment != nil) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        guard action.navigationType == .linkActivated else { return }
        switch url.scheme {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "inkline-link":
            guard let file = files.localFile(for: url),
                  DocumentFormat.extensions.contains(file.pathExtension.lowercased())
            else { return }
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        default:
            break
        }
    }

}

private final class PreviewFiles: NSObject, WKURLSchemeHandler {
    private static let resources = [
        "index.html": "text/html",
        "preview.css": "text/css",
        "preview.js": "text/javascript",
        "marked.min.js": "text/javascript"
    ]
    private static let imageTypes = [
        "png": "image/png", "apng": "image/apng", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "avif": "image/avif", "bmp": "image/bmp"
    ]

    var directory: URL?
    var projectRoot: URL?

    func localFile(for request: URL) -> URL? {
        guard request.host == "document",
              let components = URLComponents(url: request, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value
        else { return nil }
        return previewAsset(at: path, in: directory, projectRoot: projectRoot)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let request = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let file: URL?
        let mimeType: String?
        switch request.scheme {
        case "inkline-preview" where request.host == "app" && request.path.hasPrefix("/fonts/"):
            file = LocalFonts.shared.fontAsset(named: request.lastPathComponent)
            mimeType = file.map { $0.pathExtension == "otf" ? "font/otf" : "font/ttf" }
        case "inkline-preview" where request.host == "app":
            let name = request.lastPathComponent
            mimeType = Self.resources[name]
            file = Bundle.main.resourceURL?.appendingPathComponent("Preview", isDirectory: true)
                .appendingPathComponent(name)
        case "inkline-image":
            file = localFile(for: request)
            mimeType = file.flatMap { Self.imageTypes[$0.pathExtension.lowercased()] }
        default:
            file = nil
            mimeType = nil
        }
        guard let file, let mimeType, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: request, mimeType: mimeType, expectedContentLength: data.count,
                                    textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

func previewAsset(at path: String, in directory: URL?, projectRoot: URL? = nil) -> URL? {
    guard let directory, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return nil }
    let boundary = (try? canonicalAutomationURL(projectRoot ?? directory)) ?? directory
    for base in [directory, projectRoot].compactMap({ $0 }) {
        guard let file = try? canonicalAutomationURL(base.appendingPathComponent(path)),
              file.pathComponents.count > boundary.pathComponents.count,
              file.pathComponents.starts(with: boundary.pathComponents),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        return file
    }
    return nil
}
