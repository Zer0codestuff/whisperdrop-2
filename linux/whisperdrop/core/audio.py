"""Audio helpers on 16 kHz mono float32 numpy arrays: levels, WAV bytes, pause-aligned windows, rolling buffers."""

from __future__ import annotations

import io
import struct
import wave

import numpy as np

from . import SAMPLE_RATE
from .transcript import Segment, Word, join_words, ends_sentence


def rms(samples: np.ndarray) -> float:
    if samples.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))


def level(samples: np.ndarray) -> float:
    """0...1 meter value from an RMS level, on a dB scale between -60 and -10 dBFS."""
    value = rms(samples)
    if value <= 1e-6:
        return 0.0
    db = 20 * np.log10(value)
    return float(min(1.0, max(0.0, (db + 60) / 50)))


def speech_seconds(samples: np.ndarray, threshold: float = 0.004) -> float:
    frame = 320
    count = samples.size // frame
    if count == 0:
        return 0.0
    frames = samples[: count * frame].reshape(count, frame)
    loud = np.sqrt(np.mean(np.square(frames, dtype=np.float64), axis=1)) >= threshold
    return float(loud.sum() * frame / SAMPLE_RATE)


def has_speech(samples: np.ndarray, threshold: float = 0.004, minimum: float = 0.1) -> bool:
    return speech_seconds(samples, threshold) >= minimum


def wav_bytes(samples: np.ndarray, rate: int = SAMPLE_RATE) -> bytes:
    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return out.getvalue()


