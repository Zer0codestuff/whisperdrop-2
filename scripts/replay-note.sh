#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 ]]; then
  echo 'Usage: scripts/replay-note.sh AUDIO_16K_MONO REPORT.json [turbo|turbo-q8] [lecture|legacy]' >&2
  exit 2
fi
export WHISPERDROP_REPLAY_AUDIO="$1"
export WHISPERDROP_REPLAY_REPORT="$2"
export WHISPERDROP_REPLAY_MODEL="${3:-turbo}"
export WHISPERDROP_REPLAY_POLICY="${4:-lecture}"
swift test --filter NoteReplayTests/testReplay
