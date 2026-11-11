"""Records a meeting or lecture and transcribes it while it records.

Parakeet notes stream: each source's audio grows in a RollingAudio, LiveText decodes short windows about every
1.5 seconds, and every settled word joins the transcript, one sentence per paragraph. Whisper (legacy) notes cut
the audio at pauses and transcribe each piece. Paused time is not recorded and the model lease is released.
The recording folder `Audio/.recording-<id>` keeps WAV files and a partial transcript, so a crash loses at most
a second of audio and thirty seconds of text; the next launch recovers it.
"""

from __future__ import annotations

import json
import shutil
import threading
import time
import uuid
from pathlib import Path
from typing import Callable

import numpy as np

from . import paths
from .audio import media
from .audio.capture import Capture, WavWriter
from .core import cleanup
from .core import transcript as tx
from .core.audio import PauseChunker, RollingAudio, SentenceParagraphs, has_speech
from .core.livetext import LiveText
from .core.models import language_name
from .engine.host import Cancelled, EngineError
from .library import Job, Library, fallback_title

STREAMS = ("microphone", "system")
FILES = {"microphone": "you.wav", "system": "others.wav"}


class NoteRecorder:
    def __init__(self, library: Library, settings, host, post: Callable[[Callable], None],
                 on_change: Callable[[], None], on_saved: Callable[[Job], None], installed: Callable[[], set[str]]):
        self.library = library
        self.settings = settings
        self.host = host
        self.post = post
        self.on_change = on_change
        self.on_saved = on_saved
        self.installed = installed
        self._generation = 0
        self._reset()

    def _reset(self) -> None:
        self.state = "idle"            # idle, starting, recording, paused, finishing
        self.sources = "both"
        self.title = ""
        self.language = "auto"
        self.model = None
        self.streaming = False
        self.segments: list[tx.Segment] = []
        self.preview: list[tuple[str | None, str]] = []
        self.levels = {"microphone": 0.0, "system": 0.0}
        self.warning: str | None = None
        self.pause_reason: str | None = None
        self.lag = 0.0
        self.keep_audio = True
        self._folder: Path | None = None
        self._captures: dict[str, Capture] = {}
        self._writers: dict[str, WavWriter] = {}
        self._pending: dict[str, list[np.ndarray]] = {s: [] for s in STREAMS}
        self._pending_lock = threading.Lock()
        self._audio: dict[str, RollingAudio] = {}
        self._live: dict[str, LiveText] = {}
        self._sentences: dict[str, SentenceParagraphs] = {}
        self._chunkers: dict[str, PauseChunker] = {}
        self._chunk_segments: dict[str, list[tx.Segment]] = {s: [] for s in STREAMS}
        self._active: set[str] = set()
        self._lease: str | None = None
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._worker: threading.Thread | None = None
        self._recorded_before = 0.0
        self._resumed_at: float | None = None
        self._started_wall = time.time()
        self._paused_cycles = 0
        self._settled_cycles = 0
        self._last_partial = 0.0
        self._failures = 0
        self._saw_speech = False

    # State

    @property
    def active(self) -> bool:
        return self.state != "idle"

    @property
    def elapsed(self) -> float:
        running = time.monotonic() - self._resumed_at if self._resumed_at is not None else 0.0
        return self._recorded_before + running

    @property
    def labeling(self) -> bool:
        return self._active == set(STREAMS)

    def speaker(self, stream: str) -> str | None:
        if not self.labeling:
            return None
        return "you" if stream == "microphone" else "others"

    def _changed(self) -> None:
        self.post(self.on_change)

    # Commands (main thread)

    def start(self, sources: str, language: str, keep_audio: bool, title: str = "") -> str | None:
        """Starts a note. Returns an error message instead when it cannot start."""
        if self.active:
            return "A note is already recording."
        model = self.settings.model_for("notes", language)
        if not model.supports(language):
            return (f"{model.name} does not transcribe {language_name(language)}. "
                    "Download Whisper Turbo in Preferences, Models.")
        if model.id not in self.installed():
            return f"Download {model.name} in Preferences, Models before recording a note."
        self._reset()
        self._generation += 1
        self.sources, self.language, self.keep_audio, self.title = sources, language, keep_audio, title
        self.model = model
        self.streaming = model.streams
        self.state = "starting"
        self._folder = self.library.audio_folder / f".recording-{uuid.uuid4().hex[:12]}"
        try:
            paths.ensure(self._folder)
        except OSError as error:
            self._reset()
            return f"Could not create a folder for this note: {error.strerror}"
        self._write_meta()
        errors = []
        wanted = ["microphone", "system"] if sources == "both" else [sources]
        for stream in wanted:
            try:
                self._open(stream, append=False)
                self._active.add(stream)
            except OSError as error:
                errors.append(f"{'The microphone' if stream == 'microphone' else 'System audio'} could not start: {error}")
        if not self._active:
            shutil.rmtree(self._folder, ignore_errors=True)
            self._reset()
            return " ".join(errors) or "Could not start recording."
        if errors:
            self.warning = " ".join(errors)
        self._lease = self.host.acquire_lease()
        self.host.prewarm(model)
        self._started_wall = time.time()
        self._resumed_at = time.monotonic()
        self.state = "recording"
        self._worker = threading.Thread(target=self._run, args=(self._generation,), daemon=True, name="note")
        self._worker.start()
        self.on_change()
        return None

    def _open(self, stream: str, append: bool) -> None:
        assert self._folder
        writer = self._writers.get(stream) or WavWriter(self._folder / FILES[stream], append=append)
        self._writers[stream] = writer

        def deliver(samples: np.ndarray, stream=stream, writer=writer):
            writer.append(samples)
            with self._pending_lock:
                self._pending[stream].append(samples)
            self.levels[stream] = capture.level

        device = self.settings.microphone if stream == "microphone" else None
        capture = Capture(system=stream == "system", device=device, on_samples=deliver)
        capture.start()
        self._captures[stream] = capture

    def pause(self, reason: str | None = None) -> None:
        if self.state != "recording":
            return
        self._recorded_before = self.elapsed
        self._resumed_at = None
        for capture in self._captures.values():
            capture.stop()
        self._captures = {}
        self.levels = {s: 0.0 for s in STREAMS}
        self.state = "paused"
        self.pause_reason = reason
        self._paused_cycles += 1
        self._wake.set()
        self.on_change()

    def resume(self) -> None:
        if self.state != "paused" or not self.model:
            return
        errors = []
        for stream in sorted(self._active):
            try:
                self._open(stream, append=True)
            except OSError as error:
                errors.append(str(error))
        if not self._captures:
            self.warning = "Recording could not resume. " + " ".join(errors)
            self.on_change()
            return
        if errors:
            self.warning = "One source did not resume. " + " ".join(errors)
        if self._lease is None:
            self._lease = self.host.acquire_lease()
        self.host.prewarm(self.model)
        self._resumed_at = time.monotonic()
        self.state = "recording"
        self.pause_reason = None
        self.on_change()

    def stop(self) -> None:
        if self.state not in ("recording", "paused", "starting"):
            return
        self._recorded_before = self.elapsed
        self._resumed_at = None
        for capture in self._captures.values():
            capture.stop()
        self._captures = {}
        self.state = "finishing"
        self._stop.set()
        self._wake.set()
        self.on_change()

    def discard(self) -> None:
        if not self.active:
            return
        self._generation += 1
        for capture in self._captures.values():
            capture.stop()
        self._stop.set()
        self._wake.set()
        for writer in self._writers.values():
            writer.close()
        if self._folder:
            shutil.rmtree(self._folder, ignore_errors=True)
        self.host.release_lease(self._lease)
        self._reset()
        self.on_change()

    def set_title(self, title: str) -> None:
        self.title = title
        self._write_meta()

    def tick(self) -> None:
        """Called by the UI about twice a second: checks for failed sources."""
        if self.state != "recording":
            return
        for stream, capture in list(self._captures.items()):
            if capture.failure or not capture.running:
                self.pause("Recording paused because "
                           f"{'the microphone' if stream == 'microphone' else 'system audio'} stopped. "
                           "Check the input and resume when ready.")
                self.warning = f"{capture.failure or 'The source stopped.'}"
                return

    # Worker

    def _drain(self) -> dict[str, np.ndarray]:
        with self._pending_lock:
            batches = {s: np.concatenate(self._pending[s]) for s in STREAMS if self._pending[s]}
            self._pending = {s: [] for s in STREAMS}
        return batches

    def _run(self, generation: int) -> None:
        while True:
            began = time.monotonic()
            final = self._stop.is_set()
            if self._gone(generation):
                return
            for stream, samples in self._drain().items():
                if self.streaming:
                    self._audio.setdefault(stream, RollingAudio()).append(samples)
                else:
                    self._queue_chunks(stream, self._chunkers.setdefault(stream, PauseChunker()).append(samples))
            if self.state == "paused" and self._settled_cycles != self._paused_cycles:
                self._settled_cycles = self._paused_cycles
                self._step(final=True)
                if self.state == "paused":
                    self.host.release_lease(self._lease)
                    self._lease = None
            elif self.state == "recording" or final:
                self._step(final=final)
            if self._gone(generation):
                return
            self._save_partial()
            self._changed()
            if final:
                self._finish(generation)
                return
            wait = 1.5 - (time.monotonic() - began)
            if wait > 0:
                self._wake.wait(wait)
                self._wake.clear()

    def _gone(self, generation: int) -> bool:
        """True once the note was discarded or replaced; the worker then stops touching shared state."""
        return generation != self._generation

    def _step(self, final: bool) -> None:
        if self.streaming:
            for stream in STREAMS:
                if stream in self._audio:
                    self._stream_step(stream, final)
            self.lag = max((a.end - self._live[s].settled_until for s, a in self._audio.items() if s in self._live),
                           default=0.0)
        elif final:
            for stream, chunker in self._chunkers.items():
                tail = chunker.flush()
                if tail:
                    self._queue_chunks(stream, [tail])

    def _stream_step(self, stream: str, final: bool) -> None:
        audio = self._audio[stream]
        end = audio.end
        live = self._live.setdefault(stream, LiveText(audio.start))
        generation = self._generation
        while not self._gone(generation):
            span = live.window(audio.start, end)
            if span is None:
                break
            found = audio.audio(*span)
            if found is None:
                break
            start, samples = found
            words: list[tx.Word] = []
            if has_speech(samples):
                self._saw_speech = True
                try:
                    result = self.host.transcribe(samples, self.model, self.language, offset=start,
                                                  boost=self.settings.boost_quiet_audio)
                    words = result.timed_words
                except (EngineError, Cancelled) as error:
                    if not final and span[1] - span[0] < live.max_window - 0.5:
                        break  # a short window is tried again with more audio
                    self._failure(str(error))
                if self._gone(generation):
                    return
            live.accept(words, span, final=final and span[1] >= end)
            settled = live.take_settled()
            if settled:
                self._sentences.setdefault(stream, SentenceParagraphs(self.speaker(stream))).append(settled)
                self._publish_segments()
            audio.discard(live.settled_until - live.left_context - 1)
            if not final or live.settled_until >= end:
                break
        self._publish_preview()

    def _queue_chunks(self, stream: str, chunks: list[tuple[float, np.ndarray]]) -> None:
        for start, samples in chunks:
            if not has_speech(samples):
                continue
            self._saw_speech = True
            previous = " ".join(s.text for s in self._chunk_segments[stream])[-200:]
            vocabulary = self.settings.note_vocabulary.strip()[:400]
            prompt = vocabulary or (previous if previous and cleanup.repetition_score(previous) == 0 else None)
            try:
                result = self.host.transcribe(samples, self.model, self.language, prompt=prompt, offset=start,
                                              speaker=self.speaker(stream), boost=self.settings.boost_quiet_audio)
                self._chunk_segments[stream].extend(cleanup.clean(result.segments, preserve_short_closings=True))
                self._publish_segments()
            except (EngineError, Cancelled) as error:
                self._failure(str(error))

    def _failure(self, detail: str) -> None:
        self._failures += 1
        self.warning = ("A part of the recording could not be transcribed and was skipped."
                        if self._failures == 1 else
                        f"{self._failures} parts of the recording could not be transcribed and were skipped.")

    def _publish_segments(self) -> None:
        if self.streaming:
            mic = self._sentences.get("microphone").segments if "microphone" in self._sentences else []
            system = self._sentences.get("system").segments if "system" in self._sentences else []
        else:
            mic, system = list(self._chunk_segments["microphone"]), list(self._chunk_segments["system"])
        for segment in mic:
            segment.speaker = self.speaker("microphone")
        for segment in system:
            segment.speaker = self.speaker("system")
        self.segments = cleanup.merge(mic, system) if self.labeling else tx.renumber(mic + system)

    def _publish_preview(self) -> None:
        if not self.settings.note_live_text:
            self.preview = []
            return
        self.preview = [(self.speaker(s), tx.join_words(self._live[s].pending)) for s in STREAMS
                        if s in self._live and self._live[s].pending]

    def _write_meta(self) -> None:
        if not self._folder:
            return
        try:
            meta = {"title": self.title, "started": self._started_wall, "language": self.language,
                    "model": self.model.name if self.model else None, "keep_audio": self.keep_audio,
                    "sentence_paragraphs": self.streaming}
            (self._folder / "note.json").write_text(json.dumps(meta))
        except OSError:
            pass

    def _save_partial(self, force: bool = False) -> None:
        if not self._folder or (not force and time.monotonic() - self._last_partial < 30):
            return
        self._last_partial = time.monotonic()
        try:
            data = {"segments": [s.to_dict() for s in self.segments], "elapsed": self.elapsed}
            (self._folder / "transcript.json").write_text(json.dumps(data))
        except OSError:
            self.warning = "The transcript could not be saved to your library folder. Check access and disk space."

    def _finish(self, generation: int) -> None:
        for writer in self._writers.values():
            writer.close()
            if writer.failed:
                self.warning = "The recording could not be fully saved. Check available disk space."
        self.preview = []
        self._save_partial(force=True)
        self._changed()
        folder = self._folder
        assert folder
        title = self.title.strip() or fallback_title(self._started_wall)
        job = Job("note", title, str(folder), created=self._started_wall, status="completed")
        job.segments = list(self.segments)
        job.model_name = self.model.name if self.model else None
        job.language = self.language
        job.duration = self._recorded_before
        job.sentence_paragraphs = self.streaming
        notes = [self.warning] if self.warning else []
        if not self._saw_speech or not job.segments:
            notes.insert(0, "No speech was detected.")
        job.warning = "\n".join(notes) or None
        try:
            finalize(self.library, job, folder, self.keep_audio)
        except OSError as error:
            job.warning = ((job.warning or "") + f"\nThe recording could not be moved: {error.strerror}").strip()
        self.host.release_lease(self._lease)

        def done():
            if self._gone(generation):
                return
            self.library.add(job)
            try:
                self.library.write_transcripts(job)
                self.library.save()
            except OSError:
                pass
            self._reset()
            self.on_change()
            self.on_saved(job)

        self.post(done)


