import { pipeline, env, InterruptableStoppingCriteria } from '@huggingface/transformers';
import { modelProfile } from './models';
import { SpeechGuard } from './speech-guard';

env.allowLocalModels = false;
env.useBrowserCache = true;
if (env.backends.onnx.wasm) env.backends.onnx.wasm.numThreads = 1;

let gpuSubmissions = 0;
const gpuQueue = (globalThis as any).GPUQueue;
if (gpuQueue) {
  const submit = gpuQueue.prototype.submit;
  gpuQueue.prototype.submit = function (...args: any[]) {
    gpuSubmissions++;
    return submit.apply(this, args);
  };
}

type DecodedChunk = { stride: number[]; tokens: bigint[] };
type NoteSession = { chunks: DecodedChunk[]; seconds: number };
let transcriber: any;
let speechGuard: SpeechGuard | undefined;
let loadedKey = '';
let loadedModel = '';
let deviceLost = false;
const notes = new Map<string, NoteSession>();
const stopping = new InterruptableStoppingCriteria();
const cancelled = new Set<number>();
let activeId = 0;
const send = (data: unknown) => self.postMessage(data);
let chain = Promise.resolve();

function checkCancelled(id: number) {
  if (cancelled.has(id)) throw new Error('Transcription cancelled. Completed text is saved.');
}

function decode(chunks: DecodedChunk[], seconds: number, timestamps = true, settledOnly = false) {
  const [text, optional] = transcriber.tokenizer._decode_asr(chunks, {
    time_precision: transcriber.processor.feature_extractor.config.chunk_length / transcriber.model.config.max_source_positions,
    return_timestamps: timestamps,
    force_full_sequences: false,
  });
  let last = 0;
  const segments = (optional.chunks ?? []).filter((chunk: any) => !settledOnly || chunk.timestamp[1] !== null).map((chunk: any) => {
    const start = Math.max(last, Math.min(seconds, chunk.timestamp[0] ?? last));
    const end = Math.max(start, Math.min(seconds, chunk.timestamp[1] ?? seconds));
    last = end;
    return { text: chunk.text, timestamp: [start, end] };
  });
  return { text: settledOnly && timestamps ? segments.map((segment: any) => segment.text).join('').trim() : text.trim(), chunks: segments };
}

async function generate(audio: Float32Array, language: string, timestamps: boolean, id: number): Promise<bigint[]> {
  checkCancelled(id);
  if (language === 'auto') throw new Error('Choose the spoken language before transcribing.');
  let sum = 0;
  for (const value of audio) sum += value * value;
  if (!audio.length || Math.sqrt(sum / audio.length) < 0.0001) return [];
  if (audio.length <= 12 * 16000 && speechGuard && !(await speechGuard.hasSpeech(audio, () => checkCancelled(id)))) return [];
  const features = await transcriber.processor(audio);
  try {
    const output = await transcriber.model.generate({
      inputs: features.input_features,
      task: 'transcribe',
      ...(language === 'auto' ? {} : { language }),
      return_timestamps: timestamps,
      num_frames: Math.floor(audio.length / transcriber.processor.feature_extractor.config.hop_length),
      max_new_tokens: 440,
      stopping_criteria: [stopping],
    });
    const tokens = output[0].tolist();
    output.dispose();
    checkCancelled(id);
    return tokens;
  } finally { features.input_features.dispose(); }
}

