import AppKit
import UniformTypeIdentifiers

final class ProjectWorkspace {
    static let shared = ProjectWorkspace()
    static let didChange = Notification.Name("InklineProjectChanged")
    private(set) var rootURL: URL?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "projectBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                rootURL = try? canonicalAutomationURL(url)
            }
        }
    }

    func select(_ url: URL) throws {
        let root = try canonicalAutomationURL(url)
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw AutomationError(message: "Choose a project folder.")
        }
        let bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: "projectBookmark")
        rootURL = root
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func close() {
        rootURL = nil
        UserDefaults.standard.removeObject(forKey: "projectBookmark")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func root(for documentURL: URL?) -> URL? {
        guard let rootURL else { return nil }
        guard let documentURL else { return rootURL }
        guard let document = try? canonicalAutomationURL(documentURL),
              document.pathComponents.starts(with: rootURL.pathComponents) else { return nil }
        return rootURL
    }

    static func relativePath(of url: URL, from base: URL) -> String {
        let target = (try? canonicalAutomationURL(url)) ?? url
        let origin = (try? canonicalAutomationURL(base)) ?? base
        let targetParts = target.pathComponents
        let originParts = origin.pathComponents
        var common = 0
        while common < min(targetParts.count, originParts.count), targetParts[common] == originParts[common] { common += 1 }
        return (Array(repeating: "..", count: originParts.count - common) + Array(targetParts.dropFirst(common))).joined(separator: "/")
    }
}

private final class ProjectNode {
    let url: URL
    let isDirectory: Bool
    var children: [ProjectNode]?

    init(_ url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
    }

    func loadChildren() -> [ProjectNode] {
        if let children { return children }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        let nodes = urls.map(ProjectNode.init).filter { !["node_modules", "build", ".next"].contains($0.url.lastPathComponent) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        children = nodes
        return nodes
    }
}

final class ProjectBrowser: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private let titleLabel = NSTextField(labelWithString: "Project")
    private var root: ProjectNode?
    var openDocument: ((URL) -> Void)?

    override func loadView() {
        view = NSView()
        let title = NSStackView(views: [titleLabel])
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh project")!,
                               target: self, action: #selector(reload))
        refresh.isBordered = false
        refresh.toolTip = "Refresh project files"
        title.addArrangedSubview(refresh)
        title.orientation = .horizontal
        title.alignment = .centerY
        title.spacing = 8
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("projectFile"))
        column.title = "Files"
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 27
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelection)
        outline.backgroundColor = .clear
        outline.setAccessibilityLabel("Project files")
        scroll.documentView = outline
        for child in [title, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            title.heightAnchor.constraint(equalToConstant: 25),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: ProjectWorkspace.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        reload()
    }

    @objc func reload() {
        guard isViewLoaded else { return }
        let expanded = (0..<outline.numberOfRows).compactMap { index -> String? in
            guard let node = outline.item(atRow: index) as? ProjectNode, outline.isItemExpanded(node) else { return nil }
            return node.url.path
        }
        root = ProjectWorkspace.shared.rootURL.map(ProjectNode.init)
        titleLabel.stringValue = root?.url.lastPathComponent ?? "Project"
        titleLabel.toolTip = root?.url.path
        outline.reloadData()
        var row = 0
        while row < outline.numberOfRows {
            if let node = outline.item(atRow: row) as? ProjectNode, expanded.contains(node.url.path) {
                outline.expandItem(node)
            }
            row += 1
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ProjectNode ?? root)?.loadChildren().count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ProjectNode ?? root)!.loadChildren()[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ProjectNode)?.isDirectory == true
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ProjectNode else { return nil }
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: node.url.lastPathComponent)
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.toolTip = node.url.path
        return row
    }
    @objc private func openSelection() {
        guard outline.clickedRow >= 0 else { return }
        guard let node = outline.item(atRow: outline.clickedRow) as? ProjectNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else if DocumentFormat.extensions.contains(node.url.pathExtension.lowercased()) {
            openDocument?(node.url)
        }
    }
}
