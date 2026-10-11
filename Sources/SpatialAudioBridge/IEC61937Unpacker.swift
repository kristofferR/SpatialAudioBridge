import CoreMedia
import Foundation

/// Recovers the TrueHD or DTS-HD stream from IEC 61937 bursts, as passthrough outputs such as mpv's and
/// VLC's deliver them, for ``SpatialAudioRenderer`` or ``SpatialAudioTranscoder``.
///
/// ```swift
/// var unpacker = IEC61937Unpacker()          // a new one after every seek
/// try await renderer.begin(at: seekTime)
/// // For each buffer the player writes, with the time of the first one written since the seek:
/// let stream = try unpacker.unpack(bursts)
/// if !stream.isEmpty { try await renderer.enqueue(stream, time: firstTime + unpacker.skippedDuration) }
/// ```
///
/// TrueHD arrives in MAT frames and DTS-HD as type IV bursts, in either 16-bit byte order. Bursts may be
/// split anywhere. Bytes between bursts, such as the zeros a player writes while paused, and IEC 61937 null and
/// pause bursts are skipped; a gap in the audio itself is a discontinuity that needs `begin(at:)`.
@available(macOS 26, iOS 26, tvOS 26, *)
public struct IEC61937Unpacker: Sendable {
    /// The duration of the TrueHD access units dropped before the first major sync, where decoding can
    /// start. Add it to the time of the first buffer, so audio keeps its place on the timeline.
    public private(set) var skippedDuration = CMTime.zero

    private var pending: [UInt8] = []
    private var trueHD: [UInt8] = []
    private var synced = false

    public init() {}

    /// The compressed stream in `bursts`, from the first point where decoding can start. Throws for
    /// bursts of other formats, such as AC-3 or DTS core alone.
    public mutating func unpack(_ bursts: Data) throws -> Data {
        pending += bursts
        var output: [UInt8] = []
        while let (start, littleEndian) = Self.preamble(in: pending) {
            guard pending.count >= start + 8 else { break }
            let type = Self.word(pending, at: start + 4, littleEndian) & 0x1F
            let length = Self.word(pending, at: start + 6, littleEndian)
            guard type == Self.mat || type == Self.dtsTypeIV || type == Self.null || type == Self.pause else {
                throw SpatialAudioError.decoding("Unsupported IEC 61937 burst type \(type); only TrueHD (MAT) and DTS-HD (type IV) can be unpacked")
            }
            guard pending.count >= start + 8 + length else { break }
            var payload = Array(pending[(start + 8)..<(start + 8 + length)])
            pending.removeFirst(start + 8 + length)
            if littleEndian {
                for index in stride(from: 0, to: payload.count - 1, by: 2) { payload.swapAt(index, index + 1) }
            }
            if type == Self.mat { output += try trueHDUnits(inMAT: payload) }
            if type == Self.dtsTypeIV { output += try dtsFrame(inTypeIV: payload) }
        }
        // Keep a possible partial preamble; everything before it is filler.
        if Self.preamble(in: pending) == nil, pending.count > 3 { pending.removeFirst(pending.count - 3) }
        return Data(output)
    }

    /// Checks that the input ended on a whole burst and TrueHD access unit. Call it at the end of the source,
    /// before the renderer's `endOfStream()`, not after a seek or stop.
    public func finish() throws {
        if Self.preamble(in: pending) != nil {
            throw SpatialAudioError.decoding("The IEC 61937 input ends inside a burst")
        }
        if trueHD.contains(where: { $0 != 0 }) {
            throw SpatialAudioError.decoding("The IEC 61937 input ends inside a TrueHD access unit")
        }
    }

    private static let null = 0x00, pause = 0x03, mat = 0x16, dtsTypeIV = 0x11

    private static func word(_ bytes: [UInt8], at index: Int, _ littleEndian: Bool) -> Int {
        let first = Int(bytes[index]), second = Int(bytes[index + 1])
        return littleEndian ? first | second << 8 : first << 8 | second
    }

    /// The offset of the next Pa/Pb sync words and whether the burst's words are little-endian.
    private static func preamble(in bytes: [UInt8]) -> (Int, Bool)? {
        var index = 0
        while index + 3 < bytes.count {
            switch (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3]) {
            case (0x72, 0xF8, 0x1F, 0x4E): return (index, true)
            case (0xF8, 0x72, 0x4E, 0x1F): return (index, false)
            default: index += 1
            }
        }
        return nil
    }

    /// TrueHD access units from a 61424-byte MAT frame, which surrounds them with a start code, a middle
    /// code and an end code and pads them with zeros. Units may continue into the next frame.
    private mutating func trueHDUnits(inMAT frame: [UInt8]) throws -> [UInt8] {
        guard frame.count == 61_424, frame.starts(with: [0x07, 0x9E, 0x00, 0x03, 0x84, 0x01, 0x01, 0x01]) else {
            throw SpatialAudioError.decoding("Malformed MAT frame in IEC 61937 TrueHD")
        }
        trueHD += frame[20..<30_708]
        trueHD += frame[30_720..<61_408]
        var output: [UInt8] = []
        var index = 0
        while index + 2 <= trueHD.count {
            let words = (Int(trueHD[index]) << 8 | Int(trueHD[index + 1])) & 0x0FFF
            // A unit never has zero length, so a zero word is padding.
            guard words > 0 else { index += 2; continue }
            guard index + words * 2 <= trueHD.count else { break }
            let unit = trueHD[index..<(index + words * 2)]
            index += words * 2
            if !synced, unit.count >= 8, unit[(unit.startIndex + 4)..<(unit.startIndex + 8)].elementsEqual([0xF8, 0x72, 0x6F, 0xBA]) {
                synced = true
            }
            if synced {
                output += unit
            } else {
                // Each access unit lasts 1/1200 s at 48 kHz.
                skippedDuration = CMTimeAdd(skippedDuration, CMTime(value: 1, timescale: 1200))
            }
        }
        trueHD.removeFirst(index)
        return output
    }

    /// The DTS frame in a type IV burst, after its 10-byte start code and 16-bit size. Every frame starts
    /// with a core sync and decodes on its own.
    private func dtsFrame(inTypeIV payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 12, payload.starts(with: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0xFE]) else {
            throw SpatialAudioError.decoding("Malformed IEC 61937 DTS-HD burst")
        }
        let size = Int(payload[10]) << 8 | Int(payload[11])
        guard payload.count >= 12 + size else { throw SpatialAudioError.decoding("Truncated IEC 61937 DTS-HD burst") }
        return Array(payload[12..<(12 + size)])
    }
}
