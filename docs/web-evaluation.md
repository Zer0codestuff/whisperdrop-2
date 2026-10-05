# Browser transcription experiment

October 5, 2026. Experimental browser version. The measurements below were collected locally before Railway publication; they are not public-host or general-device benchmarks.

## Railway hosting

The user authorized publishing this browser version on Railway and pushing it to this repository's `main`. The public URL is https://whisperdrop-web-production.up.railway.app/. Railway serves the compiled site only; all inference and library persistence remain in the browser. The service builds `/web` through its multi-stage Dockerfile, watches `/web/**` and checks `/healthz`. The Node host adds isolation headers and correct WASM MIME, streams assets and negotiates prebuilt Brotli/gzip files. Four focused tests pass, including isolation, MIME, compression, caching, HEAD requests and rejected paths. GitHub Web checks build and test the web subdirectory on Linux. The [GitHub Deployments page](https://github.com/Zer0codestuff/whisperdrop-2/deployments) records the deployed commit and URL.

Local-demo cache and transcripts belong to a different origin and do not transfer automatically. Existing physical-microphone, long-recording and independent-reference limits below remain.

## Current compact Turbo implementation

The current demo uses Transformers.js 4.3.0 and ONNX Runtime Web `1.31.0-dev.20260914-8d85527a0`, the runtime pinned by that Transformers release. Whisper Turbo is pinned to revision `360ebcde2559d60bb474678be3c1de9ef347d01a`. Both model modules use explicit `q4f16`, avoiding an accidental multi-gigabyte FP32 encoder download. Model weights total 563,479,095 bytes. Configuration, tokenizer and a small voice detector add to that amount.

These current results supersede the rejected Small configuration below. They are fixture results, not general recognition accuracy claims.

| Configuration | Audio | Decode time | Speed | GPU submissions | Normalized WER |
| --- | --- | ---: | ---: | ---: | ---: |
| Final Turbo Q4F16, visible local demo, file import | 122.52 s synthetic Italian, 347 reference words | 29.84 s | 4.11x | 17,526 | 2.02%, 7 errors |
| Turbo Q4F16, earlier file trial | Same Italian | 67.07 s | 1.83x | 23,076 | 2.59%, 9 errors |
| Turbo Q4F16, note replay with 20 s pieces and 2 s acoustic context | Same Italian | 62.59 s | 1.96x | Measured in the worker, not retained in the entry | 2.31%, 8 errors |
| FP16 encoder and Q4F16 decoder trial, 1.47 GB | Same Italian | 31.55 s | 3.88x | 22,668 | 1.73%, 6 errors |
| Q4F16, short English fixture | Public JFK, 11 s | 9.36 s in an earlier run | 1.17x | 766 | Matched reference words |

Timing varied across runs and browser visibility states. The final comparison uses the actual file import path. Earlier and final speeds should not be treated as a controlled proof of a runtime-only speedup. The first compact download and warmup took 54.37 s; the pinned revision downloaded separately in 52.41 s. Final cached loading with kernel warmup took 5.40 s. Cache Storage is appropriate for immutable downloaded model assets; transcripts and bounded audio blocks use IndexedDB. Cache size is not a RAM or GPU-memory measurement.

A 30-second, 3-second-stride optimization decoded the Italian fixture in 48.31 s but duplicated a boundary phrase and scored 4.61% WER. It was rejected. Files retain serial 28-second windows and 4-second strides on each side. The worker extracts one window at a time, disposes tensors and reports completed text. Non-final file progress excludes unresolved trailing segments. Notes merge timestamped Whisper tokens across acoustic overlaps, instead of removing matching strings from arbitrary sentences.

The larger encoder ran in the initial isolated comparison. A final browser verification lost its connection before a result was recovered. It is not an option in the demo. Compact Turbo remains the default; Base is an explicit smaller alternative and was not benchmarked here.

## Current checks and limits

