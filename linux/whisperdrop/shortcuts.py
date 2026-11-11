"""Global dictation shortcut.

Wayland apps cannot grab keys themselves. WhisperDrop supports:
  * Hyprland: two lines in the user's config, added only when the user asks, bound to whisperdrop-ctl.
    The app never creates or removes binds at runtime: runtime Lua binds crashed Hyprland 0.56.2.
  * GNOME, KDE and other portal desktops: the XDG GlobalShortcuts portal, which reports press and release.
  * Anything else: a keyboard shortcut in the desktop's settings that runs `whisperdrop-ctl dictate toggle`.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Callable


BEGIN = "WhisperDrop dictation >>>"
END = "<<< WhisperDrop dictation"
SUGGESTED_KEYS = ("F9", "F8", "F10", "Pause", "Insert", "SUPER + D", "SUPER + SHIFT + D")


def ctl_command() -> str:
    found = shutil.which("whisperdrop-ctl")
    return found or str(Path(__file__).resolve().parents[1] / "bin" / "whisperdrop-ctl")


def hyprland() -> bool:
    return bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"))


def hypr_config() -> tuple[Path, bool] | None:
    """The file to add bindings to, and whether it is Lua (Hyprland 0.55+) or hyprlang."""
    folder = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "hypr"
    if (folder / "hyprland.lua").exists():
        bindings = folder / "bindings.lua"
        return (bindings if bindings.exists() else folder / "hyprland.lua"), True
    if (folder / "hyprland.conf").exists():
        bindings = folder / "bindings.conf"
        return (bindings if bindings.exists() else folder / "hyprland.conf"), False
    return None


def normalize(key: str) -> list[str]:
    """"super+shift + d" -> ["SUPER", "SHIFT", "D"]."""
    parts = [p.strip() for p in re.split(r"\s*\+\s*", key.strip()) if p.strip()]
    mods = {"SUPER", "SHIFT", "CTRL", "CONTROL", "ALT", "MOD4", "WIN"}
    out = []
    for part in parts:
        upper = part.upper()
        out.append(upper if upper in mods else (part.upper() if len(part) == 1 else part))
    return out


def hypr_snippet(key: str, lua: bool, command: str | None = None) -> str:
    command = command or ctl_command()
    parts = normalize(key)
    if lua:
        keys = " + ".join(parts)
        return (f'-- {BEGIN}\n'
                f'hl.bind("{keys}", hl.dsp.exec_cmd("{command} dictate press"), {{ description = "WhisperDrop: dictate" }})\n'
                f'hl.bind("{keys}", hl.dsp.exec_cmd("{command} dictate release"), '
                f'{{ release = true, description = "WhisperDrop: stop dictating" }})\n'
                f'-- {END}\n')
    mods = " ".join(parts[:-1])
    return (f"# {BEGIN}\n"
            f"bind = {mods}, {parts[-1]}, exec, {command} dictate press\n"
            f"bindr = {mods}, {parts[-1]}, exec, {command} dictate release\n"
            f"# {END}\n")


def without_block(text: str) -> str:
    pattern = re.compile(r"\n?^(?:--|#) " + re.escape(BEGIN) + r".*?^(?:--|#) " + re.escape(END) + r"\n?",
                         re.MULTILINE | re.DOTALL)
    return pattern.sub("\n", text).rstrip("\n") + "\n" if pattern.search(text) else text


def installed_key(path: Path) -> str | None:
    try:
        text = path.read_text()
    except OSError:
        return None
    if BEGIN not in text:
        return None
    text = text[text.index(BEGIN):]
    if END in text:
        text = text[:text.index(END)]
    match = re.search(r'hl\.bind\("([^"]+)"', text) or re.search(r"^bind = ([^,]*), ([^,]+), exec", text, re.MULTILINE)
    if not match:
        return "?"
    return match[1] if match.lastindex == 1 else " + ".join(p for p in (match[1].strip(), match[2].strip()) if p)


def install_hypr(key: str) -> Path:
    """Adds or replaces the WhisperDrop block. Keeps a backup next to the file. Hyprland reloads it by itself."""
    found = hypr_config()
    if not found:
        raise OSError("No Hyprland configuration was found in ~/.config/hypr.")
    path, lua = found
    current = path.read_text() if path.exists() else ""
    if current:
        backup = path.with_name(f"{path.name}.whisperdrop-backup")
        backup.write_text(current)
    updated = without_block(current).rstrip("\n")
    updated = (updated + "\n\n" if updated else "") + hypr_snippet(key, lua)
    path.write_text(updated)
    return path


def remove_hypr() -> None:
    found = hypr_config()
    if found and found[0].exists():
        text = found[0].read_text()
        if BEGIN in text:
            found[0].write_text(without_block(text))


def hypr_conflict(key: str) -> str | None:
    """Description of an existing binding on the same key, read with `hyprctl binds -j` (read only)."""
    if not shutil.which("hyprctl"):
        return None
    try:
        binds = json.loads(subprocess.run(["hyprctl", "binds", "-j"], capture_output=True, text=True, timeout=2).stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    parts = normalize(key)
    wanted_key = parts[-1].lower()
    mask_bits = {"SHIFT": 1, "CTRL": 4, "CONTROL": 4, "ALT": 8, "SUPER": 64, "MOD4": 64, "WIN": 64}
    wanted_mask = sum(mask_bits.get(p, 0) for p in parts[:-1])
    for bind in binds:
        if str(bind.get("key", "")).lower() == wanted_key and int(bind.get("modmask", 0)) == wanted_mask:
            if "whisperdrop" in str(bind.get("arg", "")).lower():
                continue
            return bind.get("description") or bind.get("arg") or "another action"
    return None


class PortalShortcut:
    """XDG GlobalShortcuts portal session reporting press and release of the dictation shortcut."""

    def __init__(self, on_press: Callable[[], None], on_release: Callable[[], None]):
        self.on_press = on_press
        self.on_release = on_release
        self.status = "Not connected"
        self.trigger: str | None = None
        self._bus = None
        self._session: str | None = None
        self._subscriptions: list[int] = []

    def connect(self, preferred: str) -> None:
        from gi.repository import Gio, GLib

        try:
            self._bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        except GLib.Error as error:
            self.status = f"No session bus: {error.message}"
            return
        sender = self._bus.get_unique_name()[1:].replace(".", "_")
        token = f"whisperdrop{int(time.time())}"
        request = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"

        def created(_bus, _sender, _path, _iface, _signal, params):
            code, results = params.unpack()
            if code != 0:
                self.status = "The desktop did not allow a global shortcut."
                return
            self._session = results.get("session_handle")
            self._bind(preferred)

        self._subscriptions.append(self._bus.signal_subscribe(
            "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response", request, None,
            Gio.DBusSignalFlags.NO_MATCH_RULE, created))
        options = {"handle_token": GLib.Variant("s", token), "session_handle_token": GLib.Variant("s", token + "s")}
        try:
            self._bus.call_sync("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                                "org.freedesktop.portal.GlobalShortcuts", "CreateSession",
                                GLib.Variant("(a{sv})", (options,)), None, Gio.DBusCallFlags.NONE, 5000, None)
            self.status = "Waiting for the desktop"
        except GLib.Error:
            self.status = "This desktop has no global shortcut portal."
            return
        for name, callback in (("Activated", self.on_press), ("Deactivated", self.on_release)):
            def handler(_b, _s, _p, _i, _sig, params, callback=callback):
                if params[1] == "dictate":
                    callback()
            self._subscriptions.append(self._bus.signal_subscribe(
                "org.freedesktop.portal.Desktop", "org.freedesktop.portal.GlobalShortcuts", name, None, None,
                Gio.DBusSignalFlags.NONE, handler))

    def _bind(self, preferred: str) -> None:
        from gi.repository import Gio, GLib

        shortcut = ("dictate", {"description": GLib.Variant("s", "Dictate with WhisperDrop"),
                                "preferred_trigger": GLib.Variant("s", "+".join(normalize(preferred)))})
        token = f"whisperdropbind{int(time.time())}"
        try:
            self._bus.call_sync("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                                "org.freedesktop.portal.GlobalShortcuts", "BindShortcuts",
                                GLib.Variant("(oa(sa{sv})sa{sv})", (self._session, [shortcut], "",
                                                                    {"handle_token": GLib.Variant("s", token)})),
                                None, Gio.DBusCallFlags.NONE, -1, None)
            self.status = "Connected"
        except GLib.Error as error:
            self.status = f"The shortcut could not be registered: {error.message}"
