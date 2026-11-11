"""Where WhisperDrop keeps its files. `--data-dir` (or WHISPERDROP_DATA_DIR) isolates everything, saved files included."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

_override: Path | None = None


def set_data_dir(path: str | os.PathLike | None) -> None:
    global _override
    _override = Path(path).expanduser().resolve() if path else None


def _xdg(name: str, fallback: str) -> Path:
    return Path(os.environ.get(name) or Path.home() / fallback)


def data_dir() -> Path:
    if _override:
        return _override
    env = os.environ.get("WHISPERDROP_DATA_DIR")
    if env:
        return Path(env).expanduser()
    return _xdg("XDG_DATA_HOME", ".local/share") / "whisperdrop"


def config_dir() -> Path:
    if _override or os.environ.get("WHISPERDROP_DATA_DIR"):
        return data_dir() / "config"
    return _xdg("XDG_CONFIG_HOME", ".config") / "whisperdrop"


def models_dir() -> Path:
    return data_dir() / "models"


def work_dir() -> Path:
    return data_dir() / "work"


def runtime_dir() -> Path:
    """Tools built by the installer, such as whisper-server."""
    return Path(os.environ.get("WHISPERDROP_RUNTIME") or (_xdg("XDG_DATA_HOME", ".local/share") / "whisperdrop" / "runtime"))


def documents_dir() -> Path:
    if _override or os.environ.get("WHISPERDROP_DATA_DIR"):
        return data_dir() / "Documents"
    try:
        out = subprocess.run(["xdg-user-dir", "DOCUMENTS"], capture_output=True, text=True, timeout=2).stdout.strip()
        if out and out != str(Path.home()):
            return Path(out)
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.home() / "Documents"


def default_library() -> Path:
    return documents_dir() / "WhisperDrop"


def tool(name: str) -> str | None:
    """A bundled tool from the runtime folder, then PATH."""
    candidate = runtime_dir() / "bin" / name
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return shutil.which(name)


def ensure(*folders: Path) -> None:
    for folder in folders:
        folder.mkdir(parents=True, exist_ok=True)
