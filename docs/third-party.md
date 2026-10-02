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
| MLX Swift | 0.32.3, MLX core 0.32.2 | MIT | https://github.com/ml-explore/mlx-swift |
| MLX Metal shader libraries | mlx-metal 0.32.2 wheels for macOS 14 and macOS 26 | MIT | https://pypi.org/project/mlx-metal/0.32.2/ |
| Parakeet TDT graph and audio front end | mlx-audio-swift, commit 8d86630ade569728aaea3dc1a29fc44e2efa719b, Hugging Face loader removed | MIT | https://github.com/Blaizzy/mlx-audio-swift |
| Parakeet TDT 0.6B v3 weights | Encoder quantized to 4 bits by sonic-speech, revision aa25511e86a4a83285774ba03df07ca62069de2f | CC BY 4.0, NVIDIA | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |

`parakeet-server` is built from this repository's `ParakeetServer` and `ParakeetMLX` targets. `ParakeetMLX` keeps the MIT license of mlx-audio-swift in `Sources/ParakeetMLX/LICENSE-mlx-audio-swift.txt`. The Parakeet weights are NVIDIA's model, converted to MLX by mlx-community and quantized to 4 bits by sonic-speech. The 217 quantized encoder layers were checked to match a local 4-bit quantization of the mlx-community weights bit for bit. The app downloads them from the pinned revision and verifies their SHA-256 hashes.

License files are copied into the app's `Contents/Resources/Runtime/licenses` directory. `scripts/prepare-runtime.sh` contains the exact FFmpeg build configuration. No changes are made to FFmpeg sources. Binary releases must include the corresponding source and license materials required by all bundled components, including yt-dlp's bundled dependencies. Release disk images are locally signed and are not notarized by Apple.
