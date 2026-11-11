"""Hallucination filtering, dictation cleanup, repetition checks and speaker merging.

Ported from `TranscriptProcessing.swift` and `RepetitionGuard.swift`.
"""

from __future__ import annotations

import re

from .transcript import Segment, ServerTranscription


def normalized(text: str) -> str:
    """Letters and numbers only, lowercased, single spaces, so "Amara.org" and "amara org" meet."""
    out: list[str] = []
    pending = False
    for ch in text.lower():
        if ch.isalnum():
            if pending and out:
                out.append(" ")
            pending = False
            out.append(ch)
        elif out:
            pending = True
    return "".join(out)


def collapse_whitespace(text: str) -> str:
    return " ".join(text.split())


def levenshtein(a: str, b: str) -> int:
    if not a:
        return len(b)
    if not b:
        return len(a)
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb))
        previous = current
    return previous[-1]


def _similarity_normalized(a: str, b: str) -> float:
    if not a and not b:
        return 1.0
    if len(a) > 400 or len(b) > 400:
        return 0.0
    denominator = max(len(a), len(b))
    return 1.0 - levenshtein(a, b) / denominator if denominator else 1.0


def similarity(a: str, b: str) -> float:
    return _similarity_normalized(normalized(a), normalized(b))


EXACT_PHRASES = [normalized(p) for p in [
    "Thank you.", "Thank you for watching.", "Thanks for watching.", "Thanks for listening.", "Please subscribe.",
    "Subtitles by.", "Subtitles by the Amara.org community.", "Grazie per la visione.", "Grazie per aver guardato.",
    "Sottotitoli a cura di.", "Sous-titres réalisés par la communauté d'Amara.org.", "Merci d'avoir regardé.",
    "Subtítulos realizados por la comunidad de Amara.org.", "Gracias por ver.", "Vielen Dank fürs Zuschauen.",
    "Untertitel im Auftrag des ZDF.", "Obrigado por assistir.", "Legendas pela comunidade de Amara.org.",
    "Спасибо за просмотр.", "ご視聴ありがとうございました", "ご視聴ありがとうございます", "시청해 주셔서 감사합니다",
    "谢谢观看", "謝謝觀看", "Bedankt voor het kijken.", "Dzięki za oglądanie.", "İzlediğiniz için teşekkürler.",
    "شكرا للمشاهدة",
]]

CREDIT_MARKERS = [normalized(p) for p in [
    "amara org", "sottotitoli", "sous titres", "subtitulos realizados", "grazie per la visione",
    "grazie per aver guardato", "thanks for watching", "thank you for watching", "please subscribe",
]]

DICTATION_CREDIT_MARKERS = [normalized(p) for p in [
    "amara org", "subtitles by", "sottotitoli a cura", "sottotitoli creati", "sous titres realises",
    "sous titres réalisés", "subtitulos realizados", "subtítulos realizados", "untertitel im auftrag", "legendas pela",
]]

ANNOTATION_PHRASES = {
    "music", "applause", "laughter", "silence", "blank audio", "inaudible", "background noise", "background music",
    "music playing", "upbeat music", "dramatic music", "foreign language", "speaking in foreign language",
    "speaking foreign language", "indistinct chatter", "crosstalk", "phone ringing", "keyboard clicking",
}

ANNOTATION_WORDS = {
    "music", "musical", "applause", "laughter", "laugh", "laughs", "laughing", "silence", "silent", "blank", "audio",
    "inaudible", "cough", "coughing", "noise", "background", "cheering", "cheers", "sigh", "sighing", "playing",
    "upbeat", "dramatic", "clapping", "sneeze", "beep", "beeping", "snoring", "gasp", "crying", "whispering",
    "unintelligible", "static", "loud", "soft", "wild", "gentle", "faint", "distant",
}


def _is_annotation(inner: str) -> bool:
    key = normalized(inner)
    if not key or key in ANNOTATION_PHRASES:
        return True
    return all(word in ANNOTATION_WORDS for word in key.split())


_BRACKETS = re.compile(r"\[([^\]]*)\]|\(([^)]*)\)")


def remove_annotations(text: str) -> str:
    def replace(match: re.Match) -> str:
        inner = match.group(1) if match.group(1) is not None else match.group(2)
        return " " if _is_annotation(inner) else match.group(0)

    return _BRACKETS.sub(replace, text)


def _matches_exact(key: str) -> bool:
    if not key:
        return False
    for phrase in EXACT_PHRASES:
        rest, count = key, 0
        while rest.startswith(phrase):
            count += 1
            rest = rest[len(phrase):]
            if rest.startswith(" "):
                rest = rest[1:]
            elif rest:
                break
        if not rest and count >= 1:
            return True
    return False


