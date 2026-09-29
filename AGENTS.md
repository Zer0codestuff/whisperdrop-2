# WhisperDrop 2

Native macOS transcription app, rebuilt from the WhisperDrop project started by Gabriele Monni and Luca Arisci. Original: https://github.com/LucaArisci/whisper-drop/tree/dev.

## Architecture and constraints
- SwiftUI app and Foundation core, Swift Package Manager, Apple Silicon, macOS 14+.
- Local whisper.cpp with Metal and quantized GGML models. GGUF is not interchangeable with Whisper GGML.
- Audio/video imports and YouTube videos/playlists through bundled FFmpeg, yt-dlp and Deno.
- Dictation is a global push-to-talk path: hotkey, microphone, resident `whisper-server`, then text inserted at the cursor.
- Notes record microphone and/or system audio, chunk the audio, and transcribe while the note is open. `ModelHost` keeps one model process and unloads it after the idle policy, unless Keep model ready is on.
- `WhisperDropCore` holds domain types, chunking, hallucination filtering and transcript merging. The app target owns capture, the model host, dictation, notes, settings and the menu bar. `WhisperDropApp` creates those objects once and injects them into the main window, the menu bar and Settings.
- Black, white and original green #2bd66b. Spacious transcript view; restrained native glass on macOS 26+.
- English artifacts and UI. No em dashes. Apply the installed unslop skill to writing.
- No Apple Developer membership is available. `scripts/setup-local-signing.sh` creates the local identity "WhisperDrop 2 Local". Builds are not notarized. An ad hoc or local signature does not remove Gatekeeper warnings.

## Run and verify
- `swift test` runs focused core tests.
- `scripts/prepare-runtime.sh` builds/downloads pinned runtime tools.
- `scripts/build-app.sh` builds the app in `dist/WhisperDrop 2.app`.
- `open 'dist/WhisperDrop 2.app'` runs it.
- `scripts/package-dmg.sh` packages the locally verified app.
- Inspect the running native app and test real transcription before claiming it works.

## Current status
File transcription, YouTube import, dictation and meeting notes are implemented on `feature/dictation-meetings`. The resident model defaults to Turbo and unloads after 10 minutes idle. First launch asks for the privacy permissions dictation and notes need. Repository target is public `Zer0codestuff/whisperdrop-2`.

## Do not
- Change or push to the original repository.
- Drop YouTube or playlist support.
- Add cloud transcription, accounts, analytics or API keys.
- Claim an ad hoc signature eliminates Gatekeeper warnings.
- Replace the original monochrome/green identity or use glass behind transcript text.
- Publish credentials, local user data, model weights or build artifacts to Git.
