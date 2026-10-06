# Lecture transcription

Capture produces 16 kHz mono samples. How they are transcribed depends on the note's model.

## Parakeet v3: streaming notes (default)

Parakeet v3 is an offline model; it has no cache-aware streaming mode. Notes emulate streaming with the same window logic as dictation's live text (`LiveText`):

- Each source's samples go into a `RollingAudio` buffer. About every 1.5 seconds the recorder decodes one window per source: it starts ten seconds before the settled boundary and covers at most 30 seconds.
- A word settles once six seconds of decoded audio follow it. Settled words go straight into the transcript; the last three stay in `LiveText` so the next request can find the boundary again by spelling. Older audio is dropped, so memory stays bounded.
- Paragraphs are sentences. A new paragraph starts after every word ending in `.`, `!` or `?`, and on speaker changes in two-source notes. There is no chunk boundary or time limit. A long passage without sentence punctuation stays one paragraph.
- Words after the settled boundary are shown in grey when **Live text** is on.
- Saved notes keep `sentenceParagraphs`, so the reader, copied text and TXT export keep one sentence per paragraph. Subtitles use one cue per sentence.
- Quiet-audio gain still applies to each window. The short-closing silence check is not applied, because it was designed for Whisper hallucinations and would judge window edges.
- A failed request is tried again with more audio on the next step. Once a window reaches 30 seconds it is skipped with a visible warning, so the note keeps up.
- If decoding falls more than 20 seconds behind, the note shows **Catching up**. Each request then covers up to 20 seconds of new audio.

## Pause and resume

**Pause** stops the capture sources and keeps the audio writers open. Parakeet notes settle every word recorded so far; Whisper notes flush their chunker and transcribe the tail. The note's model lease is then released, so the model can unload according to **Unload model**. **Resume** restarts the same sources, appends to the same CAF files and reloads the model if needed. Recording time and timestamps count recorded audio only, so they match the saved files. As while recording, writing tools wait until the note is saved.

## Streaming validation (October 6, 2026)

Silent real-time replays fed a four-minute Italian TED excerpt through the capture queue, resampler, writer, recorder and resident Parakeet server on the 8 GB M1, with a pause at 60 seconds for eight seconds. Other apps were using about two to three CPU cores at the time.

| Replay (release build) | Dropped packets | Recorded audio | Settle lag |
| --- | ---: | --- | --- |
| Original level | 0 | Sample-identical, 240.0 s | 6.5 to 8 s |
| 5% level, noise 0.0015 (gain skipped) | 0 | Sample-identical, 240.2 s | 6.5 to 8 s |
| 5% level, noise 0.0001 (gain and Silero on every window) | 0 | Sample-identical, 240.2 s | 6.6 to 8.1 s |

The longest quiet-audio preparation for one window took 0.11 seconds. While paused, the transcript held every settled sentence and no unsettled words. The streaming transcript differs from the previous chunked Parakeet output of the same file by 2.27% of words; Turbo through the legacy path differs from it by 2.84%. There is no independent reference for this excerpt, so these are consistency checks, not accuracy.

A debug build under the same outside load dropped 10 to 29 packets of 320 samples; the release build, which the app uses, dropped none. The capture worker now runs at user-interactive priority. The replay source now delivers ticks its timer missed, so it keeps real-time pace under load; before that change it delivered 240 seconds of audio in up to 247.

## Whisper (legacy): chunked notes

Whisper notes use local whisper.cpp with Metal. Every 500 ms, the recorder feeds its chunker and sends completed chunks to the resident model in order. This is chunked inference, rather than token streaming from the microphone. A 60-second request still uses Whisper's internal audio windows. The rest of this page documents that path and its measurements.

## Changes

