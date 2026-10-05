class CaptureProcessor extends AudioWorkletProcessor {
  constructor() { super(); this.buffer = new Float32Array(Math.round(sampleRate / 10)); this.offset = 0; this.closed = false;
    this.port.onmessage = ({ data }) => {
      if (data === 'flush') {
        this.closed = true;
        if (this.offset) { const tail = this.buffer.slice(0, this.offset); this.port.postMessage(tail, [tail.buffer]); this.offset = 0; }
        this.port.postMessage('flushed');
      }
    };
  }
  process(inputs) {
    if (this.closed) return false;
    const channels = inputs[0];
    if (!channels?.length) return true;
    for (let i = 0; i < channels[0].length; i++) {
      let value = 0;
      for (const channel of channels) value += channel[i] / channels.length;
      this.buffer[this.offset++] = value;
      if (this.offset === this.buffer.length) {
        this.port.postMessage(this.buffer, [this.buffer.buffer]);
        this.buffer = new Float32Array(Math.round(sampleRate / 10)); this.offset = 0;
      }
    }
    return true;
  }
}
registerProcessor('whisperdrop-capture', CaptureProcessor);
