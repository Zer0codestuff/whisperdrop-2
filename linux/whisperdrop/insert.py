"""Puts dictated text where the cursor is.

Wayland has no single way to type into another app. wtype uses the virtual keyboard protocol (Hyprland, Sway,
river, KDE); ydotool uses a kernel virtual device and works everywhere once its daemon runs (GNOME); xdotool covers
X11. The clipboard always works and is the fallback.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time


def desktop() -> str:
    return (os.environ.get("XDG_CURRENT_DESKTOP") or os.environ.get("DESKTOP_SESSION") or "").lower()


def wayland() -> bool:
    return bool(os.environ.get("WAYLAND_DISPLAY")) or os.environ.get("XDG_SESSION_TYPE") == "wayland"


def ydotool_ready() -> bool:
    if not shutil.which("ydotool"):
        return False
    socket = os.environ.get("YDOTOOL_SOCKET") or f"/run/user/{os.getuid()}/.ydotool_socket"
    return os.path.exists(socket) or os.path.exists("/tmp/.ydotool_socket")


def automatic() -> str:
    """The best typing method for this session."""
    if wayland():
        gnome = "gnome" in desktop()
        if not gnome and shutil.which("wtype"):
            return "wtype"
        if ydotool_ready():
            return "ydotool"
        return "clipboard"
    if shutil.which("xdotool"):
        return "xdotool"
    return "clipboard"


def describe(method: str) -> str:
    resolved = automatic() if method == "auto" else method
    return {"wtype": "Typing with wtype", "ydotool": "Typing with ydotool", "xdotool": "Typing with xdotool",
            "clipboard": "Copying to the clipboard"}.get(resolved, resolved)


def missing(method: str) -> str | None:
    """Why a chosen method cannot work here, or None."""
    resolved = automatic() if method == "auto" else method
    if resolved == "wtype" and not shutil.which("wtype"):
        return "Install wtype to type into other apps."
    if resolved == "wtype" and "gnome" in desktop():
        return "GNOME does not support wtype. Use ydotool, or the clipboard."
    if resolved == "ydotool" and not shutil.which("ydotool"):
        return "Install ydotool and enable its service (systemctl --user enable --now ydotool)."
    if resolved == "ydotool" and not ydotool_ready():
        return "Start the ydotool service: systemctl --user enable --now ydotool."
    if resolved == "xdotool" and not shutil.which("xdotool"):
        return "Install xdotool to type into other apps."
    if resolved == "clipboard" and not (shutil.which("wl-copy") or shutil.which("xclip") or shutil.which("xsel")):
        return "Install wl-clipboard (Wayland) or xclip (X11) to copy text."
    return None


def copy(text: str) -> bool:
    if wayland() and shutil.which("wl-copy"):
        command = ["wl-copy", "--", text]
    elif shutil.which("xclip"):
        command = ["xclip", "-selection", "clipboard"]
    elif shutil.which("xsel"):
        command = ["xsel", "--clipboard", "--input"]
    else:
        return False
    try:
        if command[0] == "wl-copy":
            subprocess.run(command, timeout=3, check=True, stdin=subprocess.DEVNULL)
        else:
            subprocess.run(command, input=text.encode(), timeout=3, check=True)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def paste_clipboard() -> str | None:
    try:
        if wayland() and shutil.which("wl-paste"):
            return subprocess.run(["wl-paste", "--no-newline"], capture_output=True, timeout=2).stdout.decode()
        if shutil.which("xclip"):
            return subprocess.run(["xclip", "-selection", "clipboard", "-o"], capture_output=True, timeout=2).stdout.decode()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def type_text(text: str, method: str = "auto") -> str:
    """Types `text` into the focused app. Returns the method used; "clipboard" when it was only copied."""
    resolved = automatic() if method == "auto" else method
    try:
        if resolved == "wtype" and shutil.which("wtype"):
            subprocess.run(["wtype", "-d", "2", "--", text], timeout=60, check=True)
            return "wtype"
        if resolved == "ydotool" and ydotool_ready():
            subprocess.run(["ydotool", "type", "--key-delay", "2", "--", text], timeout=60, check=True)
            return "ydotool"
        if resolved == "xdotool" and shutil.which("xdotool"):
            subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "2", "--", text], timeout=60, check=True)
            return "xdotool"
    except (OSError, subprocess.SubprocessError):
        pass
    copy(text)
    return "clipboard"


def delete_characters(count: int, method: str = "auto") -> bool:
    """Backspaces for live words typed earlier. Only wtype and xdotool support this reliably."""
    if count <= 0:
        return True
    resolved = automatic() if method == "auto" else method
    try:
        if resolved == "wtype" and shutil.which("wtype"):
            args = ["wtype"]
            for _ in range(count):
                args += ["-k", "BackSpace"]
            subprocess.run(args, timeout=10, check=True)
            return True
        if resolved == "xdotool" and shutil.which("xdotool"):
            subprocess.run(["xdotool", "key", "--repeat", str(count), "BackSpace"], timeout=10, check=True)
            return True
    except (OSError, subprocess.SubprocessError):
        pass
    return False


def restore_later(previous: str | None, delay: float = 1.0) -> None:
    if previous is None:
        return

    def run():
        time.sleep(delay)
        copy(previous)

    threading.Thread(target=run, daemon=True).start()
