"""User preferences in config_dir()/settings.json. Observers are called with the changed key."""

from __future__ import annotations

import json
import locale
import os
import tempfile
from pathlib import Path
from typing import Any, Callable

from . import paths
from .core import models

DEFAULTS: dict[str, Any] = {
    "spoken_language": None,           # filled from the locale on first run
    "main_model": models.DEFAULT_MODEL,
    "task_models": {},                 # dictation/notes/files -> model id
    "residency": "10-minutes",
    "auto_transcribe": True,
    "boost_quiet_audio": True,
    "library_folder": None,            # None uses ~/Documents/WhisperDrop
    "run_in_background": True,
    "guide_done": False,
    # Dictation
    "dictation_enabled": True,
    "shortcut": "F9",
    "dictation_mode": "hold-or-tap",   # hold-or-tap, hold, toggle
    "register_shortcut": True,
    "insert_method": "auto",           # auto, wtype, ydotool, xdotool, clipboard
    "sounds": True,
    "dictation_live_words": True,
    "vocabulary": "",
    # Notes
    "note_sources": "both",            # microphone, system, both
    "microphone": None,                # PipeWire source name, None for the default
    "keep_note_audio": True,
    "note_live_text": True,
    "note_vocabulary": "",
}

SOURCES = {"microphone": "Microphone", "system": "System audio", "both": "Microphone and system audio"}
MODES = {"hold-or-tap": "Hold to talk, tap for hands-free", "hold": "Hold to talk", "toggle": "Press to start and stop"}
TASKS = {"dictation": "Dictation", "notes": "Notes", "files": "Files and YouTube"}
INSERT_METHODS = {"auto": "Automatic", "wtype": "Type with wtype (wlroots, Hyprland, Sway)",
                  "ydotool": "Type with ydotool (GNOME, KDE)", "xdotool": "Type with xdotool (X11)",
                  "clipboard": "Copy to the clipboard only"}


class Settings:
    def __init__(self, path: Path | None = None):
        self.path = path or paths.config_dir() / "settings.json"
        self._values: dict[str, Any] = dict(DEFAULTS)
        self._observers: list[Callable[[str], None]] = []
        try:
            stored = json.loads(self.path.read_text())
            if isinstance(stored, dict):
                self._values.update({k: v for k, v in stored.items() if k in DEFAULTS})
        except (OSError, ValueError):
            pass
        if not self._values.get("spoken_language"):
            self._values["spoken_language"] = models.initial_language(locale.getlocale()[0] or os.environ.get("LANG"))
            self._save()
        if models.by_id(self._values["main_model"]).id != self._values["main_model"]:
            self._values["main_model"] = models.DEFAULT_MODEL
        self.installed: Callable[[], set[str]] = lambda: set()

    def __getattr__(self, key: str) -> Any:
        if key.startswith("_") or key not in DEFAULTS:
            raise AttributeError(key)
        return self._values[key]

    def set(self, key: str, value: Any) -> None:
        if key not in DEFAULTS:
            raise KeyError(key)
        if self._values.get(key) == value:
            return
        self._values[key] = value
        self._save()
        for observer in list(self._observers):
            observer(key)

    def observe(self, callback: Callable[[str], None]) -> Callable[[], None]:
        self._observers.append(callback)
        return lambda: self._observers.remove(callback) if callback in self._observers else None

    def _save(self) -> None:
        try:
            paths.ensure(self.path.parent)
            with tempfile.NamedTemporaryFile("w", dir=self.path.parent, delete=False, suffix=".tmp") as handle:
                json.dump(self._values, handle, indent=2)
            os.replace(handle.name, self.path)
        except OSError:
            pass

    # Models

    @property
    def model(self) -> models.Model:
        return models.by_id(self.main_model)

    def chosen_model(self, task: str) -> models.Model:
        return models.by_id(self.task_models.get(task) or self.main_model)

    def model_for(self, task: str, language: str | None = None) -> models.Model:
        """The model a task uses now: its own or the main model, or an installed Whisper model when that one does
        not cover the language."""
        return models.resolved(self.chosen_model(task), language or self.spoken_language, self.installed())

    def set_task_model(self, task: str, model_id: str | None) -> None:
        updated = dict(self.task_models)
        if not model_id or model_id == self.main_model:
            updated.pop(task, None)
        else:
            updated[task] = model_id
        self.set("task_models", updated)

    @property
    def library(self) -> Path:
        return Path(self.library_folder).expanduser() if self.library_folder else paths.default_library()
