#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 ]]; then
  echo 'Usage: scripts/replay-note.sh AUDIO_16K_MONO REPORT.json [turbo|turbo-q8|parakeet-v3] [lecture|legacy]' >&2
  exit 2
fi
export WHISPERDROP_REPLAY_AUDIO="$1"
export WHISPERDROP_REPLAY_REPORT="$2"
export WHISPERDROP_REPLAY_MODEL="${3:-turbo}"
export WHISPERDROP_REPLAY_POLICY="${4:-lecture}"
if [[ "$WHISPERDROP_REPLAY_MODEL" == parakeet* ]]; then scripts/stage-parakeet-server.sh; fi
swift test --filter NoteReplayTests/testReplay
