#!/usr/bin/env bash
# Builds parakeet-server and places it beside the MLX shaders in .runtime/bin for tests and replays.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .runtime/bin/mlx.metallib ]] || scripts/prepare-mlx.sh
swift build -c release --arch arm64 --product parakeet-server
# Copying over the old file in place keeps its cached code signature, and macOS then kills the new binary.
rm -f .runtime/bin/parakeet-server
cp "$(swift build -c release --arch arm64 --show-bin-path)/parakeet-server" .runtime/bin/parakeet-server
