# WhisperDrop 2

Turn recordings, videos and meetings into text, right on your Mac. Record a lecture, transcribe a YouTube playlist, or dictate directly into another app.

![WhisperDrop 2 showing a lecture transcript, saved notes and transcription controls](docs/screenshots/whisperdrop-notes.jpg)

*The app with sample lecture content.*

[Download the latest version](https://github.com/Zer0codestuff/whisperdrop-2/releases/latest) · Apple Silicon · macOS 14 or later

## Features

- Transcribe audio and video files. Drag them into the app or choose them with the file picker.
- Import YouTube videos and entire playlists by pasting a link.
- Record lectures, calls and meetings using your microphone, system audio, or both. The transcript appears as you record.
- Save notes in your library and optionally keep the original audio. When recording both sources, the transcript labels them as You and Others.
- Dictate into other apps by holding a shortcut key. The words appear where your cursor is.
- Choose the spoken language once for files, dictation and notes, or let the app detect it. Add subject terms and names in Settings to help recognition.
- Read transcripts with timestamps, copy the text, or export plain text and SRT or VTT subtitles.
- Queue several recordings, cancel processing, retry failures, and return to saved transcripts later.
- Choose from six downloadable speech models. Turbo is the default; smaller models use less memory.
- Process speech locally. After downloading a model, you can transcribe local files, record notes and dictate offline.

## Get started

1. Download the `.dmg` from the [latest release](https://github.com/Zer0codestuff/whisperdrop-2/releases/latest).
2. Drag **WhisperDrop 2.app** into Applications. If you are updating, quit the old version first and replace it.
3. Open the app and download a model from **Models**. Start with Turbo.
4. Add a recording, paste a YouTube link, or choose **New note**.

Your Mac needs Apple Silicon and macOS 14 or later. Internet access is needed for model downloads and YouTube imports.

The current release is not notarized by Apple, so macOS may block the first launch. If you trust this build, try opening it once, then go to **System Settings > Privacy & Security > Open Anyway**. See [Apple's instructions](https://support.apple.com/en-us/102445). Updating the app keeps your existing notes, models and settings.

## Notes and dictation

Notes use the app language. To record one note in another language, choose it in **Note language** beside **New note**; the next note uses it once. Use **Keep audio** if you also want to save the recording. You can find kept audio later using the note's audio button.

For dictation, hold **fn** while speaking and release it to insert the text. Set **System Settings > Keyboard > Press 🌐 key to > Do Nothing** so macOS does not open its emoji picker or Dictation at the same time. You can choose a different shortcut in the app's Settings.

On first launch a short guide explains each feature and asks for the permissions they need. You can skip it and reopen it from Help. Microphone access enables voice capture; Accessibility and Input Monitoring enable dictation; system audio access enables recording calls or other audio playing on your Mac.

## Privacy

Speech is processed on your Mac. There are no accounts, analytics, API keys or cloud transcription services.

Model downloads contact Hugging Face, and YouTube imports contact YouTube. Your notes, transcripts and kept recordings stay on your Mac. Original imported files are never overwritten.

## Technical details

### Speech engine and models

WhisperDrop 2 is a native SwiftUI app built with Swift Package Manager. It runs whisper.cpp locally with Metal acceleration and CPU fallback. FFmpeg handles media conversion; yt-dlp and Deno handle YouTube imports. These tools are bundled, so the installed app does not need Homebrew, Python or a terminal.

Models use Whisper GGML files, not GGUF. Downloads are checked against their SHA-256 hashes before installation.

| Model | Quantization | Download |
| --- | --- | ---: |
| Tiny | Q5_1 | 32 MB |
| Base | Q5_1 | 60 MB |
| Small | Q5_1 | 190 MB |
| Medium | Q5_0 | 539 MB |
| Turbo, default | Q5_0 | 574 MB |
| Turbo Q8 | Q8_0 | 874 MB |

Sizes are decimal and rounded. Models come from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp). Larger models are not always more accurate for a particular recording. [Model research](docs/models.md) covers engines considered for future versions.

Dictation and notes share a resident model process. It unloads after 10 minutes idle by default. Settings offer other intervals, and **Keep model ready** in the menu bar keeps it loaded until you turn that off or quit.

Lecture notes wait for pauses, with a 60-second limit per request. Forced cuts retain two seconds of audio to help complete words at the boundary. Read the [lecture transcription tests](docs/note-transcription.md) for measured results and remaining limitations.

### Build and run

Building requires Xcode 26 or later, its command-line tools, CMake and a C/C++ toolchain. The macOS 26 SDK is needed for Liquid Glass controls; the app also runs on earlier supported systems with a solid fallback.

```bash
git clone https://github.com/Zer0codestuff/whisperdrop-2.git
cd whisperdrop-2
scripts/prepare-runtime.sh
swift test
scripts/build-app.sh
open 'dist/WhisperDrop 2.app'
```

Runtime preparation builds pinned whisper.cpp and FFmpeg sources and downloads verified yt-dlp and Deno binaries. The first build takes several minutes. After checking the app, create a disk image with:

```bash
scripts/package-dmg.sh
```

### Local data

Saved audio and transcripts default to `~/Documents/WhisperDrop/`:

- `Audio/`: original CAF recordings, one subfolder per note when Keep audio is on.
- `Transcripts/`: TXT, SRT and VTT transcripts, plus the note's recovery JSON.

Open Settings from the main window, then General, Saved files, Choose to select another folder. Existing saved files move with the library. The app verifies copies before removing originals and updates file references together with the destination. Earlier recordings in Application Support migrate automatically.

Private app data stays in `~/Library/Application Support/WhisperDrop 2/`:

- `Models/`: downloaded speech models.
- `history.json`: library, queue state and saved folder.
- `Work/`: temporary audio, removed after processing or cancellation.
- `whisper-server.pid`: the resident model process, removed on quit.

Export uses a standard save dialog starting in your Transcripts folder. Removing a library entry leaves exported files and archived transcripts on disk. Source files must remain available until processing finishes. Interrupted jobs return to the queue after relaunch.

Boost quiet audio is on by default for notes and imported files. It applies bounded gain with peak protection when speech is quiet and sufficiently above the noise floor. A local detector limits gain to voice regions. Originals stay unchanged. Short closing phrases such as "Grazie" or "Ciao" are checked against voice activity before they enter the transcript. The detector does not cut lecture speech. Sustained repetition can trigger a fresh attempt without previous text context, with a warning if it remains unresolved. Denoising is not enabled because the tested filters did not consistently improve difficult lecture recordings. See [audio storage and cleanup](docs/audio-storage-and-cleanup.md) for validation and limits.

### Signing and distribution

The build script uses the local certificate **WhisperDrop 2 Local** when available, or an ad hoc signature otherwise. You can create the local certificate with `scripts/setup-local-signing.sh`. Neither option removes Gatekeeper warnings for downloaded copies.

The warning that Apple cannot check an app for malicious software means verification is unavailable; it is different from a malware-detection warning. Browser download quarantine and previous approvals also affect launch behavior. Developer ID signing and notarization require an Apple Developer Program membership. See [Apple's distribution guidance](https://developer.apple.com/developer-id/). Do not disable Gatekeeper globally.

## Project and license

WhisperDrop began as a project with [Luca Arisci](https://github.com/LucaArisci). This version rebuilds the [original app](https://github.com/LucaArisci/whisper-drop/tree/dev) for macOS, keeping its black, white and green identity.

[AGENTS.md](AGENTS.md) records project guidance. [Third-party notices](docs/third-party.md) cover bundled runtime licenses. App source is MIT; runtime components and model weights retain their own licenses.
