#!/usr/bin/env bash
# Silent comparison of live dictation text with whole-clip decoding. See LiveTextReplayTests.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 ]]; then
  echo 'Usage: scripts/replay-live-text.sh SET_DIR REPORT_DIR [LANGUAGE] [PIECE_SECONDS]' >&2
  echo 'SET_DIR holds refs.jsonl and 16 kHz mono WAV files. Needs the Parakeet model in .experiments/models or WHISPERDROP_LIVE_MODELS.' >&2
  exit 2
fi
export WHISPERDROP_LIVE_SET="$1"
export WHISPERDROP_LIVE_REPORT="$2"
[[ -n "${3:-}" ]] && export WHISPERDROP_LIVE_LANGUAGE="$3"
export WHISPERDROP_LIVE_PIECE="${4:-60}"
scripts/stage-parakeet-server.sh
swift test --filter LiveTextReplayTests/testLiveTextReplay