def _is_looped(key: str) -> bool:
    tokens = key.split(" ")
    count = len(tokens)
    if count < 6:
        return False
    for unit in range(1, count // 3 + 1):
        if count % unit or count // unit < 3:
            continue
        if all(tokens[i] == tokens[i % unit] for i in range(unit, count)):
            return True
    return False


def _cleaned(raw: str, preserve_short_closings: bool) -> str | None:
    text = collapse_whitespace(remove_annotations(raw))
    key = normalized(text)
    if not key:
        return None
    exact = _matches_exact(key) and not (preserve_short_closings and key == "thank you")
    credit = len(key) <= 160 and any(m in key for m in CREDIT_MARKERS)
    if exact or credit or _is_looped(key):
        return None
    return text


def clean(segments: list[Segment], remove_neighbor_repeats: bool = True, preserve_short_closings: bool = False) -> list[Segment]:
    """Removes silence hallucinations, bracketed non-speech, credit lines and runs of repeated text."""
    kept: list[Segment] = []
    for segment in segments:
        text = _cleaned(segment.text, preserve_short_closings)
        if text is None:
            continue
        if remove_neighbor_repeats and kept:
            left, right = normalized(kept[-1].text), normalized(text)
            if left and right and _similarity_normalized(left, right) >= 0.90:
                continue
        kept.append(Segment(segment.id, segment.start, segment.end, text, segment.speaker, segment.words))
    return kept


def _first_word(text: str) -> str | None:
    word = ""
    for ch in text:
        if ch.isalpha() or ch in "'’":
            word += ch
        else:
            break
    return word or None


def join_dictation(parts: list[str], language: str | None, vocabulary: str = "") -> str:
    """Lowercases a mid-sentence capital that Whisper adds after a pause, unless something marks it as a name."""
    if len(parts) <= 1 or (language or "").lower() in {"german", "de", "luxembourgish", "lb"}:
        return " ".join(parts)
    names = {w.lower() for w in re.split(r"[^\w']+|_", vocabulary) if w}
    mid_sentence: set[str] = set()
    for part in parts:
        words = part.split(" ")
        for previous, word in zip(words, words[1:]):
            if previous and previous[-1] in ".!?…:;\"»”)":
                continue
            first = _first_word(word)
            if first and first[0].isupper():
                mid_sentence.add(first)
    result = parts[0]
    for part in parts[1:]:
        following = part
        word = _first_word(part)
        if (result and result[-1] not in ".!?…:;\"»”)" and word and word[0].isupper()
                and not any(c.isupper() for c in word[1:]) and word != "I" and not word.startswith("I'")
                and word.lower() not in names and word not in mid_sentence):
            following = part[0].lower() + part[1:]
        result += " " + following
    return result


def dictation_text(transcription: ServerTranscription, vocabulary: str = "") -> str | None:
    """One line ready to insert, or None when nothing meaningful was said."""
    kept: list[str] = []
    for segment in transcription.segments:
        text = collapse_whitespace(remove_annotations(segment.text))
        key = normalized(text)
        if not key:
            continue
        if len(key) <= 160 and any(m in key for m in DICTATION_CREDIT_MARKERS):
            continue
        kept.append(text)
    line = collapse_whitespace(join_dictation(kept, transcription.language, vocabulary))
    return line or None


# Repetition


def _tokens(text: str) -> list[str]:
    return [t for t in re.split(r"[\W_]+", text.lower()) if t]


def repetition_score(text: str) -> float:
    words = _tokens(text)
    if len(words) < 24:
        return 0.0
    counts: dict[str, int] = {}
    for i in range(len(words) - 3):
        key = " ".join(words[i:i + 4])
        counts[key] = counts.get(key, 0) + 1
    if max(counts.values(), default=0) < 6:
        return 0.0
    repeated = sum(c - 2 for c in counts.values() if c >= 3)
    ratio = repeated / (len(words) - 3)
    return ratio if ratio >= 0.3 else 0.0


def prefers(candidate: str, original: str) -> bool:
    if len(_tokens(candidate)) < 5:
        return False
    score = repetition_score(original)
    return score > 0 and repetition_score(candidate) <= score - 0.15


def looped_words(text: str) -> int:
    words = _tokens(text)
    worst = 0
    for size in range(1, 9):
        if len(words) < size * 3:
            continue
        needed = 3 if size >= 3 else (4 if size == 2 else 5)
        for start in range(0, len(words) - size + 1):
            count = 1
            while start + (count + 1) * size <= len(words) and \
                    words[start + count * size:start + (count + 1) * size] == words[start:start + size]:
                count += 1
            if count >= needed:
                worst = max(worst, (count - 1) * size)
    return worst


def dictation_loops(text: str) -> bool:
    return repetition_score(text) > 0 or looped_words(text) > 0


def dictation_prefers(candidate: str, original: str) -> bool:
    original_loop, candidate_loop = looped_words(original), looped_words(candidate)
    if not dictation_loops(original):
        return False
    if not (candidate_loop < original_loop or repetition_score(candidate) < repetition_score(original)):
        return False
    if candidate_loop > original_loop or repetition_score(candidate) > repetition_score(original):
        return False
    kept = max(1, len(_tokens(original)) - original_loop)
    return len(_tokens(candidate)) >= kept * 0.7


# Speakers


def _overlaps(a: Segment, b: Segment, pad: float) -> bool:
    return a.start < b.end + pad and b.start < a.end + pad


def _is_echo(you: Segment, others: Segment) -> bool:
    if not _overlaps(you, others, 1):
        return False
    yours, theirs = normalized(you.text), normalized(others.text)
    if len(yours) < 8 or len(theirs) < 8:
        return False
    if _similarity_normalized(yours, theirs) >= 0.84:
        return True
    short, long = (yours, theirs) if len(yours) <= len(theirs) else (theirs, yours)
    return len(short) >= 24 and short in long


def merge(you: list[Segment], others: list[Segment]) -> list[Segment]:
    """Both speakers by start time. Drops "You" lines that echo an overlapping "Others" line."""
    kept = [s for s in you if not any(_is_echo(s, o) for o in others)]
    ordered = sorted(kept + others, key=lambda s: (s.start, 0 if s.speaker == "others" else 1, s.end, s.id))
    for index, segment in enumerate(ordered):
        segment.id = index
    return ordered
