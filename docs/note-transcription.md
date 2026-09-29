# Lecture transcription experiments

Notes use local whisper.cpp with Metal. Capture produces 16 kHz mono samples. Every 500 ms, the recorder feeds its chunker and sends completed chunks to the resident model in order. This is chunked inference, rather than token streaming from the microphone. A 60-second request still uses Whisper's internal audio windows.

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
