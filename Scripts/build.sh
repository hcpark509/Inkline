#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build"
mkdir -p "$build"
scratch="$(mktemp -d "$build/.inkline.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
app="$scratch/Inkline.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$root/Resources/Info.plist" "$contents/Info.plist"
cp "$root/Resources/Welcome.md" "$contents/Resources/"
cp -R "$root/Resources/Preview" "$contents/Resources/"

arch="$(uname -m)"
xcrun swiftc -swift-version 5 -O -target "${arch}-apple-macos13.0" \
  -module-cache-path "$scratch/ModuleCache" "$root"/Sources/*.swift -o "$contents/MacOS/Inkline"

xcrun swift -module-cache-path "$scratch/ModuleCache" "$root/Scripts/make-icon.swift" "$contents/Resources/Inkline.icns"
codesign --force --sign - "$app"

output="$build/Inkline.app"
if [[ -e "$output" ]]; then mv "$output" "$scratch/Previous.app"; fi
mv "$app" "$output"
printf '%s\n' "$output"
