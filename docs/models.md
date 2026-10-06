# Speech model candidates

Research checked on 2026-09-29, with local experiments on 2026-10-01. On 2026-10-06 the user made Parakeet v3 (native MLX) the default. Whisper models stay as legacy models: an installed one is used automatically for languages Parakeet does not cover. Compare accuracy, latency and memory on the same recordings before changing defaults again.

## Legacy engine

[whisper.cpp](https://github.com/ggml-org/whisper.cpp) supports quantized Whisper GGML weights and Metal on Apple Silicon. Tiny and Base remain the smallest options in this app. Turbo Q5 is the recommended legacy model and the first legacy fallback. The GGML file format used here is not interchangeable with arbitrary GGUF files.

## Parakeet TDT 0.6B v3

[NVIDIA's model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) lists 600 million parameters, 25 European languages including Italian, automatic language detection and word/segment timestamps. Weights use CC BY 4.0.

The model card now documents a Q8 GGUF file and [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp), NVIDIA's C++ runtime. That runtime documents CPU and Metal builds. This makes Parakeet a concrete candidate for a second native engine with a download-and-cache workflow similar to Whisper. It requires its own runtime, not a filename change in whisper.cpp. No Mac benchmark has been run in this project yet.

## Measured on 2026-10-01: Phonon-2 and Parakeet v3

[Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) is Fermion Research's English-only derivative of Parakeet TDT 0.6B v3. Its encoder weights take five values per row, about 2.1 bits each, so the download is 164 MB. Weights use CC BY 4.0. The official runtime is the `fermion-research` Python package on MLX.

All runs used an M1 with 8 GB RAM, macOS 26.5 and silent file input. Test sets are seeded random subsets: LibriSpeech test-clean and test-other (200 utterances each), FLEURS English and Italian (150 each) and MLS Italian (150). Two long files join consecutive utterances: 20 minutes of LibriSpeech and 10 minutes of MLS Italian. English uses Whisper's English normalizer; Italian uses Whisper's basic normalizer. Whisper is Turbo Q5 through the bundled `whisper-server` with file-transcription request fields.

| Set | Whisper Turbo Q5 | Phonon-2 | Parakeet v3 |
| --- | ---: | ---: | ---: |
| LibriSpeech clean | 2.49% | 3.04% | 2.38% |
| LibriSpeech other | 3.44% | 4.84% | 4.02% |
| FLEURS English | 5.09% | 6.66% | 5.78% |
| LibriSpeech, 20 min file | 2.39% | 1.24% | 1.38% |
| FLEURS Italian | 6.10% | 15.23% | 6.38% |
| MLS Italian | 10.34% | 29.82% | 12.84% |
| MLS Italian, 10 min file | 4.69% | 23.23% | 6.49% |

Paired bootstrap intervals put Phonon-2 behind Whisper on every short English set, by 0.6 to 1.6 points, and behind it by about 9 to 19 points in Italian. Whisper's 20-minute English result includes one skipped 40-word sentence. Phonon-2 Italian output often uses English spelling, such as `Egypto` or `Ke`.

On the 20-minute file, Phonon-2 decoded at 24x real time, Whisper at 4.6x. On this M1, Phonon-2 decoded a 5-second clip in 114 ms and a 15-second clip in 279 ms; Whisper's dictation request took 621 ms and 2.2 s. In a real-time paced rolling session that re-decodes the open phrase every 0.5 s, Phonon-2 kept up in English with a 98 ms median decode and 0.4 s maximum lag. Whisper took about 28 minutes to process 3 minutes of audio in the same pattern. Italian Phonon-2 sessions peaked at 8.8 s of lag on long phrases. This is rolling re-decoding, not a streaming encoder.

The Python runtime loaded Phonon-2 in 12 to 24 seconds and peaked at 2.0 to 2.9 GB process RSS. `whisper-server` loaded in under a second and peaked at 0.7 to 1.0 GB.

Phonon-2 can be expanded to a standard mlx-community Parakeet directory and run natively with [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), without Python. That export is 1.2 GB in bf16 or 466 MB with 4-bit MLX quantization. The native bf16 run matched the Python word error rates, loaded in under a second and peaked at 0.8 to 1.6 GB RSS. The 4-bit export kept English accuracy (3.17% clean) but worsened FLEURS Italian to 21.91%. Long files need the app's own pause-aligned windows: mlx-audio-swift's built-in 30-second chunk merge dropped up to 529 words from the 20-minute file.

The same native runtime ran Parakeet v3 with 4-bit encoder weights in 678 MB. It scored 6.43% on FLEURS Italian, 6.57% on the Italian long file and 2.64% on LibriSpeech clean, at about 18x real time and 0.85 to 0.95 GB RSS. The prototype needed `swiftLanguageModes: [.v5]` for mlx-audio-swift and an MLX 0.32.2 metallib, because Xcode's Metal Toolchain was not installed.

Conclusion: Phonon-2 is not a replacement for Whisper in this app, whose main language is Italian. The working build offers native Parakeet v3 for its 25 supported European languages. Phonon-2 remains a local experiment. See [the app-path evaluation](parakeet-evaluation.md) for the integrated 489 MB model, real Italian talks, dictation and live text. Scripts and raw reports are under ignored `.experiments/phonon/`.

## Qwen3-ASR 0.6B

[Qwen's model card](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) lists 600 million parameters, 30 languages including Italian, 22 Chinese dialects and Apache 2.0 weights. Its official inference examples use Transformers or vLLM and Safetensors weights. Timestamp alignment uses an additional model.

It is worth evaluating for recognition quality. An efficient native macOS runtime and quantized conversion would need separate verification before it fits this app's deployment requirements. A 0.6B parameter count alone does not prove a smaller download, lower RAM use or higher speed than Whisper Tiny/Base.

## Recommendation

Parakeet v3 through native MLX is the default; Whisper is the legacy baseline for other languages. Test Parakeet next on more real lecture recordings with accents, background noise and long pauses. Record word error rate, peak memory, elapsed time and cold-start cost on Apple Silicon. Consider Qwen only after verifying a suitable local runtime. Avoid claiming either model is universally better based on vendor benchmarks.
