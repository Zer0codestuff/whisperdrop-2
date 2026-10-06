#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app='dist/WhisperDrop 2.app'
tools='.runtime/sparkle-2.10.0/bin'
[[ -x "$tools/generate_appcast" ]] || { echo 'Run scripts/prepare-updater.sh first.' >&2; exit 1; }
codesign --verify --deep --strict "$app"
account='io.github.zer0codestuff.whisperdrop2.sparkle'
public_key="$($tools/generate_keys --account "$account" -p)"
embedded_key="$(plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist")"
[[ "$public_key" == "$embedded_key" ]] || { echo 'The signing key does not match this app. Do not generate a replacement key.' >&2; exit 1; }
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
build="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")"
folder="dist/update-$version-build$build"
mkdir -p "$folder"
archive="WhisperDrop-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$folder/$archive"
if [[ -f "docs/releases/v$version.md" ]]; then
  cp "docs/releases/v$version.md" "$folder/${archive%.zip}.md"
fi
"$tools/generate_appcast" --account "$account" --maximum-deltas 0 --maximum-versions 1 --embed-release-notes \
  --download-url-prefix "https://github.com/Zer0codestuff/whisperdrop-2/releases/download/v$version/" "$folder"
"$tools/sign_update" --account "$account" --verify "$folder/appcast.xml"
(cd "$folder" && shasum -a 256 "$archive" appcast.xml > SHA256SUMS.txt)
echo "Signed update prepared in $folder. Nothing has been uploaded."
