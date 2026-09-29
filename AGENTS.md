# WhisperDrop 2

Native macOS transcription app, rebuilt from the WhisperDrop project started by Gabriele Monni and Luca Arisci. Original: https://github.com/LucaArisci/whisper-drop/tree/dev.

## Architecture and constraints
- SwiftUI app and Foundation core, Swift Package Manager, Apple Silicon, macOS 14+.
- Local whisper.cpp with Metal and quantized GGML models. GGUF is not interchangeable with Whisper GGML.
- Audio/video imports and YouTube videos/playlists through bundled FFmpeg, yt-dlp and Deno.
- Black, white and original green #2bd66b. Spacious transcript view; restrained native glass on macOS 26+.
- English artifacts and UI. No em dashes. Apply the installed unslop skill to writing.
- No Apple Developer membership is available. Local builds use ad hoc signing and are not notarized.

## Run and verify
- `swift test` runs focused core tests.
- `scripts/prepare-runtime.sh` builds/downloads pinned runtime tools.
- `scripts/build-app.sh` builds the app in `dist/WhisperDrop 2.app`.
- `open 'dist/WhisperDrop 2.app'` runs it.
- `scripts/package-dmg.sh` packages the locally verified app.
- Inspect the running native app and test real transcription before claiming it works.

## Current status
Initial implementation in progress. Repository target is public `Zer0codestuff/whisperdrop-2`.

## Do not
- Change or push to the original repository.
- Drop YouTube or playlist support.
- Add cloud transcription, accounts, analytics or API keys.
- Claim an ad hoc signature eliminates Gatekeeper warnings.
- Replace the original monochrome/green identity or use glass behind transcript text.
- Publish credentials, local user data, model weights or build artifacts to Git.
