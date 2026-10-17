@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SpatialAudioBridge

/// Callback scheduling makes writer observations an upper bound on input needed for output.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class DRCFragmentTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = 0
    private var flushing = false
    private var first: Int?
    private var beforeFlush = 0
    private var segments: [APACSegment] = []

    func feeding(_ frames: Int) { lock.withLock { submitted = frames } }
    func beginFlush() { lock.withLock { flushing = true } }
    func append(_ segment: APACSegment) {
        lock.withLock {
            segments.append(segment)
            if segment.kind == .media && !flushing {
                if first == nil { first = submitted }
                beforeFlush += 1
            }
        }
    }
    func snapshot() -> (segments: [APACSegment], first: Int?, beforeFlush: Int) {
        lock.withLock { (segments, first, beforeFlush) }
    }
}

@Suite(.serialized)
struct DRCMeasurementTests {
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(3)), arguments: [false, true], [12, 16])
    func compareEncoderBuffering(live: Bool, channels: Int) async throws {
        try await compare(live: live, channels: channels, fragmented: true)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(3)), arguments: [false, true], [12, 16])
    func compareFileWriter(live: Bool, channels: Int) async throws {
        try await compare(live: live, channels: channels, fragmented: false)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private func compare(live: Bool, channels: Int, fragmented: Bool) async throws {
        let frames = 192_000
        let layout: SpatialAudioLayout = channels == 12 ? .sevenOneFour : .nineOneSix
        // Distinct tones, changing levels and isolated transients, with silent edges.
        var pcm = [Float](repeating: 0, count: frames * channels)
        for frame in 4_800..<frames - 4_800 {
            for channel in 0..<channels {
                let frequency = channel == 3 ? 60.0 : 211.0 + Double(channel) * 173
                let level = (frame / 24_000) % 2 == 0 ? 0.15 : 0.75
                pcm[frame * channels + channel] = frame % 48_000 == 0 ? 0.9
                    : Float(level * sin(2 * .pi * frequency * Double(frame) / 48_000))
            }
        }
        for disabled in [false, true] {
            var configuration = APACConfiguration(layout: layout, liveEncoding: live)
            configuration.disablesDynamicRangeControl = disabled
            let queriedPriming = try configuration.encoderPrimingDuration().value
            if fragmented {
                let encoder = try APACEncoder(configuration: configuration)
                #expect(Int64(encoder.primingFrames) == queriedPriming,
                        "The configured encoder and session priming query must agree")
                var packets: [APACEncoder.Packet] = []
                var firstPacketInput: Int?
                for offset in stride(from: 0, to: frames, by: 1024) {
                    let end = min(offset + 1024, frames)
                    let output = try encoder.encode(pcm[offset * channels..<end * channels])
                    if !output.isEmpty && firstPacketInput == nil { firstPacketInput = end }
                    packets += output
                }
                let packetsBeforeFlush = packets.count
                packets += try encoder.encode([], final: true)
                #expect(packets.first?.isIndependent == true)
                let decoded = try decode(packets.map(\.data), format: encoder.format, channels: channels)
                let decodedFrames = decoded.count / channels
                try #require(decodedFrames >= frames + encoder.primingFrames)
                let presented = Array(decoded[(encoder.primingFrames * channels)..<((encoder.primingFrames + frames) * channels)])
                try record(path: "direct", configuration: configuration, input: pcm, decoded: presented,
                           decodedFrames: decodedFrames, priming: encoder.primingFrames,
                           first: firstPacketInput, beforeFlush: packetsBeforeFlush)
            }

            let trace = DRCFragmentTrace()
            let name = "drc-live\(live)-channels\(channels)-disabled\(disabled)-fragmented\(fragmented).mp4"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
            defer { try? FileManager.default.removeItem(at: url) }
            let destination: APACDestination = fragmented
                ? .segments(syncPeriodsPerSegment: 1, onSegment: { trace.append($0) }) : .file(url)
            let transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos,
                destination: destination, configuration: configuration)
            for offset in stride(from: 0, to: frames, by: 1024) {
                let end = min(offset + 1024, frames)
                trace.feeding(end)
                try await transcoder.accumulate(PCMBlock(samples: Array(pcm[offset * channels..<end * channels]),
                    frames: end - offset, sampleRate: 48_000, channels: channels))
                await Task.yield()
            }
            trace.beginFlush()
            let report = try await transcoder.finish()
            #expect(report.sampleFrames == Int64(frames))
            let snapshot = trace.snapshot()
            if fragmented {
                try snapshot.segments.reduce(into: Data()) { $0.append($1.data) }.write(to: url)
            }
            // Preserve synthetic output before reading, including files the native decoder rejects.
            if let directory = ProcessInfo.processInfo.environment["SAB_DRC_OUTPUTS_DIR"] {
                let directory = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                try FileManager.default.copyItem(at: url, to: output)
            }
            print("SAB_DRC_WRITER file=\(name) firstOutputAtSubmittedFrames=\(String(describing: snapshot.first)) outputsBeforeFlush=\(snapshot.beforeFlush) segments=\(snapshot.segments.count)")
            let read = try await readPresentedAudio(url, layout: layout)
            #expect(read.frames == frames)
            try record(path: fragmented ? "fragmented-writer" : "file-writer", configuration: configuration, input: pcm,
                       decoded: read.samples, decodedFrames: read.frames, priming: Int(queriedPriming),
                       first: snapshot.first, beforeFlush: snapshot.beforeFlush)
        }
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private func record(path: String, configuration: APACConfiguration, input: [Float], decoded: [Float],
                        decodedFrames: Int, priming: Int, first: Int?, beforeFlush: Int) throws {
        #expect(decoded.allSatisfy { $0.isFinite })
        let peak = decoded.reduce(Float(0)) { max($0, abs($1)) }
        let rms = sqrt(decoded.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(decoded.count))
        let values: [String: Any] = [
            "path": path, "live": configuration.liveEncoding, "drcDisabled": configuration.disablesDynamicRangeControl,
            "drcRawValue": configuration.dynamicRangeConfiguration.rawValue,
            "channels": configuration.layout.channelCount, "sampleRate": 48_000,
            "bitRate": configuration.bitRate, "syncPacketFrequency": configuration.syncPacketFrequency,
            "inputFrames": input.count / configuration.layout.channelCount, "decodedFrames": decodedFrames,
            "primingFrames": priming, "firstOutputAtSubmittedFrames": first.map { $0 as Any } ?? NSNull(),
            "outputsBeforeFlush": beforeFlush, "inputSamplePeak": input.reduce(Float(0)) { max($0, abs($1)) },
            "decodedSamplePeak": peak, "decodedRMS": rms,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        let json = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("SAB_DRC_MEASUREMENT \(String(decoding: json, as: UTF8.self))")
    }
}
