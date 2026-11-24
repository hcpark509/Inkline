import AppKit

/// Suggests project file paths while typing a path argument, such as `\includegraphics{` or `![alt](`.
/// Paths are relative to the document's folder, which LaTeX, Markdown, and HTML previews all resolve.
enum PathCompletion {
    enum Kind { case graphic, image, tex, bib, stylesheet, any }

    struct Context: Equatable {
        let range: NSRange
        let partial: String
        let kind: Kind
        /// `\include` and `\bibliography` add the extension themselves.
        let dropsExtension: Bool
        let percentEncodes: Bool
    }

    private static let latex = try! NSRegularExpression(pattern:
        #"\\(includegraphics|includesvg|includepdf|input|include|subfile|subfileinclude|lstinputlisting|verbatiminput|bibliography|addbibresource|addglobalbib)\*?(?:\[[^\]\n]*\])*\{([^{}\n]*)$"#)
    private static let markdown = try! NSRegularExpression(pattern: #"(!?)\[[^\]\n]*\]\(([^()\s]*)$"#)
    private static let html = try! NSRegularExpression(pattern: #"\b(src|href|poster)\s*=\s*["']([^"'\n]*)$"#, options: [.caseInsensitive])
    private static let cssURL = try! NSRegularExpression(pattern: #"url\(\s*["']?([^"')\n]*)$"#, options: [.caseInsensitive])

    static let extensions: [Kind: Set<String>] = [
        .graphic: ["png", "jpg", "jpeg", "pdf", "eps"],
        .image: ["png", "apng", "jpg", "jpeg", "gif", "svg", "webp", "avif", "bmp"],
        .tex: ["tex"], .bib: ["bib"], .stylesheet: ["css"]
    ]

    /// The path being typed at `caret`, if the caret is inside a path argument.
    static func context(in text: NSString, caret: Int, format: DocumentFormat) -> Context? {
        guard caret <= text.length else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let start = max(lineStart, caret - 400)
        let prefix = text.substring(with: NSRange(location: start, length: caret - start))
        let whole = NSRange(prefix.startIndex..., in: prefix)
        func make(_ partial: String, _ kind: Kind, drops: Bool = false, encodes: Bool = false) -> Context {
            Context(range: NSRange(location: caret - partial.utf16.count, length: partial.utf16.count),
                    partial: partial, kind: kind, dropsExtension: drops, percentEncodes: encodes)
        }
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            Range(match.range(at: index), in: prefix).map { String(prefix[$0]) } ?? ""
        }
        switch format {
        case .latex:
            guard let match = latex.firstMatch(in: prefix, range: whole) else { return nil }
            let command = group(match, 1)
            var partial = group(match, 2)
            switch command {
            case "includegraphics", "includesvg", "includepdf": return make(partial, command == "includesvg" ? .image : .graphic)
            case "bibliography", "addglobalbib", "addbibresource":
                if command == "bibliography", let comma = partial.lastIndex(of: ",") { partial = String(partial[partial.index(after: comma)...]) }
                return make(partial, .bib, drops: command == "bibliography")
            case "input", "include", "subfile", "subfileinclude": return make(partial, .tex, drops: command == "include")
            default: return make(partial, .any)
            }
        case .markdown:
            guard let match = markdown.firstMatch(in: prefix, range: whole) else { return nil }
            return make(group(match, 2), group(match, 1) == "!" ? .image : .any, encodes: true)
        case .html:
            if let match = cssURL.firstMatch(in: prefix, range: whole) { return make(group(match, 1), .any, encodes: true) }
            guard let match = html.firstMatch(in: prefix, range: whole) else { return nil }
            let attribute = group(match, 1).lowercased()
            let partial = group(match, 2)
            if partial.contains("://") || partial.hasPrefix("#") || partial.hasPrefix("mailto:") { return nil }
            return make(partial, attribute == "href" ? .any : .image, encodes: true)
        }
    }

    private static var cache: (boundary: URL, made: Date, files: [URL])?

    /// Files under the project, skipping hidden, dependency, and build folders. Results are cached briefly.
    static func files(under boundary: URL, limit: Int = 5000) -> [URL] {
        if let cache, cache.boundary == boundary, Date().timeIntervalSince(cache.made) < 3 { return cache.files }
        let skipped: Set<String> = ["node_modules", "build", ".git", ".next", "dist", "DerivedData"]
        var found: [URL] = []
        let root = (try? canonicalAutomationURL(boundary)) ?? boundary
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                if walker.level > 8 { walker.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                found.append(url)
                if found.count >= limit { break }
            }
        }
        cache = (boundary, Date(), found)
        return found
    }

    static func invalidate() { cache = nil }

    /// Ranked paths for the typed text: path prefix, then file-name prefix, then any substring match.
    static func suggestions(for context: Context, base: URL, files: [URL], limit: Int = 30) -> [String] {
        let allowed = extensions[context.kind]
        let origin = ((try? canonicalAutomationURL(base)) ?? base).pathComponents
        func relative(_ file: URL) -> String {
            let parts = file.pathComponents
            var common = 0
            while common < min(parts.count, origin.count), parts[common] == origin[common] { common += 1 }
            return (Array(repeating: "..", count: origin.count - common) + parts.dropFirst(common)).joined(separator: "/")
        }
        let typed = context.partial.removingPercentEncoding?.lowercased() ?? context.partial.lowercased()
        var scored: [(Int, String)] = []
        for file in files {
            let ext = file.pathExtension.lowercased()
            if let allowed, !allowed.contains(ext) { continue }
            var path = relative(file)
            if context.dropsExtension { path = String(path.dropLast(ext.count + 1)) }
            let lower = path.lowercased()
            let score: Int
            if lower.hasPrefix(typed) { score = 0 }
            else if (lower.split(separator: "/").last ?? "").hasPrefix(typed) { score = 1 }
            else if typed.isEmpty || lower.contains(typed) { score = 2 }
            else { continue }
            if context.percentEncodes { path = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path }
            scored.append((score, path))
        }
        return scored.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1.count != $1.1.count { return $0.1.count < $1.1.count }
            return $0.1.localizedStandardCompare($1.1) == .orderedAscending
        }.prefix(limit).map(\.1)
    }
}

/// A small list below the caret. It never takes focus: the editor keeps typing and routes arrows, Return, Tab,
/// and Escape here while the list is visible.
final class PathSuggestionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Path suggestions")
        scroll.documentView = table
        scroll.frame = background.bounds
        scroll.autoresizingMask = [.width, .height]
        background.addSubview(scroll)
        panel.contentView = background
        return panel
    }()

    private(set) var items: [String] = []
    var onAccept: ((String) -> Void)?
    var isVisible: Bool { panel.isVisible && !items.isEmpty }
    var selected: String? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    func show(_ items: [String], below caret: NSRect, in window: NSWindow) {
        self.items = items
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        let height = CGFloat(min(items.count, 8)) * (table.rowHeight + table.intercellSpacing.height) + 8
        panel.setFrame(NSRect(x: caret.minX, y: caret.minY - height - 2, width: 380, height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
    }

    func move(_ offset: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + offset))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func accept() {
        guard let value = selected else { return }
        hide()
        onAccept?(value)
    }

    @objc private func clicked() {
        guard items.indices.contains(table.clickedRow) else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        accept()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = items[row]
        let name = (path.removingPercentEncoding ?? path) as NSString
        let label = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(string: name.lastPathComponent,
                                             attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        let folder = name.deletingLastPathComponent
        if !folder.isEmpty {
            text.append(NSAttributedString(string: "  " + folder + "/", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = path
        return label
    }
}
