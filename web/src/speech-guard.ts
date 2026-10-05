import { InferenceSession, Tensor } from 'onnxruntime-web/webgpu';

// Silero 6.2. Only reject a complete short window with no voice activity.
// Keep the original waveform, pauses and quiet spoken closings intact.
const MODEL_URL = 'https://raw.githubusercontent.com/snakers4/silero-vad/be95df9152c0d7618fa1edfeb296fc3dae32376f/src/silero_vad/data/silero_vad.onnx';

export class SpeechGuard {
  private constructor(private session: InferenceSession) {}
  static async create() {
    const cache = await caches.open('transformers-cache');
    let response = await cache.match(MODEL_URL);
    if (!response) {
      response = await fetch(MODEL_URL);
      if (!response.ok) throw new Error('The voice detector could not download. Check your connection and try again.');
      await cache.put(MODEL_URL, response.clone());
    }
    const session = await InferenceSession.create(await response.arrayBuffer(), { executionProviders: ['wasm'] });
    return new SpeechGuard(session);
  }
  async analyze(audio: Float32Array, checkCancelled: () => void) {
    let state: Tensor = new Tensor('float32', new Float32Array(256), [2, 1, 128]);
    let context = new Float32Array(64);
    let maximum = 0, voicedFrames = 0, run = 0, longestRun = 0;
    const sr = new Tensor('int64', BigInt64Array.of(16000n), []);
    try {
      for (let offset = 0; offset < audio.length; offset += 512) {
        checkCancelled();
        const samples = new Float32Array(576);
        samples.set(context); samples.set(audio.subarray(offset, offset + 512), 64);
        const input = new Tensor('float32', samples, [1, 576]);
        let output: Record<string, Tensor>;
        try { output = await this.session.run({ input, state, sr }); }
        finally { input.dispose(); }
        state.dispose(); state = output.stateN;
        context = samples.slice(-64);
        const probability = Number(output.output.data[0]);
        output.output.dispose();
        maximum = Math.max(maximum, probability);
        if (probability >= 0.5) { voicedFrames++; run++; longestRun = Math.max(longestRun, run); }
        else run = 0;
      }
      return { maximum, voicedFrames, longestRun };
    } finally { state.dispose(); sr.dispose(); }
  }
  async hasSpeech(audio: Float32Array, checkCancelled: () => void) {
    const result = await this.analyze(audio, checkCancelled);
    return result.longestRun >= 3;
  }
  dispose() { return this.session.release(); }
}
