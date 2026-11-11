#!/usr/bin/env bash
# Installs WhisperDrop for the current user. Nothing is written outside your home folder and nothing runs as root.
#
#   ./install.sh                  app, Python environment, launcher, desktop entry and icons
#   ./install.sh --with-whisper   also builds whisper.cpp (Vulkan when available) for the Whisper models
#   ./install.sh --download       also downloads Parakeet v3 (671 MB)
#
# PREFIX defaults to ~/.local. WhisperDrop's data stays in ~/.local/share/whisperdrop and ~/Documents/WhisperDrop.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
prefix=${PREFIX:-$HOME/.local}
share=${XDG_DATA_HOME:-$HOME/.local/share}
[[ $prefix != "$HOME/.local" ]] && share="$prefix/share"
home="$share/whisperdrop"
app="$home/app"
venv="$home/venv"
runtime="$home/runtime"
with_whisper=0
download=0
for argument in "$@"; do
  case "$argument" in
    --with-whisper) with_whisper=1 ;;
    --download) download=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }

hint() {
  if command -v pacman >/dev/null; then echo "sudo pacman -S --needed $1"
  elif command -v apt-get >/dev/null; then echo "sudo apt install $2"
  elif command -v dnf >/dev/null; then echo "sudo dnf install $3"
  elif command -v zypper >/dev/null; then echo "sudo zypper install $3"
  else echo "install: $2"; fi
}

say "Checking requirements"
missing=()
python3 - <<'PY' || missing+=("gtk")
import sys
assert sys.version_info >= (3, 11), "Python 3.11 or later is needed"
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw
assert (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 7), "libadwaita 1.7 or later is needed"
PY
command -v ffmpeg >/dev/null || missing+=("ffmpeg")
command -v pw-record >/dev/null || command -v parec >/dev/null || missing+=("pipewire")
if ((${#missing[@]})); then
  echo
  echo "Missing: ${missing[*]}. Install them, then run this script again:"
  echo "  $(hint "python-gobject gtk4 libadwaita ffmpeg pipewire" "python3-gi gir1.2-adw-1 ffmpeg pipewire-bin" "python3-gobject gtk4 libadwaita ffmpeg pipewire-utils")"
  exit 1
fi
optional=()
command -v yt-dlp >/dev/null || optional+=("yt-dlp (YouTube links)")
command -v wl-copy >/dev/null || command -v xclip >/dev/null || optional+=("wl-clipboard (copying dictation)")
if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
  case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*) command -v ydotool >/dev/null || optional+=("ydotool (typing dictation on GNOME)") ;;
    *) command -v wtype >/dev/null || optional+=("wtype (typing dictation)") ;;
  esac
  compgen -G "/usr/lib*/libgtk4-layer-shell.so*" >/dev/null || compgen -G "/usr/lib/*/libgtk4-layer-shell.so*" >/dev/null \
    || optional+=("gtk4-layer-shell (dictation overlay)")
else
  command -v xdotool >/dev/null || optional+=("xdotool (typing dictation)")
fi
for item in "${optional[@]}"; do warn "Optional, not installed: $item"; done

say "Installing the app in $app"
mkdir -p "$app" "$prefix/bin"
rm -rf "$app/whisperdrop" "$app/bin" "$app/data"
cp -r "$here/whisperdrop" "$here/bin" "$here/data" "$app/"
find "$app/whisperdrop" -name __pycache__ -type d -prune -exec rm -rf {} +

say "Preparing the Python environment (numpy, sherpa-onnx)"
if [[ ! -x "$venv/bin/python" ]]; then
  python3 -m venv --system-site-packages "$venv"
fi
"$venv/bin/python" -m pip install --quiet --disable-pip-version-check --upgrade -r "$here/requirements.txt"

say "Adding whisperdrop and whisperdrop-ctl to $prefix/bin"
ln -sfn "$app/bin/whisperdrop" "$prefix/bin/whisperdrop"
ln -sfn "$app/bin/whisperdrop-ctl" "$prefix/bin/whisperdrop-ctl"

say "Adding the desktop entry and icons"
mkdir -p "$share/applications" "$share/icons/hicolor/scalable/apps" "$share/icons/hicolor/symbolic/apps"
sed "s|^Exec=whisperdrop |Exec=$prefix/bin/whisperdrop |; s|^Exec=whisperdrop-ctl |Exec=$prefix/bin/whisperdrop-ctl |" \
  "$here/data/io.github.zer0codestuff.WhisperDrop.desktop" > "$share/applications/io.github.zer0codestuff.WhisperDrop.desktop"
cp "$here/data/icons/hicolor/scalable/apps/"*.svg "$share/icons/hicolor/scalable/apps/"
cp "$here/data/icons/hicolor/symbolic/apps/"*.svg "$share/icons/hicolor/symbolic/apps/"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$share/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$share/icons/hicolor" 2>/dev/null || true

if ((with_whisper)); then
  say "Building whisper.cpp v1.9.4 for the Whisper models"
  WHISPERDROP_RUNTIME="$runtime" "$here/scripts/build-whisper.sh"
fi

if ((download)); then
  say "Downloading Parakeet v3"
  "$prefix/bin/whisperdrop" download parakeet-v3
fi

case ":$PATH:" in *":$prefix/bin:"*) ;; *) warn "$prefix/bin is not in your PATH. Add it to use whisperdrop from a terminal." ;; esac
say "Done. Open WhisperDrop from your app launcher, or run: whisperdrop"
