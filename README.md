# WhisperDrop 2

Local audio and video transcription, rebuilt as a native Mac app.

WhisperDrop 2 is the second version of **WhisperDrop**, originally started as a project together with [Luca Arisci](https://github.com/LucaArisci). The [original WhisperDrop repository](https://github.com/LucaArisci/whisper-drop), including its [dev branch](https://github.com/LucaArisci/whisper-drop/tree/dev), is where the project began. This version rebuilds the macOS app in SwiftUI while keeping its black, white and green identity and local transcription workflow.

## What it does

- Add audio and video files with drag and drop or the file picker.
- Import YouTube videos and playlists into a persistent queue.
- Transcribe on your Mac with whisper.cpp, Metal acceleration and CPU fallback.
- Download six quantized Whisper models, with SHA-256 verification before use.
- Read timestamped transcripts, copy text and export TXT, SRT or VTT.
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

## Installation and Gatekeeper

The current build is **ad hoc signed and not notarized**. It is a development build, not a notarized public release. A downloaded copy may be blocked by Gatekeeper. Rewriting the app does not remove this restriction.

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
- `history.json`: source locations, queue state and transcripts.
- `Work/`: temporary audio, removed after processing or cancellation.

Original files are never overwritten. Export opens a standard save dialog. Removing a recording from the library removes its history entry; exported files and archived transcripts remain on disk. Local source files must remain available until processing finishes. Interrupted jobs return to the queue after relaunch.

## Development

The app is a Swift package. Open `Package.swift` in Xcode, or use the build scripts. `WhisperDropCore` holds input validation, model metadata, persisted jobs and subtitle conversion. The SwiftUI executable owns the queue, model downloads and bundled subprocesses.

[AGENTS.md](AGENTS.md) records project constraints. [Verification notes](docs/verification.md) describe what has actually been checked. [Third-party notices](docs/third-party.md) cover runtime licenses and binary redistribution requirements.

## License

App source: MIT. Runtime components and model weights retain their own licenses.
