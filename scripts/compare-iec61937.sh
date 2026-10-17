#!/usr/bin/env bash
set -euo pipefail

# Compares SAB's output for raw input with its output through the IEC 61937 path, as an mpv- or
# VLC-style passthrough output delivers it after attaching mid-stream. FFmpeg's spdif muxer wraps
# the stream in bursts (MAT for TrueHD, type IV at 768 kHz for DTS-HD), which are cut mid-burst.
# The unmodified `IEC61937Unpacker.swift`, built on Linux against small stand-ins for CMTime and
# SpatialAudioError, unpacks the rest in uneven chunks. The script checks that the unpacked bytes
# are the raw stream's from a sync point on, compares both renders from there, and checks that the
# unpacker's `skippedDuration` places the audio where it belongs on the timeline. Needs Swift,
# FFmpeg, Python 3 and Cargo; media and decoded audio stay in a temporary directory.
#
#   scripts/compare-iec61937.sh <truehd|dtsx> <stream>
#   scripts/compare-iec61937.sh <truehd|dtsx> <film.mkv> <ffprobe stream index> <start> <duration>
#
# ATTACH (default 0.3) is the fraction of the bursts skipped before attaching, plus 4321 bytes.

usage() {
    echo "usage: $0 <truehd|dtsx> <stream> | <truehd|dtsx> <film.mkv> <stream index> <start> <duration>" >&2
    exit 2
}
[[ $# -eq 2 || $# -eq 5 ]] || usage
codec="$1"
case "$codec" in
    truehd) format=truehd; spdif=() ;;
    dtsx) format=dts; spdif=(-dtshd_rate 768000) ;;
    *) usage ;;
esac
ffmpeg="${FFMPEG:-ffmpeg}"
swiftc="${SWIFTC:-swiftc}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ $# -eq 2 ]]; then
    stream="$2"
else
    stream="$work/excerpt.$format"
    "$root/scripts/compare-excerpt.sh" "$2" "$3" "$4" "$5" "$format" "$stream"
fi

# Both carriers run at 3,072,000 bytes per second: MAT, and type IV at 768 kHz.
carrier=3072000
"$ffmpeg" -nostdin -v error -f "$format" -i "$stream" -c copy -f spdif "${spdif[@]}" "$work/bursts.spdif"
bursts="$(stat -c %s "$work/bursts.spdif")"
attach="$(awk -v n="$bursts" -v f="${ATTACH:-0.3}" 'BEGIN { printf "%d", int(n * f / 4) * 4 + 4321 }')"

mkdir "$work/swift"
cat > "$work/swift/CoreMedia.swift" <<'SWIFT'
/// The parts of CMTime the unpacker uses, in seconds.
public struct CMTime: Sendable {
    public let seconds: Double
    public init(value: Int64, timescale: Int32) { seconds = Double(value) / Double(timescale) }
    init(seconds: Double) { self.seconds = seconds }
    public static let zero = CMTime(seconds: 0)
}
public func CMTimeAdd(_ a: CMTime, _ b: CMTime) -> CMTime { CMTime(seconds: a.seconds + b.seconds) }
SWIFT
cat > "$work/swift/main.swift" <<'SWIFT'
import Foundation

enum SpatialAudioError: Error {
    case decoding(String), unsupported(String), discontinuity(String)
}

// usage: unpack <bursts> <attach offset> <output> <truehd|dtsx>
let arguments = CommandLine.arguments
let bursts = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
var unpacker = IEC61937Unpacker()
var output = Data()
var offset = Int(arguments[2])!, size = 7
while offset < bursts.count {
    let end = min(bursts.count, offset + size)
    output += try unpacker.unpack(bursts.subdata(in: offset..<end))
    offset = end
    size = size * 13 % 9_973 + 1
}
// FFmpeg's muxer writes only whole MAT frames, so a TrueHD stream's last units can be cut off.
do { try unpacker.finish() } catch {
    guard arguments[4] == "truehd" else { throw error }
    FileHandle.standardError.write(Data("finish: \(error)\n".utf8))
}
try output.write(to: URL(fileURLWithPath: arguments[3]))
print(String(format: "%.9f", unpacker.skippedDuration.seconds))
SWIFT
(
    cd "$work/swift"
    "$swiftc" -O -parse-as-library -emit-module -emit-library -static -module-name CoreMedia CoreMedia.swift
    "$swiftc" -O -I . -L . -lCoreMedia -o unpack main.swift "$root/Sources/SpatialAudioBridge/IEC61937Unpacker.swift"
)
skipped="$("$work/swift/unpack" "$work/bursts.spdif" "$attach" "$work/unpacked.$format" "$codec")"

