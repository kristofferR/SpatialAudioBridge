"""Check the delivered TrueHD end against complete access units in FFmpeg's MAT output."""

import struct
import sys
from pathlib import Path


def delivered_end(raw: bytes, bursts: bytes) -> int:
    # FFmpeg's spdif muxer emits 61440-byte little-endian bursts. Remove only its
    # fixed framing, then match raw access units in order, allowing zero padding.
    # This oracle uses raw unit lengths, independently of IEC61937Unpacker.
    if not bursts or len(bursts) % 61_440:
        raise ValueError("expected whole FFmpeg MAT bursts")
    carried = bytearray()
    for start in range(0, len(bursts), 61_440):
        if struct.unpack_from("<4H", bursts, start) != (0xF872, 0x4E1F, 0x16, 61_424):
            raise ValueError("unexpected FFmpeg MAT preamble")
        payload = bytearray(bursts[start + 8 : start + 8 + 61_424])
        payload[::2], payload[1::2] = payload[1::2], payload[::2]
        carried += payload[20:30_708] + payload[30_720:61_408]

    position = cursor = 0
    while cursor < len(carried):
        if carried[cursor : cursor + 2] == b"\0\0":
            cursor += 2
            continue
        if position + 4 > len(raw):
            raise ValueError("MAT carries data beyond the raw stream")
        size = (int.from_bytes(raw[position : position + 2], "big") & 0xFFF) * 2
        if size < 4 or position + size > len(raw):
            raise ValueError("invalid raw TrueHD access unit")
        available = min(size, len(carried) - cursor)
        if carried[cursor : cursor + available] != raw[position : position + available]:
            raise ValueError("MAT payload differs from the raw access unit")
        if available < size:
            break  # This last unit continues into the MAT frame FFmpeg did not flush.
        position += size
        cursor += size
    return position


def check_end(raw: bytes, bursts: bytes, actual_end: int) -> None:
    expected = delivered_end(raw, bursts)
    if actual_end != expected:
        raise ValueError(f"TrueHD unpacking ended at byte {actual_end}; MAT delivers through {expected}")
    print(f"tail: MAT independently delivers through byte {expected}; {len(raw) - expected} raw bytes not carried whole")


if __name__ == "__main__":
    raw_path, bursts_path, end = sys.argv[1:]
    check_end(Path(raw_path).read_bytes(), Path(bursts_path).read_bytes(), int(end))
