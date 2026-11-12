# Third-party notices

## Marked

Inkline bundles **Marked 15.0.12** to render Markdown. The unmodified browser bundle is at `Resources/Preview/marked.min.js`.

The bundled [Marked license and Markdown notices](Resources/Preview/Marked-LICENSE.md) contain the upstream copyright notices, license terms, and disclaimers. That notice file is also copied into `Inkline.app/Contents/Resources/Preview/` by the build script.

Upstream project: https://github.com/markedjs/marked

## Platform frameworks and external software

Inkline uses macOS frameworks including AppKit, WebKit, PDFKit, CoreText, CoreFoundation, and CryptoKit. It does not bundle a TeX distribution. LaTeX compilation uses an engine already installed on the user's Mac.

Fonts imported through Settings remain in the user's private Inkline font library. Those fonts and the macOS Georgia font used by the native test suite are not redistributed in this repository or release archive.

## Project licensing

A project-wide license for Inkline's original source has not been selected. The third-party components retain their own licenses; this notice does not change those terms.
