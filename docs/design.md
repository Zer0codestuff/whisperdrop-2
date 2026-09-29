# Design direction

Keep the original palette: black #000000, white #FFFFFF, secondary text #CFCFCF, dividers #2A2A2A and green #2BD66B. Dark green #0D2014 marks selection. Red is reserved for errors.

Use the macOS system typeface, with rounded type only for the app wordmark. A narrow source list and a wide reading area replace the old grid of bordered forms. The transcript is the main content. Settings and diagnostics stay out of the reading area.

```
+----------------------+--------------------------------------------+
| WhisperDrop 2        | Recording title             Copy   Export |
|                      |                                            |
| + Add files   Link   | 00:00   Transcript text with room to read. |
|                      |                                            |
| Today                | 00:18   The next part of the recording.    |
|   Recording          |                                            |
|   Interview          |                                            |
|                      |                                            |
| Models               |                                            |
| Local processing     | Model   Language         Transcribe queue  |
+----------------------+--------------------------------------------+
```

Use native Liquid Glass only for the bottom control group on macOS 26+, with an opaque fallback on older systems and when Reduce Transparency is enabled. Keep text backgrounds solid. Avoid dashboard cards, decorative gradients and permanently visible technical logs.
