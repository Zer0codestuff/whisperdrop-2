# Runtime components

WhisperDrop 2 starts these tools as separate processes. Their licenses are separate from the app's MIT license. Runtime downloads have pinned versions and SHA-256 checksums; Whisper is pinned to a source commit.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| whisper.cpp | 1.9.4, commit 927cfce34f31707e17f2bff35c349632fb9e2c3a | MIT | https://github.com/ggml-org/whisper.cpp |
| FFmpeg | 8.1.2 | LGPL 2.1 or later, no GPL or nonfree build options | https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz |
| yt-dlp standalone | 2026.08.19 | Unlicense source; bundled executable includes GPLv3+ components | https://github.com/yt-dlp/yt-dlp/tree/2026.08.19 |
| Deno | 2.9.4 | MIT, with third-party notices in its license file | https://github.com/denoland/deno/tree/v2.9.4 |
| Whisper model weights | Quantized GGML variants | MIT | https://huggingface.co/ggerganov/whisper.cpp |
| Silero voice activity model | 6.2.0, GGML | MIT | https://huggingface.co/ggml-org/whisper-vad |

License files are copied into the app's `Contents/Resources/Runtime/licenses` directory. `scripts/prepare-runtime.sh` contains the exact FFmpeg build configuration. No changes are made to FFmpeg sources. Binary releases must include the corresponding source and license materials required by all bundled components, including yt-dlp's bundled dependencies. Release disk images are locally signed and are not notarized by Apple.
