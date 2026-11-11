"""Transcript types and text output: reading paragraphs, labeled text, subtitles, Markdown and JSON."""

from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from typing import Iterable

SPEAKER_LABELS = {"you": "You", "others": "Others"}


@dataclass
class Word:
    start: float
    end: float
    text: str


@dataclass
class Segment:
    id: int
    start: float
    end: float
    text: str
    speaker: str | None = None
    words: list[Word] | None = None

    @property
    def time_label(self) -> str:
        return time_label(self.start)

    def to_dict(self) -> dict:
        data = {"id": self.id, "start": round(self.start, 3), "end": round(self.end, 3), "text": self.text}
        if self.speaker:
            data["speaker"] = self.speaker
        if self.words:
            data["words"] = [{"start": round(w.start, 3), "end": round(w.end, 3), "text": w.text} for w in self.words]
        return data

    @staticmethod
    def from_dict(data: dict) -> "Segment":
        words = data.get("words")
        return Segment(
            id=int(data.get("id", 0)),
            start=float(data.get("start", 0)),
            end=float(data.get("end", 0)),
            text=str(data.get("text", "")),
            speaker=data.get("speaker"),
            words=[Word(float(w["start"]), float(w["end"]), str(w["text"])) for w in words] if words else None,
        )


def time_label(seconds: float) -> str:
    """`mm:ss`, or `h:mm:ss` from one hour on."""
    total = max(0, int(seconds))
    if total >= 3600:
        return f"{total // 3600}:{(total // 60) % 60:02d}:{total % 60:02d}"
    return f"{total // 60:02d}:{total % 60:02d}"


def duration_label(seconds: float | None) -> str:
    if not seconds:
        return ""
    total = int(round(seconds))
    if total < 60:
        return f"{total} s"
    if total < 600:
        return f"{total // 60} min {total % 60} s" if total % 60 else f"{total // 60} min"
    if total < 3600:
        return f"{round(total / 60)} min"
    return f"{total // 3600} h {(total // 60) % 60:02d} min"


def ends_sentence(text: str) -> bool:
    value = text.strip().strip("\"'”’)]}")
    if not value or value.endswith(".."):
        return False
    return value[-1] in ".!?"


@dataclass
class ServerTranscription:
    segments: list[Segment] = field(default_factory=list)
    language: str | None = None

    @property
    def text(self) -> str:
        return " ".join(s.text for s in self.segments)

    @property
    def timed_words(self) -> list[Word]:
        """Every word with its time. A segment without word timing counts as one word."""
        result: list[Word] = []
        for segment in self.segments:
            if segment.words:
                result.extend(segment.words)
            else:
                result.append(Word(segment.start, segment.end, " " + segment.text))
        return result


UNSPACED_LANGUAGES = {"chinese", "zh", "japanese", "ja", "korean", "ko", "cantonese", "yue", "thai", "th",
                      "lao", "lo", "myanmar", "my", "khmer", "km"}


def parse_server(data: dict | bytes | str, offset: float = 0.0, speaker: str | None = None) -> ServerTranscription:
    """Parses a whisper-server or parakeet server `verbose_json` response."""
    if isinstance(data, (bytes, str)):
        data = json.loads(data)
    language = data.get("language")
    raw = data.get("segments")
    if raw is None:
        raw = [{"start": 0, "end": 0, "text": data["text"]}] if data.get("text") else []
    joins_pieces = (language or "").lower() not in UNSPACED_LANGUAGES
    segments: list[Segment] = []
    for index, value in enumerate(raw):
        words: list[Word] = []
        for token in value.get("words") or []:
            start, end, text = token.get("start"), token.get("end"), token.get("word", "")
            if start is None or end is None or start < 0 or end < start or not text:
                continue
            if joins_pieces and not text[0].isspace() and words:
                words[-1].text += text
                words[-1].end = max(words[-1].end, end + offset)
            else:
                words.append(Word(start + offset, end + offset, text))
        start = value.get("start") or 0.0
        end = value.get("end")
        if end is None:
            end = data.get("duration") or start
        text = str(value.get("text", "")).strip()
        if text:
            segments.append(Segment(index, start + offset, end + offset, text, speaker, words or None))
    return ServerTranscription(segments, language)


