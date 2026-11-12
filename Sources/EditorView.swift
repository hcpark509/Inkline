import AppKit

enum Palette {
    enum Role: CaseIterable {
        case chrome, source, paper, ink, muted, line, purple, lavender, teal, blue, orange, rose
    }

    static var chrome: NSColor { color(.chrome) }
    static var source: NSColor { color(.source) }
    static var paper: NSColor { color(.paper) }
    static var ink: NSColor { color(.ink) }
    static var muted: NSColor { color(.muted) }
    static var line: NSColor { color(.line) }
    static var purple: NSColor { color(.purple) }
    static var lavender: NSColor { color(.lavender) }
    static var teal: NSColor { color(.teal) }
    static var blue: NSColor { color(.blue) }
    static var orange: NSColor { color(.orange) }
    static var rose: NSColor { color(.rose) }

    static func color(_ role: Role) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = AppPreferences.theme.colors(dark: dark)[role]!
            return NSColor(srgbRed: CGFloat(value >> 16) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

final class SourceEditor: NSTextView {
    private(set) var lineStarts = [0]
    convenience init() {
        self.init(usingTextLayoutManager: false)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        textContainerInset = NSSize(width: 15, height: 23)
        backgroundColor = Palette.source
        insertionPointColor = Palette.purple
        selectedTextAttributes = [.backgroundColor: Palette.lavender]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = AppPreferences.lineSpacing
        paragraph.defaultTabInterval = 28
        defaultParagraphStyle = paragraph
        textColor = Palette.ink
        typingAttributes = [.foregroundColor: Palette.ink, .paragraphStyle: paragraph]
        updateFont()
        setAccessibilityLabel("Markdown source editor")
    }

    func updateFont() {
        let selected = FontPreference.source.sourceFont
        font = selected
        typingAttributes[.font] = selected
        let paragraph = (defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.lineSpacing = AppPreferences.lineSpacing
        defaultParagraphStyle = paragraph
        textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                                 range: NSRange(location: 0, length: (string as NSString).length))
        typingAttributes[.paragraphStyle] = paragraph
        backgroundColor = Palette.source
        textColor = Palette.ink
        insertionPointColor = Palette.purple
        selectedTextAttributes = [.backgroundColor: Palette.lavender]
        enclosingScrollView?.rulersVisible = AppPreferences.showsLineNumbers
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func updateLines() {
        let text = string as NSString
        lineStarts = [0]
        var location = 0
        while location < text.length {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: location, length: 0))
            if contentsEnd < end { lineStarts.append(end) }
            location = end
        }
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func lineIndex(at location: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= location { low = middle } else { high = middle }
        }
        return low
    }
}

final class LineRuler: NSRulerView {
    private weak var editor: SourceEditor?

    init(scrollView: NSScrollView, editor: SourceEditor) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 45
    }

    required init(coder: NSCoder) { fatalError("LineRuler uses programmatic layout") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Palette.source.setFill()
        bounds.fill()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer,
              let clip = scrollView?.contentView else { return }

        let origin = editor.textContainerOrigin
        let visible = clip.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let visibleGlyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: Palette.muted
        ]

        func drawNumber(_ number: Int, at fragment: NSRect) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let position = editor.convert(NSPoint(x: 0, y: origin.y + fragment.midY), to: self)
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 10, y: position.y - size.height / 2),
                       withAttributes: attributes)
        }

        layout.enumerateLineFragments(forGlyphRange: visibleGlyphs) { _, used, _, glyphs, _ in
            let offset = layout.characterIndexForGlyph(at: glyphs.location)
            let index = editor.lineIndex(at: offset)
            if offset == editor.lineStarts[index] { drawNumber(index + 1, at: used) }
        }
        if layout.extraLineFragmentTextContainer != nil {
            let extra = layout.extraLineFragmentUsedRect
            if visible.intersects(extra.insetBy(dx: -20, dy: 0)) {
                drawNumber(editor.lineStarts.count, at: extra)
            }
        }
    }
}

enum MarkdownHighlight {
    private struct Rule {
        let regex: NSRegularExpression
        let color: NSColor

        init(_ pattern: String, _ color: NSColor) {
            regex = try! NSRegularExpression(pattern: pattern)
            self.color = color
        }
    }

