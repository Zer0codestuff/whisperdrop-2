# Speech model candidates

Research checked on 2026-09-29. These alternatives are not integrated into the app yet. Compare accuracy, latency and memory on the same Italian and English recordings before changing the default.

## Current engine

[whisper.cpp](https://github.com/ggml-org/whisper.cpp) supports quantized Whisper GGML weights and Metal on Apple Silicon. Tiny and Base remain the smallest options in this app. Turbo Q5 is the default for a wider accuracy/speed balance. The GGML file format used here is not interchangeable with arbitrary GGUF files.

## Parakeet TDT 0.6B v3

[NVIDIA's model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) lists 600 million parameters, 25 European languages including Italian, automatic language detection and word/segment timestamps. Weights use CC BY 4.0.

The model card now documents a Q8 GGUF file and [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp), NVIDIA's C++ runtime. That runtime documents CPU and Metal builds. This makes Parakeet a concrete candidate for a second native engine with a download-and-cache workflow similar to Whisper. It requires its own runtime, not a filename change in whisper.cpp. No Mac benchmark has been run in this project yet.

## Qwen3-ASR 0.6B

[Qwen's model card](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) lists 600 million parameters, 30 languages including Italian, 22 Chinese dialects and Apache 2.0 weights. Its official inference examples use Transformers or vLLM and Safetensors weights. Timestamp alignment uses an additional model.

It is worth evaluating for recognition quality. An efficient native macOS runtime and quantized conversion would need separate verification before it fits this app's deployment requirements. A 0.6B parameter count alone does not prove a smaller download, lower RAM use or higher speed than Whisper Tiny/Base.

## Recommendation

Keep Whisper as the working baseline. Benchmark Parakeet GGUF next, using real recordings with accents, background noise and long pauses. Record word error rate, peak memory, elapsed time and cold-start cost on Apple Silicon. Consider Qwen only after verifying a suitable local runtime. Avoid claiming either model is universally better based on vendor benchmarks.