def join_words(words: Iterable[Word]) -> str:
    return " ".join("".join(w.text for w in words).split())


def paragraphs(segments: list[Segment], target_characters: int = 420, each_sentence: bool = False) -> list[Segment]:
    """Reading paragraphs, independent of inference and subtitle boundaries."""
    result: list[Segment] = []
    for segment in segments:
        if not segment.text.strip():
            continue
        if not result or each_sentence:
            result.append(Segment(segment.id, segment.start, segment.end, segment.text, segment.speaker, segment.words))
            continue
        last = result[-1]
        complete = ends_sentence(last.text)
        new_paragraph = last.speaker != segment.speaker or (
            complete and (segment.start - last.end >= 3 or len(last.text) >= target_characters))
        if new_paragraph:
            result.append(Segment(segment.id, segment.start, segment.end, segment.text, segment.speaker, segment.words))
            continue
        last.text += " " + segment.text.strip()
        last.end = max(last.end, segment.end)
        last.words = None
    for index, segment in enumerate(result):
        segment.id = index
    return result


def labeled_text(segments: list[Segment], each_sentence: bool = False) -> str:
    """Plain text. With speakers, consecutive paragraphs by the same speaker share one "You:" or "Others:" label."""
    rows = [p for p in paragraphs(segments, each_sentence=each_sentence) if p.text.strip()]
    if not any(r.speaker for r in rows):
        return "\n\n".join(r.text.strip() for r in rows)
    out: list[str] = []
    index = 0
    while index < len(rows):
        speaker = rows[index].speaker
        end = index + 1
        while end < len(rows) and rows[end].speaker == speaker:
            end += 1
        body = "\n\n".join(r.text.strip() for r in rows[index:end])
        out.append(f"{SPEAKER_LABELS.get(speaker, speaker)}: {body}" if speaker else body)
        index = end
    return "\n\n".join(out)


def subtitles(segments: list[Segment], vtt: bool) -> str:
    def stamp(seconds: float) -> str:
        ms = max(0, int(round(seconds * 1000)))
        sep = "." if vtt else ","
        return f"{ms // 3600000:02d}:{(ms // 60000) % 60:02d}:{(ms // 1000) % 60:02d}{sep}{ms % 1000:03d}"

    cues = []
    for i, s in enumerate(segments):
        text = s.text.strip()
        if s.speaker and vtt:
            text = f"<v {SPEAKER_LABELS.get(s.speaker, s.speaker)}>{text}"
        cues.append(f"{i + 1}\n{stamp(s.start)} --> {stamp(s.end)}\n{text}\n")
    return ("WEBVTT\n\n" if vtt else "") + "\n".join(cues)


def markdown(title: str, segments: list[Segment], each_sentence: bool = False, details: list[str] | None = None) -> str:
    lines = [f"# {title}", ""]
    if details:
        lines += ["*" + " · ".join(d for d in details if d) + "*", ""]
    for p in paragraphs(segments, each_sentence=each_sentence):
        prefix = f"**{SPEAKER_LABELS.get(p.speaker, p.speaker)}** " if p.speaker else ""
        lines += [f"`{p.time_label}` {prefix}{p.text.strip()}", ""]
    return "\n".join(lines).rstrip() + "\n"


def to_json(title: str, segments: list[Segment], language: str | None = None, model: str | None = None,
            duration: float | None = None) -> str:
    payload = {"title": title, "language": language, "model": model, "duration": duration,
               "text": labeled_text(segments), "segments": [s.to_dict() for s in segments]}
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def renumber(segments: list[Segment]) -> list[Segment]:
    ordered = sorted(segments, key=lambda s: (s.start, s.end, s.id))
    for index, segment in enumerate(ordered):
        segment.id = index
    return ordered


def search(segments: list[Segment], query: str) -> list[int]:
    """Indexes of segments whose text contains every word of `query`, case and accent insensitive."""
    import unicodedata

    def fold(text: str) -> str:
        return "".join(c for c in unicodedata.normalize("NFD", text.casefold()) if unicodedata.category(c) != "Mn")

    terms = fold(query).split()
    if not terms:
        return []
    return [i for i, s in enumerate(segments) if all(t in fold(s.text) for t in terms)]


__all__ = [name for name in dir() if not name.startswith("_")] + ["asdict"]