self.onmessage = ({ data }) => {
  // Cancellation must reach a running decoder, rather than wait in its queue.
  if (data.type === 'cancel') {
    cancelled.add(data.requestId);
    if (activeId === data.requestId) stopping.interrupt();
    return;
  }
  chain = chain.then(async () => {
    const { id, type, model, audio, language = 'english', timestamps = true, session, final = false } = data;
    activeId = id;
    stopping.reset();
    try {
      checkCancelled(id);
      if (type === 'load') {
        const profile = modelProfile(model);
        const dtype = import.meta.env.DEV && data.dtype ? data.dtype : profile.dtype;
        const revision = profile.revision;
        const key = JSON.stringify({ model, revision, dtype });
        if (transcriber && loadedKey === key && !deviceLost) {
          send({ id, type: 'ready', cached: true, model }); return;
        }
        await transcriber?.dispose();
        await speechGuard?.dispose(); speechGuard = undefined;
        transcriber = null; loadedKey = ''; loadedModel = ''; notes.clear();
        if (deviceLost) throw new Error('The GPU connection was lost. Reload the page to reconnect.');
        const adapter = await (navigator as any).gpu?.requestAdapter({ powerPreference: 'high-performance' });
        if (!adapter || adapter.info?.isFallbackAdapter) throw new Error('A hardware WebGPU adapter is required. Use a browser with hardware WebGPU enabled.');
        if (profile.requiresF16 && !adapter.features.has('shader-f16')) throw new Error('Whisper Turbo needs GPU float16 support. Choose Whisper Base on this device.');
        const info = adapter.info;
        const backend = env.backends.onnx.webgpu!;
        backend.adapter = adapter;
        send({ type: 'gpu', info: { vendor: info?.vendor, architecture: info?.architecture, device: info?.device, description: info?.description, fallback: false, fp16: adapter.features.has('shader-f16') } });
        const started = performance.now();
        transcriber = await pipeline('automatic-speech-recognition', profile.repository, {
          device: 'webgpu', dtype, revision,
          progress_callback: (progress: any) => send({ type: 'download', ...progress }),
        });
        const device: any = await backend.device;
        void device.lost.then(() => {
          deviceLost = true;
          send({ type: 'fatal', message: 'The GPU connection was lost. Your saved text is retained. Reload the page to reconnect.' });
        });
        send({ type: 'warming' });
        await transcriber(new Float32Array(16000), { language: 'english', task: 'transcribe', max_new_tokens: 2 });
        send({ type: 'warming', detail: 'Preparing voice detection' });
        speechGuard = await SpeechGuard.create();
        loadedModel = model; loadedKey = key;
        send({ id, type: 'ready', model, revision, dtype, loadSeconds: (performance.now() - started) / 1000 });
      } else if (type === 'transcribe') {
        if (!transcriber || deviceLost) throw new Error('Load a model first.');
        if (!(audio instanceof Float32Array) || !audio.length) throw new Error('The audio file contains no samples.');
        const started = performance.now();
        const gpuStart = gpuSubmissions;
        const seconds = audio.length / 16000;
        let chunks: DecodedChunk[];
        let duration = seconds;
        if (session) {
          const state = notes.get(session) ?? { chunks: [], seconds: 0 };
          if (audio.length > 30 * 16000) throw new Error('A note chunk exceeds the 30-second model window.');
          const first = state.chunks.length === 0;
          const tokens = await generate(audio, language, true, id);
          state.chunks.push({ tokens, stride: [seconds, first ? 0 : 1, final ? 0 : 1] });
          state.seconds += seconds - (first ? 0 : 2);
          notes.set(session, state);
          chunks = state.chunks; duration = state.seconds;
        } else {
          chunks = [];
          const windowSeconds = import.meta.env.DEV ? data.windowSeconds ?? 28 : 28;
          const strideSeconds = import.meta.env.DEV ? data.strideSeconds ?? 4 : 4;
          if (windowSeconds > 30 || windowSeconds <= 2 * strideSeconds) throw new Error('Invalid audio chunk configuration.');
          const window = windowSeconds * 16000;
          const stride = strideSeconds * 16000;
          const jump = window - 2 * stride;
          for (let offset = 0; ; offset += jump) {
            const end = Math.min(offset + window, audio.length);
            const last = end >= audio.length;
            const tokens = await generate(audio.subarray(offset, end), language, timestamps, id);
            chunks.push({ tokens, stride: [(end - offset) / 16000, offset === 0 ? 0 : strideSeconds, last ? 0 : strideSeconds] });
            send({ id, type: 'partial', ...decode(chunks, end / 16000, timestamps, !last), completed: end / 16000, seconds, elapsed: (performance.now() - started) / 1000 });
            if (last) break;
          }
        }
        const output = decode(chunks, duration, timestamps);
        const elapsed = (performance.now() - started) / 1000;
        send({ id, type: 'result', ...output, seconds: duration, elapsed, gpuSubmissions: gpuSubmissions - gpuStart, model: loadedModel });
        if (session && final) notes.delete(session);
      } else if (type === 'analyze' && import.meta.env.DEV) {
        send({ id, type: 'analysis', ...await speechGuard!.analyze(audio, () => checkCancelled(id)) });
      } else if (type === 'unload') {
        await transcriber?.dispose();
        await speechGuard?.dispose(); speechGuard = undefined;
        transcriber = null; loadedKey = ''; loadedModel = ''; notes.clear();
        send({ id, type: 'unloaded' });
      }
    } catch (error) {
      if (type === 'load') {
        await transcriber?.dispose().catch(() => {});
        transcriber = null; loadedKey = ''; loadedModel = '';
      }
      send({ id, type: 'error', message: error instanceof Error ? error.message : String(error) });
    } finally { cancelled.delete(id); activeId = 0; }
  });
};
