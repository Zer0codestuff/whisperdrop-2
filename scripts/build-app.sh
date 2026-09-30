#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in whisper-cli whisper-server whisper-vad-speech-segments ffmpeg yt-dlp deno; do
  [[ -x ".runtime/bin/$tool" ]] || { echo 'Run scripts/prepare-runtime.sh first.' >&2; exit 1; }
done
[[ -f .runtime/models/ggml-silero-v6.2.0.bin ]] || { echo 'Run scripts/prepare-runtime.sh first.' >&2; exit 1; }
swift build -c release --arch arm64
app='dist/WhisperDrop 2.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Runtime/bin" "$app/Contents/Resources/Runtime/licenses" "$app/Contents/Resources/Runtime/models"
binary_dir="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$binary_dir/WhisperDrop" "$app/Contents/MacOS/WhisperDrop"
cp .runtime/bin/* "$app/Contents/Resources/Runtime/bin/"
cp .runtime/licenses/* "$app/Contents/Resources/Runtime/licenses/"
cp .runtime/models/ggml-silero-v6.2.0.bin "$app/Contents/Resources/Runtime/models/"
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
<key>CFBundleShortVersionString</key><string>2.3.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>WhisperDrop uses the microphone for dictation and notes. Audio stays on this Mac.</string>
<key>NSAudioCaptureUsageDescription</key><string>WhisperDrop records audio from other apps for meeting notes. Audio stays on this Mac.</string>
<key>NSScreenCaptureUsageDescription</key><string>WhisperDrop uses screen capture only to record meeting audio on macOS 14.0 and 14.1. Audio stays on this Mac.</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
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
identity='-'
if [[ -n "${WD_SIGN_IDENTITY:-}" ]]; then
  identity="$WD_SIGN_IDENTITY"
elif security find-identity -p codesigning | grep -F '"WhisperDrop 2 Local"' >/dev/null; then
  identity='WhisperDrop 2 Local'
fi
echo "Signing identity: ${identity}"
for tool in "$app/Contents/Resources/Runtime/bin/"*; do
  codesign --force --sign "$identity" "$tool"
done
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "$app"
