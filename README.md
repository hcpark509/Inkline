# Inkline

Inkline is a Markdown, LaTeX, and HTML editor for **macOS and Windows**, with syntax coloring, split previews, PDF export, project folders, and a local MCP server. It opens `.md`, `.markdown`, `.mdown`, `.mkd`, `.mkdn`, `.tex`, `.html`, and `.htm` files. New documents use UTF-8.

## Download and install

| Platform | Download | Installation |
| --- | --- | --- |
| macOS, Apple silicon | [Mac release](https://github.com/hcpark509/Inkline/releases/tag/v1.4) | Unzip and drag **Inkline.app** into **Applications**. |
| Windows, x64 | [Windows release](https://github.com/hcpark509/Inkline/releases/tag/windows-v1.4.0) | Run the **Setup.exe**, or extract the complete ZIP and run **Inkline.exe**. |

Quit an older copy before replacing it. Preferences and imported fonts are stored separately from the application files. Keep the Windows ZIP's neighboring runtime files with `Inkline.exe`.

The Mac version 1.4 requires **macOS 13 or later and Apple silicon (arm64)**. It is ad hoc signed and is not notarized. The Windows edition targets **Windows 10/11 x64** and is unsigned. See the [Windows guide](Windows/README.md) for Windows shortcuts, build instructions, and MCP configuration. The remaining usage guide describes the native Mac edition.

Markdown and HTML editing, previews, and PDF export work without a TeX installation. LaTeX source editing also works without TeX; compiling a LaTeX PDF requires a separately installed `pdflatex` or `xelatex`. TeX engines and fonts imported by users are not bundled.

## Features

- Markdown, LaTeX, and HTML source editing with syntax colors and Source / Split / Preview layouts.
- Live Markdown and static HTML previews; compiled LaTeX PDF preview and compile logs.
- PDF export, optional autosave, native Undo/Redo, find, and formatting shortcuts.
- Four color themes, each with light, dark, and system appearance options.
- Dedicated settings window, separate source and preview fonts, and private `.ttf` / `.otf` imports.
- Editable table generator for all three document formats and an Insert Figure command.
- Project folders, a file sidebar, and relative asset references.
- A local MCP server for Codex and other compatible MCP clients.

See the [changelog](CHANGELOG.md), [architecture notes](docs/ARCHITECTURE.md), [release guide](docs/RELEASING.md), and [third-party notices](THIRD_PARTY_NOTICES.md). The [Markdown sample](Markdown%20Sample.md) demonstrates headings, lists, tables, links, quotes, and code.

## Open the app

Double-click `build/Inkline.app` in Finder. The first launch opens a sample document. Choose **File → New** for a blank document or **File → New from Example** to open the sample again.

| Shortcut | Action |
| --- | --- |
| ⌘N | New Markdown document |
| ⌥⌘N | New LaTeX document |
| ⌘O | Open a document |
| ⌥⌘O | Open a project folder |
| ⌘S | Save |
| ⇧⌘E | Export PDF |
| ⌘Return / ⇧⌘R | Recompile LaTeX |
| ⌥⌘T | Insert a table |
| ⌥⌘I | Insert a figure |
| ⌘, | Open Settings |
| ⌘1 / ⌘2 / ⌘3 | Source / Split / Preview |
| ⌘F | Find in source |
| ⇧⌘H / ⌘B / ⌘I / ⌘K | Insert heading / bold / italic / link in Markdown or HTML |

Syntax coloring identifies headings, links, code, lists, emphasis, and quotes. The preview supports tables, task lists, links, and images alongside standard Markdown. Relative image paths resolve within the saved document’s folder, or within the selected project. Raw HTML appears as text.

Use **Inkline → Settings…** to open the dedicated settings window. General includes optional autosave, its idle delay, line numbers, line spacing, and the default TeX engine. Autosave starts disabled; enable **Automatically save changes** to save existing files after you stop typing. Save an untitled document once to choose its name and folder. The footer shows the saving mode and reports autosave errors.

Appearance offers Orchid, Ocean, Forest, and Graphite themes, each with light and dark variants. Choose System to follow macOS. Source colors and the Markdown preview update immediately. Markdown PDF exports use the theme’s light variant.

Fonts contains separate source and Markdown preview families and sizes. **Import Fonts…** copies `.ttf` and `.otf` files into Inkline’s private Application Support font library. Imported fonts remain available after relaunch and are registered only inside Inkline. The Markdown preview font also applies to Markdown PDF exports. **Format → Source Font** and **Format → Preview Font** open this settings page.

Use **Insert → Table…** to choose up to 100 rows and 20 columns, enter cell values, choose a header row, and review the generated source before inserting. The generator supports Markdown, HTML, and LaTeX. **File → Export PDF** saves the rendered document as a PDF.

## Projects and figures

Choose **File → Open Project Folder…** to select a working folder. The sidebar shows its files and subfolders; double-click supported documents to open them. Use the refresh button after changes made outside Inkline. The selected project is remembered across launches. **File → Close Project** hides the sidebar.

Documents inside the project can reference figures and inputs elsewhere within it. For example, `chapters/note.md` can use `../figures/chart.png`. Markdown also resolves paths such as `figures/chart.png` from the project root when they are absent beside the document. **Insert → Figure…** generates a document-relative path automatically. For an untitled document, paths start at the project root; save it in that root to retain those paths. Save into the intended subfolder before inserting figures when using a nested document.

## HTML

Open an `.html` or `.htm` file, choose **File → New HTML Document**, or select **HTML** from the window’s format menu. The split preview renders the HTML and CSS as you edit. Keep linked stylesheets, fonts, and images within the selected project, or within the saved document’s folder when no project is selected. The preview uses local assets and leaves page scripts disabled. **File → Export PDF** captures the full rendered HTML page as a single PDF page.

## LaTeX

Open a `.tex` file, choose **File → New LaTeX Document**, or use the format menu in the window. Changing the format of a saved document opens an untitled copy of its source in the selected format. Use the starter document to see the expected LaTeX structure.

Pick pdfLaTeX or XeLaTeX and click **Recompile** or press **⌘Return** to build the PDF. Click **Log** for compiler messages. Inkline uses the TeX distribution installed on your Mac, such as MacTeX or TinyTeX. Saved files can reference inputs and images from their folder and the selected project root. The starter includes `graphicx` for figures. To change the typeset font, set it in your LaTeX preamble. XeLaTeX supports system fonts through the `fontspec` package.

## Codex and MCP

Inkline includes a native MCP server. After installing the app in Applications, run the following command from the folder you want to share with Codex.

```sh
codex mcp add inkline -- /Applications/Inkline.app/Contents/MacOS/Inkline mcp \
  --automation-read-root "$PWD" --automation-write-root "$PWD"
```

Restart Codex or start a new chat to load the connection. The MCP helper opens its matching Inkline app when a tool first needs it. The server and app communicate locally through a macOS message port. Use **MCP → MCP Access Enabled** to pause or resume access and **MCP → Connection Details** to see the most recent request.

Codex can list, read, create, open, edit, save, and close documents, switch source/preview layouts and formats, compile LaTeX, and export PDFs. Open documents also appear as readable MCP resources. File operations and saved-document access follow the configured folders. Untitled documents are available to the connection. Repeat the read/write root flags to share additional folders. With no root flags, access is limited to untitled documents.

Text edits use Inkline’s Undo support and require the revision returned by `read_document`. A stale edit is rejected so a change made in the editor can be read before retrying. `edit_document` requires one unique occurrence of the text to replace. Existing export files and Save As destinations require an explicit `overwrite=true`. Documents with unsaved changes must be saved before MCP can close them.

The regression test runs against a separate QA copy of the app and a temporary working folder.

```sh
python3 Scripts/test-mcp.py "/path/to/Inkline QA.app" "/path/to/temporary-test-folder"
```

The native feature suite creates its own test app with separate preferences. It checks autosave, Undo/Redo, settings actions, editor/sidebar layout, table escaping and compilation, project references, ⌘Return, imported fonts, and Markdown/HTML exports. It requires pdfLaTeX and uses the macOS Georgia font as an import fixture.

```sh
bash Scripts/test-workspace.sh
```

## Build

The following commands build the native **macOS** app. For Windows, use the [Windows build guide](Windows/README.md#build-from-source). Its source and tests live in `Windows/`, alongside the existing Mac implementation in `Sources/`.

On macOS 13 or later with the Xcode Command Line Tools installed, run these commands from the Inkline folder.

```sh
./Scripts/build.sh
open build/Inkline.app
```

The build targets the Mac’s current architecture and ad hoc signs the app for local use. The Markdown renderer is bundled, so the app can render text offline. Remote images require a connection. See the bundled [Marked license](Resources/Preview/Marked-LICENSE.md).

To create an app ZIP and a SHA-256 checksum after building:

```sh
bash Scripts/package-release.sh --skip-build
```

Omit `--skip-build` to rebuild before packaging. Generated apps, archives, compiler caches, and test fixtures stay under the ignored `build/` directory. App downloads are attached to GitHub Releases; the Git repository contains source and documentation.
