#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon is required.' >&2; exit 1; }
cmake_tool="${WD_CMAKE:-cmake}"
command -v "$cmake_tool" >/dev/null || { echo 'Install CMake, then run this script again.' >&2; exit 1; }

source_dir='.runtime/src/llama.cpp'
build_dir='.runtime/text-build'
revision='7fe450e19305b828c199d602c23a8337aaa1f03b'
mkdir -p .runtime/{bin,src,licenses}
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --depth 1 --branch v0.5.0 https://github.com/ggml-org/llama.cpp.git "$source_dir"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || { echo 'Unexpected llama.cpp revision. Use the pinned v0.5.0 source.' >&2; exit 1; }
git -C "$source_dir" diff --quiet && git -C "$source_dir" diff --cached --quiet || { echo 'The pinned llama.cpp source has local edits. Restore it before building the text runtime.' >&2; exit 1; }
[[ ! -f "$source_dir/tools/ui/dist/index.html" ]] || { echo 'Remove custom llama.cpp web UI assets before building the text runtime.' >&2; exit 1; }

# Embed the Metal kernels and link llama/ggml statically. Keep CPU code portable
# across Apple Silicon Macs and exclude the server's unrelated web frontend.
"$cmake_tool" -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_IS_DEV=OFF \
  -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
"$cmake_tool" --build "$build_dir" --target llama-server -j 6

# Replacing the inode avoids macOS retaining a previous cached code signature.
rm -f .runtime/bin/llama-server
cp "$build_dir/bin/llama-server" .runtime/bin/llama-server
chmod +x .runtime/bin/llama-server
cp "$source_dir/LICENSE" .runtime/licenses/llama.cpp.txt
cp "$source_dir/licenses/LICENSE-jsonhpp" .runtime/licenses/llama-json.txt
cp "$source_dir/vendor/cpp-httplib/LICENSE" .runtime/licenses/llama-httplib.txt
cp "$source_dir/vendor/hash/xxhash/LICENSE" .runtime/licenses/llama-xxhash.txt
cp "$source_dir/vendor/hash/sha256/LICENSE" .runtime/licenses/llama-sha256.txt
cp "$source_dir/vendor/hash/rotate-bits/LICENSE.md" .runtime/licenses/llama-rotate-bits.txt
sed -n '1,/^\/\/ SOFTWARE\./p' "$source_dir/ggml/src/ggml-cpu/llamafile/sgemm.cpp" > .runtime/licenses/llama-llamafile.txt
# stb_image is linked by the server's multimodal support. Retain both offered
# licenses in the bundled notices, even though WhisperDrop uses text only.
sed -n '/^This software is available under 2 licenses/,$p' "$source_dir/vendor/stb/stb_image.h" > .runtime/licenses/llama-stb.txt
sed -n '1,/^\*\//p' "$source_dir/common/base64.hpp" > .runtime/licenses/llama-base64.txt
cp NOTICE-Draft.txt .runtime/licenses/Draft.txt
if otool -L .runtime/bin/llama-server | tail -n +2 | grep -E '/opt/homebrew|/usr/local|@rpath' ; then
  echo 'Non-portable dependency in llama-server.' >&2; exit 1
fi
.runtime/bin/llama-server --version
printf 'Text runtime ready: llama.cpp v0.5.0 (%s).\n' "$revision"