raw_bytes="$(stat -c %s "$stream")"
unpacked_bytes="$(stat -c %s "$work/unpacked.$format")"
start="$(python3 -c 'import sys; a, b = (open(p, "rb").read() for p in sys.argv[1:]); print(a.find(b[:4096]))' \
    "$stream" "$work/unpacked.$format")"
echo "$(basename "$stream"): $raw_bytes bytes; bursts $bursts bytes, attached at byte $attach; unpacked $unpacked_bytes bytes"
if [[ "$start" -ge 0 ]] && cmp -s -i "$start:0" -n "$unpacked_bytes" "$stream" "$work/unpacked.$format"; then
    echo "content: byte-identical to the raw stream's bytes $start to $((start + unpacked_bytes)); $((raw_bytes - start - unpacked_bytes)) final bytes not delivered"
else
    echo "FAIL: the unpacked stream is not part of the raw stream"
    exit 1
fi
if [[ "$codec" == dtsx && $((start + unpacked_bytes)) -ne "$raw_bytes" ]]; then
    echo "FAIL: DTS unpacking did not reach the end of the raw stream"
    exit 1
fi
# Render the raw stream up to the same end, so the renders' frame counts differ only by the start.
head -c "$((start + unpacked_bytes))" "$stream" > "$work/raw.$format"

baseline() {
    cargo run --quiet --release --locked --manifest-path "$root/Rust/SpatialAudioCore/Cargo.toml" \
        --example baseline -- "$codec" 7.1.4 "$1" --pcm "$2" | awk '$1 == "frames" { print $2 }'
}
raw_frames="$(baseline "$work/raw.$format" "$work/raw.f32le")"
unpacked_frames="$(baseline "$work/unpacked.$format" "$work/unpacked.f32le")"
offset=$((raw_frames - unpacked_frames))
cargo run --quiet --release --locked --manifest-path "$root/Rust/SpatialAudioCore/Cargo.toml" \
    --example pcm_diff -- "$codec" "$work/raw.f32le" "$work/unpacked.f32le" 12 "$offset"
# Where the bursts carry the first unpacked frame. Each DTS-HD burst spans its frame. FFmpeg spaces
# TrueHD access units in MAT frames by their input timing, which runs ahead of their presentation
# by the decoder buffer's varying delay, so that position is the input timing since the first unit.
if [[ "$codec" == truehd ]]; then
    carried="$(python3 -I -c '
import sys
data, start = open(sys.argv[1], "rb").read(), int(sys.argv[2])
position, previous, elapsed = 0, None, 0
while position <= start:
    timing = data[position + 2] << 8 | data[position + 3]
    if previous is not None:
        elapsed += (timing - previous) & 0xFFFF
    previous = timing
    position += ((data[position] << 8 | data[position + 1]) & 0xFFF) * 2
print(elapsed)
' "$stream" "$start")"
else
    carried="$offset"
fi
# The unpacker documents its placement as exact for DTS-HD and within about one TrueHD access unit.
tolerance=$([[ "$codec" == truehd ]] && echo 40 || echo 0.5)
awk -v a="$attach" -v c="$carrier" -v s="$skipped" -v o="$offset" -v p="$carried" -v t="$tolerance" 'BEGIN {
    placed = (a / c + s) * 48000
    printf "timeline: attached at %.6f s + skippedDuration %.6f s = frame %.1f; carried at frame %d, presented at frame %d of the raw render\n", a / c, s, placed, p, o
    printf "placement against the carrier: %+.1f frames (%+.3f ms); against the presentation: %+.1f frames (%+.3f ms)\n", placed - p, (placed - p) / 48, placed - o, (placed - o) / 48
    if (placed - p > t || p - placed > t) { printf "FAIL: placed more than %s frames from where the bursts carry it\n", t; exit 1 }
    print "PASS"
}'
