# WhisperDrop 2

Local audio and video transcription, rebuilt as a native Mac app.

WhisperDrop 2 is the second version of **WhisperDrop**, originally started as a project together with [Luca Arisci](https://github.com/LucaArisci). The [original WhisperDrop repository](https://github.com/LucaArisci/whisper-drop), including its [dev branch](https://github.com/LucaArisci/whisper-drop/tree/dev), is where the project began. This version rebuilds the macOS app in SwiftUI while keeping its black, white and green identity and local transcription workflow.

## What it does

- Add audio and video files with drag and drop or the file picker.
- Import YouTube videos and playlists into a persistent queue.
- Transcribe on your Mac with whisper.cpp, Metal acceleration and CPU fallback.
- Download six quantized Whisper models, with SHA-256 verification before use.
- Read timestamped transcripts, copy text and export TXT, SRT or VTT.
- Dictate into the app in front by holding the fn key (or another key you choose). Text is typed at the cursor.
- Record a note from the microphone, from system audio (a call or online meeting), or from both. The transcript builds while you record, with You and Others labeled when both sources are on.
- Keep the speech model loaded only while you need it. The default unloads it after 10 minutes idle. A menu bar switch can keep it ready.
- Cancel processing, retry failed recordings and keep completed transcripts across launches.
- Use native Liquid Glass controls on macOS 26+, with a solid fallback on earlier systems or with Reduce Transparency enabled.

Transcription never uses a cloud API. Model downloads contact Hugging Face; YouTube imports contact YouTube. Local recordings can be transcribed offline after the chosen model is installed. There are no accounts, analytics or API keys.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Internet access for model downloads and YouTube.
- To build: Xcode 26 or later, its command-line tools, CMake and a working C/C++ toolchain. The SwiftUI glass API requires the macOS 26 SDK even though the deployment target is macOS 14.

## Build and run

```bash
git clone https://github.com/Zer0codestuff/whisperdrop-2.git
cd whisperdrop-2
scripts/prepare-runtime.sh
swift test
scripts/build-app.sh
open 'dist/WhisperDrop 2.app'
```

Runtime preparation builds pinned whisper.cpp and FFmpeg sources and downloads verified standalone yt-dlp and Deno binaries. The resulting app contains its tools and does not require Python, Homebrew or a terminal at launch. The first build takes several minutes.

Create a local disk image after checking the app:

```bash
scripts/package-dmg.sh
```

## Dictation and notes

Dictation and notes run on this Mac with the model you choose in Settings. Turbo is the default. The first launch asks for Microphone, Accessibility, Input Monitoring and, when you record a call, system audio. You can skip any of them and allow it later in Settings.

Hold fn to dictate. On a Mac, System Settings, Keyboard, set **Press 🌐 key to** to **Do Nothing**. Otherwise macOS also opens the emoji picker or its own Dictation while you hold fn. You can switch the shortcut to Right Option, Right Command or Right Control.

The model stays in memory according to the residency setting (after each use, or after 2, 10, 30 or 60 minutes idle, or for the whole time the app is open). **Keep model ready** in the menu bar overrides that and leaves it loaded. Quitting the app stops the resident `whisper-server` process.

Notes are saved in the library. Speaker lines are copied and exported as "You" and "Others". Recorded audio is kept when **Keep note audio** is on.

## Installation and Gatekeeper

`scripts/build-app.sh` signs the app with the local identity **WhisperDrop 2 Local** when that certificate is in the keychain, and falls back to an ad hoc signature otherwise. Create the identity with:

```bash
scripts/setup-local-signing.sh
```

The build is **not notarized**. It is a development build, not a notarized public release. A downloaded copy may be blocked by Gatekeeper. A local signature does not remove that restriction.

Developer ID signing and Apple notarization require an Apple Developer Program membership. Once available, the bundle and all runtime executables need a distribution signing and notarization pipeline. Do not disable Gatekeeper globally. See [Apple's distribution guidance](https://developer.apple.com/developer-id/).

## Models

The original app uses **GGML**, not GGUF. WhisperDrop 2 keeps the whisper.cpp GGML models. A GGUF file for another model architecture cannot be loaded into whisper.cpp.

| Model | Quantization | Download |
| --- | --- | ---: |
| Tiny | Q5_1 | 32 MB |
| Base | Q5_1 | 60 MB |
| Small | Q5_1 | 190 MB |
| Medium | Q5_0 | 539 MB |
| Turbo, default | Q5_0 | 574 MB |
| Turbo Q8 | Q8_0 | 874 MB |

Sizes are decimal, rounded. Model files come from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp). A larger model is not automatically better for every recording. Try Tiny or Base when download size and memory matter most.

See [model research](docs/models.md) for Parakeet and Qwen alternatives. They are research candidates, not selectable engines in this version.

## Files and privacy

App data lives in `~/Library/Application Support/WhisperDrop 2/`:

- `Models/`: downloaded model weights.
- `Transcripts/`: one folder per recording, containing TXT, SRT and VTT output.
- `Notes/`: one folder per recorded note, with the partial transcript and, when kept, the audio.
- `history.json`: source locations, queue state and transcripts.
- `Work/`: temporary audio, removed after processing or cancellation.
- `whisper-server.pid`: the resident model process, removed when the app quits.

Original files are never overwritten. Export opens a standard save dialog. Removing a recording from the library removes its history entry; exported files and archived transcripts remain on disk. Local source files must remain available until processing finishes. Interrupted jobs return to the queue after relaunch.

## Development

The app is a Swift package. Open `Package.swift` in Xcode, or use the build scripts. `WhisperDropCore` holds input validation, model metadata, persisted jobs and subtitle conversion. The SwiftUI executable owns the queue, model downloads and bundled subprocesses.

[AGENTS.md](AGENTS.md) records project constraints. [Verification notes](docs/verification.md) describe what has actually been checked. [Third-party notices](docs/third-party.md) cover runtime licenses and binary redistribution requirements.

## License

App source: MIT. Runtime components and model weights retain their own licenses.
