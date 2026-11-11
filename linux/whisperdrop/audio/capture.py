"""PipeWire capture of the microphone or of system audio (the default output's monitor).

Each source runs `pw-record` (or `parec` as a fallback) writing 16 kHz mono float32 to a pipe. A reader thread
delivers 100 ms blocks to `on_samples`. When the process ends unexpectedly, `failure` explains why.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import threading
from dataclasses import dataclass
from typing import Callable

import numpy as np

from ..core import SAMPLE_RATE
from ..core.audio import level

BLOCK = SAMPLE_RATE // 10


@dataclass
class Device:
    name: str
    description: str
    monitor: bool


def _pactl_json(*args: str) -> list | dict | None:
    if not shutil.which("pactl"):
        return None
    try:
        out = subprocess.run(["pactl", "-f", "json", *args], capture_output=True, text=True, timeout=3).stdout
        return json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def microphones() -> list[Device]:
    sources = _pactl_json("list", "sources") or []
    devices = []
    for source in sources:
        name = source.get("name", "")
        monitor = name.endswith(".monitor") or source.get("monitor_of_sink") not in (None, "n/a", "")
        if not monitor:
            devices.append(Device(name, source.get("description") or name, False))
    return devices


def default_sink() -> str | None:
    try:
        return subprocess.run(["pactl", "get-default-sink"], capture_output=True, text=True, timeout=3).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def available() -> str | None:
    """Why capture cannot work, or None."""
    if not (shutil.which("pw-record") or shutil.which("parec")):
        return "Recording needs PipeWire (pw-record) or PulseAudio (parec)."
    return None


class Capture:
    def __init__(self, system: bool = False, device: str | None = None,
                 on_samples: Callable[[np.ndarray], None] | None = None):
        self.system = system
        self.device = device
        self.on_samples = on_samples or (lambda samples: None)
        self.level = 0.0
        self.failure: str | None = None
        self.frames = 0
        self._process: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None
        self._stopping = False

    def command(self) -> list[str]:
        if shutil.which("pw-record"):
            command = ["pw-record", "--raw", "--rate", str(SAMPLE_RATE), "--channels", "1", "--format", "f32",
                       "--latency", "50ms", "-P", "{ application.name = WhisperDrop, node.dont-reconnect = false }"]
            # A PulseAudio monitor name ("<sink>.monitor") is the sink itself for PipeWire, captured as a sink.
            monitor = bool(self.device and self.device.endswith(".monitor"))
            if self.system or monitor:
                sink = (self.device[: -len(".monitor")] if monitor else self.device) or default_sink()
                command += ["-P", "{ stream.capture.sink = true }"]
                if sink:
                    command += ["--target", sink]
            elif self.device:
                command += ["--target", self.device]
            command += ["--media-category", "Capture", "--media-role", "Communication" if not self.system else "Music", "-"]
            return command
        device = (self.device or "@DEFAULT_MONITOR@") if self.system else (self.device or "@DEFAULT_SOURCE@")
        return ["parec", "--raw", "--format=float32le", f"--rate={SAMPLE_RATE}", "--channels=1",
                f"--device={device}", "--latency-msec=50", "--client-name=WhisperDrop"]

    def start(self) -> None:
        problem = available()
        if problem:
            raise OSError(problem)
        self._stopping = False
        self.failure = None
        self._process = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         stdin=subprocess.DEVNULL, bufsize=0)
        self._thread = threading.Thread(target=self._read, daemon=True, name="capture-system" if self.system else "capture-mic")
        self._thread.start()

    def _read(self) -> None:
        process = self._process
        assert process and process.stdout
        need = BLOCK * 4
        buffer = b""
        while True:
            data = process.stdout.read(need - len(buffer))
            if not data:
                break
            buffer += data
            if len(buffer) < need:
                continue
            samples = np.frombuffer(buffer, dtype="<f4").astype(np.float32)
            buffer = b""
            self.frames += samples.size
            self.level = level(samples)
            try:
                self.on_samples(samples)
            except Exception:  # noqa: BLE001
                pass
        if len(buffer) >= 4:
            samples = np.frombuffer(buffer[: len(buffer) // 4 * 4], dtype="<f4").astype(np.float32)
            self.frames += samples.size
            self.on_samples(samples)
        code = process.wait()
        if not self._stopping:
            detail = (process.stderr.read() if process.stderr else b"").decode(errors="replace").strip().splitlines()
            self.failure = (detail[-1] if detail else f"The recorder exited ({code}).")[:200]
        self.level = 0.0

    def stop(self) -> None:
        """Stops capture after delivering every sample already recorded."""
        self._stopping = True
        process = self._process
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(3)
            except subprocess.TimeoutExpired:
                process.kill()
        if self._thread:
            self._thread.join(3)
        self._process = None
        self.level = 0.0

    @property
    def running(self) -> bool:
        return self._process is not None and self._process.poll() is None


class WavWriter:
    """16-bit mono WAV written off the capture thread. The header is refreshed about once a second,
    so a crash leaves a readable file up to the last refresh."""

    def __init__(self, path, append: bool = False):
        import os

        self.path = path
        self.failed = False
        self._lock = threading.Lock()
        self._pending: list[np.ndarray] = []
        self._event = threading.Event()
        self._closed = False
        exists = append and os.path.exists(path)
        self._file = open(path, "r+b" if exists else "w+b")
        if exists:
            self._file.seek(0, 2)
            self._bytes = max(0, self._file.tell() - 44)
        else:
            self._bytes = 0
            self._header()
        self._thread = threading.Thread(target=self._run, daemon=True, name="wav-writer")
        self._thread.start()

    def _header(self) -> None:
        import struct

        size = self._bytes
        header = b"RIFF" + struct.pack("<I", 36 + size) + b"WAVEfmt " + struct.pack(
            "<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16) + b"data" + struct.pack("<I", size)
        position = self._file.tell()
        self._file.seek(0)
        self._file.write(header)
        self._file.seek(max(position, 44))

    def append(self, samples: np.ndarray) -> None:
        with self._lock:
            self._pending.append(samples)
        self._event.set()

    def _run(self) -> None:
        import time

        last_sync = time.monotonic()
        while True:
            self._event.wait(0.5)
            self._event.clear()
            with self._lock:
                batch, self._pending = self._pending, []
                closing = self._closed
            try:
                for samples in batch:
                    data = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
                    self._file.write(data)
                    self._bytes += len(data)
                if batch and (closing or time.monotonic() - last_sync >= 1):
                    self._header()
                    self._file.flush()
                    last_sync = time.monotonic()
            except OSError:
                self.failed = True
            if closing:
                with self._lock:
                    if not self._pending:
                        break

    def close(self) -> None:
        with self._lock:
            self._closed = True
        self._event.set()
        self._thread.join(10)
        try:
            self._header()
            self._file.close()
        except OSError:
            self.failed = True

    @property
    def seconds(self) -> float:
        return self._bytes / 2 / SAMPLE_RATE