- Notes wait for pauses, with a 45-second target and a 60-second maximum. Speech detection uses a lower energy threshold for quiet lectures. Natural cuts retain 0.5 seconds before speech and up to 0.4 seconds after it.
- Forced cuts retain two seconds of audio. The recorder defers the last second of timed words and commits them from the next request. Token pieces are joined into whole words before this decision.
- Requests disable whisper-server's character wrapping. That wrapping previously split words such as `internaz` and `ionale` into separate segments.
- Reading paragraphs are independent of model segments and subtitle timing. Paragraph breaks follow sentence endings, pauses and speaker changes.
- The capture queue preserves packet order when slots are reused. It reports overflow. Disk writes run on another queue and synchronize about once per second.
- Language and Keep audio are visible beside New note. First use reminds the user to check language. Saved notes expose their CAF files in Finder. Optional subject vocabulary is in Settings.
- The recorder preserves legitimate repeated sentences and displays capture, write and transcription warnings in saved notes. Recording duration excludes time spent finishing transcription.

## Measurements

The controlled fixture is 122.52 seconds of Italian synthetic speech about linear optimization, with a known reference of 347 words. Word error rate uses lowercase Unicode word tokens and Levenshtein distance. Punctuation is ignored, but words such as `uno` and digits such as `1` count as different.

| Configuration | Word error rate |
| --- | ---: |
| Previous chunking and server wrapping, Turbo Q5 | 26.22% |
| Previous chunking with wrapping removed, Turbo Q5 | 23.05% |
| New chunking without overlap, Turbo Q5 | 7.49% |
| New chunking and overlap, Turbo Q5 | 2.31% |
| New chunking and overlap, Turbo Q8 | 2.02% |
| New chunking, Turbo Q5, without previous-text prompt | 3.17% |
| New chunking, Turbo Q8, without previous-text prompt | 1.44% |

The Q5 result was reproduced by a silent, real-time replay through the PCM queue, resampler, writer, recorder and actual model host. The replay dropped no packets and retained exactly the input sample count. With the chosen previous-text prompt, Q8 reduced errors from eight to seven. Q8 used about 300 MB more sampled process RSS. This is not a peak RAM or GPU-memory measurement.

A second fixture scales the same speech to 4.5% amplitude and adds deterministic noise with standard deviation 0.0015. The previous chunker emitted no speech chunks. The new Q5 pipeline scored 2.31% word error rate. This checks the specific quiet-speech regression, rather than general noise robustness.

Saved lecture comparisons include the short recording that exposed the broken words and several separate four- or six-minute sections of the longer lecture. There is no independent reference transcript for those recordings, so they have no measured word error rate. Mathematical notation and some specialist terms remain inaccurate. Q8 and subject prompts produced mixed changes there. Q5 remains the default.

The complete 3495.60-second saved lecture was replayed through the production chunker and Q5 host. It produced 83 requests and took 375.82 seconds of inference, a real-time factor of 0.108. Sampled process RSS reached 769 MB. These measurements include model inference rather than 58 minutes of waiting at recording cadence. An accelerated recorder replay also passed with audio retention off and zero dropped packets.

Additional silence padding, gain, denoising, beam search and a basic Silero VAD configuration did not consistently improve the saved recording. Silero is a separate speech detector, not a transcription model. It was tested locally and is not enabled in the app. Shorter chunk targets also produced mixed results.

## Repeat a test

Use local 16 kHz mono WAV or CAF files and installed models. Reports and audio belong outside Git. Keep experiment data under ignored `.experiments/`.

```sh
scripts/replay-note.sh /absolute/audio.caf /absolute/report.json turbo lecture
scripts/replay-note.sh /absolute/audio.caf /absolute/baseline.json turbo legacy
scripts/replay-note-session.sh /absolute/audio.wav /absolute/session.json 1
```

The first two commands advance capture in 500 ms steps without waiting for playback. The last command feeds PCM at recording cadence without opening an audio device or playing sound. Set `WHISPERDROP_SESSION_KEEP_AUDIO=0` to verify deletion after saving the transcript. Normal `swift test` skips these opt-in inference runs.

Private reports preserve the tested requests, timings and output text for review. An audible UI recording interrupted by system mute was excluded from accuracy measurements and replaced by silent replay.
