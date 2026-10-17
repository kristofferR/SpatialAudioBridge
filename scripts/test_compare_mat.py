import struct
import unittest

from compare_mat import check_end, delivered_end


def unit(size: int, timing: int) -> bytes:
    return struct.pack(">HH", size // 2, timing) + b"\x55" * (size - 4)


def mat_bursts(data: bytes) -> bytes:
    bursts = bytearray()
    for start in range(0, len(data) - 61_375, 61_376):
        area = data[start : start + 61_376]
        payload = bytearray(b"\x77" * 20 + area[:30_688] + b"\x88" * 12 + area[30_688:] + b"\x99" * 16)
        payload[::2], payload[1::2] = payload[1::2], payload[::2]
        bursts += struct.pack("<4H", 0xF872, 0x4E1F, 0x16, 61_424) + payload + b"\0" * 8
    return bytes(bursts)


class MatEndTests(unittest.TestCase):
    def test_partial_final_unit_and_unit_crossing_mat_boundaries(self):
        units = [unit(8_000, timing) for timing in range(16)]
        raw = b"".join(units)
        bursts = mat_bursts(raw)
        self.assertEqual(delivered_end(raw, bursts), 15 * 8_000)
        check_end(raw, bursts, 15 * 8_000)
        # Losing one whole MAT frame must fail even though the output is a raw prefix.
        with self.assertRaisesRegex(ValueError, "MAT delivers through"):
            check_end(raw, bursts, delivered_end(raw, bursts[:61_440]))
        # Even one omitted complete unit must fail.
        with self.assertRaises(ValueError):
            check_end(raw, bursts, 14 * 8_000)

    def test_zero_padding_and_complete_final_unit(self):
        first, last = unit(100, 0), unit(200, 40)
        raw = first + last
        bursts = mat_bursts(first + b"\0" * 200 + last + b"\0" * (61_376 - 500))
        self.assertEqual(delivered_end(raw, bursts), len(raw))

    def test_rejects_mismatched_raw_content(self):
        raw = unit(8_000, 0) * 8
        bursts = mat_bursts(raw)
        with self.assertRaisesRegex(ValueError, "payload differs"):
            delivered_end(raw[:100] + b"\x66" + raw[101:], bursts)


if __name__ == "__main__":
    unittest.main()
