"""Push-to-talk dictation: the shortcut opens the microphone, the model transcribes, the text goes to the cursor.

Shortcuts arrive as `press` and `release` (Hyprland bindings, the GlobalShortcuts portal, or whisperdrop-ctl).
Modes:
    hold-or-tap  hold to talk and release to insert; a quick tap starts hands-free mode, the next press stops
    hold         hold to talk and release to insert
    toggle       press to start, press again to stop
With Parakeet, words appear in the overlay while you speak (LiveText windows about every 0.8 seconds).
"""

from __future__ import annotations

import threading
import time
from typing import Callable

import numpy as np

from . import insert
from .audio.capture import Capture
from .core import SAMPLE_RATE, cleanup
from .core.audio import has_speech
from .core.livetext import LiveText
from .engine.host import Cancelled, EngineError

TAP_SECONDS = 0.35
LIMIT_SECONDS = 600


class Dictation:
    def __init__(self, settings, host, post: Callable[[Callable], None], on_change: Callable[[], None],
                 installed: Callable[[], set[str]], can_start: Callable[[], str | None] = lambda: None):
        self.settings = settings
        self.host = host
        self.post = post
        self.on_change = on_change
        self.installed = installed
        self.can_start = can_start
        self.state = "idle"            # idle, listening, transcribing
        self.message: str | None = None
        self.live = ""
        self.level = 0.0
        self.recent: list[str] = []
        self.hands_free = False
        self.replay: np.ndarray | None = None   # verification: feed a clip instead of the microphone
        self.output: Callable[[str], str] | None = None  # verification: receive the text instead of typing it
        self._pressed_at = 0.0
        self._capture: Capture | None = None
        self._samples: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._generation = 0
        self._model = None

    # Shortcut events (main thread)

    def press(self) -> None:
        mode = self.settings.dictation_mode
        if self.state == "listening":
            if mode == "toggle" or self.hands_free:
                self.stop()
            return
        if self.state == "idle":
            self._pressed_at = time.monotonic()
            self.start()

    def release(self) -> None:
        if self.state != "listening" or self.hands_free:
            return
        mode = self.settings.dictation_mode
        if mode == "toggle":
            return
        if mode == "hold-or-tap" and time.monotonic() - self._pressed_at < TAP_SECONDS:
            self.hands_free = True
            self._set_message("Hands-free. Press the shortcut again to finish.")
            return
        self.stop()

    def toggle(self) -> None:
        if self.state == "listening":
            self.stop()
        elif self.state == "idle":
            self.hands_free = True
            self.start()

    # Commands

    def start(self) -> None:
        if self.state != "idle":
            return
        blocked = self.can_start()
        model = self.settings.model_for("dictation")
        if not blocked and model.id not in self.installed():
            blocked = f"Download {model.name} in Preferences, Models to dictate."
        if not blocked and not model.supports(self.settings.spoken_language):
            blocked = f"{model.name} does not cover this language. Download Whisper Turbo in Preferences, Models."
        if blocked:
            self._flash(blocked)
            return
        self._model = model
        self._generation += 1
        generation = self._generation
        self._samples = []
        self.live = ""
        self.message = None
        self.state = "listening"
        self.host.prewarm(model)
        if self.replay is not None:
            threading.Thread(target=self._feed_replay, args=(generation,), daemon=True).start()
        else:
            self._capture = Capture(system=False, device=self.settings.microphone, on_samples=self._append)
            try:
                self._capture.start()
            except OSError as error:
                self._capture = None
                self.state = "idle"
                self._flash(f"The microphone could not start. {error}")
                return
        if model.streams and self.settings.dictation_live_words:
            threading.Thread(target=self._preview, args=(generation,), daemon=True, name="dictation-live").start()
        threading.Thread(target=self._watch, args=(generation,), daemon=True, name="dictation-watch").start()
        self.on_change()

    def _append(self, samples: np.ndarray) -> None:
        with self._lock:
            self._samples.append(samples)
        if self._capture:
            self.level = self._capture.level

    def _feed_replay(self, generation: int) -> None:
        from .core.audio import level

        clip = self.replay
        assert clip is not None
        for start in range(0, clip.size, SAMPLE_RATE // 10):
            if generation != self._generation or self.state != "listening":
                return
            block = clip[start:start + SAMPLE_RATE // 10]
            self.level = level(block)
            with self._lock:
                self._samples.append(block)
            time.sleep(0.1)
        self.post(lambda: self.stop() if generation == self._generation else None)

    def _audio(self) -> np.ndarray:
        with self._lock:
            return np.concatenate(self._samples) if self._samples else np.zeros(0, dtype=np.float32)

    def stop(self) -> None:
        """Ends listening and inserts the text."""
        if self.state != "listening":
            return
        if self._capture:
            self._capture.stop()
            failure = self._capture.failure
            self._capture = None
        else:
            failure = None
        self.state = "transcribing"
        self.hands_free = False
        self.level = 0.0
        self.on_change()
        generation = self._generation
        audio = self._audio()
        threading.Thread(target=self._finish, args=(generation, audio, failure), daemon=True,
                         name="dictation-finish").start()

    def cancel(self) -> None:
        if self.state == "idle":
            return
        self._generation += 1
        if self._capture:
            self._capture.stop()
            self._capture = None
        self.state = "idle"
        self.hands_free = False
        self.live = ""
        self.level = 0.0
        self._set_message("Dictation discarded.", flash=True)

    # Workers

    def _watch(self, generation: int) -> None:
        began = time.monotonic()
        while generation == self._generation and self.state == "listening":
            time.sleep(0.25)
            if self._capture and self._capture.failure:
                self.post(lambda: self.stop() if generation == self._generation else None)
                return
            if time.monotonic() - began > LIMIT_SECONDS:
                self.post(lambda: self.stop() if generation == self._generation else None)
                return
            self.post(self.on_change)  # level meter

    def _preview(self, generation: int) -> None:
        live = LiveText()
        while generation == self._generation and self.state == "listening":
            began = time.monotonic()
            audio = self._audio()
            end = audio.size / SAMPLE_RATE
            span = live.window(0.0, end)
            if span and has_speech(audio[int(span[0] * SAMPLE_RATE):int(span[1] * SAMPLE_RATE)]):
                piece = audio[int(span[0] * SAMPLE_RATE):int(span[1] * SAMPLE_RATE)]
                try:
                    result = self.host.transcribe(piece, self._model, self.settings.spoken_language,
                                                  offset=span[0], short_clip=True)
                    if generation != self._generation or self.state != "listening":
                        return
                    live.accept(result.timed_words, span)
                    text = live.text
                    self.post(lambda text=text: self._show_live(generation, text))
                except (EngineError, Cancelled):
                    pass
            time.sleep(max(0.1, 0.8 - (time.monotonic() - began)))

    def _show_live(self, generation: int, text: str) -> None:
        if generation == self._generation and self.state == "listening":
            self.live = text
            self.on_change()

    def _finish(self, generation: int, audio: np.ndarray, failure: str | None) -> None:
        text, problem = None, None
        if audio.size < SAMPLE_RATE * 0.2 or not has_speech(audio, threshold=0.006, minimum=0.15):
            problem = failure and f"The microphone stopped. {failure}" or "No speech was heard."
        else:
            try:
                result = self.host.transcribe(audio, self._model, self.settings.spoken_language,
                                              prompt=self.settings.vocabulary.strip()[:400] or None, short_clip=True)
                text = cleanup.dictation_text(result, self.settings.vocabulary)
                if not text:
                    problem = "No speech was heard."
            except (EngineError, Cancelled) as error:
                problem = str(error)
        if generation != self._generation:
            return
        method = None
        if text:
            if self.output:
                method = self.output(text)
            else:
                # Typing leaves the clipboard alone. When typing is unavailable the text stays on the clipboard.
                method = insert.type_text(text + " ", self.settings.insert_method)

        def done():
            if generation != self._generation:
                return
            self.state = "idle"
            self.live = ""
            if text:
                self.recent.insert(0, text)
                del self.recent[20:]
                if method == "clipboard":
                    self._set_message("Copied. Press Ctrl+V to paste.", flash=True)
                else:
                    self.message = None
                    self.on_change()
            else:
                self._set_message(problem or "No speech was heard.", flash=True)

        self.post(done)

    # Messages

    def _flash(self, message: str) -> None:
        self._set_message(message, flash=True)

    def _set_message(self, message: str | None, flash: bool = False) -> None:
        self.message = message
        self.on_change()
        if flash:
            generation = self._generation

            def clear():
                time.sleep(3)
                self.post(lambda: self._clear_message(generation, message))

            threading.Thread(target=clear, daemon=True).start()

    def _clear_message(self, generation: int, message: str | None) -> None:
        if self.message == message and self.state == "idle":
            self.message = None
            self.on_change()
