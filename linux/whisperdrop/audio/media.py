"""FFmpeg decoding and compression, and YouTube downloads through yt-dlp."""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
from pathlib import Path
from typing import Callable

import numpy as np

from .. import paths
from ..core import SAMPLE_RATE

EXTENSIONS = {"mp3", "wav", "m4a", "ogg", "oga", "flac", "opus", "webm", "mp4", "aac", "aiff", "aif", "mov", "mkv",
              "wma", "m4v", "caf", "avi", "3gp", "amr", "mpga", "mpeg", "mpg", "ts"}

YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"}


class MediaError(Exception):
    pass


def ffmpeg() -> str:
    found = paths.tool("ffmpeg")
    if not found:
        raise MediaError("FFmpeg is not installed. Install the ffmpeg package.")
    return found


def is_media(path: str | os.PathLike) -> bool:
    return Path(path).suffix.lower().lstrip(".") in EXTENSIONS


def youtube_url(text: str) -> str | None:
    from urllib.parse import urlparse

    text = text.strip()
    try:
        url = urlparse(text)
    except ValueError:
        return None
    if url.scheme.lower() not in ("http", "https") or (url.hostname or "").lower() not in YOUTUBE_HOSTS:
        return None
    if url.username or url.password:
        return None
    return text


def _run(command: list[str], cancel: threading.Event | None, progress: Callable[[str], None] | None = None) -> str:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                               text=True, errors="replace", start_new_session=True)
    lines: list[str] = []

    def read():
        assert process.stdout
        for line in process.stdout:
            lines.append(line)
            if len(lines) > 400:
                del lines[:200]
            if progress:
                progress(line)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    while process.poll() is None:
        if cancel and cancel.is_set():
            process.terminate()
            try:
                process.wait(3)
            except subprocess.TimeoutExpired:
                process.kill()
            raise InterruptedError()
        reader.join(0.1)
    reader.join(1)
    output = "".join(lines)
    if process.returncode != 0:
        raise MediaError(output.strip().splitlines()[-1] if output.strip() else f"{command[0]} failed.")
    return output


def duration(path: str | os.PathLike) -> float | None:
    probe = paths.tool("ffprobe")
    if not probe:
        return None
    try:
        out = subprocess.run([probe, "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
                             capture_output=True, text=True, timeout=30).stdout
        return float(json.loads(out)["format"]["duration"])
    except (OSError, subprocess.SubprocessError, KeyError, ValueError, TypeError):
        return None


def decode(source: str | os.PathLike, destination: str | os.PathLike, cancel: threading.Event | None = None,
           progress: Callable[[float], None] | None = None) -> Path:
    """Any audio or video to a 16 kHz mono 16-bit WAV."""
    total = duration(source) or 0

    def report(line: str):
        match = re.search(r"time=(\d+):(\d+):(\d+\.?\d*)", line)
        if match and total and progress:
            seconds = int(match[1]) * 3600 + int(match[2]) * 60 + float(match[3])
            progress(min(1.0, seconds / total))

    _run([ffmpeg(), "-nostdin", "-hide_banner", "-y", "-i", str(source), "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE),
          "-c:a", "pcm_s16le", "-f", "wav", str(destination)], cancel, report)
    return Path(destination)


def load_samples(path: str | os.PathLike) -> np.ndarray:
    """A 16 kHz mono WAV written by `decode`, as float32."""
    from ..core.audio import read_wav

    samples, rate = read_wav(Path(path).read_bytes())
    if rate != SAMPLE_RATE:
        raise MediaError("Unexpected sample rate.")
    return samples


def compress(source: Path, destination: Path) -> None:
    """WAV to AAC M4A at 48 kbit/s, the Mac app's note format. Never overwrites an existing file."""
    if destination.exists():
        raise MediaError(f"{destination.name} already exists.")
    temporary = destination.with_name(destination.name + ".part.m4a")
    _run([ffmpeg(), "-nostdin", "-hide_banner", "-y", "-i", str(source), "-c:a", "aac", "-b:a", "48k",
          "-movflags", "+faststart", str(temporary)], None)
    expected = duration(source)
    actual = duration(temporary)
    if expected and actual and abs(expected - actual) > 0.5:
        temporary.unlink(missing_ok=True)
        raise MediaError("The compressed recording is incomplete.")
    temporary.rename(destination)
    source.unlink()


def mix_for_playback(files: list[Path], destination: Path) -> Path:
    """One file with every track of a note, for the player."""
    if len(files) == 1:
        return files[0]
    inputs: list[str] = []
    for file in files:
        inputs += ["-i", str(file)]
    _run([ffmpeg(), "-nostdin", "-hide_banner", "-y", *inputs, "-filter_complex",
          f"amix=inputs={len(files)}:duration=longest:normalize=0", "-c:a", "aac", "-b:a", "64k", str(destination)], None)
    return destination


# YouTube


def ytdlp() -> str:
    found = paths.tool("yt-dlp")
    if not found:
        raise MediaError("yt-dlp is not installed. Install the yt-dlp package to import YouTube links.")
    return found


def youtube_entries(url: str, cancel: threading.Event | None = None) -> list[tuple[str, str]]:
    """(url, title) for a video, or for every video of a playlist."""
    output = _run([ytdlp(), "--flat-playlist", "--dump-single-json", "--no-warnings", url], cancel)
    start = output.find("{")
    data = json.loads(output[start:])
    if data.get("_type") == "playlist":
        entries = []
        for entry in data.get("entries") or []:
            video = entry.get("url") or entry.get("webpage_url")
            if video and not video.startswith("http"):
                video = f"https://www.youtube.com/watch?v={entry.get('id')}"
            if video:
                entries.append((video, entry.get("title") or "YouTube video"))
        return entries
    return [(data.get("webpage_url") or url, data.get("title") or "YouTube video")]


def youtube_audio(url: str, folder: Path, cancel: threading.Event | None = None,
                  progress: Callable[[float], None] | None = None) -> Path:
    paths.ensure(folder)

    def report(line: str):
        match = re.search(r"\[download\]\s+(\d+(?:\.\d+)?)%", line)
        if match and progress:
            progress(float(match[1]) / 100)

    template = str(folder / "%(id)s.%(ext)s")
    output = _run([ytdlp(), "-f", "bestaudio/best", "--no-playlist", "--newline", "--no-warnings", "-o", template,
                   "--print", "after_move:filepath", url], cancel, report)
    for line in reversed(output.strip().splitlines()):
        candidate = Path(line.strip())
        if candidate.is_file():
            return candidate
    files = sorted(folder.iterdir(), key=lambda p: p.stat().st_mtime)
    if not files:
        raise MediaError("The YouTube download did not produce a file.")
    return files[-1]
