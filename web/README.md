# WhisperDrop Web

An isolated browser experiment for WhisperDrop 2. The interface defaults to dark mode with the original green accent. The native app is unchanged.

[Open WhisperDrop Web](https://whisperdrop-web-production.up.railway.app/)

## Run

Requires Node.js 22.12 or newer and a current browser with hardware WebGPU, preferably Chrome or Edge on Apple Silicon.

```sh
cd web
npm install
npm run dev
```

Open http://127.0.0.1:5173. `npm run build` checks TypeScript, builds static files in `web/dist` and creates Brotli/gzip copies of large assets. `npm run preview` serves that build locally. `npm start` runs the production server on port 3000, or the port set by `PORT`.

## What works

- Local audio and browser-supported video file transcription, including multiple files.
- Microphone notes, transcribed in chunks while the page stays open.
- A shared multilingual Whisper model and explicit spoken language selection.
- Persistent model downloads using Cache Storage, with a request for persistent browser storage.
- Transcripts and optional note audio in IndexedDB, editable titles and text, copy, TXT, SRT and JSON export.
- Model removal and GPU memory release, without deleting transcripts.
- Recovery of saved text after an interrupted session.

Audio and transcripts are never sent to a server. The first model load downloads public ONNX weights from Hugging Face. Browser data belongs to this origin, browser profile and device. Export anything you need to keep.

## Implementation

Vite, TypeScript, Transformers.js and ONNX Runtime Web. A dedicated worker loads the model with `device: 'webgpu'`. Whisper Turbo is the default, using Q4F16 for both encoder and decoder. Its weights total 563,479,095 bytes, about 564 MB. An FP16 encoder trial used about 1.47 GB, but that profile is not exposed in the demo because its final browser verification lost the connection. Whisper Base is a smaller alternative. Turbo requires the GPU `shader-f16` feature; unsupported devices get a clear message and can select Base. All model revisions and runtime versions are pinned. GGML files from the native app cannot be reused. Audio decoding produces 16 kHz mono PCM. Microphone capture uses an AudioWorklet rather than the UI thread. Note chunks cut near pauses after 12 seconds and at 24 seconds at the latest, carrying two seconds of audio context.

The page requests a screen wake lock while recording. Browser background throttling, sleeping and closing the tab can still interrupt recording. Queued transcription PCM is bounded. Optional note audio is converted into five-second PCM blocks and persisted to IndexedDB while recording. The last unfinished block can be lost on interruption. Saved text is persisted after each decoded chunk and every ten seconds. Startup recovers text and stored audio only when no other tab holds the session lock. Files and notes share that lock to prevent simultaneous sessions from overwriting recovery state.

File size is limited to 500 MB and decoded duration to two hours, but decoded PCM memory can be much larger than the compressed file. Codec support depends on the browser. File transcription uses serial 28-second windows with four seconds of stride on each side. Mel features and tensors are released after each window. Progress preserves completed segments; Cancel keeps that text. Note overlap is resolved from Whisper timestamped tokens instead of deleting repeated sentences from strings. A pinned Silero 6.2 voice detector runs locally on WASM for short windows, rejecting noise without blacklisting words or trimming lecture pauses. SRT timestamps come from model segments. Editing transcript text does not realign those segments.

## Browser boundaries

There is no system-wide hotkey or cursor insertion, because a page cannot reproduce the native app's global dictation permissions. YouTube import needs a separate service or extension to fetch media, so it is outside this local-only experiment. System audio is also outside the current microphone-only capture path.

Serving a deployed build requires HTTPS and these headers:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Model files are cached for reuse. This experiment does not install a service worker, so a completely offline page reload is not guaranteed.

## Railway deployment

The `whisperdrop-web` Railway service follows `Zer0codestuff/whisperdrop-2`, branch `main`, with root directory `/web`, Dockerfile `Dockerfile`, watch pattern `/web/**` and healthcheck `/healthz`. Changes under `web/` trigger a build. The multi-stage Docker image contains only Node.js, the compiled site and `server.mjs`; the runtime has no npm dependencies or speech models. The server binds `0.0.0.0` on Railway's `PORT` and serves the isolation headers above, correct WASM MIME, precompressed assets and immutable caching for hashed bundles. HTML and the capture worklet revalidate so new deployments remain reachable.

The live URL is https://whisperdrop-web-production.up.railway.app/. GitHub's [Deployments page](https://github.com/Zer0codestuff/whisperdrop-2/deployments) records the deployed commit and live environment URL. The website origin has its own model cache and library; local-demo data does not migrate automatically. Hosting serves static files only, with inference and persistence still on the user's device.

## Evidence

See [the evaluation](../docs/web-evaluation.md) for the measured browser, GPU, fixtures and limits. Development builds expose `window.whisperdrop` for silent tests through the production worker and import path. Production builds omit those hooks. `npm test` runs focused audio, WAV, capture-tail and production-server checks. Model quality and browser flows require real browser inference; see the evaluation for fixtures and limitations.

## Sources

- [Transformers.js WebGPU guide](https://huggingface.co/docs/transformers.js/guides/webgpu)
- [Per-module quantization](https://huggingface.co/docs/transformers.js/guides/dtypes)
- [Whisper Turbo ONNX weights](https://huggingface.co/onnx-community/whisper-large-v3-turbo)
- [Silero VAD](https://github.com/snakers4/silero-vad/tree/be95df9152c0d7618fa1edfeb296fc3dae32376f)
- [Whisper Base ONNX weights](https://huggingface.co/onnx-community/whisper-base)
