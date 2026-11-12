# Architecture

This page describes the native **macOS** implementation. The separate [Windows implementation](../Windows/README.md) uses Electron, CodeMirror, a restricted main/preload/renderer interface, and a standalone console MCP helper over a local named pipe. Both editions implement the same document formats and twelve MCP tools.

Inkline is a Swift/AppKit document application targeting macOS 13 and later. The app builds directly with the Xcode Command Line Tools; it has no Swift Package Manager, npm, or Python runtime dependency. Python is used only by the MCP regression script.

## Source map

| File | Responsibility |
| --- | --- |
| `Sources/main.swift` | Launch the GUI or run the `mcp` stdio subcommand. |
| `Application.swift` | Application lifecycle, menus, project commands, and window keyboard shortcuts. |
| `InklineDocument.swift` | Document source, encoding/BOM preservation, save/ autosave, revisions, and undoable automation edits. |
| `WorkspaceController.swift` | Editor/preview layouts, document format, formatting actions, figures, tables, compilation, and export orchestration. |
| `EditorView.swift` | Plain-text editor, line ruler, syntax highlighting, and palette roles. |
| `PreviewController.swift` | Markdown WebKit view, bundled resource handlers, project images, preview fonts/themes, and paginated PDF export. |
| `HTMLPreviewController.swift` | Static HTML rendering, local assets, and full-page HTML PDF export. |
| `LatexCompiler.swift` | Engine discovery, temporary build directories, project inputs, compiler deadlines, and logs. |
| `AppPreferences.swift` | Persistent preferences, appearance, and light/dark theme palettes. |
| `FontPreferences.swift`, `LocalFonts.swift` | Source/preview typefaces, app-private font copies, CoreText registration, and preview font assets. |
| `SettingsWindowController.swift` | Dedicated General, Appearance, and Fonts settings tabs. |
| `ProjectWorkspace.swift` | Remembered project folder, relative paths, and project file browser. |
| `TableBuilder.swift` | Editable table draft, native grid sheet, and format-specific escaping. |
| `MCPServer.swift` | JSON-RPC stdio transport, protocol negotiation, tool schemas, file roots, and app bridge client. |
| `AutomationBridge.swift` | GUI-side local message port, document access, and MCP operations on the main thread. |
| `Resources/Preview/` | Bundled Marked renderer, preview HTML/CSS/JavaScript, and upstream license. |

## Document flow

An `InklineDocument` owns the source. Its `WorkspaceController` connects an undoable plain-text editor to the appropriate preview. Markdown and HTML refresh as source changes. LaTeX builds on demand and marks an older PDF out of date when its inputs change.

Autosave is opt-in. A debounce timer saves documents that already have a file location. Disabling autosave cancels pending work; untitled documents require a manual save to choose a destination. Preferences and font changes update presentation without changing source content.

The selected project folder is stored as a bookmark. Saved documents inside that folder can resolve project-relative assets. Without a project, Markdown and HTML local assets are limited to the document's folder and descendants. Markdown first tries a document-relative asset, then the project root. Canonical paths are checked before assets are served.

## Rendering and export

- Markdown uses the bundled Marked parser in a nonpersistent `WKWebView`. Raw HTML in Markdown is escaped. Local images use a restricted resource handler; remote HTTP(S) images can load when referenced.
- Imported font assets are served from the preview's own custom URL scheme. Font files are copied under `Application Support/<bundle identifier>/Fonts` and registered with CoreText for the app process.
- Markdown PDF export uses a dedicated light-theme renderer and paginates at A4 size.
- HTML uses a separate WebKit configuration with page scripts disabled. Its export captures the rendered HTML page as a single PDF page.
- LaTeX invokes `pdflatex` or `xelatex` for two passes in a temporary directory, with shell escape disabled and a 45-second compile deadline. The document directory and project root are added to `TEXINPUTS`. Its output is displayed with PDFKit and exported as the compiled PDF.

## MCP integration

The executable's `mcp` subcommand reads newline-delimited JSON-RPC from stdin and writes replies to stdout. It supports initialization, tools, and document resources. A per-user message-port name derived from the app bundle path connects the helper to the matching GUI app. The helper opens that app when needed.

Tool names:

| Group | Tools |
| --- | --- |
| Documents | `list_documents`, `read_document`, `create_document`, `open_document`, `close_document` |
| Content | `replace_document`, `edit_document`, `save_document` |
| Presentation | `set_view`, `set_format` |
| Output | `compile_latex`, `export_pdf` |

Read/write roots are explicit helper arguments. Write roots also grant read access; no roots grants access only to untitled documents. The helper/bridge validate canonical paths, including symlink destinations. These roots govern requests through Inkline's MCP helper; they are not an operating-system sandbox for the GUI or an external TeX engine.

Content edits and PDF export use a SHA-256 revision of the document format and source. Stale revisions are rejected. Content edits enter native Undo history. Unique-match edits reject ambiguous text. Existing unrelated save/export destinations require `overwrite=true`. MCP refuses to close modified documents. Changing a saved document's format opens an untitled copy.

## Tests and generated files

`Scripts/test-workspace.sh` builds an isolated native test app with its own bundle identifier and preferences. `Scripts/WorkspaceTests/main.swift` exercises autosave, settings actions, Undo/Redo, table escaping and focus, window layout, project assets, compilation shortcuts, imported fonts, and exports.

`Scripts/test-mcp.py` drives a separate QA app through the same stdio MCP interface used by clients. It covers lifecycle, content edits, stale revisions, resources, save/reopen, format copies, PDF export, read-only roots, symlink escapes, overwrite protection, and modified-close refusal.

Build outputs, module caches, QA apps, test fixtures, and release archives live under the ignored `build/` directory.
