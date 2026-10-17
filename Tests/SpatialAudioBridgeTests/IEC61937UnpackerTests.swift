import CoreMedia
import Foundation
import Testing
@testable import SpatialAudioBridge

/// Bursts as FFmpeg's spdif muxer writes them: Pa, Pb, Pc and Pd, the payload in 16-bit words, and padding.
private func burst(type: UInt16, payload: [UInt8], period: Int, littleEndian: Bool) -> [UInt8] {
    let words: [UInt16] = [0xF872, 0x4E1F, type, UInt16(payload.count)]
    var bytes = words.flatMap { littleEndian ? [UInt8($0 & 0xFF), UInt8($0 >> 8)] : [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    var body = payload
    if littleEndian { for index in stride(from: 0, to: body.count - 1, by: 2) { body.swapAt(index, index + 1) } }
    bytes += body
    return bytes + [UInt8](repeating: 0, count: max(0, period - bytes.count))
}

/// MAT frames around a TrueHD stream with zero padding between units, split at the middle and end codes.
private func matBursts(_ units: [[UInt8]], littleEndian: Bool, lead: [UInt8] = []) -> [UInt8] {
    var body = lead
    for unit in units { body += unit + [0, 0, 0, 0] }
    let half = 30_708 - 20, start: [UInt8] = [0x07, 0x9E, 0x00, 0x03, 0x84, 0x01, 0x01, 0x01, 0x80, 0x00, 0x56, 0xA5, 0x3B, 0xF4, 0x81, 0x83, 0x49, 0x80, 0x77, 0xE0]
    var bursts: [UInt8] = []
    for offset in stride(from: 0, to: body.count, by: half * 2) {
        var chunk = Array(body[offset..<min(body.count, offset + half * 2)])
        chunk += [UInt8](repeating: 0, count: half * 2 - chunk.count)
        let frame = start + chunk[0..<half] + [UInt8](repeating: 0xC3, count: 12) + chunk[half...] + [UInt8](repeating: 0xC3, count: 16)
        bursts += burst(type: 0x16, payload: frame, period: 61_440, littleEndian: littleEndian) + [UInt8](repeating: 0, count: 100)
    }
    return bursts
}

/// Fake TrueHD units: a length word with a check nibble, and the major sync where requested.
private func unit(words: Int, majorSync: Bool, seed: Int) -> [UInt8] {
    var bytes = (0..<(words * 2)).map { UInt8(truncatingIfNeeded: $0 * 31 + seed) }
    bytes[0] = UInt8(0xF0 | (words >> 8)); bytes[1] = UInt8(words & 0xFF)
    if majorSync { bytes[4...7] = [0xF8, 0x72, 0x6F, 0xBA] }
    return bytes
}

@available(macOS 26, iOS 26, tvOS 26, *)
private func unpackInChunks(_ bytes: [UInt8]) throws -> (Data, IEC61937Unpacker) {
    var unpacker = IEC61937Unpacker()
    var output = Data()
    var offset = 0, size = 7
    while offset < bytes.count {
        let end = min(bytes.count, offset + size)
        output += try unpacker.unpack(Data(bytes[offset..<end]))
        offset = end
        size = size * 13 % 9_973 + 1
    }
    return (output, unpacker)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func trueHDUnitsComeOutOfMATFramesFromTheFirstMajorSync() throws {
    let leading = (0..<3).map { unit(words: 120, majorSync: false, seed: $0) }
    let units = (0..<300).map { unit(words: 100 + $0 * 7 % 900, majorSync: $0 % 16 == 0, seed: $0) }
    // The end of a unit from before the stream started, as when attaching midstream.
    let continuation = [UInt8](repeating: 0xAB, count: 300)
    // The tail of a burst from before the unpacker, timed at the 3,072,000-byte/s carrier.
    let partialBurst = [UInt8](repeating: 0x55, count: 1_000)
    for (littleEndian, lead, before) in [(true, [UInt8](), [UInt8]()), (false, continuation, partialBurst)] {
        let (output, unpacker) = try unpackInChunks(before + matBursts(leading + units, littleEndian: littleEndian, lead: lead))
        #expect(output == Data(units.joined()))
        // Skipped data counts by its share of the 61376 unit bytes in each 20 ms MAT frame; each leading unit
        // takes 240 bytes and 4 of padding.
        let skipped = CMTimeAdd(CMTime(value: Int64(before.count), timescale: 3_072_000),
                                CMTime(value: Int64(lead.count + 3 * 244), timescale: 61_376 * 50))
        #expect(unpacker.skippedDuration == skipped)
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func dtsFramesComeOutOfTypeIVBursts() throws {
    // Core headers of 512-sample frames, as at 48 kHz.
    let frames = (0..<5).map { index in [0x7F, 0xFE, 0x80, 0x01, 0xFC, 0x3C] + [UInt8](repeating: UInt8(index), count: 2_374) }
    for littleEndian in [true, false] {
        let bursts = [UInt8](repeating: 0, count: 4_096) + frames.flatMap { frame in
            burst(type: 0x0411, payload: [0x01, 0, 0, 0, 0, 0, 0, 0, 0xFE, 0xFE, UInt8(frame.count >> 8), UInt8(frame.count & 0xFF)] + frame,
                  period: 32_768, littleEndian: littleEndian)
        }
        let (output, unpacker) = try unpackInChunks(bursts)
        #expect(output == Data(frames.joined()))
        // Subtype 4: a 32768-byte period per 512-sample frame, 3,072,000 bytes/s.
        #expect(unpacker.skippedDuration == CMTime(value: 4_096, timescale: 3_072_000))
    }
    // FFmpeg swaps a little-endian DTS source itself, so the wrapper may arrive in the other byte order.
    var swapped = [0x01, 0, 0, 0, 0, 0, 0, 0, 0xFE, 0xFE, UInt8(frames[0].count >> 8), UInt8(frames[0].count & 0xFF)] + frames[0]
    for index in stride(from: 0, to: swapped.count - 1, by: 2) { swapped.swapAt(index, index + 1) }
    var unpacker = IEC61937Unpacker()
    #expect(try unpacker.unpack(Data(burst(type: 0x0411, payload: swapped, period: 32_768, littleEndian: false))) == Data(frames[0]))
    let empty = burst(type: 0x0411, payload: [0x01, 0, 0, 0, 0, 0, 0, 0, 0xFE, 0xFE, 0, 0], period: 32_768, littleEndian: true)
    #expect(throws: SpatialAudioError.self) { try unpacker.unpack(Data(empty)) }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func nullBurstsAreSkippedAndPausesErrorsAndTruncationAreReported() throws {
    let units = (0..<40).map { unit(words: 300, majorSync: $0 == 0, seed: $0) }
    let bursts = matBursts(units, littleEndian: true)
    var unpacker = IEC61937Unpacker()
    #expect(try unpacker.unpack(Data(burst(type: 0x00, payload: [], period: 64, littleEndian: true) + bursts)) == Data(units.joined()))
    try unpacker.finish()
    // A pause burst marks a gap, and Pc bit 7 marks a damaged payload.
    var pausing = IEC61937Unpacker()
    #expect {
        try pausing.unpack(Data(burst(type: 0x03, payload: [0, 0, 0, 1], period: 64, littleEndian: true)))
    } throws: { error in
        if case SpatialAudioError.discontinuity = error { true } else { false }
    }
    var damaged = IEC61937Unpacker()
    #expect {
        try damaged.unpack(Data(burst(type: 0x96, payload: [0, 0, 0, 1], period: 64, littleEndian: true)))
    } throws: { error in
        if case SpatialAudioError.decoding = error { true } else { false }
    }
    for prefix in [30_000, bursts.count + 2] {
        var truncated = IEC61937Unpacker()
        _ = try truncated.unpack(Data((bursts + [0x72, 0xF8, 0x1F, 0x4E]).prefix(prefix)))
        #expect(throws: SpatialAudioError.self) { try truncated.finish() }
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func matFramesWithoutAMajorSyncAreRejected() {
    let units = (0..<160).map { unit(words: 2_000, majorSync: false, seed: $0) }
    var unpacker = IEC61937Unpacker()
    #expect(throws: SpatialAudioError.self) { try unpacker.unpack(Data(matBursts(units, littleEndian: true))) }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func otherBurstTypesAreRejected() {
    var unpacker = IEC61937Unpacker()
    // An AC-3 burst.
    #expect {
        try unpacker.unpack(Data(burst(type: 0x01, payload: [0x0B, 0x77], period: 6_144, littleEndian: true)))
    } throws: { error in
        if case SpatialAudioError.unsupported = error { true } else { false }
    }
}

/// FFmpeg's spdif muxer produced these bursts in mpv; unpacking must return the original stream.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")
       && (ProcessInfo.processInfo.environment["SAB_TRUEHD_FIXTURE"] != nil || ProcessInfo.processInfo.environment["SAB_DTSX_FIXTURE"] != nil)))
func ffmpegBurstsUnpackToTheOriginalStream() throws {
    let environment = ProcessInfo.processInfo.environment
    for (variable, options) in [("SAB_TRUEHD_FIXTURE", [String]()), ("SAB_DTSX_FIXTURE", ["-dtshd_rate", "768000"])] {
        guard let path = environment[variable] else { continue }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).spdif")
        defer { try? FileManager.default.removeItem(at: output) }
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        ffmpeg.arguments = ["-v", "error", "-i", path, "-t", "20", "-c", "copy", "-f", "spdif"] + options + [output.path]
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        try #require(ffmpeg.terminationStatus == 0)
        let (unpacked, unpacker) = try unpackInChunks(Array(try Data(contentsOf: output)))
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        // FFmpeg stops at 20 s and may hold back a final partial MAT frame.
        #expect(unpacked.count > 1_000_000 || unpacked.count > original.count / 2, "\(variable): only \(unpacked.count) bytes")
        #expect(original.starts(with: unpacked), "\(variable): unpacked stream differs from the source")
        #expect(unpacker.skippedDuration == .zero)
    }
}

/// Mutated MAT and type IV streams, split anywhere, either unpack or throw a `SpatialAudioError`,
/// never return more than they took, and hold at most a burst and an access unit between calls.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test(.timeLimit(.minutes(2))) func mutatedBurstsUnpackOrFailWithinBounds() throws {
    let units = (0..<60).map { unit(words: 100 + $0 * 37 % 900, majorSync: $0 % 16 == 0, seed: $0) }
    let dtsFrame: [UInt8] = [0x7F, 0xFE, 0x80, 0x01] + (0..<508).map { UInt8(truncatingIfNeeded: $0 * 7) }
    let typeIV = [UInt8]([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0xFE, 0x02, 0x00]) + dtsFrame
    let bases = [matBursts(units, littleEndian: true), matBursts(units, littleEndian: false),
                 (0..<4).flatMap { _ in burst(type: 0x0011, payload: typeIV, period: 2_048, littleEndian: true) }]
    for seed in Mutation.seeds(base: 0x1EC6_1937) {
        var random = Mutation(seed: seed)
        let input = random.mutate(bases[random.below(bases.count)])
        var unpacker = IEC61937Unpacker()
        var produced = 0
        do {
            for range in random.chunks(input.count) {
                produced += try unpacker.unpack(Data(input[range])).count
                // At most filler from two chunks, one burst (Pd counts up to 65535 bytes) and a
                // TrueHD access unit (up to 8190).
                #expect(unpacker.bufferedBytes <= 2 * 20_000 + 65_543 + 8_190, "seed \(seed)")
            }
            try? unpacker.finish()
        } catch is SpatialAudioError {
        } catch {
            Issue.record("seed \(seed): unexpected \(error)")
        }
        #expect(produced <= input.count, "seed \(seed)")
    }
}

