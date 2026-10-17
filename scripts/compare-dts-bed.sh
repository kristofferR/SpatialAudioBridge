#!/usr/bin/env bash
set -euo pipefail

# Compares SAB's lossless DTS compatible bed, before spatial fold subtraction, with FFmpeg's
# decode of the same DTS-HD MA core and lossless extension. Media and decoded audio stay in a
# temporary directory.
#
#   scripts/compare-dts-bed.sh <stream.dts>
#   scripts/compare-dts-bed.sh <film.mkv> <ffprobe stream index> <start seconds> <duration seconds>

usage() {
    echo "usage: $0 <stream.dts> | <film.mkv> <stream index> <start> <duration>" >&2
    exit 2
}
[[ $# -eq 1 || $# -eq 4 ]] || usage
ffmpeg="${FFMPEG:-ffmpeg}"
ffprobe="${FFPROBE:-ffprobe}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ $# -eq 1 ]]; then
    stream="$1"
else
    # Stream copy keeps whole DTS frames, so both decoders read identical bytes.
    stream="$work/excerpt.dts"
    "$root/scripts/compare-excerpt.sh" "$1" "$2" "$3" "$4" dts "$stream"
fi

probe() { "$ffprobe" -v error -select_streams a:0 -show_entries "$1" -of default=nw=1:nk=1 "$stream"; }
profile="$(probe stream=profile)"
layout="$(probe stream=channel_layout)"
# FFmpeg decodes lossless frames as s16p or s32p; a lossy fallback would be fltp.
formats="$("$ffprobe" -v error -select_streams a:0 -show_entries frame=sample_fmt -of default=nw=1:nk=1 "$stream" |
    sort | uniq -c | xargs)"
channels="$("$ffmpeg" -hide_banner -layouts | awk -v l="$layout" '$1 == l { print $2; exit }')"
[[ -n "$channels" ]] || { echo "unknown FFmpeg channel layout: $layout" >&2; exit 1; }
echo "$(basename "$stream"): $(stat -c %s "$stream") bytes, $profile, layout $layout ($channels), FFmpeg frames: $formats"
echo "FFmpeg: $("$ffmpeg" -version | head -n 1)"

"$ffmpeg" -nostdin -v error -i "$stream" -map 0:a:0 -c:a pcm_s32le -f s32le "$work/reference.s32le"
cargo run --quiet --release --locked --manifest-path "$root/Rust/SpatialAudioCore/Cargo.toml" \
    --example dts_bed -- "$stream" "$work/reference.s32le" "$channels"
