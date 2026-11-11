"""Audio playback for transcripts: ffmpeg decodes from any position, pw-play (or paplay) outputs it.

Seeking restarts the pipeline at the new position, which takes about a tenth of a second. Several files (a note's
You and Others recordings) are mixed together. The position comes from the clock since the pipeline started.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from .media import duration, ffmpeg

RATE = 48000


class Player:
    def __init__(self, files: list[str]):
        self.files = [f for f in files if Path(f).exists()]
        self.length = max((duration(f) or 0 for f in self.files), default=0.0)
        self.speed = 1.0
        self._offset = 0.0
        self._started: float | None = None
        self._decoder: subprocess.Popen | None = None
        self._output: subprocess.Popen | None = None

    @staticmethod
    def available() -> bool:
        return bool(shutil.which("pw-play") or shutil.which("paplay"))

    @property
    def playing(self) -> bool:
        if self._started is None:
            return False
        if self._output and self._output.poll() is not None:
            self._offset = self.length if self.position >= self.length - 0.5 else self.position
            self._started = None
            return False
        return True

    @property
    def position(self) -> float:
        if self._started is None:
            return self._offset
        return min(self.length or 1e9, self._offset + (time.monotonic() - self._started) * self.speed)

    def play(self, start: float | None = None) -> None:
        self._kill()
        if start is not None:
            self._offset = max(0.0, start)
        if self.length and self._offset >= self.length - 0.2:
            self._offset = 0.0
        if not self.files:
            return
        inputs: list[str] = []
        for file in self.files:
            inputs += ["-ss", f"{self._offset:.3f}", "-i", file]
        filters = []
        if len(self.files) > 1:
            filters.append(f"amix=inputs={len(self.files)}:duration=longest:normalize=0")
        if abs(self.speed - 1.0) > 0.01:
            filters.append(f"atempo={self.speed:.2f}")
        command = [ffmpeg(), "-nostdin", "-hide_banner", "-loglevel", "error", *inputs]
        if filters:
            command += ["-filter_complex" if len(self.files) > 1 else "-af", ",".join(filters)]
        command += ["-f", "s16le", "-ac", "2", "-ar", str(RATE), "-"]
        target = os.environ.get("WHISPERDROP_PLAYBACK_TARGET")
        if shutil.which("pw-play"):
            output = ["pw-play", "--raw", "--format", "s16", "--rate", str(RATE), "--channels", "2",
                      "--media-role", "Music", "-P", "{ application.name = WhisperDrop }"]
            if target:
                output += ["--target", target]
            output.append("-")
        else:
            output = ["paplay", "--raw", "--format=s16le", f"--rate={RATE}", "--channels=2", "--client-name=WhisperDrop"]
            if target:
                output.append(f"--device={target}")
        self._decoder = subprocess.Popen(command, stdout=subprocess.PIPE, stdin=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, start_new_session=True)
        self._output = subprocess.Popen(output, stdin=self._decoder.stdout, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
        assert self._decoder.stdout
        self._decoder.stdout.close()
        self._started = time.monotonic()

    def pause(self) -> None:
        self._offset = self.position
        self._kill()

    def seek(self, seconds: float) -> None:
        if self.playing:
            self.play(seconds)
        else:
            self._offset = max(0.0, min(seconds, self.length or seconds))

    def set_speed(self, speed: float) -> None:
        playing = self.playing
        self._offset = self.position
        self.speed = speed
        if playing:
            self.play()

    def _kill(self) -> None:
        for process in (self._output, self._decoder):
            if process and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
        for process in (self._output, self._decoder):
            if process:
                try:
                    process.wait(1)
                except subprocess.TimeoutExpired:
                    process.kill()
        self._decoder = self._output = None
        self._started = None

    def close(self) -> None:
        self._kill()
