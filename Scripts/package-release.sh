#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --skip-build ) ]]; then
  printf 'Usage: %s [--skip-build]\n' "$0" >&2
  exit 2
fi
if [[ $# -eq 0 ]]; then bash "$root/Scripts/build.sh"; fi

app="$root/build/Inkline.app"
if [[ ! -d "$app" ]]; then
  printf 'Build Inkline first, or omit --skip-build.\n' >&2
  exit 1
fi
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
arch="$(lipo -archs "$app/Contents/MacOS/Inkline" | tr ' ' '-')"
output="$root/build/releases"
mkdir -p "$output"
scratch="$(mktemp -d "$output/.package.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
name="Inkline-${version}-macOS-${arch}.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$scratch/$name"
(
  cd "$scratch"
  shasum -a 256 "$name" > "$name.sha256"
)
mv "$scratch/$name" "$output/$name"
mv "$scratch/$name.sha256" "$output/$name.sha256"
printf '%s\n' "$output/$name" "$output/$name.sha256"
