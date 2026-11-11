"""One resident speech model process shared by dictation, notes and files.

whisper-server (whisper.cpp) runs Whisper models; `parakeet_server` runs Parakeet v3. Both answer the same
multipart request with `verbose_json`. The process unloads after the idle policy unless a note holds a lease.
Thread safe: transcribe() blocks the calling worker thread. State changes are reported through `on_change`.
"""

from __future__ import annotations

import json
import os
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Callable

import numpy as np

from .. import paths
from ..core import cleanup
from ..core.audio import boost_quiet, wav_bytes
from ..core.models import Model
from ..core.transcript import ServerTranscription, parse_server

RESIDENCY = {  # seconds idle before unloading; None keeps the model loaded
    "after-use": 0, "2-minutes": 120, "10-minutes": 600, "30-minutes": 1800, "1-hour": 3600, "always": None,
}
RESIDENCY_LABELS = {
    "after-use": "After each use", "2-minutes": "After 2 minutes idle", "10-minutes": "After 10 minutes idle",
    "30-minutes": "After 30 minutes idle", "1-hour": "After 1 hour idle", "always": "Keep model ready",
}


class EngineError(Exception):
    pass


class Cancelled(Exception):
    pass


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def multipart(wav: bytes, fields: dict[str, str]) -> tuple[bytes, str]:
    boundary = "WhisperDrop-" + uuid.uuid4().hex
    parts = [f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
             f"Content-Type: audio/wav\r\n\r\n".encode(), wav, b"\r\n"]
    for name, value in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode())
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


