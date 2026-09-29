#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in whisper-cli ffmpeg yt-dlp deno; do
  [[ -x ".runtime/bin/$tool" ]] || { echo 'Run scripts/prepare-runtime.sh first.' >&2; exit 1; }
done
swift build -c release --arch arm64
app='dist/WhisperDrop 2.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Runtime/bin" "$app/Contents/Resources/Runtime/licenses"
binary_dir="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$binary_dir/WhisperDrop" "$app/Contents/MacOS/WhisperDrop"
cp .runtime/bin/* "$app/Contents/Resources/Runtime/bin/"
cp .runtime/licenses/* "$app/Contents/Resources/Runtime/licenses/"
cp docs/third-party.md "$app/Contents/Resources/Runtime/NOTICE.md"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WhisperDrop</string>
<key>CFBundleIdentifier</key><string>io.github.zer0codestuff.whisperdrop2</string>
<key>CFBundleName</key><string>WhisperDrop 2</string>
<key>CFBundleDisplayName</key><string>WhisperDrop 2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>UTExportedTypeDeclarations</key><array>
<dict><key>UTTypeIdentifier</key><string>io.github.zer0codestuff.whisperdrop2.srt</string>
<key>UTTypeDescription</key><string>SubRip subtitles</string>
<key>UTTypeConformsTo</key><array><string>public.text</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>srt</string></array><key>public.mime-type</key><string>application/x-subrip</string></dict></dict>
<dict><key>UTTypeIdentifier</key><string>io.github.zer0codestuff.whisperdrop2.vtt</string>
<key>UTTypeDescription</key><string>WebVTT subtitles</string>
<key>UTTypeConformsTo</key><array><string>public.text</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>vtt</string></array><key>public.mime-type</key><string>text/vtt</string></dict></dict>
</array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Audio or video</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.audio</string><string>public.movie</string></array>
</dict></array>
</dict></plist>
PLIST
mkdir -p dist/AppIcon.iconset
swift scripts/make-icon.swift dist/AppIcon.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" dist/AppIcon.png --out "dist/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" dist/AppIcon.png --out "dist/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns dist/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
for tool in "$app/Contents/Resources/Runtime/bin/"*; do codesign --force --sign - "$tool"; done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "$app"
