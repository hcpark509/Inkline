import AppKit
import UniformTypeIdentifiers
import WebKit

final class HTMLPreviewController: NSObject, WKNavigationDelegate {
    static let template = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>My HTML page</title>
      <style>
        body { font: 17px/1.6 system-ui; margin: 2rem; }
        h1 { color: #6741a5; }
      </style>
    </head>
    <body>
      <h1>My HTML page</h1>
      <p>Edit the source to see your changes here.</p>
    </body>
    </html>
    """ + "\n"

    private let files = HTMLPreviewFiles()
    private let frame: NSRect
    private var documentURL: URL?
    private var projectRoot: URL?
    private var revision = 0
    private var acceptsPageLoad = false
    private var exportRenderer: HTMLPreviewController?
    private var whenLoaded: ((Error?) -> Void)?

    init(frame: NSRect = .zero) {
        self.frame = frame
        super.init()
    }

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(files, forURLScheme: HTMLPreviewFiles.scheme)
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self
        view.setAccessibilityLabel("Rendered HTML preview")
        return view
    }()

    func render(_ source: String, documentURL: URL?, projectRoot: URL? = nil) {
        guard revision == 0 || source != files.source || documentURL != self.documentURL || projectRoot != self.projectRoot else { return }
        files.source = source
        self.documentURL = documentURL
        self.projectRoot = projectRoot
        files.directory = projectRoot ?? documentURL?.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        loadPage()
    }

    private func loadPage() {
        revision += 1
        var page = URLComponents()
        page.scheme = HTMLPreviewFiles.scheme
        page.host = HTMLPreviewFiles.host
        let filename = documentURL.flatMap { url in
            projectRoot.map { ProjectWorkspace.relativePath(of: url, from: $0) }
        } ?? documentURL?.lastPathComponent ?? "index.html"
        page.path = "/" + filename
        page.queryItems = [URLQueryItem(name: "inkline-render", value: String(revision))]
        guard let url = page.url else { return }
        files.pageURL = url
        acceptsPageLoad = true
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        if acceptsPageLoad, url == files.pageURL, action.targetFrame?.isMainFrame == true {
            acceptsPageLoad = false
            decisionHandler(.allow)
            return
        }
        guard action.navigationType == .linkActivated else {
            decisionHandler(.cancel)
            return
        }
        if url.fragment != nil, var page = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            page.fragment = nil
            if page.url == files.pageURL, action.targetFrame?.isMainFrame == true {
                decisionHandler(.allow)
                return
            }
        }
        decisionHandler(.cancel)
        switch url.scheme {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case HTMLPreviewFiles.scheme:
            guard let file = files.localFile(for: url),
                  DocumentFormat.extensions.contains(file.pathExtension.lowercased()) else { return }
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if whenLoaded != nil {
            finishLoading(URLError(.cannotLoadFromNetwork))
        } else if revision > 0 {
            loadPage()
        }
    }

    private func finishLoading(_ error: Error?) {
        let action = whenLoaded
        whenLoaded = nil
        action?(error)
    }

    func exportPDF(source: String, documentURL: URL?, projectRoot: URL? = nil, to url: URL, completion: @escaping (Error?) -> Void) {
        let renderer = HTMLPreviewController(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))
        exportRenderer = renderer
        renderer.whenLoaded = { [weak self, weak renderer] error in
            Task { @MainActor in
                defer { self?.exportRenderer = nil }
                do {
                    if let error { throw error }
                    guard let renderer else { return }
                    try await renderer.savePDF(to: url)
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
        renderer.render(source, documentURL: documentURL, projectRoot: projectRoot)
    }

    @MainActor private func savePDF(to url: URL) async throws {
        let dimensions: [Double] = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                """
                const images = Array.from(document.images, image => {
                    image.loading = "eager";
                    return image.decode();
                });
                await Promise.race([
                    Promise.allSettled([document.fonts.ready, ...images]),
                    new Promise(resolve => setTimeout(resolve, 6000))
                ]);
                return [document.documentElement.scrollWidth, document.documentElement.scrollHeight];
                """,
                arguments: [:], in: nil, in: .defaultClient, completionHandler: { result in
                    continuation.resume(with: result.flatMap { value in
                        guard let size = value as? [Double], size.count == 2 else {
                            return .failure(CocoaError(.fileWriteUnknown))
                        }
                        return .success(size)
                    })
                }
            )
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: max(frame.width, dimensions[0]),
                                    height: max(frame.height, dimensions[1]))
        let pdf = try await webView.pdf(configuration: configuration)
        try pdf.write(to: url, options: .atomic)
    }
}

private final class HTMLPreviewFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "inkline-html"
    static let host = "document"
    private static let policy = "default-src 'none'; style-src inkline-html: 'unsafe-inline'; img-src inkline-html: data:; font-src inkline-html: data:; base-uri 'none'; form-action 'none'"
    private static let fonts = ["woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf"]

    var pageURL: URL?
    var directory: URL?
    var source = ""

    func localFile(for url: URL) -> URL? {
        guard url.scheme == Self.scheme, url.host == Self.host else { return nil }
        return previewAsset(at: String(url.path(percentEncoded: false).dropFirst()), in: directory)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let data: Data
        let type: String
        if url == pageURL {
            data = Data(source.utf8)
            type = "text/html; charset=utf-8"
        } else if let file = localFile(for: url), let mimeType = Self.contentType(for: file),
                  let asset = try? Data(contentsOf: file, options: .mappedIfSafe) {
            data = asset
            type = mimeType
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = [
            "Content-Type": type,
            "Content-Security-Policy": Self.policy,
            "Referrer-Policy": "no-referrer",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private static func contentType(for file: URL) -> String? {
        let ext = file.pathExtension.lowercased()
        if ext == "css" { return "text/css" }
        if let font = fonts[ext] { return font }
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .image) else { return nil }
        return type.preferredMIMEType
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
