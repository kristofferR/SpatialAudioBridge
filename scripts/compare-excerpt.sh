#!/usr/bin/env bash
set -euo pipefail

# Cuts a compressed excerpt from a film for the compare-* scripts: whole DTS frames, or TrueHD from
# its first major sync, where SAB's raw input must start.
#
#   scripts/compare-excerpt.sh <film> <ffprobe stream index> <start seconds> <duration seconds> <truehd|dts> <output>

[[ $# -eq 6 ]] || { echo "usage: $0 <film> <stream index> <start> <duration> <truehd|dts> <output>" >&2; exit 2; }
film="$1" index="$2" start="$3" duration="$4" format="$5" output="$6"
[[ "$format" == truehd || "$format" == dts ]] || { echo "format must be truehd or dts" >&2; exit 2; }
# The raw muxers log Matroska's repeated TrueHD timestamps as errors; SAB itself rejects any gap.
"${FFMPEG:-ffmpeg}" -nostdin -v fatal -analyzeduration 200M -probesize 1G -ss "$start" -t "$duration" \
    -i "$film" -map "0:$index" -c copy -f "$format" -y "$output"
if [[ "$format" == truehd ]]; then
    # A major-sync access unit carries its signature 4 bytes in.
    python3 -I -c '
import sys
path = sys.argv[1]
data = open(path, "rb").read()
sync = data.find(b"\xf8\x72\x6f\xba", 4)
if sync < 0:
    sys.exit("no TrueHD major sync in the excerpt")
open(path, "wb").write(data[sync - 4:])
' "$output"
fi
