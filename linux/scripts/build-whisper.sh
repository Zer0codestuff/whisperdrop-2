#!/usr/bin/env bash
# Builds the pinned whisper.cpp server for WhisperDrop's Whisper models: Vulkan when its headers and glslc exist,
# otherwise CPU. Needs git, cmake and a C++ compiler. Output: $WHISPERDROP_RUNTIME/bin/whisper-server.
set -euo pipefail
runtime=${WHISPERDROP_RUNTIME:-${XDG_DATA_HOME:-$HOME/.local/share}/whisperdrop/runtime}
source="$runtime/src/whisper.cpp"
tag=v1.9.4
commit=927cfce34f31707e17f2bff35c349632fb9e2c3a
for tool in git cmake c++; do command -v "$tool" >/dev/null || { echo "$tool is needed to build whisper.cpp." >&2; exit 1; }; done
if [[ ! -d "$source/.git" ]]; then
  mkdir -p "$(dirname "$source")"
  git clone -q --depth 1 --branch "$tag" https://github.com/ggml-org/whisper.cpp.git "$source"
fi
[[ $(git -C "$source" rev-parse HEAD) == "$commit" ]] || { echo "Unexpected whisper.cpp revision." >&2; exit 1; }
flags=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DGGML_NATIVE=OFF)
if command -v glslc >/dev/null && { [[ -e /usr/include/vulkan/vulkan.h ]] || pkg-config --exists vulkan 2>/dev/null; }; then
  flags+=(-DGGML_VULKAN=ON); echo "Building with Vulkan."
else
  echo "Vulkan headers or glslc not found: building for the CPU."
fi
cmake -S "$source" -B "$source/build" "${flags[@]}" >/dev/null
cmake --build "$source/build" --target whisper-server -j "$(nproc)" >/dev/null
mkdir -p "$runtime/bin" "$runtime/licenses"
rm -f "$runtime/bin/whisper-server"
cp "$source/build/bin/whisper-server" "$runtime/bin/"
cp "$source/LICENSE" "$runtime/licenses/whisper.cpp.txt"
echo "Installed $runtime/bin/whisper-server"
