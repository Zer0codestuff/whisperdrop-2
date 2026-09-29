#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app='dist/WhisperDrop 2.app'
[[ -d "$app" ]] || { echo 'Build and verify the app first.' >&2; exit 1; }
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
dmg="dist/WhisperDrop-${version}-arm64.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname 'WhisperDrop 2' -srcfolder "$staging" -ov -format UDZO "$dmg"
identity='-'
if security find-identity -p codesigning | grep -F '"WhisperDrop 2 Local"' >/dev/null; then
  identity='WhisperDrop 2 Local'
fi
codesign --force --sign "$identity" "$dmg"
echo "Wrote ${dmg}"
echo 'This build is not notarized. Gatekeeper can block a downloaded copy.'