- TypeScript and Vite production builds passed. The main bundle is about 34 kB before gzip; the worker is about 554 kB and the local runtime WASM about 26.9 MB. npm audit reported zero vulnerabilities.
- Three focused tests passed: duration and gain at 48 kHz and 44.1 kHz, PCM/WAV encoding, and exact capture-tail delivery with no duplicate flush or post-stop samples.
- The compiled app, with development hooks absent and the required isolation headers active, imported the public English fixture through its real file input. It decoded 11 seconds in 2.94 seconds with 572 GPU submissions, matched the words and loaded the pinned model from cache in 6.65 seconds.
- Real file import, Italian note replay, model cache loading, TXT/SRT/JSON contents and cancellation ran in the browser. Cancellation after the first window returned in about five seconds and retained its saved text. The final change additionally excludes unresolved trailing text from partial file saves.
- Optional note audio persists as five-second PCM16 blocks, with bounded pending writes. A 10-second storage check recovered all 160,000 samples in a 320,044-byte WAV. An interrupted-note reload recovered the saved text and a 160,044-byte five-second WAV, then removed its temporary blocks. Recovery did not touch that note while another tab held the session lock.
- T3 denied physical microphone access. The UI reports the blocked permission and returns to an idle state. A synthetic MediaStream exercised the real capture graph silently and closed its tracks/context. Its independent Web Audio clocks produced a small source/capture offset, so this test is not evidence of sample-exact real-device capture.
- Desktop dark UI was inspected with a screenshot. Mobile viewport measurements showed no horizontal overflow. Some intermediate T3 screenshot calls failed, then the compiled build produced a successful final Models screenshot. The final desktop app and drawer fit 1280 by 800, with dark form controls and Apple Metal GPU details. A normal Chrome or Edge microphone session and long real recordings still need verification.
- Full-origin offline reload is not promised because there is no service worker. Imported compressed media is decoded as a whole, so memory can exceed the source size. File input is limited to 500 MB and two decoded hours. GPU memory release disposes sessions and terminates their worker. The browser's per-origin memory API rejected measurement; no exact RAM or GPU-memory figure is claimed. macOS driver counters describe aggregate GPU activity across apps and cannot attribute a utilization percentage to WhisperDrop alone.

Silero 6.2 is pinned to `be95df9152c0d7618fa1edfeb296fc3dae32376f` and runs locally on WASM. It only checks complete short windows, not individual lecture words or pauses. The speech condition requires three consecutive 32 ms frames at probability 0.5 or above. The room-noise control peaked at 0.355 and produced no speech frames. With the guard it returned empty text in 0.17 s and submitted no Whisper GPU commands. The original and quiet spoken `Ciao` and `Grazie` controls peaked above 0.998 and remained recognized. There is no blacklist for these words. This gate is deliberately limited to windows up to 12 seconds; longer nonspeech sections can still produce Whisper hallucinations.

Whisper itself collapsed a four-repeat spoken sentence fixture into one sentence, with timestamps both on and off. The merge code does not delete arbitrary repeated sentences, but it cannot restore words that the decoder never generated. This remains a recognition limitation. Editing transcript text does not realign SRT segments.

Private evidence is under ignored `.experiments/web/turbo/`. Temporary served fixtures, test library entries and obsolete model caches were removed. No native app code, user library or system audio volume changed. Those private fixtures were collected before the Railway deployment.