/// The pinned decoder's public Atmos vectors in MAT bursts unpack to the original stream and decode
/// to every access unit's 40 frames. Mutated before or after framing, split anywhere and decoded as
/// they unpack, they yield well-formed finite PCM or throw a `SpatialAudioError`, within the
/// unpacker's buffering bound.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test(.enabled(if: PublicVectors.directory != nil), .timeLimit(.minutes(2)))
func mutatedPublicAtmosBurstsDecodeOrFailWithinBounds() throws {
    let streams = try PublicVectors.atmos()
    for stream in streams {
        let units = PublicVectors.accessUnits(stream)
        #expect(units.joined().count == stream.count)
        let (output, unpacker) = try unpackInChunks(matBursts(units, littleEndian: true))
        #expect(output == Data(stream))
        try unpacker.finish()
        let decoder = try Decoder(codec: .trueHDAtmos, layout: .sevenOneFour)
        let blocks = try output.withUnsafeBytes { try decoder.decode($0, end: true) }
        #expect(blocks.reduce(0) { $0 + $1.frames } == units.count * 40)
        #expect(decoder.isSpatial)
    }
    for seed in Mutation.seeds(base: 0x7E57_0A75) {
        var random = Mutation(seed: seed)
        let stream = streams[random.below(streams.count)], littleEndian = random.below(2) == 0
        // Most of a MAT frame is padding, so mutate the stream itself as often as its framing.
        let input = random.below(2) == 0
            ? matBursts([random.mutate(stream)], littleEndian: littleEndian)
            : random.mutate(matBursts(PublicVectors.accessUnits(stream), littleEndian: littleEndian))
        let layout: SpatialAudioLayout = random.below(2) == 0 ? .sevenOneFour : .nineOneSix
        func check(_ blocks: [PCMBlock]) {
            for block in blocks {
                #expect(block.sampleRate == 48_000 && block.channels == layout.channelCount
                        && block.samples.count == block.frames * block.channels, "seed \(seed)")
                #expect(block.samples.allSatisfy(\.isFinite), "seed \(seed)")
            }
        }
        var unpacker = IEC61937Unpacker()
        do {
            let decoder = try Decoder(codec: .trueHDAtmos, layout: layout)
            for range in random.chunks(input.count) {
                let unpacked = try unpacker.unpack(Data(input[range]))
                #expect(unpacker.bufferedBytes <= 2 * 20_000 + 65_543 + 8_190, "seed \(seed)")
                if !unpacked.isEmpty { check(try unpacked.withUnsafeBytes { try decoder.decode($0, end: false) }) }
            }
            try? unpacker.finish()
            check(try decoder.decode(UnsafeRawBufferPointer(start: nil, count: 0), end: true))
        } catch is SpatialAudioError {
        } catch {
            Issue.record("seed \(seed): unexpected \(error)")
        }
    }
}