def finalize(library: Library, job: Job, folder: Path, keep_audio: bool) -> None:
    """Names the recording folder after the note and converts or deletes its WAV files."""
    wavs = [folder / FILES[s] for s in STREAMS if (folder / FILES[s]).exists()]
    if not keep_audio:
        shutil.rmtree(folder, ignore_errors=True)
        job.source = ""
        job.audio_files = []
        return
    target = library.unique_folder(folder.parent, job.title)
    folder.rename(target)
    job.source = str(target)
    audio = []
    both = len(wavs) == 2
    for wav in wavs:
        current = target / wav.name
        suffix = (" (You)" if wav.name == FILES["microphone"] else " (Others)") if both else ""
        destination = target / f"{target.name}{suffix}.m4a"
        try:
            media.compress(current, destination)
            audio.append(str(destination))
        except (media.MediaError, OSError):
            audio.append(str(current))
            job.warning = ((job.warning or "") + "\nThe recording could not be converted to M4A. "
                           "The original audio was kept.").strip()
    for extra in ("note.json", "transcript.json"):
        (target / extra).unlink(missing_ok=True)
    job.audio_files = audio


def recover(library: Library) -> list[Job]:
    """Notes interrupted by a crash or power loss become library items with their partial transcript."""
    recovered = []
    folder = library.audio_folder
    if not folder.is_dir():
        return recovered
    for leftover in sorted(folder.glob(".recording-*")):
        try:
            meta = json.loads((leftover / "note.json").read_text())
        except (OSError, ValueError):
            meta = {}
        try:
            partial = json.loads((leftover / "transcript.json").read_text())
        except (OSError, ValueError):
            partial = {}
        started = meta.get("started") or leftover.stat().st_mtime
        title = (meta.get("title") or "").strip() or fallback_title(started)
        job = Job("note", f"{title} (recovered)", str(leftover), created=started, status="completed")
        job.segments = [tx.Segment.from_dict(s) for s in partial.get("segments", [])]
        job.duration = partial.get("elapsed")
        job.model_name = meta.get("model")
        job.language = meta.get("language")
        job.sentence_paragraphs = bool(meta.get("sentence_paragraphs"))
        job.warning = ("This note was interrupted before it was saved. The transcript may miss its last seconds; "
                       "the recording was kept.")
        if not any(leftover.glob("*.wav")) and not job.segments:
            shutil.rmtree(leftover, ignore_errors=True)
            continue
        try:
            finalize(library, job, leftover, True)
        except OSError:
            continue
        library.add(job)
        library.write_transcripts(job)
        recovered.append(job)
    if recovered:
        library.save()
    return recovered
