"""Words recognized while audio keeps arriving, for live text in dictation and notes.

Port of `LiveText.swift`. Each request decodes a short window that starts a little before the settled boundary.
A word settles once `settle_after` seconds of decoded audio follow it. Settled words never change.
"""

from __future__ import annotations

from dataclasses import dataclass

from .transcript import Word, join_words


def _key(text: str) -> str:
    return "".join(c for c in text.lower() if c.isalnum())


class LiveText:
    def __init__(self, start: float = 0.0):
        # 3 s of context made Parakeet switch Italian speech to English words; 10 s does not.
        self.left_context = 10.0
        self.settle_after = 6.0
        self.max_window = 30.0
        self.settled: list[Word] = []
        self.pending: list[Word] = []
        self.settled_until = start
        self._taken = 0

    def window(self, audio_start: float, end: float) -> tuple[float, float] | None:
        """Audio to decode next, or None when nothing new can be decoded."""
        start = max(audio_start, self.settled_until - self.left_context)
        stop = min(end, start + self.max_window)
        if stop <= self.settled_until or stop - start < 0.3:
            return None
        return (start, stop)

    def accept(self, words: list[Word], window: tuple[float, float], final: bool = False) -> None:
        fresh = self._new_words(words)
        if final:
            self.settled += fresh
            self.pending = []
            self.settled_until = max(self.settled_until, window[1])
            return
        cutoff = window[1] - self.settle_after
        count = 0
        while count < len(fresh) and fresh[count].end <= cutoff:
            count += 1
        if count:
            self.settled += fresh[:count]
            last = fresh[count - 1].end
            following = fresh[count].start if count < len(fresh) else cutoff
            self.settled_until = max(self.settled_until, last + max(0.0, following - last) / 2)
        elif not fresh and cutoff > self.settled_until:
            # Silence or noise. Move on so windows do not grow.
            self.settled_until = cutoff
        self.pending = fresh[count:]

    def _new_words(self, words: list[Word]) -> list[Word]:
        heard = [w for w in words if _key(w.text)]
        if not self.settled:
            return [w for w in heard if (w.start + w.end) / 2 >= self.settled_until]
        last = self.settled[-1]
        tail = [_key(w.text) for w in self.settled[-3:]]
        for length in range(len(tail), 0, -1):
            target = tail[-length:]
            best: tuple[int, float] | None = None
            for index in range(0, len(heard) - length + 1):
                distance = abs(heard[index + length - 1].start - last.start)
                if distance <= 0.5 and all(_key(heard[index + k].text) == target[k] for k in range(length)):
                    if best is None or distance < best[1]:
                        best = (index, distance)
            if best is not None:
                return heard[best[0] + length:]
        return [w for w in heard if (w.start + w.end) / 2 >= self.settled_until]

    def take_settled(self) -> list[Word]:
        """Settled words not handed out yet. Only the last three are retained afterwards."""
        fresh = self.settled[self._taken:]
        if len(self.settled) > 3:
            self.settled = self.settled[-3:]
        self._taken = len(self.settled)
        return fresh

    def discard(self, through: float) -> None:
        before = len(self.settled)
        self.settled = [w for w in self.settled if (w.start + w.end) / 2 >= through]
        self._taken = max(0, self._taken - (before - len(self.settled)))
        self.pending = [w for w in self.pending if (w.start + w.end) / 2 >= through]
        self.settled_until = max(self.settled_until, through)

    @property
    def settled_text(self) -> str:
        return join_words(self.settled)

    @property
    def text(self) -> str:
        return join_words(self.settled + self.pending)


@dataclass
class Edit:
    """Characters to delete from the end of the old text, then the text to type."""
    delete: int
    insert: str


def edit_between(old: str, new: str) -> Edit:
    shared = 0
    while shared < len(old) and shared < len(new) and old[shared] == new[shared]:
        shared += 1
    return Edit(len(old) - shared, new[shared:])
