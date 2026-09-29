#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 ]]; then
  echo 'Usage: scripts/replay-note-session.sh AUDIO_16K_MONO REPORT.json [SPEED]' >&2
  exit 2
fi
export WHISPERDROP_SESSION_AUDIO="$1"
export WHISPERDROP_SESSION_REPORT="$2"
export WHISPERDROP_SESSION_SPEED="${3:-1}"
swift test --filter NoteSessionReplayTests/testRecordedSessionReplay
