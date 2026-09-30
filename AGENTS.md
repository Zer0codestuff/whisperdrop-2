# WhisperDrop 2

Native macOS transcription app, rebuilt from the WhisperDrop project started by Gabriele Monni and Luca Arisci. Original: https://github.com/LucaArisci/whisper-drop/tree/dev.

## Architecture and constraints
- SwiftUI app and Foundation core, Swift Package Manager, Apple Silicon, macOS 14+.
- Local whisper.cpp with Metal and quantized GGML models. GGUF is not interchangeable with Whisper GGML.
- Audio/video imports and YouTube videos/playlists through bundled FFmpeg, yt-dlp and Deno.
- Dictation is a global push-to-talk path: hotkey, microphone, resident `whisper-server`, then text inserted at the cursor.
- Notes record microphone and/or system audio, chunk the audio, and transcribe while the note is open. `ModelHost` keeps one model process and unloads it after the idle policy, unless Keep model ready is on.
- Lecture note chunks have a 60-second limit. Forced cuts retain two seconds of audio and defer the last second of timed words to the next request. Reading paragraphs are independent of subtitle segments.
- Capture uses a bounded FIFO PCM queue with overflow reporting. File writes run off the capture worker, synchronize about once per second, and drain before closing.
- `WhisperDropCore` holds domain types, chunking, hallucination filtering and transcript merging. The app target owns capture, the model host, dictation, notes, settings and the menu bar. `WhisperDropApp` creates those objects once and injects them into the main window, the menu bar and Settings.
- Black, white and original green #2bd66b. Spacious transcript view; restrained native glass on macOS 26+.
- English artifacts and UI. No em dashes. Apply the installed unslop skill to writing.
- No Apple Developer membership is available. `scripts/setup-local-signing.sh` creates the local identity "WhisperDrop 2 Local". Builds are not notarized. An ad hoc or local signature does not remove Gatekeeper warnings.

## Run and verify
- `swift test` runs focused core tests.
- `scripts/replay-note.sh AUDIO REPORT.json [turbo|turbo-q8] [lecture|legacy]` compares actual chunking and inference with a 16 kHz mono local file.
- `scripts/replay-note-session.sh AUDIO REPORT.json [SPEED]` silently feeds PCM through the capture queue, resampler, writer, note recorder and model. Speed 1 reproduces recording cadence. Replays require installed local models; normal tests skip them.
- `scripts/prepare-runtime.sh` builds/downloads pinned runtime tools.
- `scripts/build-app.sh` builds the app in `dist/WhisperDrop 2.app`.
- `open 'dist/WhisperDrop 2.app'` runs it.
- `scripts/package-dmg.sh` packages the locally verified app.
- Inspect the running native app and test real transcription before claiming it works.

## Current status
Version 2.1.1 includes the lecture transcription fixes, visible note language and audio retention. File transcription, YouTube import, dictation and meeting notes are implemented. The resident model defaults to Turbo Q5 and unloads after 10 minutes idle. First launch asks for the privacy permissions dictation and notes need. Repository target is public `Zer0codestuff/whisperdrop-2`.

## Recent changes and validation
- README introduces features and installation before technical details, with a native app screenshot at `docs/screenshots/whisperdrop-notes.jpg`. Screenshot content is synthetic and uses an isolated `--data-dir`; never publish the user's library. Keep the GitHub description focused on what users can do.
- Corrected PCM packet ordering under backlog, removed whisper-server's character wrapping inside words, and preserved real repeated note sentences.
- Note language and audio retention are visible beside New note. First use reminds the user to check language. Saved notes expose their audio in Finder. Optional note vocabulary is in Settings.
- Session language, vocabulary and audio retention are frozen at recording start. Capture/write failures and skipped transcription chunks remain visible in the saved note.
- `swift test` passes. The release app builds and its local signature verifies. Silent real-time recording replay preserves every input sample; retention-off replay verifies audio deletion after saving. Native language, retention, paragraph layout and Finder access were checked.
- The known Italian fixture improved from 26.22% to 2.31% word error rate with Q5. The complete 58-minute saved lecture was replayed with the production chunker. See `docs/note-transcription.md` for methods and limits.
- Release 2.1.1 uses build number 3. About reads the version from Info.plist. Release downloads remain locally signed and unnotarized; README documents Apple's current Open Anyway flow and distinguishes verification warnings from malware detection.
- The release DMG was mounted and its nested signatures checked. The packaged binary matched the installed app. Replacement preserved the original history, note audio, transcripts and model files.
- Private experiments and lesson audio stay under ignored `.experiments/`. Do not infer lecture accuracy from synthetic speech scores. Mathematical symbols and terms still need comparison with an independent reference.
- Q8 is permitted for experiments; keep Q5 as the default unless a repeatable material improvement is demonstrated. Silence padding, denoising and beam search have not consistently improved the saved lecture.

## Do not
- Change or push to the original repository.
- Drop YouTube or playlist support.
- Add cloud transcription, accounts, analytics or API keys.
- Claim an ad hoc signature eliminates Gatekeeper warnings.
- Replace the original monochrome/green identity or use glass behind transcript text.
- Publish credentials, local user data, model weights or build artifacts to Git.
- Play audible test fixtures or change system volume. Use silent file replays for transcription experiments.
