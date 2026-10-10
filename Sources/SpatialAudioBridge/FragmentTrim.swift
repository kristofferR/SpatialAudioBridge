import Foundation

/// Shortens the last sample of a fragmented-MP4 media segment by `frames`, so decoding ends at the
/// last source sample instead of the end of the final, padded APAC packet. AVAssetWriter ignores
/// end trims when it writes fragments, while Apple's decoder honors a shorter final sample.
///
/// Returns nil for a layout AVAssetWriter does not write, such as one with `sidx`, absolute data
/// offsets or per-sample durations; the caller then keeps the segment unchanged.
func trimmingLastSample(of segment: Data, by frames: UInt32) -> Data? {
    var bytes = [UInt8](segment)
    let top = MP4Box.children(of: bytes, in: 0..<bytes.count)
    guard !top.contains(where: { $0.type == "sidx" }), let moof = top.first(where: { $0.type == "moof" }),
          let traf = MP4Box.children(of: bytes, in: moof.body).first(where: { $0.type == "traf" }) else { return nil }
    let parts = MP4Box.children(of: bytes, in: traf.body)
    guard let tfhd = parts.first(where: { $0.type == "tfhd" }), let trun = parts.last(where: { $0.type == "trun" }) else { return nil }
    // Data offsets relative to the moof, and a default sample duration to shorten.
    let tfhdFlags = tfhd.flags(bytes)
    guard tfhdFlags & 0x1 == 0, tfhdFlags & 0x8 != 0 else { return nil }
    // After the version, flags and track ID, and the sample description index when present.
    let defaultDuration = MP4Box.uint32(bytes, at: tfhd.body.lowerBound + 8 + (tfhdFlags & 0x2 != 0 ? 4 : 0))
    let flags = trun.flags(bytes)
    let count = Int(MP4Box.uint32(bytes, at: trun.body.lowerBound + 4))
    var fields = trun.body.lowerBound + 8 + (flags & 0x1 != 0 ? 4 : 0) + (flags & 0x4 != 0 ? 4 : 0)
    let entrySize = [0x100, 0x200, 0x400, 0x800].filter { flags & $0 != 0 }.count * 4
    guard count > 0, flags & 0x100 == 0, fields + count * entrySize == trun.range.upperBound,
          defaultDuration > frames else { return nil }
    // Give every sample of the last run an explicit duration, the final one shortened.
    var entries: [UInt8] = []
    for index in 0..<count {
        entries += MP4Box.bytes(index == count - 1 ? defaultDuration - frames : defaultDuration)
        entries += bytes[fields..<fields + entrySize]
        fields += entrySize
    }
    let growth = count * 4
    let entriesStart = fields - count * entrySize
    bytes.replaceSubrange(entriesStart..<trun.range.upperBound, with: entries)
    MP4Box.setUInt32(&bytes, MP4Box.uint32(bytes, at: trun.body.lowerBound) | 0x100, at: trun.body.lowerBound)
    for box in [trun, traf, moof] {
        MP4Box.setUInt32(&bytes, MP4Box.uint32(bytes, at: box.range.lowerBound) + UInt32(growth), at: box.range.lowerBound)
    }
    // The media data now starts `growth` bytes later, and every run of this fragment points into it.
    for run in parts where run.type == "trun" && run.flags(bytes) & 0x1 != 0 {
        let at = run.body.lowerBound + 8
        MP4Box.setUInt32(&bytes, UInt32(bitPattern: Int32(bitPattern: MP4Box.uint32(bytes, at: at)) + Int32(growth)), at: at)
    }
    return Data(bytes)
}

/// A minimal reader for the plain 32-bit-sized boxes AVAssetWriter writes in fragments.
private struct MP4Box {
    let type: String
    let range: Range<Int>
    var body: Range<Int> { range.lowerBound + 8..<range.upperBound }

    static func children(of bytes: [UInt8], in range: Range<Int>) -> [MP4Box] {
        var boxes: [MP4Box] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound {
            let size = Int(uint32(bytes, at: position))
            // Stop at 64-bit or open-ended sizes, which fragments from AVAssetWriter do not use.
            guard size >= 8, position + size <= range.upperBound else { break }
            boxes.append(MP4Box(type: String(decoding: bytes[position + 4..<position + 8], as: UTF8.self),
                                range: position..<position + size))
            position += size
        }
        return boxes
    }

    static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        bytes[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A full box's flags: the low 24 bits of the word that starts with its version.
    func flags(_ bytes: [UInt8]) -> UInt32 { Self.uint32(bytes, at: body.lowerBound) & 0xFF_FFFF }

    static func bytes(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }

    static func setUInt32(_ bytes: inout [UInt8], _ value: UInt32, at index: Int) {
        bytes.replaceSubrange(index..<index + 4, with: Self.bytes(value))
    }
}
