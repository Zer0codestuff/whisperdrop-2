#!/usr/bin/env bash
# MLX shaders for parakeet-server. SwiftPM does not compile Metal sources, so the metallib comes from the
# mlx-metal wheel whose core version matches mlx-swift 0.32.3 (MLX 0.32.2).
# MLX loads bin/mlx.metallib first and falls back to bin/Resources/mlx.metallib. The macOS 26 build carries the
# kernels that MLX selects on newer GPUs; the macOS 14 build covers macOS 14 and 15.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .runtime/{bin/Resources,src,licenses}
fetch() {
  local url="$1" path="$2" expected="$3"
  if [[ ! -f "$path" ]]; then curl --fail --location --retry 3 "$url" -o "$path.part"; mv "$path.part" "$path"; fi
  printf '%s  %s\n' "$expected" "$path" | shasum -a 256 --check
}
fetch https://files.pythonhosted.org/packages/dd/cd/4e50bf325100e7165e13d025f264362bf0009196269f9eaf87f2c6e738a2/mlx_metal-0.32.2-py3-none-macosx_26_0_arm64.whl \
  .runtime/src/mlx_metal-0.32.2-macos26.whl e6abeac9ac5265830c9c1541b6f96e9be37a85c2446763a46ad466c63a3837ab
fetch https://files.pythonhosted.org/packages/f7/ab/ba1952908c5d2a5070cf1cfbfea0161c4751ea62299e2776819810917483/mlx_metal-0.32.2-py3-none-macosx_14_0_arm64.whl \
  .runtime/src/mlx_metal-0.32.2-macos14.whl 3825fff379dbc107dd3413e564a06caeaa24819910ec49c0439e454c06a1b9b8
unzip -p .runtime/src/mlx_metal-0.32.2-macos26.whl mlx/lib/mlx.metallib > .runtime/bin/mlx.metallib
unzip -p .runtime/src/mlx_metal-0.32.2-macos14.whl mlx/lib/mlx.metallib > .runtime/bin/Resources/mlx.metallib
chmod 644 .runtime/bin/mlx.metallib .runtime/bin/Resources/mlx.metallib
curl -fsSL https://raw.githubusercontent.com/ml-explore/mlx-swift/0.32.3/LICENSE -o .runtime/licenses/mlx-swift.txt
cp Sources/ParakeetMLX/LICENSE-mlx-audio-swift.txt .runtime/licenses/mlx-audio-swift.txt
ls -la .runtime/bin/mlx.metallib .runtime/bin/Resources/mlx.metallib
printf 'MLX shaders ready.\n'
