#!/usr/bin/env bash
# Removes the app, its Python environment, the launcher and the desktop entry.
# Models, settings and history stay unless you pass --purge. Saved transcripts and audio are never removed.
set -euo pipefail
prefix=${PREFIX:-$HOME/.local}
share=${XDG_DATA_HOME:-$HOME/.local/share}
[[ $prefix != "$HOME/.local" ]] && share="$prefix/share"
home="$share/whisperdrop"
rm -f "$prefix/bin/whisperdrop" "$prefix/bin/whisperdrop-ctl"
rm -f "$share/applications/io.github.zer0codestuff.WhisperDrop.desktop"
rm -f "$share/icons/hicolor/scalable/apps/io.github.zer0codestuff.WhisperDrop.svg" \
      "$share/icons/hicolor/symbolic/apps/io.github.zer0codestuff.WhisperDrop-symbolic.svg"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/io.github.zer0codestuff.WhisperDrop.desktop"
rm -rf "$home/app" "$home/venv" "$home/runtime"
if [[ ${1:-} == --purge ]]; then
  rm -rf "$home" "${XDG_CONFIG_HOME:-$HOME/.config}/whisperdrop"
  echo "Removed WhisperDrop, its models, settings and history. Saved files in ~/Documents/WhisperDrop were kept."
else
  echo "Removed WhisperDrop. Models, settings and history are in $home; run with --purge to remove them too."
fi
echo "If you added the dictation shortcut to Hyprland, remove the WhisperDrop block from your bindings file."
