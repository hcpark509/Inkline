import AppKit

struct TableDraft {
    var rows = 3
    var columns = 3
    var hasHeader = true
    private var values: [String: String] = [:]

    subscript(_ row: Int, _ column: Int) -> String {
        get { values["\(row),\(column)"] ?? "" }
        set { values["\(row),\(column)"] = newValue }
    }

    static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func latexEscape(_ text: String) -> String {
        let replacements: [Character: String] = [
            "\\": #"\textbackslash{}"#, "{": #"\{"#, "}": #"\}"#, "$": #"\$"#,
            "&": #"\&"#, "#": "\\#", "_": #"\_"#, "%": #"\%"#,
            "~": #"\textasciitilde{}"#, "^": #"\textasciicircum{}"#
        ]
        return text.map { replacements[$0] ?? String($0) }.joined()
    }

    func source(for format: DocumentFormat) -> String {
        let cells = (0..<rows).map { row in (0..<columns).map { self[row, $0] } }
        switch format {
        case .markdown:
            func line(_ row: [String]) -> String {
                "| " + row.map {
                    $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: #"\|"#)
                        .replacingOccurrences(of: "\n", with: " ")
                }.joined(separator: " | ") + " |"
            }
            let header = hasHeader ? cells[0] : Array(repeating: "", count: columns)
            let separator = Array(repeating: "---", count: columns)
            return ([line(header), line(separator)] + cells.dropFirst(hasHeader ? 1 : 0).map(line)).joined(separator: "\n") + "\n"
        case .html:
            var lines = ["<table>"]
            for (index, row) in cells.enumerated() {
                let tag = hasHeader && index == 0 ? "th" : "td"
                lines.append("  <tr>" + row.map { "<\(tag)>\(Self.htmlEscape($0))</\(tag)>" }.joined() + "</tr>")
            }
            return (lines + ["</table>"]).joined(separator: "\n") + "\n"
        case .latex:
            var lines = [#"\begin{tabular}{|"# + Array(repeating: "l|", count: columns).joined() + "}", #"\hline"#]
            for (index, row) in cells.enumerated() {
                let values = row.map { text -> String in
                    let value = Self.latexEscape(text)
                    return hasHeader && index == 0 ? #"\textbf{"# + value + "}" : value
                }
                lines.append(values.joined(separator: " & ") + #" \\ \hline"#)
            }
            return (lines + [#"\end{tabular}"#]).joined(separator: "\n") + "\n"
        }
    }
}

final class TableBuilder: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let format: DocumentFormat
    private var draft = TableDraft()
    private let grid = EditableTableView()
    private let preview = NSTextView()
    private let rows = NSTextField(string: "3")
    private let columns = NSTextField(string: "3")
    private let rowStepper = NSStepper()
    private let columnStepper = NSStepper()
    private var insert: ((String) -> Void)?

    init(format: DocumentFormat) {
        self.format = format
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 535),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Insert \(format.title) Table"
        window.contentMinSize = NSSize(width: 640, height: 440)
        build()
    }

    required init?(coder: NSCoder) { fatalError("TableBuilder is created programmatically.") }

    func present(on parent: NSWindow, insert: @escaping (String) -> Void) {
        self.insert = insert
        parent.beginSheet(window!)
    }

    private func dimension(_ label: String, field: NSTextField, max: Int) -> NSView {
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = NSNumber(value: max)
        formatter.allowsFloats = false
        field.formatter = formatter
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        field.target = self
        field.action = #selector(resizeGrid)
        field.setAccessibilityLabel("Table " + label.lowercased())
        let stepper = label == "Rows" ? rowStepper : columnStepper
        stepper.minValue = 1
        stepper.maxValue = Double(max)
        stepper.integerValue = 3
        stepper.target = self
        stepper.action = label == "Rows" ? #selector(stepRows(_:)) : #selector(stepColumns(_:))
        return NSStackView(views: [NSTextField(labelWithString: label), field, stepper])
    }

    private func build() {
        let root = NSView()
        window?.contentView = root
        let header = NSStackView(views: [
            dimension("Rows", field: rows, max: 100), dimension("Columns", field: columns, max: 20)
        ])
        header.spacing = 18
        let hasHeader = NSButton(checkboxWithTitle: "First row is a header", target: self, action: #selector(changeHeader(_:)))
        hasHeader.state = .on
        header.addArrangedSubview(hasHeader)
        let note = NSTextField(labelWithString: "Enter cell values below. Resize the table up to 100 rows and 20 columns.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = grid
        scroll.borderType = .lineBorder
        grid.dataSource = self
        grid.delegate = self
        grid.rowHeight = 30
        grid.usesAlternatingRowBackgroundColors = true
        grid.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        grid.gridColor = .separatorColor
        grid.selectionHighlightStyle = .none
        grid.columnAutoresizingStyle = .noColumnAutoresizing
        grid.setAccessibilityLabel("Editable table cells")

        let previewScroll = NSScrollView()
        previewScroll.hasVerticalScroller = true
        previewScroll.documentView = preview
        previewScroll.borderType = .lineBorder
        preview.isEditable = false
        preview.isVerticallyResizable = true
        preview.frame = NSRect(x: 0, y: 0, width: 660, height: 115)
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textContainerInset = NSSize(width: 9, height: 8)
        preview.isHorizontallyResizable = false
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("Generated table source")

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Insert Table", target: self, action: #selector(commit(_:)))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, apply])
        actions.spacing = 8
        for child in [header, note, scroll, previewScroll, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            note.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: previewScroll.topAnchor, constant: -12),
            previewScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            previewScroll.heightAnchor.constraint(equalToConstant: 115),
            previewScroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        rebuildColumns()
    }

    @objc private func stepRows(_ sender: NSStepper) { rows.integerValue = sender.integerValue; resizeGrid() }
    @objc private func stepColumns(_ sender: NSStepper) { columns.integerValue = sender.integerValue; resizeGrid() }

    @objc private func resizeGrid() {
        let newRows = min(100, max(1, rows.integerValue))
        let newColumns = min(20, max(1, columns.integerValue))
        rows.integerValue = newRows
        columns.integerValue = newColumns
        rowStepper.integerValue = newRows
        columnStepper.integerValue = newColumns
        guard newRows != draft.rows || newColumns != draft.columns else { return }
        draft.rows = newRows
        draft.columns = newColumns
        rebuildColumns()
    }

    private func rebuildColumns() {
        for column in grid.tableColumns { grid.removeTableColumn(column) }
        for column in 0..<draft.columns {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column)))
            item.title = "Column \(column + 1)"
            item.width = max(120, 665 / CGFloat(draft.columns))
            grid.addTableColumn(item)
        }
        grid.reloadData()
        grid.frame.size.width = grid.tableColumns.reduce(0) { $0 + $1.width + grid.intercellSpacing.width }
        refreshPreview()
    }

    @objc private func changeHeader(_ sender: NSButton) { draft.hasHeader = sender.state == .on; refreshPreview() }
    private func refreshPreview() { preview.string = draft.source(for: format) }

    func numberOfRows(in tableView: NSTableView) -> Int { draft.rows }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }) else { return nil }
        let field = NSTextField(string: draft[row, column])
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.identifier = NSUserInterfaceItemIdentifier("\(row),\(column)")
        field.delegate = self
        field.setAccessibilityLabel("Row \(row + 1), column \(column + 1)")
        return field
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let key = field.identifier?.rawValue else { return }
        let index = key.split(separator: ",").compactMap { Int($0) }
        guard index.count == 2 else { return }
        draft[index[0], index[1]] = field.stringValue
        refreshPreview()
    }

    @objc private func commit(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        resizeGrid()
        let value = draft.source(for: format)
        window?.sheetParent?.endSheet(window!)
        window?.orderOut(nil)
        insert?(value)
    }
    @objc private func cancel(_ sender: Any?) {
        window?.sheetParent?.endSheet(window!)
        window?.orderOut(nil)
    }
}

private final class EditableTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is NSTextField || super.validateProposedFirstResponder(responder, for: event)
    }
}
