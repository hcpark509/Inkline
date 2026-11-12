# Inkline for Windows

The Windows edition provides the Markdown, HTML, LaTeX, PDF, project, typeface, settings, autosave, and MCP features of Inkline 1.4. It uses Electron and CodeMirror; the native AppKit Mac edition remains in the repository's `Sources/` directory.

## Download

Get the installer or ZIP from the [Windows release](https://github.com/hcpark509/Inkline/releases/tag/windows-v1.4.0).

- **Setup.exe:** installs for the current user, offers an installation folder, and creates Start menu and desktop shortcuts.
- **ZIP:** extract the complete archive, then run `Inkline.exe`. Keep its DLLs, resources, and other neighboring files together.
- **SHA256SUMS.txt:** contains checksums for the installer and ZIP.

The prebuilt app targets Windows 10/11 x64. The runtime is included, so Node.js and Electron do not need to be installed separately. This release is unsigned. The app does not download or install TeX engines or user fonts automatically.

## Features

| Feature | Windows behavior |
| --- | --- |
| Editing | Markdown, HTML, and LaTeX syntax colors; document tabs; Unicode; Undo/Redo; search; line numbers; adjustable fonts and line spacing. |
| Layout | Source, Split, or Preview, with a draggable divider and optional project sidebar. |
| Markdown | Live rendering, tables, task lists, links, code, relative project images, and raw HTML displayed as text. |
| HTML | Live HTML/CSS rendering with local project assets and authored page scripts disabled. |
| LaTeX | pdfLaTeX or XeLaTeX compilation, a rendered PDF preview, and a compile log. |
| PDF export | A4 Markdown/HTML exports and direct export of the compiled LaTeX PDF. |
| Autosave | Opt-in, with an idle delay; untitled documents require a first manual save. External file changes are reported before replacing their contents. |
| Themes | Orchid, Ocean, Forest, and Graphite, each with light, dark, and system appearance. |
| Tables | Editable values, 1–100 rows, 1–20 columns, optional headers, and Markdown/HTML/LaTeX output. |
| Projects | Remembered project folder, expandable file browser, relative figure insertion, and project-level TeX inputs. |
| Fonts | Private `.ttf` and `.otf` imports, independent source/preview families and sizes, and imported fonts in Markdown PDF export. |
| Settings | A separate window with General, Appearance, and Fonts pages. |
| MCP | The same twelve document tools and resource access as the Mac edition, over a local Windows named pipe. |

Markdown and HTML editing, rendering, and PDF export work offline apart from referenced remote images. LaTeX source editing also works without TeX. Compiling LaTeX requires a separately installed **MiKTeX or TeX Live** distribution with `pdflatex` or `xelatex` available on PATH. The app also checks common per-user MiKTeX/TinyTeX installation folders. The starter uses `amsmath` and `graphicx`.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Ctrl+N | New Markdown document |
| Ctrl+Alt+N | New LaTeX document |
| Ctrl+O | Open documents |
| Ctrl+Alt+O | Open project folder |
| Ctrl+S / Ctrl+Shift+S | Save / Save As |
| Ctrl+Shift+E | Export PDF |
| Ctrl+Enter / Ctrl+Shift+R | Recompile LaTeX |
| Ctrl+1 / Ctrl+2 / Ctrl+3 | Source / Split / Preview |
| Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y | Undo / Redo |
| Ctrl+F | Find in source |
| Ctrl+Shift+H / Ctrl+B / Ctrl+I / Ctrl+K | Heading / bold / italic / link |
| Ctrl+Alt+T / Ctrl+Alt+I | Insert table / figure |
| Ctrl+, | Open Settings |
| Ctrl+W | Close document |

Open Settings to enable autosave. Save a new document once to choose its destination. In Fonts, select a suggested family or type another installed family name; use **Import Fonts** to copy font files into Inkline's private library.

Choose **File → Open Project Folder** to keep documents and figures together. For example, `chapters/note.md` can use `../figures/chart.png`. Markdown also falls back to the project root for paths such as `figures/chart.png`. Save a document into its intended subfolder before inserting relative figures. Double-click supported files in the project browser to open them.

## MCP setup for Codex

After installing Inkline, run this in PowerShell, adjusting the executable and shared folder if needed:

```powershell
$inkline = Join-Path $env:LOCALAPPDATA 'Programs\Inkline\Inkline.exe'
codex mcp add inkline-windows -- $inkline mcp `
  --automation-read-root 'C:\Documents\MyProject' `
  --automation-write-root 'C:\Documents\MyProject'
```

The folder must already exist. If you chose a different installation folder or use the ZIP, point the command to that `Inkline.exe`. Restart the MCP client after adding the connection.

The helper starts the matching GUI app when needed. Write roots also grant read access. With no roots, only untitled documents are available. Content edits require a current revision and enter the editor's Undo history. Unique-match edits reject ambiguous text. Existing unrelated save/export destinations require `overwrite=true`. Modified documents must be saved before MCP closes them. Saved format changes create untitled copies.

The supported tools are `list_documents`, `read_document`, `create_document`, `open_document`, `close_document`, `replace_document`, `edit_document`, `save_document`, `set_view`, `set_format`, `compile_latex`, and `export_pdf`. Open document sources are also MCP resources. Pause MCP from Settings → General.

## Local data

The installed Windows app stores its settings, selected project path, imported font copies, and local MCP authentication token under `%APPDATA%\Inkline`. Replacing the program files does not replace this directory. The installer preserves it on uninstall. Document text remains in files you save; preferences do not contain unsaved document source.

The renderer is sandboxed, with context isolation and no Node integration. Documents use restricted preview resource handlers. HTML scripts, forms, and embedded objects are disabled. MCP file roots constrain helper requests and are not an operating-system sandbox for the GUI or an external TeX engine. LaTeX runs with shell escape disabled, a timeout, and temporary output files.

## Build from source

Use Node.js 22.12 or later on Windows x64. From this folder:

```powershell
npm ci
npx install-electron --no
npm run build
npm start
```

Build the installer and ZIP on Windows:

```powershell
$env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
npm run dist:win
```

Outputs are under `dist-packages/`. `package-lock.json` pins the dependency graph. The build bundles the renderer, PDF worker/assets, generated icon, and runtime dependency notices. `node_modules/`, generated renderer files, installers, caches, and screenshots are ignored by Git.

## Tests and CI

```powershell
npm test
npm run build
$env:INKLINE_REQUIRE_TEX = '1'
npm run test:desktop
```

The core suite checks Unicode/BOM encodings, CRLF preservation, autosave, concurrent saves, external changes, path/symlink boundaries, settings, all table formats, MCP revisions, resources, and local bridge authentication.

The Playwright desktop suite launches an isolated app/profile. It exercises real editor input, native Undo after MCP edits, editable tables, light/dark themes, the settings window, native font import, autosave, project figures, HTML script isolation, all PDF exports, LaTeX preview, compilation shortcuts, and the stdio MCP helper. Without `INKLINE_REQUIRE_TEX=1`, the suite permits the documented missing-engine result; CI requires actual compilation.

The [Windows workflow](../.github/workflows/windows.yml) runs on a Windows runner, installs TinyTeX for tests, builds the installer/ZIP, silently installs the installer, and runs the same desktop suite against the installed `Inkline.exe`. Successful builds upload installers, ZIPs, checksums, and diagnostic screenshots as workflow artifacts. No TeX installation is included in the app download.

Original Inkline source retains the repository's current licensing status. See [third-party notices](../THIRD_PARTY_NOTICES.md); built downloads also include complete generated runtime dependency licenses and Electron/Chromium notices.
