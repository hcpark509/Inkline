import AppKit

/// Page dimensions in PostScript points. Inkline exports and prints on A4 unless a document states its own size.
struct PaperSize: Equatable {
    let width: CGFloat
    let height: CGFloat

    static let a4 = PaperSize(millimeters: 210, 297)
    var size: NSSize { NSSize(width: width, height: height) }

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    private init(millimeters width: CGFloat, _ height: CGFloat) {
        self.init(width: width * 72 / 25.4, height: height * 72 / 25.4)
    }

    private init(inches width: CGFloat, _ height: CGFloat) {
        self.init(width: width * 72, height: height * 72)
    }

    private static let named: [String: PaperSize] = [
        "a5": PaperSize(millimeters: 148, 210), "a4": PaperSize(millimeters: 210, 297),
        "a3": PaperSize(millimeters: 297, 420), "b5": PaperSize(millimeters: 176, 250),
        "b4": PaperSize(millimeters: 250, 353), "jis-b5": PaperSize(millimeters: 182, 257),
        "jis-b4": PaperSize(millimeters: 257, 364), "letter": PaperSize(inches: 8.5, 11),
        "legal": PaperSize(inches: 8.5, 14), "ledger": PaperSize(inches: 11, 17)
    ]

    private static let units: [String: CGFloat] = [
        "pt": 1, "pc": 12, "in": 72, "cm": 72 / 2.54, "mm": 72 / 25.4, "q": 72 / 101.6, "px": 0.75
    ]

    /// Parses the value of a CSS `@page { size: … }` descriptor. Returns nil for `auto` or an unsupported value.
    static func css(_ value: String) -> PaperSize? {
        let tokens = value.lowercased().replacingOccurrences(of: "!important", with: "")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, tokens.count <= 3 else { return nil }
        var named: PaperSize?
        var orientation: String?
        var lengths: [CGFloat] = []
        for token in tokens {
            if let size = Self.named[token], named == nil {
                named = size
            } else if ["portrait", "landscape"].contains(token), orientation == nil {
                orientation = token
            } else if let length = length(token) {
                lengths.append(length)
            } else {
                return nil
            }
        }
        if !lengths.isEmpty {
            guard named == nil, orientation == nil, lengths.count <= 2 else { return nil }
            return PaperSize(width: lengths[0], height: lengths.count == 2 ? lengths[1] : lengths[0])
        }
        let base = named ?? .a4
        let long = max(base.width, base.height), short = min(base.width, base.height)
        guard named != nil || orientation != nil else { return nil }
        return orientation == "landscape" ? PaperSize(width: long, height: short) : PaperSize(width: short, height: long)
    }

    private static func length(_ token: String) -> CGFloat? {
        guard let unit = units.keys.sorted(by: { $0.count > $1.count }).first(where: { token.hasSuffix($0) }),
              let number = Double(token.dropLast(unit.count)), number > 0, number.isFinite else { return nil }
        return CGFloat(number) * units[unit]!
    }
}

/// Applies Inkline's paper defaults to LaTeX sources without moving any source line.
enum LatexPaper {
    /// Classes whose page size is part of the class design, such as slides and cropped figures.
    static let fixedSizeClasses: Set<String> = ["beamer", "standalone", "tikzposter", "a0poster", "sciposter", "baposter"]

    private static let explicitPatterns = [
        #"\b(?:[abc]\d{1,2}|letter|legal|executive|ansi[a-e]|b\dj|jisb\d)paper\b"#,
        #"\bpaper(?:size|width|height)?\s*="#,
        #"\\setlength\s*\{?\s*\\(?:paper|pdfpage|stock)(?:width|height)\b"#,
        #"\\(?:paper|pdfpage|stock)(?:width|height)\s*="#,
        #"\\setstocksize\b|\\stock(?:a\d|b\d|letter|legal|executive)\b"#,
        #"\\(?:usepackage|RequirePackage)\s*(?:\[[^\]]*\])?\s*\{[^}]*\b(?:beamerposter|a0poster)\b"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let documentClass = try! NSRegularExpression(
        pattern: #"\\documentclass\s*(?:\[[^\]]*\])?\s*\{\s*([^}\s]+)\s*\}"#)

    /// Keeps the PDF media box in step with the paper size LaTeX lays out, unless the document or a package
    /// such as geometry has already set the PDF page size.
    static let pageSync = #"\edef\InklinePaperW{\the\pdfpagewidth}\edef\InklinePaperH{\the\pdfpageheight}"#
        + #"\AtBeginDocument{\ifdim\pdfpagewidth=\InklinePaperW\relax\ifdim\pdfpageheight=\InklinePaperH\relax"#
        + #"\ifdim\paperwidth>0pt\ifdim\paperheight>0pt\pdfpagewidth=\paperwidth\pdfpageheight=\paperheight"#
        + #"\fi\fi\fi\fi}"#

    static func preamble(of source: String) -> String {
        let uncommented = source.replacingOccurrences(of: #"(?<!\\)%[^\n]*"#, with: "", options: .regularExpression)
        guard let end = uncommented.range(of: #"\begin{document}"#) else { return uncommented }
        return String(uncommented[..<end.lowerBound])
    }

    static func className(in source: String) -> String? {
        let preamble = preamble(of: source)
        let range = NSRange(preamble.startIndex..., in: preamble)
        guard let match = documentClass.firstMatch(in: preamble, range: range),
              let name = Range(match.range(at: 1), in: preamble) else { return nil }
        return String(preamble[name])
    }

    /// True when the source chooses its own paper size, so Inkline must not apply A4.
    static func statesPaperSize(_ source: String) -> Bool {
        if let name = className(in: source), fixedSizeClasses.contains(name) { return true }
        let preamble = preamble(of: source)
        let range = NSRange(preamble.startIndex..., in: preamble)
        return explicitPatterns.contains { $0.firstMatch(in: preamble, range: range) != nil }
    }

    /// Returns the source to compile: A4 is passed to the document class when no size is stated, and the PDF
    /// page size follows the layout. Everything is added before the first line's text, so line numbers in
    /// compiler messages stay the same.
    static func prepare(_ source: String) -> String {
        var prefix = pageSync
        if !statesPaperSize(source), let name = className(in: source) {
            prefix = #"\PassOptionsToClass{a4paper}{"# + name + "}" + prefix
        }
        return prefix + source
    }
}
