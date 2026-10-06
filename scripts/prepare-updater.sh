#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Sparkle's release tools are for signing and local verification, not runtime model weights.
version='2.10.0'
checksum='c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
directory=".runtime/sparkle-$version"
if [[ ! -x "$directory/bin/sign_update" ]]; then
  mkdir -p "$directory"
  archive="$directory/Sparkle.tar.xz"
  curl --fail --location --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$archive"
  actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
  [[ "$actual" == "$checksum" ]] || { echo 'Sparkle release checksum mismatch.' >&2; exit 1; }
  tar -xf "$archive" -C "$directory"
fi
echo "$directory/bin"
