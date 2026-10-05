# WhisperDrop Web experiment

## Purpose and architecture
Local browser version of WhisperDrop 2, isolated from the native app. Vite and TypeScript, with a static Railway host and no server-side transcription. `main.ts` owns UI and sessions; `worker.ts` runs pinned Whisper ONNX models through Transformers.js 4.3.0 and hardware WebGPU. `models.ts` defines model revisions and explicit precision. `audio.ts` and `capture-worklet.js` handle decoding, resampling and microphone PCM. `storage.ts` uses IndexedDB for transcripts and audio blocks. `note-audio.ts` persists bounded five-second PCM blocks. `session-lock.ts` prevents conflicting sessions and recovery across tabs. `speech-guard.ts` runs pinned Silero 6.2 on local WASM for short windows. Weights use browser Cache Storage. `server.mjs` streams compiled assets with WebGPU isolation headers, WASM MIME, immutable hashed-asset caching and prebuilt Brotli/gzip representations. The multi-stage Dockerfile ships no npm dependencies or model weights in its runtime.

## Run and verify
- `npm install`, `npm run dev`, then http://127.0.0.1:5173.
- `npm run build` checks TypeScript, builds static files and precompresses large assets. `npm run preview -- --port 5173 --strictPort` serves the compiled demo on the same origin after stopping Vite dev.
- `npm test` runs focused downsampling, PCM/WAV, exact worklet-tail and production-host checks. `npm start` serves the compiled site on `PORT`, default 3000. `/healthz` is the Railway healthcheck. `.github/workflows/web.yml` runs these checks and the build on Linux.
- Use T3's collaborative browser. Development-only `window.whisperdrop` hooks run silent fixtures through the actual worker, file import and note paths. Production omits those hooks. Tests are never played through speakers.

## Current status and evidence
Whisper Turbo Q4F16 is the default, about 564 MB of weights, requiring GPU `shader-f16`. Both encoder and decoder use explicit Q4F16. Base remains an explicit smaller alternative for limited GPUs. No automatic CPU fallback. The final compact file test decoded 122.52 seconds of synthetic Italian in 29.84 seconds, with 17,526 GPU submissions and 2.02% normalized WER. A note replay scored 2.31% WER. Earlier runs were slower, so timing is not a hardware guarantee. See `../docs/web-evaluation.md` for methods and limits.

File and microphone-note UI, model caching, editable library, TXT/SRT/JSON export, partial-file cancellation, durable optional note audio, interrupted-session recovery and GPU worker release are implemented. The production build and focused tests pass. Physical microphone permission is denied in T3, so microphone-device success still needs a normal browser check. Synthetic routed capture and storage/recovery checks ran silently. Whisper collapsed a four-repeat spoken fixture into one sentence; this remains a model limitation. An FP16 encoder trial downloaded 1.47 GB and ran, but the final browser verification lost its connection, so that option is not in the demo.

## Preferences and constraints
Dark mode is the default regardless of OS appearance. Preserve black, white and #2bd66b, spacious transcript text and English artifacts. No em dashes. No cloud inference, accounts, analytics or API keys. The user authorized Railway publication and commit/push to `main` for this change. Future publications still need authorization. The page must remain open during recording. Files are limited to 500 MB and two decoded hours, but browser codec and decoded-memory limits still apply. No service worker, so fully offline page reload is not guaranteed. SRT retains original transcription and timing after text edits. The last unfinished audio block can be lost on interruption.

## Recent changes
- 2026-10-05: Added Railway static hosting at https://whisperdrop-web-production.up.railway.app/, with repository `Zer0codestuff/whisperdrop-2`, branch `main`, root `/web`, Dockerfile `Dockerfile`, watch pattern `/web/**` and `/healthz`. Added compressed assets, the production server, its focused test and Linux web CI. README and GitHub Deployments link the browser version. Origin storage is separate from the local demo. Four focused tests and the production build pass.
- 2026-10-05: Replaced rejected Small with pinned Turbo Q4F16, upgraded the runtime, added serial feature extraction and progress, cancellable decoding, token-based note merging, short-window voice detection, bounded audio persistence and recovery, cross-tab session locks and worker termination on GPU release. Added three focused audio checks and recorded real inference, export, cancellation and persistence evidence. Native app code is unchanged. Temporary fixtures and obsolete test model caches were removed. The compiled English import and final dark Models screenshot passed, and the GPU release control returned to the cached/unloaded state. File and microphone error handlers retain their own entry even when another library item is selected.

## Do not
- Change native app behavior as part of this experiment.
- Add cloud inference, accounts, analytics or API keys.
- Claim GPU inference from adapter availability alone. Measure GPU submissions.
- Claim general accuracy from synthetic speech, or hide model errors with text blacklists.
- Trim lecture speech with VAD or denoise without repeatable validation.
- Expose the unverified larger encoder as a supported default.
- Claim fully offline reload without a tested service worker.
- Publish without explicit authorization.
- Commit fixtures, browser data, weights or generated builds.

## Next steps
Check physical microphone recording in an ordinary browser, long real recordings and independent references, Base on a device without float16, and browser-specific memory and background behavior. The larger encoder needs an isolated, recoverable browser test before being offered again.
