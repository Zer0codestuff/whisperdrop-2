export function resample(input: Float32Array, sourceRate: number, targetRate = 16000): Float32Array {
  if (sourceRate === targetRate) return input;
  const ratio = sourceRate / targetRate;
  const output = new Float32Array(Math.floor(input.length / ratio));
  // Average source intervals when downsampling instead of dropping samples.
  for (let i = 0; i < output.length; i++) {
    const start = i * ratio, end = (i + 1) * ratio;
    let total = 0;
    for (let j = Math.floor(start); j < Math.ceil(end); j++) {
      total += (input[j] ?? 0) * (Math.min(end, j + 1) - Math.max(start, j));
    }
    output[i] = total / ratio;
  }
  return output;
}
export async function decodeAudio(file: Blob): Promise<Float32Array> {
  const context = new AudioContext({ sampleRate: 16000 });
  try {
    const buffer = await context.decodeAudioData(await file.arrayBuffer());
    const mono = new Float32Array(buffer.length);
    for (let c = 0; c < buffer.numberOfChannels; c++) {
      const channel = buffer.getChannelData(c);
      for (let i = 0; i < mono.length; i++) mono[i] += channel[i] / buffer.numberOfChannels;
    }
    return resample(mono, buffer.sampleRate);
  } catch { throw new Error('This browser cannot decode that file. Try WAV, MP3, M4A, OGG or a supported video file.'); }
  finally { await context.close(); }
}
export function joinAudio(parts: Float32Array[]): Float32Array {
  const result = new Float32Array(parts.reduce((total, p) => total + p.length, 0));
  let offset = 0;
  for (const part of parts) { result.set(part, offset); offset += part.length; }
  return result;
}
export function pcm16(audio: Float32Array): ArrayBuffer {
  const buffer = new ArrayBuffer(audio.length * 2);
  const data = new DataView(buffer);
  for (let i = 0; i < audio.length; i++) {
    const value = Math.max(-1, Math.min(1, audio[i]));
    data.setInt16(i * 2, value * (value < 0 ? 32768 : 32767), true);
  }
  return buffer;
}
export function wavHeader(samples: number): ArrayBuffer {
  const buffer = new ArrayBuffer(44);
  const data = new DataView(buffer);
  const write = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i++) data.setUint8(offset + i, text.charCodeAt(i));
  };
  write(0, 'RIFF'); data.setUint32(4, 36 + samples * 2, true); write(8, 'WAVE'); write(12, 'fmt ');
  data.setUint32(16, 16, true); data.setUint16(20, 1, true); data.setUint16(22, 1, true);
  data.setUint32(24, 16000, true); data.setUint32(28, 32000, true); data.setUint16(32, 2, true);
  data.setUint16(34, 16, true); write(36, 'data'); data.setUint32(40, samples * 2, true);
  return buffer;
}
export class MicrophoneCapture {
  context?: AudioContext;
  stream?: MediaStream;
  node?: AudioWorkletNode;
  async start(onAudio: (audio: Float32Array, rate: number) => void) {
    this.stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
    try {
      this.context = new AudioContext({ sampleRate: 48000 });
      await this.context.audioWorklet.addModule('/capture-worklet.js');
      this.node = new AudioWorkletNode(this.context, 'whisperdrop-capture');
      this.node.port.onmessage = ({ data }) => { if (data instanceof Float32Array) onAudio(data, this.context!.sampleRate); };
      const source = this.context.createMediaStreamSource(this.stream);
      source.connect(this.node);
      const mute = this.context.createGain(); mute.gain.value = 0;
      this.node.connect(mute).connect(this.context.destination);
      await this.context.resume();
    } catch (error) { await this.stop(); throw error; }
  }
  async stop() {
    if (this.node && this.context?.state === 'running') {
      const node = this.node;
      await new Promise<void>(resolve => {
        const timeout = setTimeout(() => { node.port.removeEventListener('message', listener); resolve(); }, 500);
        const listener = (event: MessageEvent) => {
          if (event.data === 'flushed') { clearTimeout(timeout); node.port.removeEventListener('message', listener); resolve(); }
        };
        node.port.addEventListener('message', listener); node.port.postMessage('flush');
      });
    }
    this.stream?.getTracks().forEach(t => t.stop());
    this.node?.disconnect();
    if (this.context?.state !== 'closed') await this.context?.close();
    this.node = undefined; this.context = undefined; this.stream = undefined;
  }
}
