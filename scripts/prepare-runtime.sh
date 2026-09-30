#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon is required.' >&2; exit 1; }
command -v cmake >/dev/null || { echo 'Install CMake, then run this script again.' >&2; exit 1; }
mkdir -p .runtime/{bin,src,licenses,models}
fetch() {
  local url="$1" path="$2" expected="$3"
  if [[ ! -f "$path" ]]; then curl --fail --location --retry 3 "$url" -o "$path.part"; mv "$path.part" "$path"; fi
  printf '%s  %s\n' "$expected" "$path" | shasum -a 256 --check
}
configure_whisper() {
  if [[ ! -d .runtime/src/whisper.cpp/.git ]]; then
    git clone --depth 1 --branch v1.9.4 https://github.com/ggml-org/whisper.cpp.git .runtime/src/whisper.cpp
  fi
  [[ "$(git -C .runtime/src/whisper.cpp rev-parse HEAD)" == 927cfce34f31707e17f2bff35c349632fb9e2c3a ]]
  cmake -S .runtime/src/whisper.cpp -B .runtime/src/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF
}
if [[ ! -x .runtime/bin/whisper-cli ]]; then
  configure_whisper
  cmake --build .runtime/src/whisper.cpp/build --target whisper-cli -j 6
  cp .runtime/src/whisper.cpp/build/bin/whisper-cli .runtime/bin/
fi
if [[ ! -x .runtime/bin/whisper-server ]]; then
  configure_whisper
  cmake --build .runtime/src/whisper.cpp/build --target whisper-server -j 6
  cp .runtime/src/whisper.cpp/build/bin/whisper-server .runtime/bin/
fi
if [[ ! -x .runtime/bin/whisper-vad-speech-segments ]]; then
  configure_whisper
  cmake --build .runtime/src/whisper.cpp/build --target whisper-vad-speech-segments -j 6
  cp .runtime/src/whisper.cpp/build/bin/whisper-vad-speech-segments .runtime/bin/
fi
fetch https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin .runtime/models/ggml-silero-v6.2.0.bin 2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987
fetch https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE .runtime/src/silero-license.txt 2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b
cp .runtime/src/silero-license.txt .runtime/licenses/Silero.txt
fetch https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz .runtime/src/ffmpeg.tar.xz 464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
if [[ ! -d .runtime/src/ffmpeg-8.1.2 ]]; then tar -xf .runtime/src/ffmpeg.tar.xz -C .runtime/src; fi
if [[ ! -x .runtime/bin/ffmpeg ]]; then
  (
    cd .runtime/src/ffmpeg-8.1.2
    ./configure --cc=clang --arch=arm64 --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0 --disable-autodetect --disable-shared --enable-static --disable-doc --disable-debug --disable-ffplay --disable-ffprobe --disable-network --disable-avdevice --disable-videotoolbox --disable-audiotoolbox --disable-encoders --enable-encoder=pcm_s16le --disable-muxers --enable-muxer=wav --disable-filters --enable-filter=aresample --enable-filter=aformat --enable-filter=anull --enable-filter=atrim --enable-filter=asetpts
    make -j 6
    cp ffmpeg ../../bin/ffmpeg
  )
fi
fetch https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos .runtime/src/yt-dlp_macos 0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202
cp .runtime/src/yt-dlp_macos .runtime/bin/yt-dlp
fetch https://github.com/denoland/deno/releases/download/v2.9.4/deno-aarch64-apple-darwin.zip .runtime/src/deno.zip 6d17647fdbf9c587a581dba205054c4ccf732dae0a196cc1e9b44c07589db412
unzip -oq .runtime/src/deno.zip -d .runtime/bin
chmod +x .runtime/bin/*
cp .runtime/src/whisper.cpp/LICENSE .runtime/licenses/whisper.cpp.txt
cp .runtime/src/ffmpeg-8.1.2/COPYING.LGPLv2.1 .runtime/licenses/FFmpeg.txt
curl -fsSL https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/LICENSE -o .runtime/licenses/yt-dlp.txt
curl -fsSL https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/THIRD_PARTY_LICENSES.txt -o .runtime/licenses/yt-dlp-third-party.txt
curl -fsSL https://raw.githubusercontent.com/denoland/deno/v2.9.4/LICENSE.md -o .runtime/licenses/Deno.txt
for tool in .runtime/bin/*; do
  if otool -L "$tool" | tail -n +2 | grep -E '/opt/homebrew|/usr/local' ; then
    echo "Non-portable dependency in $tool" >&2; exit 1
  fi
done
printf 'Runtime ready.\n'
