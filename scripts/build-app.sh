#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in whisper-cli whisper-server whisper-vad-speech-segments llama-server ffmpeg yt-dlp deno; do
  [[ -x ".runtime/bin/$tool" ]] || { echo 'Run scripts/prepare-runtime.sh first.' >&2; exit 1; }
done
[[ -f .runtime/models/ggml-silero-v6.2.0.bin ]] || { echo 'Run scripts/prepare-runtime.sh first.' >&2; exit 1; }
[[ -f .runtime/bin/mlx.metallib && -f .runtime/bin/Resources/mlx.metallib ]] || { echo 'Run scripts/prepare-mlx.sh first.' >&2; exit 1; }
swift build -c release --arch arm64
app='dist/WhisperDrop 2.app'
# A fresh bundle: binaries copied over older ones in place keep a stale cached signature.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Runtime/bin" "$app/Contents/Resources/Runtime/licenses" "$app/Contents/Resources/Runtime/models"
sparkle='.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
[[ -d "$sparkle" ]] || { echo 'Sparkle framework is missing from SwiftPM artifacts.' >&2; exit 1; }
# ditto retains versioned framework symlinks and helper executable permissions.
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
cp .build/checkouts/Sparkle/LICENSE "$app/Contents/Resources/Runtime/licenses/Sparkle.txt"
binary_dir="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$binary_dir/WhisperDrop" "$app/Contents/MacOS/WhisperDrop"
cp -R .runtime/bin/. "$app/Contents/Resources/Runtime/bin/"
cp "$binary_dir/parakeet-server" "$app/Contents/Resources/Runtime/bin/parakeet-server"
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
<key>CFBundleShortVersionString</key><string>2.6.0</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>WhisperDrop uses the microphone for dictation and notes. Audio stays on this Mac.</string>
<key>NSAudioCaptureUsageDescription</key><string>WhisperDrop records audio from other apps for meeting notes. Audio stays on this Mac.</string>
<key>NSScreenCaptureUsageDescription</key><string>WhisperDrop uses screen capture only to record meeting audio on macOS 14.0 and 14.1. Audio stays on this Mac.</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSServices</key><array><dict>
<key>NSMenuItem</key><dict><key>default</key><string>WhisperDrop: Improve text</string></dict>
<key>NSMessage</key><string>improveText</string>
<key>NSPortName</key><string>WhisperDrop 2</string>
<key>NSSendTypes</key><array><string>NSStringPboardType</string></array>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Audio or video</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.audio</string><string>public.movie</string></array>
</dict></array>
</dict></plist>
PLIST
/usr/bin/python3 - "$app/Contents/Info.plist" <<'PY'
import json,os,pathlib,plistlib,sys,base64,urllib.parse
p=pathlib.Path(sys.argv[1]); info=plistlib.loads(p.read_bytes())
config=json.loads(pathlib.Path('Resources/UpdateConfiguration.json').read_text())
info['CFBundleShortVersionString']=os.environ.get('WD_APP_VERSION',info['CFBundleShortVersionString'])
info['CFBundleVersion']=os.environ.get('WD_BUILD_NUMBER',info['CFBundleVersion'])
assert info['CFBundleVersion'].isdigit(), 'WD_BUILD_NUMBER must be an integer'
info['CFBundleIdentifier']=os.environ.get('WD_BUNDLE_IDENTIFIER',info['CFBundleIdentifier'])
verification=info['CFBundleIdentifier']=='io.github.zer0codestuff.whisperdrop2.updater-verification'
assert verification or info['CFBundleIdentifier']=='io.github.zer0codestuff.whisperdrop2', 'Unsupported bundle identifier'
feed=os.environ.get('WD_UPDATE_FEED_URL',config['feedURL']); url=urllib.parse.urlparse(feed)
assert url.hostname and not url.username and not url.password and not url.fragment
assert url.scheme=='https' or (verification and url.scheme=='http' and url.hostname in ['127.0.0.1','localhost','::1']), 'Updates require HTTPS outside isolated loopback verification'
key=os.environ.get('WD_UPDATE_PUBLIC_KEY',config['publicKey']);assert len(base64.b64decode(key,validate=True))==32
info.update(SUFeedURL=feed,SUPublicEDKey=key,SUEnableAutomaticChecks=False,SUAutomaticallyUpdate=False,
            SUAllowsAutomaticUpdates=False,SUEnableSystemProfiling=False,SUVerifyUpdateBeforeExtraction=True,
            SURequireSignedFeed=True,SUSignedFeedFailureExpirationInterval=0)
if verification:
 directory=pathlib.Path(os.environ['WD_UPDATE_VERIFICATION_DIR']).resolve()
 assert str(directory).startswith(str(pathlib.Path('.experiments').resolve())+os.sep), 'Verification data must stay under .experiments'
 info['WDUpdateVerificationDataDirectory']=str(directory)
 info['NSAppTransportSecurity']={'NSAllowsLocalNetworking':True}
p.write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_XML))
PY
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
identity='-'
if [[ -n "${WD_SIGN_IDENTITY:-}" ]]; then
  identity="$WD_SIGN_IDENTITY"
elif security find-identity -p codesigning | grep -F '"WhisperDrop 2 Local"' >/dev/null; then
  identity='WhisperDrop 2 Local'
fi
echo "Signing identity: ${identity}"
for tool in "$app/Contents/Resources/Runtime/bin/"*; do
  # Shader libraries are resources sealed by the app signature, not code.
  [[ -f "$tool" && -x "$tool" ]] || continue
  codesign --force --sign "$identity" "$tool"
done
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$identity" "$framework/Autoupdate"
for service in "$framework/XPCServices/"*.xpc; do
  codesign --force --sign "$identity" "$service"
done
codesign --force --sign "$identity" "$framework/Updater.app"
codesign --force --sign "$identity" "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
echo "$app"