    private static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})([^\r\n]*)"#)
    private static let rules: [Rule] = [
        Rule(#"^ {0,3}#{1,6}(?=\s|$).*"#, Palette.purple),
        Rule(#"^ {0,3}(?:> ?)+.*"#, Palette.rose),
        Rule(#"^\s*(?:[-+*]|\d+[.)])(?=\s)"#, Palette.blue),
        Rule(#"^ {0,3}(?:={2,}|-{2,}|(?:\*\s*){3,}|(?:_\s*){3,})\s*$"#, Palette.purple),
        Rule(#"\[(?: |x|X)\](?=\s)"#, Palette.blue),
        Rule(#"(?<!\\)(?:\*\*[^*\r\n]+\*\*|__[^_\r\n]+__|~~[^~\r\n]+~~)"#, Palette.blue),
        Rule(#"(?<![\w*\\])\*[^*\r\n]+\*(?!\*)|(?<![\w_\\])_[^_\r\n]+_(?![\w_])"#, Palette.rose),
        Rule(#"(?<!\\)!?\[[^\]\r\n]+\](?:\([^\r\n]*?\)|\[[^\]\r\n]*\])|<https?://[^>\s]+>"#, Palette.teal),
        Rule(#"(?<![`\\])(`+)(?!`)[^`\r\n](?:[^\r\n]*?[^\r\n])?\1(?!`)"#, Palette.orange)
    ]

    static func apply(to editor: SourceEditor) {
        guard let layout = editor.layoutManager, !editor.hasMarkedText() else { return }
        let text = editor.string
        let source = text as NSString
        let all = NSRange(location: 0, length: source.length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard all.length > 0 else { return }
        var openFence: (character: Character, length: Int)?

        func paint(_ range: NSRange, _ color: NSColor) {
            layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
        }

        for (index, start) in editor.lineStarts.enumerated() where start < source.length {
            let end = index + 1 < editor.lineStarts.count ? editor.lineStarts[index + 1] : source.length
            let range = NSRange(location: start, length: end - start)
            let fenceMatch = fence.firstMatch(in: text, range: range)
            if let open = openFence {
                paint(range, Palette.orange)
                if let match = fenceMatch {
                    let marker = source.substring(with: match.range(at: 1))
                    let suffix = source.substring(with: match.range(at: 2))
                    if marker.first == open.character, marker.count >= open.length,
                       suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                        openFence = nil
                    }
                }
            } else if let match = fenceMatch {
                let marker = source.substring(with: match.range(at: 1))
                let suffix = source.substring(with: match.range(at: 2))
                if let character = marker.first, character != "`" || !suffix.contains("`") {
                    openFence = (character, marker.count)
                    paint(range, Palette.orange)
                }
            } else {
                for rule in rules {
                    rule.regex.enumerateMatches(in: text, range: range) { match, _, _ in
                        if let match { paint(match.range, rule.color) }
                    }
                }
            }
        }
    }
}

enum LatexHighlight {
    private static let commands = try! NSRegularExpression(pattern: #"\\(?:[a-zA-Z@]+\*?|[^\r\n])"#)
    private static let comments = try! NSRegularExpression(pattern: #"(?:^|[^\\\r\n])(?:\\\\)*(%[^\r\n]*)"#,
                                                         options: .anchorsMatchLines)
    private static let math = try! NSRegularExpression(pattern: #"(?<!\\)(\$\$|\$).*?\1|\\\([^\r\n]*?\\\)|\\\[[\s\S]*?\\\]"#)

    static func apply(to editor: SourceEditor) {
        guard let layout = editor.layoutManager, !editor.hasMarkedText() else { return }
        let text = editor.string
        let all = NSRange(text.startIndex..<text.endIndex, in: text)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        for (pattern, color, group) in [(math, Palette.orange, 0), (commands, Palette.purple, 0),
                                        (comments, Palette.teal, 1)] {
            pattern.enumerateMatches(in: text, range: all) { match, _, _ in
                if let match {
                    layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: match.range(at: group))
                }
            }
        }
    }
}

enum HTMLHighlight {
    private static let tokens = try! NSRegularExpression(
        pattern: #"(?i)(<!--[\s\S]*?(?:-->|$))|(</?[a-z!][\w:.-]*(?:[^"'<>]|"[^"]*"|'[^']*')*>)|(&#?[a-z\d]+;)"#
    )
    private static let attributes = try! NSRegularExpression(
        pattern: #"\s+([\w:.-]+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s>]+))?"#
    )

    static func apply(to editor: SourceEditor) {
        guard let layout = editor.layoutManager, !editor.hasMarkedText() else { return }
        let text = editor.string
        let all = NSRange(text.startIndex..<text.endIndex, in: text)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)

        func paint(_ range: NSRange, _ color: NSColor) {
            guard range.location != NSNotFound else { return }
            layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
        }

        tokens.enumerateMatches(in: text, range: all) { match, _, _ in
            guard let match else { return }
            let tag = match.range(at: 2)
            if tag.location != NSNotFound {
                paint(tag, Palette.purple)
                attributes.enumerateMatches(in: text, range: tag) { attribute, _, _ in
                    guard let attribute else { return }
                    paint(attribute.range(at: 1), Palette.blue)
                    paint(attribute.range(at: 2), Palette.orange)
                }
            } else {
                paint(match.range, match.range(at: 1).location != NSNotFound ? Palette.teal : Palette.rose)
            }
        }
    }
}
