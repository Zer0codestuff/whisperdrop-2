"""Model downloads with SHA-256 verification. Partial files resume; nothing is installed until every file checks out."""

from __future__ import annotations

import hashlib
import shutil
import threading
import urllib.request
from pathlib import Path
from typing import Callable

from . import paths
from .core.models import CATALOG, Model


class Downloads:
    def __init__(self, post: Callable[[Callable], None], on_change: Callable[[], None]):
        self.post = post
        self.on_change = on_change
        self.active: str | None = None
        self.progress = 0.0
        self.error: str | None = None
        self._cancel = threading.Event()
        self._installed: set[str] | None = None

    def location(self, model: Model) -> Path:
        """Whisper weights are one file; Parakeet gets a folder."""
        if model.engine == "whisper":
            return paths.models_dir() / model.files[0].name
        return paths.models_dir() / model.id

    def installed(self) -> set[str]:
        if self._installed is None:
            found = set()
            for model in CATALOG:
                place = self.location(model)
                if model.engine == "whisper":
                    ok = place.is_file() and place.stat().st_size == model.files[0].size
                else:
                    ok = all((place / f.name).is_file() and (place / f.name).stat().st_size == f.size for f in model.files)
                if ok:
                    found.add(model.id)
            self._installed = found
        return set(self._installed)

    def refresh(self) -> None:
        self._installed = None
        self.on_change()

    def download(self, model: Model) -> None:
        if self.active:
            return
        self.active, self.progress, self.error = model.id, 0.0, None
        self._cancel = threading.Event()
        self.on_change()
        threading.Thread(target=self._run, args=(model, self._cancel), daemon=True, name="download").start()

    def cancel(self) -> None:
        self._cancel.set()

    def delete(self, model: Model) -> None:
        place = self.location(model)
        if place.is_dir():
            shutil.rmtree(place, ignore_errors=True)
        else:
            place.unlink(missing_ok=True)
        self.refresh()

    def _run(self, model: Model, cancel: threading.Event) -> None:
        staging = paths.models_dir() / f".{model.id}.partial"
        error = None
        try:
            paths.ensure(staging)
            total = model.size
            done_before = 0
            for file in model.files:
                target = staging / file.name
                self._fetch(file.url, target, file.size, cancel,
                            lambda got, base=done_before: self._report((base + got) / total))
                if cancel.is_set():
                    raise InterruptedError()
                if _sha256(target) != file.sha256:
                    target.unlink(missing_ok=True)
                    raise ValueError(f"{file.name} did not match its checksum. Try the download again.")
                done_before += file.size
            place = self.location(model)
            if model.engine == "whisper":
                (staging / model.files[0].name).replace(place)
                shutil.rmtree(staging, ignore_errors=True)
            else:
                if place.exists():
                    shutil.rmtree(place)
                staging.replace(place)
        except InterruptedError:
            error = None
        except (OSError, ValueError) as failure:
            error = str(failure) if isinstance(failure, ValueError) else f"The download failed: {failure}"

        def finish():
            self.active, self.progress, self.error = None, 0.0, error
            self._installed = None
            self.on_change()

        self.post(finish)

    def _report(self, value: float) -> None:
        self.progress = value

        def apply():
            self.on_change()

        self.post(apply)

    def _fetch(self, url: str, target: Path, size: int, cancel: threading.Event, report: Callable[[int], None]) -> None:
        have = target.stat().st_size if target.exists() else 0
        if have == size:
            report(size)
            return
        if have > size:
            target.unlink()
            have = 0
        request = urllib.request.Request(url, headers={"User-Agent": "WhisperDrop", **({"Range": f"bytes={have}-"} if have else {})})
        with urllib.request.urlopen(request, timeout=30) as response:
            if have and response.status != 206:
                have = 0
            with open(target, "ab" if have else "wb") as handle:
                got = have
                last = 0
                while True:
                    if cancel.is_set():
                        return
                    chunk = response.read(1 << 20)
                    if not chunk:
                        break
                    handle.write(chunk)
                    got += len(chunk)
                    if got - last >= 4 << 20:
                        last = got
                        report(got)
        if target.stat().st_size != size:
            raise OSError("The download ended early. Try again to resume it.")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(4 << 20), b""):
            digest.update(block)
    return digest.hexdigest()
