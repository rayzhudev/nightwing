#!/bin/bash
# Rebuild the exact LGPL-only independent FFmpeg tools. No Nightwing code is linked.
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
archive="$source_dir/ffmpeg-8.1.3.tar.xz"
[[ -f "$archive" ]] || archive="$source_dir/../dist/media-build/downloads/ffmpeg-8.1.3.tar.xz"
[[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" == 7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3 ]]
work="$(mktemp -d "${TMPDIR:-/tmp}/nightwing-ffmpeg-rebuild.XXXXXX")"
tar -xf "$archive" -C "$work"
for architecture in arm64 x86_64; do
  mkdir "$work/$architecture"
  (
    cd "$work/$architecture"
    "$work/ffmpeg-8.1.3/configure" --arch="$architecture" --cc="clang -arch $architecture" \
      --disable-autodetect --disable-gpl --disable-nonfree --disable-shared --enable-static \
      --disable-x86asm --disable-doc --disable-debug --disable-avdevice --disable-network \
      --extra-cflags=-mmacosx-version-min=11.0 --extra-ldflags=-mmacosx-version-min=11.0
    make -j8
  )
done
for tool in ffmpeg ffprobe; do
  lipo -create "$work/arm64/$tool" "$work/x86_64/$tool" -output "$work/$tool"
done
printf 'Universal LGPL-only outputs and build trees retained at: %s\n' "$work"
