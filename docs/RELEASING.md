# Build and release guide

## Requirements

- A Mac running macOS 13 or later.
- Xcode Command Line Tools, including `xcrun swiftc`, or a full Xcode installation.
- For LaTeX checks: an installed pdfLaTeX engine with `amsmath` and `graphicx`. XeLaTeX is optional.
- For the MCP regression suite: Python 3 and a normal logged-in macOS desktop session.
- For publishing: Git and an authenticated GitHub CLI with access to the repository.

The build script targets the current Mac's architecture. The v1.4 prebuilt download was built for arm64. Intel and universal binaries are not included in that release.

## Build

From the repository root:

```sh
bash Scripts/build.sh
open build/Inkline.app
```

The build copies the app resources, compiles `Sources/*.swift` with a macOS 13 deployment target, generates the app icon, and ad hoc signs the result. The finished bundle is `build/Inkline.app`.

Application identity and version live in `Resources/Info.plist`. Keep the version reported by `MCPServer.version` in `Sources/MCPServer.swift` aligned when changing the application version.

## Validate

```sh
bash Scripts/test-workspace.sh
```

The native suite opens temporary test windows, uses a separate test bundle identifier, imports a copy of the macOS Georgia font into that test app's private library, and leaves PDF fixtures under its printed `build/` path. It requires pdfLaTeX.

Run MCP regression against a separate QA copy, so it does not edit documents in your installed app:

```sh
qa_root="$(mktemp -d "$PWD/build/mcp-qa.XXXXXX")"
ditto build/Inkline.app "$qa_root/Inkline QA.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.inkline.editor.mcp-qa' \
  "$qa_root/Inkline QA.app/Contents/Info.plist"
codesign --force --sign - "$qa_root/Inkline QA.app"
mkdir "$qa_root/work"
python3 Scripts/test-mcp.py "$qa_root/Inkline QA.app" "$qa_root/work"
```

The test helper opens that QA app automatically. Quit the QA app after testing. Use a fresh working folder for each run.

## Package

```sh
bash Scripts/package-release.sh --skip-build
```

The script verifies the existing app signature and creates an architecture-labeled ZIP and its SHA-256 checksum under `build/releases/`. Without `--skip-build`, it rebuilds first. The ZIP contains `Inkline.app`, including the renderer and its license notice. It excludes preferences, imported user fonts, compiler caches, and test fixtures.

To check a downloaded archive, run this in the folder containing both files:

```sh
shasum -a 256 -c Inkline-1.4-macOS-arm64.zip.sha256
```

This packaging flow produces an ad hoc signed app. It does not perform Developer ID signing or notarization.

## Publish

Push the source commit before creating a release. For the v1.4 naming scheme:

```sh
git tag -a v1.4 -m 'Inkline 1.4'
git push origin v1.4
gh release create v1.4 \
  build/releases/Inkline-1.4-macOS-arm64.zip \
  build/releases/Inkline-1.4-macOS-arm64.zip.sha256 \
  --repo hcpark509/Inkline \
  --verify-tag --title 'Inkline 1.4' --notes-file docs/releases/v1.4.md
```

For later releases, update the version, changelog, release notes, tag, and artifact names together. Verify that the release's tag points to the commit used to build its app.
