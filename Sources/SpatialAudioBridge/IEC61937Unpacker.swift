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
/// split anywhere. Bytes between bursts, such as the zeros a player writes while paused, and IEC 61937 null
/// bursts are skipped. A pause burst marks a gap in the audio itself, so it throws: start a new timeline
/// with `begin(at:)` and a new unpacker at the next burst.
@available(macOS 26, iOS 26, tvOS 26, *)
public struct IEC61937Unpacker: Sendable {
    /// The duration of the input dropped before the first point where decoding can start: bytes before
    /// the first burst, timed at the carrier's rate, and TrueHD data before the first major sync, timed by
    /// its share of the 20 ms MAT frames, both accurate to about one access unit. Add it to the time of
    /// the first buffer, so audio keeps its place on the timeline.
    public private(set) var skippedDuration = CMTime.zero

    private var pending: [UInt8] = []
    private var trueHD: [UInt8] = []
    private var synced = false
    /// Carrier bytes before the first burst, which are timed once its rate is known.
    private var leading: Int? = 0
    private var unsyncedFrames = 0

    public init() {}

    /// The compressed stream in `bursts`, from the first point where decoding can start. Throws for
    /// bursts of other formats, such as AC-3 or DTS core alone.
    public mutating func unpack(_ bursts: Data) throws -> Data {
        pending += bursts
        var output: [UInt8] = []
        while let (start, littleEndian) = Self.preamble(in: pending) {
            guard pending.count >= start + 8 else { break }
            let info = Self.word(pending, at: start + 4, littleEndian), type = info & 0x7F
            let length = Self.word(pending, at: start + 6, littleEndian)
            guard info & 0x80 == 0 else { throw SpatialAudioError.decoding("An IEC 61937 burst is marked as containing errors") }
            guard type != Self.pause else {
                throw SpatialAudioError.decoding("An IEC 61937 pause burst marks a gap in the audio; start a new timeline")
            }
            guard type == Self.mat || type == Self.dtsTypeIV || type == Self.null else {
                throw SpatialAudioError.decoding("Unsupported IEC 61937 burst type \(type); only TrueHD (MAT) and DTS-HD (type IV) can be unpacked")
            }
            guard pending.count >= start + 8 + length else { break }
            var payload = Array(pending[(start + 8)..<(start + 8 + length)])
            pending.removeFirst(start + 8 + length)
            if littleEndian {
                for index in stride(from: 0, to: payload.count - 1, by: 2) { payload.swapAt(index, index + 1) }
            }
            if let bytes = leading.map({ $0 + start }) {
                if type == Self.null {
                    leading = bytes + 8 + length
                    continue
                }
                let rate = type == Self.mat ? Self.highBitRate : Self.dtsCarrierRate(info: info, burst: payload)
                skippedDuration = CMTimeAdd(skippedDuration, CMTime(value: Int64(bytes), timescale: Int32(rate)))
                leading = nil
            }
            if type == Self.mat { output += try trueHDUnits(inMAT: payload) }
            if type == Self.dtsTypeIV { output += try dtsFrame(inTypeIV: payload) }
        }
        // Keep a possible partial preamble; everything before it is filler, or the rest of a burst that
        // started before this unpacker.
        if Self.preamble(in: pending) == nil, pending.count > 3 {
            leading = leading.map { $0 + pending.count - 3 }
            pending.removeFirst(pending.count - 3)
        }
        return Data(output)
    }

    /// Checks that the input ended on a whole burst and TrueHD access unit. Call it at the end of the source,
    /// before the renderer's `endOfStream()`, not after a seek or stop.
    public func finish() throws {
        // Filler is zeros, so anything else left over is the start of a burst.
        if pending.contains(where: { $0 != 0 }) {
            throw SpatialAudioError.decoding("The IEC 61937 input ends inside a burst")
        }
        if trueHD.contains(where: { $0 != 0 }) {
            throw SpatialAudioError.decoding("The IEC 61937 input ends inside a TrueHD access unit")
        }
    }

