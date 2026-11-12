#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
scratch="$(mktemp -d "$root/build/.workspace-tests.XXXXXX")"
app="$scratch/Inkline Tests.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.inkline.editor.workspace-tests' "$app/Contents/Info.plist"
cp -R "$root/Resources/Preview" "$app/Contents/Resources/"

sources=()
for source in "$root"/Sources/*.swift; do
  if [[ "${source##*/}" != main.swift ]]; then sources+=("$source"); fi
done
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path "$root/build/TestModuleCache" "${sources[@]}" \
  "$root/Scripts/WorkspaceTests/main.swift" -o "$app/Contents/MacOS/Inkline"
codesign --force --sign - "$app"
"$app/Contents/MacOS/Inkline"
printf 'Native workspace checks passed. PDF fixtures: %s/Fixtures\n' "$scratch"
