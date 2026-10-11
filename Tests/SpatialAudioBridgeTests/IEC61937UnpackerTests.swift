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
private func matBursts(_ units: [[UInt8]], littleEndian: Bool) -> [UInt8] {
    var body: [UInt8] = []
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
    for littleEndian in [true, false] {
        let (output, unpacker) = try unpackInChunks(matBursts(leading + units, littleEndian: littleEndian))
        #expect(output == Data(units.joined()))
        #expect(unpacker.skippedDuration == CMTime(value: 3, timescale: 1200))
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func dtsFramesComeOutOfTypeIVBursts() throws {
    let frames = (0..<5).map { index in [0x7F, 0xFE, 0x80, 0x01] + [UInt8](repeating: UInt8(index), count: 2_376) }
    for littleEndian in [true, false] {
        let bursts = frames.flatMap { frame in
            burst(type: 0x0411, payload: [0x01, 0, 0, 0, 0, 0, 0, 0, 0xFE, 0xFE, UInt8(frame.count >> 8), UInt8(frame.count & 0xFF)] + frame,
                  period: 32_768, littleEndian: littleEndian)
        }
        let (output, unpacker) = try unpackInChunks(bursts)
        #expect(output == Data(frames.joined()))
        #expect(unpacker.skippedDuration == .zero)
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func otherBurstTypesAreRejected() {
    var unpacker = IEC61937Unpacker()
    // An AC-3 burst.
    #expect(throws: SpatialAudioError.self) { try unpacker.unpack(Data(burst(type: 0x01, payload: [0x0B, 0x77], period: 6_144, littleEndian: true))) }
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
