# Changelog

## [Windows 1.4.0] — 2026-11-12

- Added a Windows implementation with Markdown, HTML, and LaTeX editing, previews, PDF export, autosave, keyboard shortcuts, all four color themes, editable table generation, project folders, private font imports, and a separate Settings window.
- Added Windows named-pipe/stdio MCP integration with the twelve document tools, revision protection, Undo, resources, and configured read/write roots.
- Added pinned dependencies, Windows installer and ZIP packaging, core and desktop regression suites, and a Windows CI workflow that tests the installed app.
- Preserved the native Mac app and its existing v1.4 release.

[Windows 1.4.0]: https://github.com/hcpark509/Inkline/releases/tag/windows-v1.4.0

## [1.4] — 2026-11-12

First GitHub release of Inkline, including the complete Markdown, LaTeX, HTML, and MCP implementation.

### Added

- Optional autosave with an adjustable idle delay. New documents require an initial manual save.
- Command-Return and Shift-Command-R shortcuts for LaTeX compilation.
- Orchid, Ocean, Forest, and Graphite themes with light, dark, and system appearance.
- A separate Settings window for saving, appearance, source and preview fonts, line numbers, line spacing, and the default TeX engine.
- Private TrueType and OpenType font imports for source text, Markdown previews, and Markdown PDF exports.
- An editable table generator with up to 100 rows and 20 columns, optional headers, and Markdown, HTML, and LaTeX output.
- A remembered project folder, file sidebar, and relative image/input resolution.
- An Insert Figure command that generates relative references.

### Included capabilities

- Native AppKit document windows, syntax coloring, find, formatting shortcuts, and Undo/Redo.
- Bundled offline Markdown rendering with tables and task lists.
- Static HTML/CSS rendering with local project assets and page scripts disabled.
- pdfLaTeX and XeLaTeX compilation, PDF preview, and compile logs.
- Markdown, HTML, and LaTeX PDF exports.
- Twelve local MCP tools and readable document resources, revision checks, and configurable file roots.
- Build, native workspace regression, MCP regression, icon generation, and release packaging scripts.

### Distribution

- Prebuilt app: Apple silicon, macOS 13 or later.
- The app is ad hoc signed and is not notarized.
- LaTeX engines are installed separately. No imported font files or local user documents are included in the download.

[1.4]: https://github.com/hcpark509/Inkline/releases/tag/v1.4
