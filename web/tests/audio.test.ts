import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { resample, joinAudio, pcm16, wavHeader } from '../src/audio.ts';

test('48 kHz and 44.1 kHz downsampling preserve duration and DC gain', () => {
  for (const rate of [48000, 44100]) {
    const pcm = new Float32Array(rate * 2).fill(0.25);
    const output = resample(pcm, rate);
    assert.equal(output.length, 32000);
    assert.ok(output.every(value => Math.abs(value - 0.25) < 1e-6));
  }
});

test('PCM and WAV export encode signed samples, duration and clipping', () => {
  const samples = joinAudio([new Float32Array([-2, -1, 0]), new Float32Array([0.5, 1, 2])]);
  const pcm = new DataView(pcm16(samples));
  assert.deepEqual(Array.from({ length: 6 }, (_, index) => pcm.getInt16(index * 2, true)), [-32768, -32768, 0, 16383, 32767, 32767]);
  const header = new DataView(wavHeader(samples.length));
  assert.equal(header.getUint32(24, true), 16000);
  assert.equal(header.getUint32(40, true), 12);
  assert.equal(header.getUint32(4, true), 48);
});

test('capture flush retains its tail exactly once and ends the worklet', () => {
  for (const rate of [48000, 44100]) {
    const messages: any[] = [];
    let Processor: any;
    const context = vm.createContext({
      sampleRate: rate,
      AudioWorkletProcessor: class { port = { postMessage: (value: any) => messages.push(value), onmessage: undefined }; },
      registerProcessor: (_name: string, implementation: any) => { Processor = implementation; },
    });
    vm.runInContext(readFileSync(new URL('../public/capture-worklet.js', import.meta.url), 'utf8'), context);
    const processor = new Processor();
    let inputSamples = 0;
    for (let block = 0; block < 111; block++) {
      const left = new Float32Array(128).fill(0.25);
      const right = new Float32Array(128).fill(0.75);
      assert.equal(processor.process([[left, right]]), true);
      inputSamples += 128;
    }
    processor.port.onmessage({ data: 'flush' });
    const captured = messages.filter(ArrayBuffer.isView);
    assert.equal(captured.reduce((sum: number, part: any) => sum + part.length, 0), inputSamples);
    assert.ok(captured.every((part: any) => part.every((value: number) => value === 0.5)));
    assert.equal(messages.at(-1), 'flushed');
    assert.equal(processor.process([[new Float32Array(128)]]), false);
    processor.port.onmessage({ data: 'flush' });
    assert.equal(messages.filter(ArrayBuffer.isView).length, captured.length);
  }
});
