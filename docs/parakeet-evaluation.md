# Parakeet v3 evaluation

Measured on 2026-10-01 on an M1 with 8 GB RAM and macOS 26.5. All audio came from files. Nothing was played aloud. Scripts, audio and raw reports stay in ignored `.experiments/`.

Parakeet v3 is NVIDIA's Parakeet TDT 0.6B v3 with its encoder quantized to 4 bits on MLX. The app runs it in `parakeet-server`, a loopback process with the same interface as `whisper-server`. Whisper Turbo Q5 is the baseline, run through the app's own request paths.

## How the engine fits in

- `ModelHost` starts `whisper-server` or `parakeet-server` from the model's engine. Requests, idle unloading, leases and crash cleanup are unchanged.
- File transcription with Parakeet sends 25 to 35 second windows cut at pauses through its own `ModelHost`, so a note recorded with another live model is never unloaded. Whisper files still use `whisper-cli`.
- Notes keep the production chunker. The server cuts any request longer than 35 seconds at a pause.
- Parakeet does not take a language code or a prompt. It detects the language itself and ignores the vocabulary lists. Japanese, Chinese, Korean, Arabic and Turkish are refused before a model starts.
- Whisper's repetition retries are skipped for Parakeet, because greedy transducer decoding returns the same text again. The silence check and quiet-audio boost still apply.
- With Parakeet, **Live text** shows unconfirmed words. In 2.4.0 it re-decoded only the last 20 seconds, so longer passages lost their earlier unconfirmed words; 2.5.0 settles words instead, see [Live text in 2.5.0](#live-text-in-250). Dictation requests run about every 0.8 seconds; notes about every 1.5 seconds, only when no chunk is waiting.

## Test material

| Set | Content | Reference |
| --- | --- | --- |
| TED Italian | Four TEDx talks in Italian, 66.7 minutes: Quattrociocchi, Lucangeli, Tecchio, Ghidini | Human Italian subtitles by TED volunteers, credits and bracketed notes removed |
| Dictation Italian | 80 FLEURS Italian clips of 2 to 9 seconds | FLEURS transcripts |
| Dictation English | 80 LibriSpeech test-clean clips of 2 to 6 seconds | LibriSpeech transcripts |
| Public sets | LibriSpeech, FLEURS and MLS subsets, see [model research](models.md) | Dataset transcripts |
| Non-speech | Silence, white noise at -60, -40 and -30 dBFS, brown noise, 50 Hz hum, clicks | Empty |

TED subtitles leave out some hesitations and repeats, so both engines lose points the speaker did say. Compare the engines with each other; the absolute values overstate the errors. Word error rate ignores case and punctuation (Whisper's basic normalizer for Italian, its English normalizer for English).

## Results

### Real Italian talks

| Path | Parakeet v3 | Whisper Turbo Q5 |
| --- | ---: | ---: |
| Native app, file transcription | 4.99%, 28.9x real time | 5.20%, 4.8x real time |
| Production note chunker, replayed | 5.16%, 31x | 6.19%, 4.8x |
| Real-time session replay, 5 minutes | 4.65% | 5.10% |

File times include app launch, conversion, the silence check and quiet-audio preparation. On one talk, Whisper's first note request turned the opening music into the repeated subtitle credit "Michele Gianella Revisore". Its repetition retry did not remove it. Without that passage the two engines are close on talks. Parakeet decoded each 16 to 19 minute talk in 26 to 37 seconds of inference.

### Dictation

| Set | Parakeet v3 | Whisper Turbo Q5 |
| --- | ---: | ---: |
| Italian, 2 to 9 s | 2.72%, median 200 ms, 90th percentile 219 ms | 12.84%, median 718 ms, 90th percentile 908 ms |
| English, 2 to 6 s | 3.35%, median 149 ms, 90th percentile 172 ms | 48.21%, median 689 ms, 90th percentile 4.47 s |

Requests went through `ModelHost` with `shortClip` and the dictation text filter, exactly like the push-to-talk path. The Whisper column above describes the 2.3.0 request settings. Its shortened encoder window returned unrelated text or "It. It. It." for several 2 to 3 second clips. This was a Whisper dictation regression, independent of Parakeet.

The final 2.4.0 request settings were replayed on all 160 clips through the same app path:

| Set | Parakeet v3 | Whisper Turbo Q5, full encoder |
| --- | ---: | ---: |
| Italian | 2.72%, median 201 ms, p90 219 ms | 2.30%, median 2,216 ms, p90 3,215 ms |
| English | 3.35%, median 150 ms, p90 171 ms | 3.11%, median 3,402 ms, p90 4,255 ms |

The full encoder makes Whisper much more reliable on these short clips, at a latency cost. Its small WER advantage over Parakeet on this sample does not establish a general accuracy advantage. Timings are from separate runs on the same Mac, not simultaneous paired measurements.

The interrupted thread left an encoder-window experiment running. It finished during the follow-up validation. Each variant decoded the same 80 English and 80 Italian files directly through the server, without the app's silence trimming or dictation filter:

| Encoder window | English WER | Italian WER |
| --- | ---: | ---: |
| Previous duration-based window | 68.78% | 22.36% |
| At least 768 frames | 3.11% | 13.61% |
| Full window | 3.23% | 2.21% |

The intermediate window was also checked through the complete app request path. It scored 3.71% in English and 13.35% in Italian, with median latency of 1.03 s and 1.10 s. Several Italian sentences were decoded two or three times; the short-phrase loop detector did not retry those longer sentences. That variant was rejected. The 2.4.0 working build leaves `audio_ctx` unset for dictation and keeps the full encoder window. Short dictation still uses one segment, and an actual decoder loop can receive one retry without a prompt and with temperature 0.2. The full-window app-path results are recorded in the follow-up validation below.

### Non-speech

Through the original dictation path, Whisper produced "Grazie a tutti." for white noise at -30 dBFS and for clicks. The full-encoder follow-up still returned "Grazie." for that white-noise control and "Grazie a tutti." for clicks: two nonempty answers in nine controls. Parakeet returned nothing for every control. Through the note path with the silence check, both returned nothing.

### Quiet speech

A three-minute TED excerpt scaled to 4.5% amplitude with noise of standard deviation 0.0015 gave estimated WER of 14.78% for Parakeet and 13.14% for Whisper. The reference prefix length was selected near the hypothesis length, without independent timestamp alignment, so these values are exploratory. The clean full-talk scores were 3.99% and 3.21%; they cover a different duration. The quiet-audio boost did not apply, because the signal-to-noise contrast was too low. This is one fixture.

### Live text

These 2.4.0 measurements used the 20-second preview window. In a real-time session replay of a five-minute talk, previews changed every 1.55 seconds at the median, at most 7.3 seconds apart. The final transcript was identical with Live text on and off, and no capture packets were dropped. Confirmed text trailed the recording by 7.4 seconds at the median with Parakeet and 12.3 seconds with Whisper. Previews are unconfirmed and can change, for example "Torchemada" became "Torque Mada" before the chunk was confirmed.

### Resources

| | Parakeet v3 | Whisper Turbo Q5 |
| --- | ---: | ---: |
| Download | 489 MB | 574 MB |
| Server process RSS | 0.47 to 0.71 GB | 0.69 to 0.76 GB |
| Model load after first use | 0.4 to 1 s | 0.4 to 2 s |
| First load on a new Mac | about 5 s, Metal kernels compile | not measured here |

The app bundle grows from 144 MB to 477 MB: `parakeet-server` is 30 MB and the two MLX shader libraries are 318 MB.

## Follow-up validation

The follow-up recovered T3 Code thread `2bba956b-a16c-4aa9-8ca3-3a8b6d8a1d42`, which had stopped at Claude's usage limit. The implementation and earlier raw reports were retained.

- The standard suite passed in debug and release: 98 tests discovered, 92 passed and six optional model replays skipped. Real-model checks ran separately. Four resident-model switches from Whisper to Parakeet and back completed with stable, nonempty text.
- Native UI checks used an isolated `--data-dir`. The Models catalog shows the experimental badge and the complete description. Settings loaded and unloaded Parakeet, enabled Live text for Parakeet, disabled it for Whisper, and explained the unused vocabulary lists.
- A Japanese note was refused in the native app before capture started. Notes and dictation now validate the selected language before opening the microphone or prewarming the model.
- An Italian 60-second public fixture was imported with the native file picker and transcribed with Parakeet. Its completed transcript and timestamps appeared in the app.
- A saved test note was renamed to `Lezione 1` from the header. The library context menu also opened the rename dialog. Blank names disabled Save, and Cancel preserved the previous name. The native app retained `Lezione 1` after the final rebuild and restart. Automated checks cover persistence after reopening, duplicate titles, notes without audio, unchanged audio and transcript hashes, and write failures retaining the old title.
- New 60-second sessions at speed 1, with Live text on and off, each retained all 960,000 samples with zero dropped packets. Their final transcripts were identical; the enabled session showed 34 nonempty preview updates.
- A normal-cadence session with audio retention off saved the transcript, deleted its temporary audio and reported zero dropped packets.
- A preceding session run while the Whisper benchmark and UI inspection were active dropped one 320-sample packet, or 20 ms. The saved note exposed the capture warning. The serial reruns passed; capture under competing load is not guaranteed lossless.

- The final native About panel reported version 2.4.0, build 6. The full Models footer was readable after its wrapping fix. The build uses an ad hoc signature because no code-signing identity is currently available in the local keychain. It is not notarized.
- The 207 MB DMG was mounted read-only. Its app and all eight executable signatures passed verification; SHA-256 hashes for all 23 packaged files matched the final build. The volume was detached after inspection. The release folder includes verified checksums and the unchanged FFmpeg source archive.

The note preview task is cancelled when recording stops or Live text is turned off. Completed chunks take priority over another preview source, and an older task cannot clear a new session's preview task.

## Live text in 2.5.0

### Problem

The 2.4.0 preview decoded the last 20 seconds. A lecture chunk stays open for up to 60 seconds, and dictation has no limit, so after 20 seconds the oldest unconfirmed words dropped out of view while the newest ones replaced them. The dictation bar also showed a single line cut at the start.

### Method

`LiveText` in WhisperDropCore keeps two lists: settled words, which never change, and pending words, which the next request replaces. A word settles once 6 seconds of decoded audio follow it. Each request starts 10 seconds before the settled boundary and covers at most 30 seconds, so requests stay short however long the speaker talks. The request re-hears the last settled words; they are found again by spelling within half a second of their old time, and only the words after them are new. Without that match, the boundary time decides.

The first version used 3 seconds of context and settled words after 4 seconds. Starting mid-sentence with so little context made Parakeet switch Italian speech to English words ("test of the journalistic", "joy but if"), and a time-only boundary repeated or dropped short words ("la la", "ad ad"). On one 18-minute talk cut into 19 dictations, live text scored 6.15% word error rate against 4.77% for decoding each dictation whole. Ten seconds of context with 4-second settling gave 5.06%; ten seconds with 6-second settling gave 4.84%, which became the default.

`LiveTextReplayTests` (`scripts/replay-live-text.sh`) cuts long files at pauses into dictations of about 60 seconds. For each dictation it decodes the whole clip, as dictation does without live text, and replays the live loop on recording time: a request every 0.8 seconds, or as soon as the previous one returns, then the final request for the audio after the settled words. Requests go through the real `ModelHost` and `parakeet-server`.

Results with the final settings. Word error rate is computed against the reference transcripts with the same normalizer as the model comparison; "whole" decodes each dictation once, "live" is the text dictation inserts at the end. Latency is the wait after the dictation ends. Settle lag is how far settled words trail the recording, measured after every live request.

| Set | Dictations | Whole WER | Live WER | Whole latency, median | Live final latency, median | Settle lag, median / max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Italian MLS, long files | 12 × 51 s | 7.22% | 7.36% | 1.67 s | 0.59 s | 6.2 s / 7.6 s |
| English LibriSpeech clean, long files | 24 × 50 s | 1.41% | 1.28% | 1.88 s | 0.66 s | 6.2 s / 8.2 s |
| Italian TED talks | 68 × 59 s | 4.91% | 5.11% | 2.16 s | 0.64 s | 6.2 s / 11.6 s |

Live text costs about 0.1 to 0.2 points of word error rate on Italian and none on this English set, and the wait after a long dictation drops by about two thirds, because only the words after the settled ones are decoded at the end. The 11.6-second lag happened when a request took longer than usual; the next request then started later. In native text fields the app still decodes the whole clip at the end, so the inserted text matches the "whole" column there; the "live" column applies to browsers, where typed words are kept.

### Notes

Notes show every word since the last committed chunk: settled and pending words of the open audio, minus words whose middle falls inside an already transcribed chunk. The committed transcript still comes from the production chunker, so Live text cannot change the saved note. The live view follows new text only while its end is visible; scrolling up stops following, and **Latest** returns to the end.

A 4-minute excerpt of an Italian TED talk was replayed at recording pace through the capture queue, writer, note recorder and Parakeet (`scripts/replay-note-session.sh`, speed 1). The session kept every sample and reported zero dropped packets; 26 paragraph segments were committed. The grey text changed 156 times. At its longest it showed 121 words, covering 55.8 seconds of speech not yet committed, against at most 20 seconds of audio in 2.4.0; the median was 64 words.

The first attempt failed every chunk with "The speech model stopped while loading". `scripts/stage-parakeet-server.sh` had copied the rebuilt server over the old file, and macOS killed the new binary because the old file's code signature was still cached. The script now deletes the file first, and `scripts/build-app.sh` starts from an empty app bundle.

### Dictation in other apps

With **In the text field**, dictation writes into the field that had focus when listening started. Checks used `--verify-dictation`, which feeds a WAV file to the dictation path at recording pace without playing it, while a separate process read the target field through Accessibility every half second.

| Target | What happened |
| --- | --- |
| TextEdit document | Accessibility edits. Words appeared about once a second and were corrected in place ("l'echità" became "l'essere vivente"). The final whole-clip text replaced the live text 3.6 s after the 45-second clip ended. The bar stayed compact. |
| TextEdit after existing text | The dictation started with a space after "Prima frase." |
| Safari address bar | Accessibility edits, as in TextEdit. |
| Safari page text area | The edit call succeeded but the text did not change. The writer switched to typing and words arrived steadily, about 6 seconds behind; the final text was complete. |
| Chrome page text area | Same as Safari. Chrome builds its accessibility tree about 2 seconds after it is requested, so the writer waits up to 3 seconds; with a 1.2-second wait it gave up and the text was pasted at the end instead. |
| Caret moved during dictation | The writer stopped, the field kept the words already written, and the full text went to the clipboard with a message. |
| Escape during dictation | The field returned to its previous length. |

Typed key events carry a marker the dictation hotkey monitor ignores, so a held fn or right-side modifier does not see them as a shortcut. Simulated held fn, right Command and right Option did not change the typed text in Chrome. When the caret follows text, dictation starts with a space; this also applies to the usual paste.

## Limits

- The language cannot be forced. Mixed Italian and English speech, and very short commands, were not tested.
- Vocabulary hints do nothing with Parakeet.
- About 9,600 reference words cannot show rare-term accuracy. Mathematical notation and specialist lecture terms were not compared with an independent reference.
- No test covered the user's own lecture recordings. They were not on this Mac.
- Dictation with live text was tested with recorded clips fed through the app's dictation path, in TextEdit, Safari and Chrome. It was not tested with a live microphone, with a physical fn key held, or in Electron apps such as Slack, Notion or VS Code, Microsoft Word, terminals or password fields. Secure input turns live writing off.
- Typing in browsers leaves words about six seconds behind speech, and typed words are kept at the end; only the rest is decoded again. In native fields the final text comes from decoding the whole clip.
- macOS 14 and 15 rely on the fallback shader library. Its loading order was tested on macOS 26 by corrupting the primary library; no older macOS was available.
- The package stays on Swift tools 5.10, so the vendored Parakeet code compiles in Swift 5 mode. Upstream mlx-audio-swift does not compile under Swift 6 strict concurrency.
