import AppKit
import CoreText
import CryptoKit

struct ImportedFont {
    let family: String
    let postScriptName: String
    let url: URL
}

final class LocalFonts {
    static let shared = LocalFonts()
    private(set) var fonts: [ImportedFont] = []

    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.inkline.editor", isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
    }

    func load() {
        fonts = []
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            register(url)
        }
    }

    private func descriptors(_ url: URL) -> [CTFontDescriptor] {
        CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
    }

    private func register(_ url: URL) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        for descriptor in descriptors(url) {
            guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { continue }
            if !fonts.contains(where: { $0.postScriptName == name }) {
                fonts.append(ImportedFont(family: family, postScriptName: name, url: url))
            }
        }
        fonts.sort { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    func importFiles(_ urls: [URL]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls {
            guard ["ttf", "otf"].contains(url.pathExtension.lowercased()), !descriptors(url).isEmpty else {
                throw AutomationError(message: "\(url.lastPathComponent) is not a supported TrueType or OpenType font.")
            }
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let destination = folder.appendingPathComponent(hash).appendingPathExtension(url.pathExtension.lowercased())
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            }
            register(destination)
        }
        NotificationCenter.default.post(name: AppPreferences.didChange, object: nil)
    }

    var families: [String] {
        Array(Set(NSFontManager.shared.availableFontFamilies + fonts.map(\.family)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func font(for family: String) -> ImportedFont? {
        fonts.first(where: { $0.family == family || $0.postScriptName == family })
    }

    func fontAsset(named name: String) -> URL? {
        fonts.first(where: { $0.url.lastPathComponent == name })?.url
    }
}