class ModelHost:
    def __init__(self, model_folder: Callable[[Model], Path], on_change: Callable[[], None] | None = None):
        self.model_folder = model_folder
        self.on_change = on_change or (lambda: None)
        self.residency = "10-minutes"
        self.state = "unloaded"  # unloaded, loading, ready, busy, failed
        self.message = ""
        self.loaded: Model | None = None
        self._process: subprocess.Popen | None = None
        self._port = 0
        self._path = ""
        self._lock = threading.RLock()       # process lifecycle
        self._inference = threading.Lock()   # one load or request at a time, so a switch never kills a request
        self._leases_lock = threading.Lock()
        self._leases: set[str] = set()
        self._last_use = time.monotonic()
        self._active = 0
        self._log = paths.data_dir() / "engine.log"
        self._pid_file = paths.data_dir() / "engine.pid"
        self._kill_stale()
        threading.Thread(target=self._idle_loop, daemon=True, name="model-idle").start()

    # Public

    def acquire_lease(self) -> str:
        lease = uuid.uuid4().hex
        with self._leases_lock:
            self._leases.add(lease)
        return lease

    def release_lease(self, lease: str | None) -> None:
        if lease:
            with self._leases_lock:
                self._leases.discard(lease)
                self._last_use = time.monotonic()

    def prewarm(self, model: Model) -> None:
        threading.Thread(target=self._prewarm, args=(model,), daemon=True, name="model-prewarm").start()

    def _prewarm(self, model: Model) -> None:
        with self._inference:
            try:
                self.load(model)
            except EngineError:
                pass
            self._last_use = time.monotonic()

    def unload(self) -> None:
        """Stops the model now unless a request is running. Safe to call from the UI thread."""
        if not self._inference.acquire(blocking=False):
            return
        try:
            with self._lock:
                self._stop_process()
                self._set("unloaded")
        finally:
            self._inference.release()

    def shutdown(self) -> None:
        with self._lock:
            self._stop_process()

    def transcribe(self, samples: np.ndarray, model: Model, language: str = "auto", prompt: str | None = None,
                   offset: float = 0.0, speaker: str | None = None, short_clip: bool = False, boost: bool = False,
                   cancel: threading.Event | None = None) -> ServerTranscription:
        with self._leases_lock:
            self._active += 1
        try:
            gained = samples
            if boost:
                gained, _ = boost_quiet(samples)
            with self._inference:
                if cancel and cancel.is_set():
                    raise Cancelled()
                self.load(model)
                if cancel and cancel.is_set():
                    raise Cancelled()
                self._set("busy")
                try:
                    one_segment = short_clip and samples.size / 16000 <= 28
                    data = self._post(wav_bytes(gained), language, prompt if model.uses_prompt else None,
                                      model.engine == "whisper", one_segment, 0.0, cancel)
                    result = parse_server(data, offset, speaker)
                    if model.engine == "whisper":
                        result = self._retry_loops(result, gained, language, short_clip, one_segment, offset, speaker, cancel)
                finally:
                    self._set("ready" if self._running() else "unloaded")
            return result
        finally:
            with self._leases_lock:
                self._active -= 1
                self._last_use = time.monotonic()
            if RESIDENCY.get(self.residency) == 0 and not self._leases and not self._active:
                threading.Thread(target=self.unload, daemon=True).start()

    # Loading

    def load(self, model: Model) -> None:
        with self._lock:
            if self.loaded and self.loaded.id == model.id and self._running():
                return
            self._stop_process()
            self.loaded = model
            self._set("loading")
            try:
                self._start(model)
            except EngineError as error:
                self._stop_process()
                self.loaded = None
                self._set("failed", str(error))
                raise

    def _start(self, model: Model) -> None:
        folder = self.model_folder(model)
        if not folder.exists():
            raise EngineError(f"Download {model.name} in Preferences, Models first.")
        self._port = free_port()
        self._path = "/" + secrets.token_hex(12)
        if model.engine == "whisper":
            binary = paths.tool("whisper-server")
            if not binary:
                raise EngineError("whisper-server is not installed. Run install.sh --with-whisper, or use Parakeet v3.")
            threads = str(min(8, max(2, (os.cpu_count() or 4) - 2)))
            command = [binary, "--host", "127.0.0.1", "--port", str(self._port), "-m", str(folder), "-t", threads,
                       "-l", "auto", "--inference-path", self._path]
        else:
            command = [sys.executable, "-m", "whisperdrop.engine.parakeet_server", "--model", str(folder),
                       "--port", str(self._port), "--inference-path", self._path]
        paths.ensure(self._log.parent)
        log = open(self._log, "ab")
        log.write(f"\n--- {time.strftime('%Y-%m-%d %H:%M:%S')} {model.name}\n".encode())
        env = dict(os.environ)
        env["PYTHONPATH"] = str(Path(__file__).resolve().parents[2]) + os.pathsep + env.get("PYTHONPATH", "")
        self._process = subprocess.Popen(command, stdout=log, stderr=log, stdin=subprocess.DEVNULL, env=env,
                                         start_new_session=True)
        log.close()
        self._pid_file.write_text(str(self._process.pid))
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                raise EngineError(f"The speech model stopped while loading. {self._log_tail()}".strip())
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self._port}/health", timeout=1) as response:
                    if response.status == 200:
                        self._set("ready")
                        self._last_use = time.monotonic()
                        return
            except (urllib.error.URLError, OSError, ConnectionError):
                pass
            time.sleep(0.15)
        raise EngineError("The speech model took too long to load.")

    def _log_tail(self) -> str:
        try:
            lines = [l for l in self._log.read_text(errors="replace").splitlines() if l.strip()]
            return lines[-1][:200] if lines else ""
        except OSError:
            return ""

    def _running(self) -> bool:
        return self._process is not None and self._process.poll() is None

    def _stop_process(self) -> None:
        process, self._process = self._process, None
        self.loaded = None if process else self.loaded
        if process and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=3)
            except (ProcessLookupError, subprocess.TimeoutExpired, PermissionError):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        self._pid_file.unlink(missing_ok=True)

    def _kill_stale(self) -> None:
        try:
            pid = int(self._pid_file.read_text())
            cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace")
            if "parakeet_server" in cmdline or "whisper-server" in cmdline:
                os.killpg(pid, signal.SIGTERM)
        except (OSError, ValueError, ProcessLookupError, PermissionError):
            pass
        self._pid_file.unlink(missing_ok=True)

    def _idle_loop(self) -> None:
        while True:
            time.sleep(5)
            seconds = RESIDENCY.get(self.residency, 600)
            idle = time.monotonic() - self._last_use
            if (self._running() and seconds is not None and not self._leases and not self._active
                    and idle >= max(seconds, 1)):
                self.unload()
                continue
            with self._lock:
                if self._process is not None and not self._running() and self.state in ("ready", "busy"):
                    self._process = None
                    self.loaded = None
                    self._set("failed", "The speech model stopped unexpectedly.")

    def _set(self, state: str, message: str = "") -> None:
        self.state = state
        self.message = message
        try:
            self.on_change()
        except Exception:  # noqa: BLE001
            pass

    # Requests

    def _post(self, wav: bytes, language: str, prompt: str | None, words: bool, no_timestamps: bool,
              temperature: float, cancel: threading.Event | None) -> dict:
        fields = {"response_format": "verbose_json", "temperature": f"{temperature:.1f}", "translate": "false",
                  "no_language_probabilities": "true", "language": language or "auto"}
        if words:
            fields.update({"max_len": "-1", "token_timestamps": "true"})
        if prompt:
            fields["prompt"] = prompt
        if no_timestamps:
            fields["no_timestamps"] = "true"
        body, content_type = multipart(wav, fields)
        request = urllib.request.Request(f"http://127.0.0.1:{self._port}{self._path}", data=body, method="POST",
                                         headers={"Content-Type": content_type})
        result: dict = {}
        error: list[BaseException] = []

        def run():
            try:
                with urllib.request.urlopen(request, timeout=600) as response:
                    result.update(json.loads(response.read()))
            except urllib.error.HTTPError as failure:
                detail = failure.read()[:240].decode(errors="replace")
                error.append(EngineError(f"Transcription failed ({failure.code}). {detail}".strip()))
            except (urllib.error.URLError, OSError, ValueError):
                error.append(EngineError("Could not reach the speech model. Try again." if self._running()
                                         else "The speech model stopped. Try again."))

        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        while worker.is_alive():
            worker.join(0.1)
            if cancel and cancel.is_set():
                raise Cancelled()
        if error:
            raise error[0]
        return result

    def _retry_loops(self, result: ServerTranscription, samples: np.ndarray, language: str, short_clip: bool,
                     one_segment: bool, offset: float, speaker: str | None, cancel) -> ServerTranscription:
        try:
            if not short_clip and cleanup.repetition_score(result.text) > 0:
                retry = parse_server(self._post(wav_bytes(samples), language, None, True, False, 0.0, cancel), offset, speaker)
                if cleanup.prefers(retry.text, result.text):
                    return retry
            if short_clip and cleanup.dictation_loops(result.text):
                retry = parse_server(self._post(wav_bytes(samples), language, None, True, one_segment, 0.2, cancel), offset, speaker)
                if cleanup.dictation_prefers(retry.text, result.text):
                    return retry
        except EngineError:
            pass
        return result
