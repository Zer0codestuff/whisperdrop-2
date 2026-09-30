# Audio storage and cleanup

Version 2.2.0 adds configurable saved folders, quiet-audio preprocessing and transcript checks. Turbo Q5 remains the default.

## Saved files

The default destination is `~/Documents/WhisperDrop/`, with `Audio` and `Transcripts` subfolders. Settings, General, Saved files selects the parent destination and moves managed files. Export starts in Transcripts but still permits a separate save location. Models and temporary work stay in Application Support.

Legacy note CAF files move into Audio. Note recovery JSON and generated TXT, SRT and VTT files live in Transcripts. Each note keeps its folder identifier. Original audio is copied byte for byte. The app verifies SHA-256, atomically commits the destination and job URLs in history.json, then removes verified source files. A pending previous destination lets relaunch finish interrupted cleanup. Conflicting files are never overwritten. Unrelated files in a selected parent folder remain untouched.

An explicit `--data-dir` keeps saved files inside that isolated directory by default, so verification cannot migrate the real library or write to Documents.

## Quiet audio

Inference can boost quiet speech using its 70th-percentile 20 ms frame RMS, with a maximum gain of four. Gain requires a voice level between 0.0005 and 0.015 and at least six times the 10th-percentile floor. Quiet audio dominated by noise is left at its original level. Ten milliseconds of peak lookahead and a 120 ms release keep boosted peaks below 0.98 without shifting, trimming or extending samples. A local Silero check on original audio limits gain to detected voice regions with 20 ms fades. Weak speech outside those regions remains at its original level. Failed voice checks skip gain. The recorded CAF stays unchanged.

Notes freeze the boost preference at recording start. File imports freeze it at queue start and process at most 60 seconds of samples at once. The option is in General settings. Dictation keeps its existing low-latency path.

## Closing phrases in silence

Silero 6.2.0 is bundled locally with its license and a pinned checksum. It checks voice activity, separately from transcription. The threshold is 0.35, with 200 ms minimum speech and 100 ms padding. Its ranges are used to check short Italian and English closing phrases, including a timed closing after a pause inside a longer segment. Ordinary lecture sentences are retained even when the detector misses their weak voice. It does not remove or concatenate audio before Whisper.

Unknown timing and failed detector calls preserve text. Failed checks produce a visible warning. A spoken "Grazie", "Ciao" or "Thank you" stays when voice activity supports its timing. Existing subtitle-credit and annotation filtering still applies. Repeated real note sentences are preserved.

## Repeated passages

A sustained decoder loop can become the next note chunk's prompt and keep repeating across the lecture. A guard looks for four-word sequences that appear at least six times and occupy at least 30% of a passage of 24 or more words. Normal repeated sentences do not trigger it. Suspicious prompt tails are omitted without changing the saved transcript.

When inference returns such a loop, the app makes one extra attempt on original audio without the previous text context. It accepts the candidate only if it contains at least five words and reduces the repetition score by at least 0.15. The guard never deletes repeated text itself. A failed attempt keeps the first result and shows a warning. Unresolved repetition also produces a warning. This can increase transcription time for difficult passages.

## Validation

- Migration tests cover legacy files, custom destinations, collisions, interrupted cleanup, unrelated files, corrupt history and recording-time guards.
- Audio tests cover bounded gain, loud transients, unchanged normal speech, silence, steady hum, invalid samples and exact imported-file sample counts.
- Debug and release suites each pass 70 tests. Three fixture-dependent tests are skipped in standard runs and were run separately with local recordings. The signed release app builds and verifies, including its bundled voice model, binary and license.
- Real-model Italian controls preserve full sentences and isolated "Grazie" and "Ciao" at 3% amplitude. Silence and a room-noise control no longer produce their invented closing phrases.
- On the existing 347-word quiet Italian reference, the final pipeline has seven errors, 2.02% word error rate, compared with eight errors, 2.31%, before the stricter gain policy. All three requests receive gain. This is a synthetic control, not a lecture accuracy measurement.
- A complete 946.00-second lecture was replayed with the production chunker and Q5. Each run made 17 chunk requests. The baseline produced ten isolated closing phrases. Preliminary broad gain removed those closings but introduced long decoder loops, so it was rejected. Disabling context globally and Q8 were also mixed. Voice-only gain did not consistently improve the lecture. These comparisons motivated the stricter noise-floor check. There is no independent reference transcript and no measured lecture word error rate.
- The final Q5 replay has no isolated closing phrases. Its noise-floor check skips gain on all 17 lecture chunks, and one chunk gets a repetition retry. Its most frequent four-word phrase appears six times, compared with 77 in the rejected broad-gain run. Ordinary recognition errors and shorter repetitions remain. On this M4 with 16 GB RAM, the final debug replay took 160.4 seconds for 946.0 seconds of audio, including voice checks and recovery. Native sample preparation took 2.0 seconds. Maximum observed server RSS after a request was 796,256 KB, which does not include all Metal memory or the app process.
- Synthetic repeated-sentence controls check that the app does not remove additional repetitions relative to raw Whisper output. Whisper itself reduced six identical synthetic sentences to one in both cases. This is a model limitation; the app cannot promise that every spoken repeat will be recognized.

The preliminary gain, spectral-denoise and inference-time VAD comparisons were mixed. Inference-time VAD discarded weak real speech. Denoising sometimes introduced repetitions or damaged terms, so it is not enabled. A subject vocabulary prompt was also mixed. Private audio, transcripts, reports and backups remain under ignored `.experiments/2026-09-30-preprocessing/`.

A silent recording-session replay at normal capture cadence retained all samples of a 122.52-second input with no dropped packets. PCM16 writer quantization stayed within one least significant bit, so inference gain never reached the recorded file. A separate retention-off replay deleted its CAF after saving. The first retention-off attempt was interrupted by macOS sleep and reported a dropped packet; the awake retry passed.

The final pipeline repeated the normal-cadence retention check successfully in 128.9 seconds and passed the retention-off check in 14.0 seconds. An additional 10x-speed stress replay exceeded the bounded capture queue and lost one 320-sample packet. The note reported the loss. This accelerated replay is not evidence of sample-perfect capture at 10x speed; normal capture cadence is the supported recording path.

Native checks covered the visible Settings button, General settings, folder selection with existing files, TXT export starting in the new Transcripts folder, quiet-file import and Finder access to a migrated note's audio. The real library's four CAF files and four recovery JSON files match their original SHA-256 values. All four history entries and their transcript text were retained. TXT, SRT and VTT were generated for each note. Models remain in Application Support. The locally signed app is installed with an ignored backup of the previous app and library.

No audible fixtures or system volume changes were used. Private recordings, generated transcripts and experiment reports are excluded from the repository and release assets.
