"""The transcript library: history.json in the data folder, saved audio and transcripts in the library folder.

Layout, matching the Mac app:
    <library>/Audio/<Title>/<Title>.m4a            a note's kept recording ("<Title> (You).m4a" and "(Others)" with both)
    <library>/Transcripts/<Title>/<Title>.txt|.srt|.vtt|.md
Main thread only. Workers hand their results back through GLib.idle_add.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from . import paths
from .core import transcript as tx

ACTIVE = {"downloading", "converting", "transcribing"}
STATUS_LABELS = {"queued": "Waiting", "downloading": "Downloading", "converting": "Preparing audio",
                 "transcribing": "Transcribing", "completed": "Done", "failed": "Failed", "cancelled": "Stopped"}


@dataclass
class Job:
    kind: str                      # file, youtube, note
    title: str
    source: str                    # file path or URL; the note's audio folder for notes
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    status: str = "queued"
    created: float = field(default_factory=time.time)
    segments: list[tx.Segment] = field(default_factory=list)
    error: str | None = None
    warning: str | None = None
    model_name: str | None = None
    language: str | None = None
    duration: float | None = None
    audio_files: list[str] = field(default_factory=list)
    transcript_folder: str | None = None
    sentence_paragraphs: bool = False
    progress: float = 0.0          # not saved

    @property
    def active(self) -> bool:
        return self.status in ACTIVE

    @property
    def text(self) -> str:
        return tx.labeled_text(self.segments, each_sentence=self.sentence_paragraphs)

    @property
    def status_label(self) -> str:
        return STATUS_LABELS.get(self.status, self.status.title())

    def to_dict(self) -> dict:
        return {"id": self.id, "kind": self.kind, "title": self.title, "source": self.source, "status": self.status,
                "created": self.created, "segments": [s.to_dict() for s in self.segments], "error": self.error,
                "warning": self.warning, "model_name": self.model_name, "language": self.language,
                "duration": self.duration, "audio_files": self.audio_files,
                "transcript_folder": self.transcript_folder, "sentence_paragraphs": self.sentence_paragraphs}

    @staticmethod
    def from_dict(data: dict) -> "Job":
        job = Job(kind=data.get("kind", "file"), title=data.get("title") or "Untitled", source=data.get("source", ""))
        for key in ("id", "status", "created", "error", "warning", "model_name", "language", "duration",
                    "transcript_folder", "sentence_paragraphs"):
            if key in data and data[key] is not None:
                setattr(job, key, data[key])
        job.audio_files = list(data.get("audio_files") or [])
        job.segments = [tx.Segment.from_dict(s) for s in data.get("segments") or []]
        if job.status in ACTIVE:
            job.status = "queued"  # interrupted by quitting; it runs again
        return job


def file_name(title: str) -> str:
    """A folder and file name for a title: no slashes or control characters, at most 80 characters."""
    name = re.sub(r"[/\\\x00-\x1f:]+", " ", title).strip().strip(".")
    name = " ".join(name.split())[:80].strip()
    return name or "Untitled"


def fallback_title(when: float | None = None) -> str:
    return time.strftime("Note %b %d, %H.%M", time.localtime(when or time.time())).replace(" 0", " ")


class Library:
    def __init__(self, settings):
        self.settings = settings
        self.path = paths.data_dir() / "history.json"
        self.jobs: list[Job] = []
        self.load_error: str | None = None
        self.load()

    # Folders

    @property
    def root(self) -> Path:
        return self.settings.library

    @property
    def audio_folder(self) -> Path:
        return self.root / "Audio"

    @property
    def transcripts_folder(self) -> Path:
        return self.root / "Transcripts"

    # Storage

    def load(self) -> None:
        try:
            data = json.loads(self.path.read_text())
            self.jobs = [Job.from_dict(item) for item in data.get("jobs", [])]
        except FileNotFoundError:
            self.jobs = []
        except (OSError, ValueError) as error:
            # Keep the unreadable file for recovery and start empty without overwriting it.
            backup = self.path.with_name(f"history-unreadable-{int(time.time())}.json")
            try:
                shutil.copy2(self.path, backup)
            except OSError:
                pass
            self.load_error = f"The library could not be read ({error}). A copy was kept as {backup.name}."
            self.jobs = []

    def save(self) -> None:
        paths.ensure(self.path.parent)
        payload = {"version": 1, "jobs": [job.to_dict() for job in self.jobs]}
        with tempfile.NamedTemporaryFile("w", dir=self.path.parent, delete=False, suffix=".tmp", encoding="utf-8") as h:
            json.dump(payload, h, ensure_ascii=False)
            h.flush()
            os.fsync(h.fileno())
        os.replace(h.name, self.path)

    def get(self, job_id: str | None) -> Job | None:
        return next((job for job in self.jobs if job.id == job_id), None)

    def add(self, job: Job) -> Job:
        self.jobs.insert(0, job)
        self.save()
        return job

    def remove(self, job_id: str, delete_files: bool = False) -> None:
        job = self.get(job_id)
        if not job:
            return
        self.jobs.remove(job)
        self.save()
        if delete_files:
            for folder in self.folders(job):
                trash(folder)

    def folders(self, job: Job) -> list[Path]:
        found = []
        if job.transcript_folder and Path(job.transcript_folder).is_dir():
            found.append(Path(job.transcript_folder))
        if job.kind == "note" and job.source and Path(job.source).is_dir():
            found.append(Path(job.source))
        return found

    # Writing transcripts

    def unique_folder(self, parent: Path, title: str, current: Path | None = None) -> Path:
        base = file_name(title)
        name, attempt = base, 1
        while (parent / name).exists() and (current is None or (parent / name).resolve() != current.resolve()):
            attempt += 1
            name = f"{base} {attempt}"
        return parent / name

    def write_transcripts(self, job: Job) -> None:
        """TXT, SRT, VTT and Markdown in the job's transcript folder, named after the title."""
        if job.status != "completed":
            return
        current = Path(job.transcript_folder) if job.transcript_folder else None
        folder = current if current and current.is_dir() else self.unique_folder(self.transcripts_folder, job.title)
        paths.ensure(folder)
        stem = folder.name
        details = [time.strftime("%B %d, %Y %H:%M", time.localtime(job.created)), job.model_name or "",
                   tx.duration_label(job.duration)]
        outputs = {
            ".txt": job.text + "\n",
            ".srt": tx.subtitles(job.segments, vtt=False),
            ".vtt": tx.subtitles(job.segments, vtt=True),
            ".md": tx.markdown(job.title, job.segments, job.sentence_paragraphs, details),
        }
        for old in folder.glob("*"):
            if old.suffix in outputs and old.stem != stem:
                old.unlink(missing_ok=True)
        for suffix, content in outputs.items():
            atomic_write(folder / f"{stem}{suffix}", content)
        job.transcript_folder = str(folder)

    def export(self, job: Job, fmt: str) -> str:
        if fmt == "txt":
            return job.text + "\n"
        if fmt == "srt":
            return tx.subtitles(job.segments, vtt=False)
        if fmt == "vtt":
            return tx.subtitles(job.segments, vtt=True)
        if fmt == "md":
            return tx.markdown(job.title, job.segments, job.sentence_paragraphs,
                               [time.strftime("%B %d, %Y %H:%M", time.localtime(job.created)), job.model_name or ""])
        if fmt == "json":
            return tx.to_json(job.title, job.segments, job.language, job.model_name, job.duration)
        raise ValueError(fmt)

    # Renaming

    def rename(self, job_id: str, title: str) -> None:
        """Renames the item, its transcript folder and files, and a note's audio folder and recordings."""
        job = self.get(job_id)
        title = " ".join(title.split())
        if not job or not title or title == job.title:
            return
        if job.active:
            raise ValueError("Wait until transcription finishes to rename this item.")
        old_title = job.title
        moves: list[tuple[Path, Path]] = []
        try:
            if job.kind == "note" and job.source and Path(job.source).is_dir():
                folder = Path(job.source)
                target = self.unique_folder(folder.parent, title, current=folder)
                if target != folder:
                    folder.rename(target)
                    moves.append((target, folder))
                renamed = []
                for audio in job.audio_files:
                    path = target / Path(audio).name
                    suffix = " (You)" if "(You)" in path.stem else " (Others)" if "(Others)" in path.stem else ""
                    new = target / f"{target.name}{suffix}{path.suffix}"
                    if path.exists() and path != new and not new.exists():
                        path.rename(new)
                        moves.append((new, path))
                        renamed.append(str(new))
                    else:
                        renamed.append(str(path if path.exists() else new))
                job.source = str(target)
                job.audio_files = renamed
            if job.transcript_folder and Path(job.transcript_folder).is_dir():
                folder = Path(job.transcript_folder)
                target = self.unique_folder(folder.parent, title, current=folder)
                if target != folder:
                    folder.rename(target)
                    moves.append((target, folder))
                job.transcript_folder = str(target)
            job.title = title
            self.write_transcripts(job)
            self.save()
        except OSError as error:
            for new, old in reversed(moves):
                try:
                    new.rename(old)
                except OSError:
                    pass
            job.title = old_title
            raise ValueError(f"Could not rename: {error.strerror or error}") from error

    # Moving the library

    def move_library(self, destination_parent: Path) -> Path:
        """Moves Audio and Transcripts into destination_parent/WhisperDrop and updates every reference."""
        old_root = self.root
        new_root = destination_parent / "WhisperDrop"
        if new_root.resolve() == old_root.resolve():
            return new_root
        paths.ensure(new_root)
        for name in ("Audio", "Transcripts"):
            source = old_root / name
            if not source.exists():
                continue
            target = new_root / name
            if target.exists() and any(target.iterdir()):
                raise ValueError(f"{target} already contains files. Choose an empty folder.")
            target.rmdir() if target.exists() else None
            shutil.move(str(source), str(target))

        def moved(value: str | None) -> str | None:
            if not value:
                return value
            try:
                return str(new_root / Path(value).relative_to(old_root))
            except ValueError:
                return value

        for job in self.jobs:
            job.transcript_folder = moved(job.transcript_folder)
            if job.kind == "note":
                job.source = moved(job.source) or job.source
                job.audio_files = [moved(a) or a for a in job.audio_files]
        self.settings.set("library_folder", str(new_root))
        self.save()
        return new_root


def atomic_write(path: Path, content: str) -> None:
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, suffix=".tmp", encoding="utf-8") as h:
        h.write(content)
    os.replace(h.name, path)


def trash(path: Path) -> None:
    """Moves a file or folder to the Trash through GIO, or leaves it in place when that fails."""
    try:
        from gi.repository import Gio

        Gio.File.new_for_path(str(path)).trash(None)
    except Exception:  # noqa: BLE001
        pass
