import AVFoundation
import Foundation
import Testing
@testable import SpatialAudioBridge

/// A container-only experiment: keep the fragmented packets and replace only their APAC entry.
@Suite(.serialized)
struct FragmentInitializationTests {
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(3)), arguments: [false, true], [12, 16])
    func decodeDisabledDRCWithStandaloneInitialization(live: Bool, channels: Int) async throws {
        let layout: SpatialAudioLayout = channels == 12 ? .sevenOneFour : .nineOneSix
        var configuration = APACConfiguration(layout: layout, liveEncoding: live)
        configuration.disablesDynamicRangeControl = true
        let frames = 192_000
        let pcm = (0..<frames * channels).map { sample in
            let channel = sample % channels
            let frame = sample / channels
            return Float(0.2 * sin(2 * .pi * Double(211 + channel * 173) * Double(frame) / 48_000))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let standalone = directory.appendingPathComponent("standalone.mp4")
        let fragmented = directory.appendingPathComponent("fragmented.mp4")
        let repaired = directory.appendingPathComponent("repaired.mp4")
        let segments = InitializationSegments()
        for destination in [APACDestination.file(standalone), .segments(syncPeriodsPerSegment: 1, onSegment: { segments.append($0) })] {
            let transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: destination,
                                                      configuration: configuration)
            for start in stride(from: 0, to: frames, by: 1024) {
                let end = min(start + 1024, frames)
                try await transcoder.accumulate(PCMBlock(samples: Array(pcm[start * channels..<end * channels]),
                    frames: end - start, sampleRate: 48_000, channels: channels))
            }
            _ = try await transcoder.finish()
        }
        let original = segments.data
        try original.write(to: fragmented)
        let replacement = try replacingAPACEntry(in: original, from: Data(contentsOf: standalone))
        #expect(replacement != original, "The experiment requires different codec initialization entries")
        try replacement.write(to: repaired)
        if let output = ProcessInfo.processInfo.environment["SAB_DRC_OUTPUTS_DIR"] {
            let output = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (name, url) in [("original", fragmented), ("repaired", repaired), ("standalone", standalone)] {
                let target = output.appendingPathComponent("initialization-live\(live)-channels\(channels)-\(name).mp4")
                try Data(contentsOf: url).write(to: target)
            }
        }
        let reference = try await readPresentedAudio(standalone, layout: layout)
        let decoded = try await readPresentedAudio(repaired, layout: layout)
        #expect(reference.frames == frames)
        #expect(decoded.frames == frames)
        let matches = decoded.samples == reference.samples
        #expect(matches,
                "Container repair must reproduce the working standalone decode, including trims")
        print("SAB_DRC_INITIALIZATION live=\(live) channels=\(channels) frames=\(decoded.frames) pcmMatches=\(matches)")
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
private final class InitializationSegments: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ segment: APACSegment) { lock.withLock { bytes.append(segment.data) } }
    var data: Data { lock.withLock { bytes } }
}

/// Only the ordinary 32-bit boxes in these single-track writer outputs are accepted.
@available(macOS 26, iOS 26, tvOS 26, *)
private func replacingAPACEntry(in fragmented: Data, from standalone: Data) throws -> Data {
    let path = ["moov", "trak", "mdia", "minf", "stbl", "stsd", "apac"]
    func boxes(_ data: Data, path: ArraySlice<String>, range: Range<Int>) throws -> [Range<Int>] {
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            try #require(size >= 8 && size <= range.upperBound - offset, "Expected a bounded 32-bit box")
            let box = offset..<offset + size
            let kind = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            if kind == path.first {
                if path.count == 1 { return [box] }
                let children = offset + (kind == "stsd" ? 16 : 8)
                return [box] + (try boxes(data, path: path.dropFirst(), range: children..<box.upperBound))
            }
            offset += size
        }
        throw InitializationError.missingBox(path.first ?? "empty path")
    }
    let target = try boxes(fragmented, path: path[...], range: 0..<fragmented.count)
    let source = try boxes(standalone, path: path[...], range: 0..<standalone.count)
    let oldEntry = try #require(target.last)
    let newEntry = try #require(source.last)
    let delta = newEntry.count - oldEntry.count
    var result = fragmented
    result.replaceSubrange(oldEntry, with: standalone[newEntry])
    for ancestor in target.dropLast() {
        let size = try #require(UInt32(exactly: ancestor.count + delta))
        result.replaceSubrange(ancestor.lowerBound..<ancestor.lowerBound + 4,
                               with: [UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                                      UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
    }
    // Everything following moov, including every moof/mdat and their relative offsets, is untouched.
    let moov = try #require(target.first)
    #expect(result[(moov.upperBound + delta)...] == fragmented[moov.upperBound...])
    return result
}

@available(macOS 26, iOS 26, tvOS 26, *)
private enum InitializationError: Error {
    case missingBox(String)
}