Sources for this implementation: [Transformers.js 4.3.0 release](https://github.com/huggingface/transformers.js/releases/tag/4.3.0), [Turbo ONNX model](https://huggingface.co/onnx-community/whisper-large-v3-turbo), [ONNX Runtime WebGPU](https://onnxruntime.ai/docs/tutorials/web/ep-webgpu.html), and [pinned Silero VAD](https://github.com/snakers4/silero-vad/tree/be95df9152c0d7618fa1edfeb296fc3dae32376f).

## Historical Small experiment

## Environment

Apple M4 MacBook Pro, 10 GPU cores and 16 GB RAM. T3 Code collaborative browser, Chromium 152 and Electron 44. WebGPU reported vendor `apple`, architecture `metal-3`, and a non-fallback hardware adapter. Tests used silent PCM input, with no audio playback or system volume changes.

Transformers.js 3.8.1 and ONNX Runtime Web 1.21.0. The production worker requests `device: 'webgpu'`, with an FP32 encoder and Q4 decoder. The worker counts calls to `GPUQueue.submit` during inference. Some shape operations still run on CPU, as expected for this runtime. GPU command submissions establish that inference uses the hardware GPU, but are not a GPU utilization percentage.

## Recovered results

| Model and settings | Audio | Decode time | Speed | GPU submissions | Recognition result |
| --- | --- | ---: | ---: | ---: | --- |
| Small, FP32 encoder / Q4 decoder, timestamps | 122.52 s synthetic Italian | 17.23 s | 7.11x real time | 62,300 | 40.92% normalized WER, rejected |
| Small, same precision, no timestamps | Same Italian | 13.58 s | 9.02x real time | 48,020 | 8.07% normalized WER, boundary errors remain |
| Small, full FP32, timestamps | Same Italian | 21.20 s | 5.78x real time | 52,444 | Repetitions reduced, boundary substitutions and duplicated passages remain |
| Small, FP32 encoder / Q4 decoder, timestamps | 11 s public JFK English clip | 0.89 s | 12.39x real time | 1,610 | Matched the expected words on this single clip |

The Italian reference contains 347 normalized words. WER uses lowercase Unicode word tokens, ignores punctuation, and counts substitutions, deletions and insertions by edit distance. The timestamp baseline had 142 errors; the no-timestamp trial had 28. These are synthetic Italian speech results and one English clip, not evidence of general lecture or meeting accuracy.

Small's first download, session construction and short kernel warmup took 19.72 s. A subsequent load from the browser cache took 2.68 s. Small's selected model files total about 586 MB; Base's selected files total about 206 MB. Tokenizer and configuration files add a small amount.

Full FP32 Small loaded in 19.19 s after downloading its additional decoder. A Turbo FP16 trial started, but the T3 preview host became unavailable and no result was recovered. Do not infer Turbo performance or quality from that trial. Base is implemented as an alternative but was not benchmarked.

## What was verified

- Real model download, browser cache reload, warmup and GPU inference.
- Long synthetic Italian and short English transcription through the production worker.
- Desktop interface inspection and screenshot in the T3 browser.
- Final TypeScript and Vite production build, including the capture tail and mobile library fixes. npm audit reported zero vulnerabilities. The final main UI bundle is 29.19 kB before gzip.

The first desktop inspection showed a small vertical overflow at 1280 by 800. Home padding was reduced afterward. The final visual result still needs another browser inspection.

## Unfinished verification and known problems

The browser connection was lost during the larger-model trial. Its tool call returned after the user's experiment deadline, so further model experiments stopped. The current Small Q4 timestamp path remains experimental and is not an accepted quality result. The final build passed after the capture and mobile library fixes, but those changes were not exercised in the browser.

Microphone permission, real recording, note replay, capture tail flushing, queue overload behavior, subtitle exports, editing persistence, mobile responsiveness and inference from the production build were not verified end to end. The note path carries two seconds of context and merges overlapping text only near matching segment times. Its boundary behavior needs fixtures before quality claims.

Recording keeps queued PCM in memory. It stops capture if more than twelve chunks remain queued, then drains them. Committed text survives a page interruption, while unfinished audio does not. Optional note audio is saved only on stop. A browser can suspend a background tab. There is no service worker, so offline page reload is not guaranteed even though model downloads are cached.

The next quality experiment should compare a current Transformers.js/ONNX runtime and silence-aware file chunking against this reference, then complete the Turbo trial. Avoid adding text filters that merely hide decoder repetition. Preserve correctly spoken repeated sentences.

## Sources and private evidence

- [Transformers.js WebGPU](https://huggingface.co/docs/transformers.js/guides/webgpu)
- [Per-module precision](https://huggingface.co/docs/transformers.js/guides/dtypes)
- [Whisper Small ONNX](https://huggingface.co/onnx-community/whisper-small)
- [Whisper Base ONNX](https://huggingface.co/onnx-community/whisper-base)
- [English test clip](https://huggingface.co/datasets/Xenova/transformers.js-docs/resolve/main/jfk.wav)

Recovered outputs are under ignored `.experiments/web/`. Temporary WAV files were removed from the served project. No user library or private audio was published.

## Dark mode and Parakeet feasibility follow-up

The web UI now defaults to dark mode regardless of the system appearance, including native selects, note controls, models and storage. Desktop 1280 by 800 and mobile 390 by 844 views were inspected in the T3 browser. There was no horizontal overflow or remaining white panel. The desktop home padding was reduced to remove its small vertical overflow. TypeScript and Vite builds passed. These visual checks do not resolve the outstanding inference and recording quality checks above.

The app's experimental model is Parakeet TDT 0.6B v3, with its encoder quantized to 4 bits for MLX. Its pinned model and configuration total 488,831,119 bytes, about 489 MB. Those native MLX weights cannot be loaded directly into the current ONNX browser worker.

[Parakeet.js](https://github.com/ysdede/parakeet.js) documents a browser path with the encoder on WebGPU and the decoder on WASM, plus browser caching and streaming helpers. This would require a separate inference integration rather than changing the current Whisper model ID. The library's documented WebGPU example uses FP32 for the encoder and INT8 for the decoder.

The following download totals were calculated from the [ONNX repository file sizes](https://huggingface.co/ysdede/parakeet-tdt-0.6b-v3-onnx/tree/main) on October 5, 2026, including the vocabulary and configuration. They use decimal MB/GB and exclude the app/runtime code. The optional ONNX preprocessor adds about 0.14 MB; Parakeet.js defaults to its JavaScript preprocessor.

| Browser configuration | Download | Runtime qualification |
| --- | ---: | --- |
| FP16 encoder + INT8 decoder | 1,257,264,689 bytes, about 1.26 GB | Published weights exist; needs hardware and numerical-quality validation |
| FP32 encoder + INT8 decoder | 2,495,495,263 bytes, about 2.50 GB | Matches the documented WebGPU example |
| INT8 encoder + INT8 decoder | 670,488,236 bytes, about 670 MB | CPU/WASM option; current Parakeet.js upgrades an INT8 WebGPU encoder request to FP32 |

These are available-file and documentation checks, not local Parakeet browser benchmarks. Model cache size is not a RAM/GPU memory measurement. No Parakeet engine was added and no model download was started in this follow-up. Railway's authenticated read-only `whoami` call succeeded. Nothing was deployed.