    private static let null = 0x00, pause = 0x03, mat = 0x16, dtsTypeIV = 0x11
    /// MAT, and DTS-HD master audio as mpv sends it, use the 8-channel 192 kHz carrier: 3,072,000 bytes/s.
    private static let highBitRate = 192_000 * 8 * 2

    /// Bytes per second of a type IV carrier: its burst period, (512 << subtype) frames of 4 bytes, spans
    /// one DTS frame, whose length the core header gives in 32-sample blocks.
    private static func dtsCarrierRate(info: Int, burst: [UInt8]) -> Int {
        let period = (512 << ((info >> 8) & 0x07)) * 4
        let frame = burst.count >= 18 && burst[12..<16].elementsEqual([0x7F, 0xFE, 0x80, 0x01]) ? Array(burst[16..<18]) : nil
        guard let frame else { return highBitRate }
        let samples = ((Int(frame[0] & 0x01) << 6 | Int(frame[1] >> 2)) + 1) * 32
        return period * 48_000 / samples
    }

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
        if !synced {
            // The first bytes may continue a unit from an earlier frame, so length words cannot be trusted
            // until a major-sync unit, which starts 4 bytes before its signature.
            guard let signature = Self.firstMajorSync(in: trueHD) else {
                // TrueHD repeats major syncs at least every 128 units (107 ms); 200 ms without one is not TrueHD.
                unsyncedFrames += 1
                guard unsyncedFrames < 10 else {
                    throw SpatialAudioError.decoding("No TrueHD major sync in 200 ms of IEC 61937 MAT frames")
                }
                drop(max(0, trueHD.count - 7))
                return []
            }
            drop(signature - 4)
            synced = true
        }
        var output: [UInt8] = []
        var index = 0
        while index + 2 <= trueHD.count {
            let words = (Int(trueHD[index]) << 8 | Int(trueHD[index + 1])) & 0x0FFF
            // A unit never has zero length, so a zero word is padding.
            guard words > 0 else { index += 2; continue }
            guard index + words * 2 <= trueHD.count else { break }
            output += trueHD[index..<(index + words * 2)]
            index += words * 2
        }
        trueHD.removeFirst(index)
        return output
    }

    /// Drops unsynced TrueHD data and counts its duration: each MAT frame carries 61376 bytes of it in 20 ms.
    private mutating func drop(_ count: Int) {
        trueHD.removeFirst(count)
        skippedDuration = CMTimeAdd(skippedDuration, CMTime(value: Int64(count), timescale: 61_376 * 50))
    }

    /// The offset of the first major-sync signature that can start a unit, at least 4 bytes in.
    private static func firstMajorSync(in bytes: [UInt8]) -> Int? {
        var index = 4
        while index + 3 < bytes.count {
            if bytes[index] == 0xF8, bytes[index + 1] == 0x72, bytes[index + 2] == 0x6F, bytes[index + 3] == 0xBA {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The DTS frame in a type IV burst, after its 10-byte start code and 16-bit size. Every frame starts
    /// with a core sync and decodes on its own.
    private func dtsFrame(inTypeIV burst: [UInt8]) throws -> [UInt8] {
        var payload = burst
        // FFmpeg swaps a little-endian DTS source itself, so the wrapper can arrive in the other byte order.
        if payload.starts(with: [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0xFE]) {
            for index in stride(from: 0, to: payload.count - 1, by: 2) { payload.swapAt(index, index + 1) }
        }
        guard payload.count >= 12, payload.starts(with: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0xFE]) else {
            throw SpatialAudioError.decoding("Malformed IEC 61937 DTS-HD burst")
        }
        let size = Int(payload[10]) << 8 | Int(payload[11])
        guard size > 0 else { throw SpatialAudioError.decoding("Empty IEC 61937 DTS-HD burst") }
        guard payload.count >= 12 + size else { throw SpatialAudioError.decoding("Truncated IEC 61937 DTS-HD burst") }
        return Array(payload[12..<(12 + size)])
    }
}
