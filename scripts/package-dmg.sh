#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app='dist/WhisperDrop 2.app'
[[ -d "$app" ]] || { echo 'Build and verify the app first.' >&2; exit 1; }
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname 'WhisperDrop 2' -srcfolder "$staging" -ov -format UDZO 'dist/WhisperDrop-2.0.0-arm64.dmg'
echo 'This local build is ad hoc signed, not notarized.'