def read_wav(data: bytes) -> tuple[np.ndarray, int]:
    """Mono float32 samples from 16-bit PCM WAV bytes. Tolerates a placeholder data size."""
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("Not a WAV file.")
    offset, channels, rate, bits, fmt = 12, 0, 0, 0, 0
    while offset + 8 <= len(data):
        chunk, size = data[offset:offset + 4], struct.unpack_from("<I", data, offset + 4)[0]
        body = offset + 8
        if chunk == b"fmt ":
            fmt, channels, rate = struct.unpack_from("<HHI", data, body)
            bits = struct.unpack_from("<H", data, body + 14)[0]
        elif chunk == b"data":
            if fmt != 1 or bits != 16 or channels < 1:
                raise ValueError("Send 16-bit PCM WAV audio.")
            end = len(data) if size in (0, 0xFFFFFFFF) else min(len(data), body + size)
            usable = (end - body) // (2 * channels) * 2 * channels
            pcm = np.frombuffer(data, dtype="<i2", count=usable // 2, offset=body).astype(np.float32) / 32768
            if channels > 1:
                pcm = pcm.reshape(-1, channels).mean(axis=1)
            return pcm, rate
        offset = body + size + (size & 1)
    raise ValueError("The WAV file has no audio data.")


def boost_quiet(samples: np.ndarray, maximum_gain: float = 4.0) -> tuple[np.ndarray, float]:
    """Bounded gain for quiet speech with peak protection. Room noise without speech stays as it is.

    A simpler form of the Mac app's preprocessor, without the voice detector: gain only applies when the loudest
    frames stand well above the quiet ones, so a constant hiss is not amplified.
    """
    frame = 320
    count = samples.size // frame
    if count < 10:
        return samples, 1.0
    frames = samples[: count * frame].reshape(count, frame)
    levels = np.sqrt(np.mean(np.square(frames, dtype=np.float64), axis=1))
    loud = float(np.percentile(levels, 95))
    floor = float(np.percentile(levels, 20))
    if loud >= 0.05 or loud < 4 * max(floor, 1e-5):
        return samples, 1.0
    peak = float(np.max(np.abs(samples))) or 1.0
    gain = min(maximum_gain, 0.08 / max(loud, 1e-6), 0.95 / peak)
    if gain <= 1.05:
        return samples, 1.0
    return (samples * gain).astype(np.float32), gain


# Pause-aligned windows, from LongAudio.swift


SINGLE_SHOT = 35.0
BAND_START = 25.0
BAND_END = 35.0
TARGET = 30.0
BLOCK = 800
NOISE_FLOOR = 0.004
GATE_RATIO = 0.18


def block_rms(samples: np.ndarray) -> np.ndarray:
    if samples.size == 0:
        return np.zeros(0, dtype=np.float32)
    padded = np.zeros(((samples.size + BLOCK - 1) // BLOCK) * BLOCK, dtype=np.float32)
    padded[: samples.size] = samples
    blocks = padded.reshape(-1, BLOCK)
    return np.sqrt(np.mean(np.square(blocks, dtype=np.float64), axis=1)).astype(np.float32)


def windows(samples: np.ndarray, rate: int = SAMPLE_RATE) -> list[tuple[int, int]]:
    """Contiguous windows covering the audio. Up to 35 s stays whole; longer audio is cut inside each
    25 to 35 second band, in the middle of its longest quiet run, or at 30 s when the band never pauses."""
    count = samples.size
    single = int(SINGLE_SHOT * rate)
    if count <= single:
        return [(0, count)] if count else []
    values = block_rms(samples)
    result: list[tuple[int, int]] = []
    start = 0
    while count - start > single:
        low, high, goal = start + int(BAND_START * rate), start + int(BAND_END * rate), start + int(TARGET * rate)
        first = (low + BLOCK - 1) // BLOCK
        last = min(len(values), high // BLOCK)
        span = values[min(len(values), start // BLOCK):last]
        peak = float(span.max()) if span.size else 0.0
        gate = max(NOISE_FLOOR, GATE_RATIO * peak)
        cut = goal
        best: tuple[int, int] | None = None
        block = first
        while block < last:
            if values[block] > gate:
                block += 1
                continue
            end = block
            while end < last and values[end] <= gate:
                end += 1
            middle = (block + end) * BLOCK // 2
            candidate = (end - block, -abs(middle - goal))
            if best is None or candidate > best:
                best = candidate
                cut = middle
            block = end
        cut = max(low, min(high, cut, count))
        result.append((start, cut))
        start = cut
    result.append((start, count))
    return result


class RollingAudio:
    """Recorded audio a streaming note can still decode. Old samples are dropped so memory stays bounded."""

    def __init__(self):
        self._chunks: list[np.ndarray] = []
        self._samples = np.zeros(0, dtype=np.float32)
        self._first = 0

    def _flatten(self) -> None:
        if self._chunks:
            self._samples = np.concatenate([self._samples, *self._chunks])
            self._chunks = []

    @property
    def start(self) -> float:
        return self._first / SAMPLE_RATE

    @property
    def end(self) -> float:
        return (self._first + self._samples.size + sum(c.size for c in self._chunks)) / SAMPLE_RATE

    def append(self, samples: np.ndarray) -> None:
        if samples.size:
            self._chunks.append(samples.astype(np.float32, copy=False))

    def audio(self, start: float, end: float) -> tuple[float, np.ndarray] | None:
        self._flatten()
        lo = max(0, min(self._samples.size, int(round(start * SAMPLE_RATE)) - self._first))
        hi = max(lo, min(self._samples.size, int(round(end * SAMPLE_RATE)) - self._first))
        if hi <= lo:
            return None
        return (self._first + lo) / SAMPLE_RATE, self._samples[lo:hi].copy()

    def discard(self, before: float) -> None:
        self._flatten()
        count = min(self._samples.size, int(before * SAMPLE_RATE) - self._first)
        if count > 0:
            self._samples = self._samples[count:]
            self._first += count


class SentenceParagraphs:
    """Settled words grouped into sentences, one paragraph each. The last sentence stays open until it ends."""

    def __init__(self, speaker: str | None = None):
        self.speaker = speaker
        self.closed: list[Segment] = []
        self.open: list[Word] = []

    def append(self, words: list[Word]) -> None:
        for word in words:
            text = word.text.strip()
            if not text:
                continue
            if not self.open and self.closed and text[0].isalpha() and text[0].islower():
                # "LibriVox." then "org." or "e.g." then "the": the sentence had not really ended.
                self.open = list(self.closed.pop().words or [])
            self.open.append(word)
            if ends_sentence(word.text):
                sentence = self._segment(self.open)
                if sentence:
                    self.closed.append(sentence)
                self.open = []

    @property
    def segments(self) -> list[Segment]:
        current = self._segment(self.open)
        return self.closed + [current] if current else list(self.closed)

    def _segment(self, words: list[Word]) -> Segment | None:
        text = join_words(words)
        if not words or not text:
            return None
        return Segment(0, words[0].start, words[-1].end, text, self.speaker, list(words))


class PauseChunker:
    """Cuts a live stream for Whisper (legacy) notes: at a pause after enough speech, or inside the
    25 to 35 second band like file windows. Simpler than the Mac lecture chunker."""

    def __init__(self, pause_after: float = 8.0, pause_length: float = 0.8):
        self.pause_after = pause_after
        self.pause_length = pause_length
        self.buffer = np.zeros(0, dtype=np.float32)
        self.start = 0.0

    def append(self, samples: np.ndarray) -> list[tuple[float, np.ndarray]]:
        self.buffer = np.concatenate([self.buffer, samples.astype(np.float32, copy=False)])
        out: list[tuple[float, np.ndarray]] = []
        while True:
            cut = self._cut()
            if cut is None:
                return out
            out.append((self.start, self.buffer[:cut].copy()))
            self.buffer = self.buffer[cut:]
            self.start += cut / SAMPLE_RATE

    def _cut(self) -> int | None:
        length = self.buffer.size / SAMPLE_RATE
        if length > SINGLE_SHOT:
            return windows(self.buffer)[0][1]
        if length < self.pause_after + self.pause_length:
            return None
        values = block_rms(self.buffer[int(self.pause_after * SAMPLE_RATE):])
        need = int(self.pause_length * SAMPLE_RATE / BLOCK)
        quiet = values <= max(NOISE_FLOOR, GATE_RATIO * float(block_rms(self.buffer).max() or 0))
        run = 0
        for index, is_quiet in enumerate(quiet):
            run = run + 1 if is_quiet else 0
            if run >= need:
                middle = index - run // 2
                return int(self.pause_after * SAMPLE_RATE) + middle * BLOCK
        return None

    def flush(self) -> tuple[float, np.ndarray] | None:
        if self.buffer.size == 0:
            return None
        out = (self.start, self.buffer)
        self.start += self.buffer.size / SAMPLE_RATE
        self.buffer = np.zeros(0, dtype=np.float32)
        return out
