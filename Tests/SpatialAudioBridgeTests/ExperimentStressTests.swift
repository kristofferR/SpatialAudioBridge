// Temporary #56 experiment; not for merging.
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SpatialAudioBridge

@available(macOS 26, iOS 26, tvOS 26, *)
private func stressRun(_ iteration: Int, layout: SpatialAudioLayout, live: Bool, frames: Int, pcm: [Float]) async throws -> String {
    let channels = layout.channelCount
    let configuration = APACConfiguration(layout: layout, liveEncoding: live)
    let collector = SegmentCollector()
    let transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .segments(
        syncPeriodsPerSegment: 1, onSegment: { collector.append($0) }), configuration: configuration)
    for offset in stride(from: 0, to: frames, by: 317) {
        let count = min(317, frames - offset)
        try await transcoder.accumulate(PCMBlock(samples: Array(pcm[offset * channels..<(offset + count) * channels]),
                                                 frames: count, sampleRate: 48_000, channels: channels))
    }
    _ = try await transcoder.finish()
    let segments = collector.snapshot()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stress-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try segments.reduce(into: Data()) { $0.append($1.data) }.write(to: url)
    let media = segments.filter { $0.kind == .media }
    let timings = try media.map { try fragmentTiming($0.data) }
    let decoded = try await readPresentedAudio(url, layout: layout)
    #expect(decoded.frames == frames, "iteration \(iteration)")
    return "SAB_STRESS channels=\(channels) live=\(live) iteration=\(iteration) decoded=\(decoded.frames) packetFrames=\(timings.map(\.frames)) decodeTimes=\(timings.map(\.decodeTime)) reported=\(media.map { $0.duration.map { CMTimeConvertScale($0, timescale: 48_000, method: .default).value } ?? -1 })"
}

@available(macOS 26, iOS 26, tvOS 26, *)
private func stress(layout: SpatialAudioLayout, live: Bool, frames: Int, iterations: Int, concurrency: Int) async throws {
    let channels = layout.channelCount
    let pcm = (0..<frames * channels).map { sample in
        let channel = sample % channels, frame = sample / channels
        return Float(0.3 * sin(2 * .pi * Double(211 + channel * 173) * Double(frame) / 48_000))
    }
    try await withThrowingTaskGroup(of: String.self) { group in
        var next = 0
        for _ in 0..<concurrency where next < iterations {
            let iteration = next
            group.addTask { try await stressRun(iteration, layout: layout, live: live, frames: frames, pcm: pcm) }
            next += 1
        }
        while let line = try await group.next() {
            print(line)
            if next < iterations {
                let iteration = next
                group.addTask { try await stressRun(iteration, layout: layout, live: live, frames: frames, pcm: pcm) }
                next += 1
            }
        }
    }
}

@Suite(.serialized)
struct ExperimentStressTests {
    /// The #69 configuration: live 9.1.6, 96,000 frames, one sync period per fragment.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(20)))
    func liveNineOneSixDuration() async throws {
        try await stress(layout: .nineOneSix, live: true, frames: 96_000, iterations: 400, concurrency: 6)
    }

    /// The #76 configuration: offline 7.1.4, 192,000 frames.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(20)))
    func offlineSevenOneFourDuration() async throws {
        try await stress(layout: .sevenOneFour, live: false, frames: 192_000, iterations: 100, concurrency: 6)
    }

    /// Whether the native sample-buffer renderer plays on this runner at all.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func nativeRendererProbe() async throws {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos, configuration: APACConfiguration(),
                                                synchronizer: synchronizer, output: AVSampleBufferAudioRenderer(),
                                                makeDecoder: { ProbeDecoder() })
        let start = CMTime(value: 480_000, timescale: 48_000)
        try await renderer.begin(at: start)
        var started = false
        for offset in stride(from: 480_000, to: 480_000 + 48_000 * 4, by: 1_600) {
            try await renderer.enqueue(withUnsafeBytes(of: (UInt32(offset), UInt32(1_600))) { Data($0) },
                                       time: CMTime(value: Int64(offset), timescale: 48_000))
            if !started, await renderer.isReadyToPlay {
                started = true
                synchronizer.setRate(1, time: start)
                print("SAB_PROBE ready after input to \(offset)")
            }
        }
        try await Task.sleep(for: .seconds(1))
        print("SAB_PROBE started=\(started) status=\(await renderer.renderingStatus.rawValue) time=\(synchronizer.currentTime().seconds) ahead=\(await renderer.queuedAhead.seconds)")
        synchronizer.rate = 0
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
private final class ProbeDecoder: SpatialAudioRendererDecoding {
    func decode(_ bytes: UnsafeRawBufferPointer, end: Bool) throws -> [PCMBlock] {
        guard bytes.count == 8 else { return [] }
        let start = Int(bytes.loadUnaligned(as: UInt32.self)), count = Int(bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        return [PCMBlock(samples: clickPCM(frames: start..<start + count, clicks: [start + 100], channels: 12),
                         frames: count, sampleRate: 48_000, channels: 12)]
    }
}
