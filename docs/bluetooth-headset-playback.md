# Bluetooth headset playback

On November 13, 2026 the user reported muffled audio in Bluetooth headphones (Nothing Headphone (1)) on one Mac only. The cause was WhisperDrop, including while it was idle.

## Diagnosis

A Bluetooth headset has two modes. Music uses A2DP, here AAC at 44.1 kHz stereo. Opening its microphone moves it to the hands-free profile, 16 kHz mono in both directions, which sounds muffled.

System logs from that afternoon show:

- Every playback session ran over the hands-free link at 16 kHz. `bluetoothd` gave the reason as audio IO at 16,000 Hz, and the IO was started by the browser playing media, not by a microphone client.
- WhisperDrop was not capturing at those moments. Its `AVAudioEngine`, kept for the life of `MicCapture`, had rebuilt its input unit around the headset microphone each time the headset connected and became the default input.
- When WhisperDrop quit, `coreaudiod` deregistered its clients and the headset returned to A2DP within the same 10 ms.

A controlled script on the same Mac (macOS 27.0, M4) reproduced it without WhisperDrop:

| Step, with the headset as default input | Headset playback rate |
|---|---|
| Before | 44,100 Hz |
| `AVAudioEngine()` created and `inputNode` read, nothing started | 16,000 Hz |
| Input unit pointed at the built-in microphone | 16,000 Hz, and the engine moved the unit back within 2 s |
| Engine released | 44,100 Hz |
| HAL IOProc running on the built-in microphone for 2.5 s | 44,100 Hz throughout |

So the 2.6.1 guard, which pointed the engine's input unit at the built-in microphone, could not work: the engine switches the headset as soon as its input node exists and restores its own device choice afterwards.

## Correction in 2.6.2

- `MicCapture` no longer uses `AVAudioEngine`. It runs a HAL IOProc on one device and holds no audio object while idle.
- `AudioInputDevices.preferredInput()` picks the default input, except that a Bluetooth default gives way to a built-in microphone. A Mac with no built-in microphone still opens the headset microphone, and the headset then uses its speaking mode only while capture runs.
- `InputChunker` collects the IOProc's packets, about 10 ms each, into 100 ms mono chunks, so the slot queue and the level meter see the same cadence as before. It keeps the first channel of the first input stream. The converter it replaces also kept only the first channel of stereo input.
- While capturing, C property listeners on the default input, the device's liveness, its sample rate and its stream configuration reopen capture when the chosen device or its format changes. A failed reopen is reported through `failureMessage` as before. The block listener API is not used: a Swift closure registered with it kept firing after removal in a local trial.
- Stopping flushes the last partial chunk, so the final 100 ms of speech is no longer discarded.
- The Objective-C `AudioCaptureBridge` target and its two tests are removed. They only wrapped `AVAudioEngine` exceptions.

## Verification

All on the affected Mac, with the headset connected and playing.

- Debug and release suites: 167 tests each, 155 passed, 12 optional checks skipped, no failures.
- `WHISPERDROP_VERIFY_MICROPHONE=1 swift test --build-system native --filter CaptureTests` with the headset as default input: the headset stayed at 44,100 Hz while a `MicCapture` existed idle, during two captures and after each stop. Samples arrived from the built-in microphone. Three repeated starts delivered samples each time.
- A temporary test, not committed because it changes the system default input: capture moved to a new default microphone (a public aggregate wrapping the built-in one), returned to the built-in microphone when that device was destroyed mid-capture, reported no failure, and left no device running after `stop`. Making the headset the default mid-capture did not restart capture or change the headset's rate.

Not verified: a Mac without a built-in microphone, a multichannel audio interface, USB microphones, and a physical dictation shortcut through the packaged app.
