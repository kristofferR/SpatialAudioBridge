import AVFoundation
import Foundation
import Testing
@testable import SpatialAudioBridge

/// AVAssetWriter's fragmented initialization segment describes APAC with its default configuration,
/// which the native decoder rejects for packets encoded with dynamic-range control disabled (#55).
@Suite(.serialized)
struct FragmentInitializationTests {
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(3)), arguments: [false, true], [12, 16])
    func decodeDisabledDRCFragments(live: Bool, channels: Int) async throws {
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
        try segments.data.write(to: fragmented)
        if let output = ProcessInfo.processInfo.environment["SAB_DRC_OUTPUTS_DIR"] {
            let output = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (name, url) in [("fragmented", fragmented), ("standalone", standalone)] {
                let target = output.appendingPathComponent("initialization-live\(live)-channels\(channels)-\(name).mp4")
                try Data(contentsOf: url).write(to: target)
            }
        }
        let expected = try await readPresentedAudio(standalone, layout: layout)
        let decoded = try await readPresentedAudio(fragmented, layout: layout)
        #expect(expected.frames == frames)
        #expect(decoded.frames == frames)
        let matches = decoded.samples == expected.samples
        #expect(matches, "Fragments must decode exactly as the standalone file, including trims")
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
