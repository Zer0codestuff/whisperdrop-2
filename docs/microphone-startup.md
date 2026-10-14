# Microphone startup

The October 14, 2026 crash occurred while dictation opened the microphone, before speech inference. The macOS report records SIGABRT and an uncaught `com.apple.coreaudio.avfaudio` exception in `AVAudioEngineGraph::InstallTapOnNode`, called from `MicCapture.start()`.

The audio log identifies the failure: the hardware input changed from 16,000 Hz to 48,000 Hz, but the tap requested the old 16,000 Hz format. The exception says `Failed to create tap due to format mismatch`. The app's Bluetooth fallback selects the built-in microphone through the input audio unit, while the engine's output bus can retain its earlier format. Reading that output format for the tap caused the mismatch. The report does not indicate an out-of-memory termination. The affected Mac has an M4 and 16 GB RAM.

## Correction in 2.6.1

- Read the input node's hardware format after choosing the device. Continue converting captured buffers to 16 kHz mono off the audio thread.
- Check whether the input unit already uses the built-in device before setting it again, and report selection errors.
- Ignore a queued configuration notification when the engine is already running. For a stopped engine, drain the PCM worker and resampler before reinstalling the tap.
- Use a small Objective-C bridge to convert tap and engine-start exceptions to Swift errors. Swift `do/catch` cannot catch `NSException`. The bridge uses the error-returning tap API when built with the macOS 27 SDK and running on macOS 27; older SDKs and systems retain the protected legacy call. macOS 14 remains supported.
- Show an Input Monitoring permission action in Settings, Dictation. Retry shortcut monitoring when the app becomes active, and stop an existing monitor if permission was revoked. Accessibility is still required for inserting text into another app.

The bridge only handles microphone graph setup. It does not change speech models, audio output, note streaming or saved transcript text.

## Verification

On the M4 Mac with macOS 27, debug and release each discovered 157 tests: 146 passed, eleven optional checks skipped, zero failures. New regression checks request a mismatched hardware format and install a duplicate tap, then confirm that a subsequent valid tap still installs. Neither check starts the engine or records audio.

The signed native app ran with an isolated `--data-dir`. A microphone-only note recorded 16 kHz mono PCM from the built-in 48 kHz input, paused and resumed without a crash, and was discarded. No test sound was played. A 122.5-second synthetic Italian file produced a 342-word transcript in 2.2 seconds through the bundled Parakeet runtime, including its opening and closing sentences. This checks execution and complete file processing, not broad recognition accuracy. The native Dictation pane was inspected with Input Monitoring denied; its permission action was visible and the remaining settings stayed scrollable.

The optional `WHISPERDROP_VERIFY_MICROPHONE=1` test discards samples and checks three starts of the same capture object. It was skipped locally because the test runner has no microphone grant. The signed app had microphone access, but lacked Input Monitoring and Accessibility, so a physical shortcut and cross-app insertion were not verified. No Bluetooth headset was connected during the final trial; the original switch is established by the crash log and code path, rather than a second live Bluetooth reproduction.

The build replaced the installed app after retaining its previous bundle and history in an ignored backup. All 120 regular files matched the candidate in both the installed bundle and the mounted DMG; nested signatures and the DMG checksum passed. Of 89 retained library, model and draft files, 88 kept their SHA-256 hashes. `history.json` was rewritten with different JSON key ordering, while its parsed content and ten jobs remained identical. The installed app also reported missing Input Monitoring and Accessibility.

Private logs, reports and screenshots remain under ignored `.experiments/2026-10-14-microphone/` and `.experiments/microphone-fix-*`.

References: Apple's [input node hardware-format guidance](https://developer.apple.com/documentation/AVFAudio/AVAudioEngine/inputNode) and [error-returning tap API](https://developer.apple.com/documentation/avfaudio/avaudionode/installtaponbus%3Abuffersize%3Aformat%3Aerror%3Ablock%3A?language=objc).
