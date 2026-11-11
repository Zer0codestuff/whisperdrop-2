"""Dictation overlay: a pill at the bottom of the screen that never takes keyboard focus.

Uses gtk4-layer-shell where the compositor supports it (Hyprland, Sway, KDE). Elsewhere (GNOME) a normal window
would steal focus from the app being typed into, so a desktop notification is shown instead.
"""

from __future__ import annotations

import math
import os
import shutil
import struct
import subprocess
import wave

from gi.repository import Gtk

from .. import paths
from .widgets import LevelBars, label

try:
    import gi

    gi.require_version("Gtk4LayerShell", "1.0")
    from gi.repository import Gtk4LayerShell as LayerShell
except (ImportError, ValueError):
    LayerShell = None


def layer_shell() -> bool:
    return LayerShell is not None and LayerShell.is_supported()


class Hud:
    def __init__(self, app):
        self.app = app
        self.window: Gtk.Window | None = None
        self.notified = False
        self._last_state = "idle"

    def _build(self) -> None:
        window = Gtk.Window(application=self.app, decorated=False, resizable=False, focusable=False,
                            can_focus=False, title="WhisperDrop dictation")
        window.add_css_class("hud-window")
        LayerShell.init_for_window(window)
        LayerShell.set_layer(window, LayerShell.Layer.OVERLAY)
        LayerShell.set_anchor(window, LayerShell.Edge.BOTTOM, True)
        LayerShell.set_margin(window, LayerShell.Edge.BOTTOM, 56)
        LayerShell.set_keyboard_mode(window, LayerShell.KeyboardMode.NONE)
        LayerShell.set_namespace(window, "whisperdrop-dictation")
        pill = Gtk.Box(spacing=12)
        pill.add_css_class("hud")
        self.levels = LevelBars(height=16)
        pill.append(self.levels)
        self.state = label("", ("hud-state",))
        pill.append(self.state)
        self.live = label("", ("hud-live",))
        self.live.set_max_width_chars(60)
        self.live.set_ellipsize(1)  # start: keep the newest words visible
        pill.append(self.live)
        window.set_child(pill)
        self.window = window

    def update(self) -> None:
        dictation = self.app.dictation
        state = dictation.state
        if self.app.settings.sounds and state != self._last_state:
            if state == "listening":
                tone(True)
            elif self._last_state == "listening":
                tone(False)
        self._last_state = state
        visible = state != "idle" or bool(dictation.message)
        if not layer_shell():
            self._notify(dictation, state)
            return
        if self.window is None:
            if not visible:
                return
            self._build()
        if not visible:
            self.window.set_visible(False)
            return
        if state == "listening":
            text = "Hands-free" if dictation.hands_free else "Listening"
        elif state == "transcribing":
            text = "Transcribing"
        else:
            text = dictation.message or ""
        self.state.set_text(text)
        self.live.set_text(dictation.live if state != "idle" else "")
        self.live.set_visible(bool(dictation.live) and state != "idle")
        self.levels.set_visible(state == "listening")
        self.levels.set_level(dictation.level)
        self.window.set_visible(True)

    def _notify(self, dictation, state: str) -> None:
        if state == "listening" and not self.notified:
            self.notified = True
            self.app.notify("Listening", "Release the shortcut to type the words.")
        elif state == "idle":
            self.notified = False
            if dictation.message:
                self.app.notify("WhisperDrop", dictation.message)


def tone(start: bool) -> None:
    """A short, quiet tone when listening starts (rising) or ends (falling)."""
    if not shutil.which("pw-play"):
        return
    path = paths.data_dir() / f"tone-{'start' if start else 'end'}.wav"
    if not path.exists():
        rate, length = 48000, 0.09
        frames = bytearray()
        for i in range(int(rate * length)):
            t = i / rate
            frequency = (660 + 220 * t / length) if start else (880 - 220 * t / length)
            envelope = math.sin(math.pi * t / length)
            frames += struct.pack("<h", int(0.12 * envelope * 32767 * math.sin(2 * math.pi * frequency * t)))
        paths.ensure(path.parent)
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(bytes(frames))
    command = ["pw-play", "--media-role", "Notification"]
    target = os.environ.get("WHISPERDROP_PLAYBACK_TARGET")
    if target:
        command += ["--target", target]
    subprocess.Popen(command + [str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
