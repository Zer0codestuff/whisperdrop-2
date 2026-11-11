"""Transcribes queued files and YouTube videos one at a time on a worker thread."""

from __future__ import annotations

import shutil
import threading
from pathlib import Path
from typing import Callable

import numpy as np

from . import paths
from .audio import media
from .core import SAMPLE_RATE, cleanup
from .core import transcript as tx
from .core.audio import windows
from .engine.host import Cancelled, EngineError
from .library import Job, Library


class Transcriber:
    def __init__(self, library: Library, settings, host, post: Callable[[Callable], None],
                 on_change: Callable[[str | None], None], installed: Callable[[], set[str]]):
        self.library = library
        self.settings = settings
        self.host = host
        self.post = post                  # runs a callable on the main thread
        self.on_change = on_change        # called on the main thread with a job id, or None for the queue
        self.installed = installed
        self.current: str | None = None
        self.status = ""
        self.importing = 0
        self._cancel = threading.Event()
        self._worker: threading.Thread | None = None

    @property
    def busy(self) -> bool:
        return self._worker is not None and self._worker.is_alive()

    @property
    def queued(self) -> list[Job]:
        return [job for job in self.library.jobs if job.status == "queued" and job.kind != "note"]

    # Adding

    def add_files(self, files: list[str]) -> list[Job]:
        added = []
        for file in files:
            path = Path(file)
            if not path.is_file():
                continue
            added.append(self.library.add(Job("file", path.stem, str(path))))
        if added:
            self.on_change(None)
            if self.settings.auto_transcribe:
                self.start()
        return added

    def add_youtube(self, url: str, done: Callable[[list[Job], str | None], None] | None = None) -> None:
        self.importing += 1
        self.on_change(None)
        cancel = self._cancel

        def run():
            try:
                entries = media.youtube_entries(url, cancel)
                error = None if entries else "No videos were found at that link."
            except InterruptedError:
                entries, error = [], None
            except (media.MediaError, ValueError) as failure:
                entries, error = [], f"Could not read the YouTube link. {failure}"

            def finish():
                self.importing -= 1
                jobs = [self.library.add(Job("youtube", title, link)) for link, title in reversed(entries)]
                jobs.reverse()
                self.on_change(None)
                if done:
                    done(jobs, error)
                if jobs and self.settings.auto_transcribe:
                    self.start()

            self.post(finish)

        threading.Thread(target=run, daemon=True, name="youtube-import").start()

    # Queue

    def start(self) -> None:
        if self.busy or not self.queued:
            return
        self._cancel = threading.Event()
        self._worker = threading.Thread(target=self._run, daemon=True, name="transcriber")
        self._worker.start()

    def cancel(self) -> None:
        self._cancel.set()

    def retry(self, job_id: str) -> None:
        job = self.library.get(job_id)
        if job and job.kind != "note" and not job.active:
            job.status, job.error, job.progress = "queued", None, 0.0
            self.library.save()
            self.on_change(job_id)
            self.start()

    def _next(self) -> Job | None:
        queued = self.queued
        return queued[-1] if queued else None  # oldest first

    def _run(self) -> None:
        while not self._cancel.is_set():
            box: list[Job | None] = []
            event = threading.Event()

            def pick():
                box.append(self._next())
                event.set()

            self.post(pick)
            event.wait()
            job = box[0]
            if job is None:
                break
            self._transcribe(job)
        self.post(lambda: (setattr(self, "current", None), setattr(self, "status", ""), self.on_change(None)))

    def _update(self, job: Job, **values) -> None:
        def apply():
            for key, value in values.items():
                setattr(job, key, value)
            if "status" in values:
                self.library.save()
            self.on_change(job.id)

        self.post(apply)

    def _transcribe(self, job: Job) -> None:
        cancel = self._cancel
        work = paths.work_dir() / job.id
        self.post(lambda: setattr(self, "current", job.id))
        model = self.settings.model_for("files")
        language = self.settings.spoken_language
        try:
            if model.id not in self.installed():
                raise EngineError(f"Download {model.name} in Preferences, Models, then try again.")
            paths.ensure(work)
            source = Path(job.source)
            if job.kind == "youtube":
                self._update(job, status="downloading", progress=0.0, error=None)
                source = media.youtube_audio(job.source, work, cancel, lambda p: self._update(job, progress=p * 0.3))
            elif not source.is_file():
                raise media.MediaError("The file is no longer available. It may have been moved or deleted.")
            self._update(job, status="converting", progress=0.3 if job.kind == "youtube" else 0.0, error=None)
            base = 0.3 if job.kind == "youtube" else 0.0
            wav = media.decode(source, work / "audio.wav", cancel, lambda p: self._update(job, progress=base + p * 0.1))
            samples = media.load_samples(wav)
            duration = samples.size / SAMPLE_RATE
            self._update(job, status="transcribing", progress=base + 0.1, duration=duration)
            segments = self._segments(job, samples, model, language, cancel, base + 0.1)
            if cancel.is_set():
                raise Cancelled()

            def complete():
                job.segments = segments
                job.status, job.progress = "completed", 1.0
                job.model_name = model.name
                job.language = language
                job.error = None if segments else "No speech was detected in this recording."
                try:
                    self.library.write_transcripts(job)
                except OSError as error:
                    job.warning = f"The transcript files could not be saved: {error.strerror}"
                self.library.save()
                self.on_change(job.id)

            self.post(complete)
        except (Cancelled, InterruptedError):
            self._update(job, status="cancelled", progress=0.0, error="Stopped. You can queue it again.")
        except (EngineError, media.MediaError, OSError, ValueError) as error:
            self._update(job, status="failed", progress=0.0, error=str(error) or "Transcription failed.")
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def _segments(self, job: Job, samples: np.ndarray, model, language: str, cancel: threading.Event,
                  base: float) -> list[tx.Segment]:
        spans = windows(samples)
        total = max(1, samples.size)
        segments: list[tx.Segment] = []
        previous = ""
        for lo, hi in spans:
            if cancel.is_set():
                raise Cancelled()
            piece = samples[lo:hi]
            if piece.size == 0 or float(np.max(np.abs(piece))) < 1e-4:
                continue
            prompt = None
            if model.uses_prompt:
                prompt = self.settings.vocabulary.strip()[:400] or (previous[-200:] if cleanup.repetition_score(previous[-200:]) == 0 else None)
            result = self.host.transcribe(piece, model, language, prompt=prompt, offset=lo / SAMPLE_RATE,
                                          boost=self.settings.boost_quiet_audio, cancel=cancel)
            found = result.segments
            if model.engine == "whisper":
                found = cleanup.clean(found)
            segments.extend(found)
            previous = (previous + " " + result.text).strip()[-400:]
            self._update(job, progress=base + (1 - base) * hi / total)
        return tx.renumber(segments)
