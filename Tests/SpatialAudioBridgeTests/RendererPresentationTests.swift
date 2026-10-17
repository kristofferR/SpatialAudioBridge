// Xcode 26's SDK does not mark AVSampleBufferRenderSynchronizer Sendable.
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SpatialAudioBridge

/// Records each enqueued buffer's presentation time and APAC packet. A flush drops what was queued,
/// as the native renderer does when a timeline begins.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class RecordingRendererOutput: SpatialAudioRendererOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [(time: CMTime, packet: Data)] = []
    private var format: CMAudioFormatDescription?
    var isReadyForMoreMediaData: Bool { true }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { true }
    var status: AVQueuedSampleBufferRenderingStatus { .rendering }
    var error: (any Error)? { nil }
    var isMuted = false
    var volume: Float = 1

    var queued: (buffers: [(time: CMTime, packet: Data)], format: CMAudioFormatDescription?) { lock.withLock { (buffers, format) } }

    func enqueue(_ buffer: CMSampleBuffer) {
        #expect(CMSampleBufferGetNumSamples(buffer) == 1, "One APAC packet per buffer")
        let block = CMSampleBufferGetDataBuffer(buffer)!
        var data = Data(count: CMBlockBufferGetDataLength(block))
        _ = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        lock.withLock {
            format = CMSampleBufferGetFormatDescription(buffer)
            buffers.append((CMSampleBufferGetPresentationTimeStamp(buffer), data))
        }
    }
    func flush() { lock.withLock { buffers.removeAll() } }
    func flush(fromSourceTime time: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) { completionHandler(false) }
}

/// Stands in for the compressed decoder: each packet names a span of the synthetic click source.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class ClickDecoder: SpatialAudioRendererDecoding {
    let clicks: [Int]
    let channels: Int
    init(clicks: [Int], channels: Int) {
        self.clicks = clicks
        self.channels = channels
    }

    static func packet(_ frames: Range<Int>) -> Data {
        withUnsafeBytes(of: (UInt32(frames.lowerBound), UInt32(frames.count))) { Data($0) }
    }

    func decode(_ bytes: UnsafeRawBufferPointer, end: Bool) throws -> [PCMBlock] {
        guard bytes.count == 8 else { return [] }
        let start = Int(bytes.loadUnaligned(as: UInt32.self)), count = Int(bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        return [PCMBlock(samples: clickPCM(frames: start..<start + count, clicks: clicks, channels: channels),
                         frames: count, sampleRate: 48_000, channels: channels)]
    }
}

@Suite(.serialized)
struct RendererPresentationTests {
    /// The sample-buffer path, which never reaches a file: the buffers `SpatialAudioRenderer` enqueues
    /// must put each click at its source time on the synchronizer's timeline, from a zero start, a
    /// seek forward with pre-roll to discard and a seek back to a source that starts late.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(2)), arguments: [SpatialAudioLayout.sevenOneFour, .nineOneSix])
    func clicksKeepTheirTimesAcrossTimelines(layout: SpatialAudioLayout) async throws {
        let channels = layout.channelCount
        // (timeline start, first packet's time, end), in source frames. Each ends partway through a packet.
        let timelines = [(0, 0, 96_037), (480_037, 480_037 - 4_800, 576_037), (144_017, 144_017 + 480, 240_017)]
        // Two clicks per timeline, and one in the second timeline's discarded pre-roll.
        let clicks = [12_000, 84_037, 477_637, 492_037, 564_037, 156_017, 228_017]
        let output = RecordingRendererOutput()
        let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos, configuration: APACConfiguration(layout: layout),
                                                synchronizer: AVSampleBufferRenderSynchronizer(), output: output,
                                                makeDecoder: { ClickDecoder(clicks: clicks, channels: channels) })
        let priming = Int(try APACConfiguration(layout: layout, liveEncoding: true).encoderPrimingDuration().value)

        for (start, input, end) in timelines {
            let timeline = CMTime(value: Int64(start), timescale: 48_000)
            try await renderer.begin(at: timeline)
            for offset in stride(from: input, to: end, by: 1_607) {
                try await renderer.enqueue(ClickDecoder.packet(offset..<min(offset + 1_607, end)),
                                           time: CMTime(value: Int64(offset), timescale: 48_000))
            }
            try await renderer.endOfStream()
            var progress: SpatialAudioRendererProgress?
            for await latest in await renderer.progress() { progress = latest; break }
            #expect(progress == SpatialAudioRendererProgress(timelineStart: timeline, submittedEnd: CMTime(value: Int64(end), timescale: 48_000),
                                                             isFinal: true))

            // Packet n plays from the timeline start less the priming, plus n packets: the priming
            // packets end where the host starts the synchronizer, and nothing from an earlier timeline remains.
            let (buffers, format) = output.queued
            for (index, buffer) in buffers.enumerated() {
                let expected = CMTime(value: Int64(start - priming + index * 1024), timescale: 48_000)
                #expect(buffer.time == expected, "packet \(index) of the timeline at \(start)")
            }
            let decoded = try decode(buffers.map(\.packet), format: try #require(format), channels: channels)
            let frames = end - start
            try #require(decoded.count / channels >= priming + frames, "The timeline's audio must all be enqueued")
            // Decoded frame n presents at the first buffer's time plus n frames.
            func presented(_ frame: Int) -> Int { start - priming + frame }
            let expected = clicks.filter { (start..<end).contains($0) }
            #expect(expected.count == 2)
            for click in expected {
                let near = (click - start + priming - 2_400)..<(click - start + priming + 2_400)
                let frame = try #require(near.max { abs(decoded[$0 * channels]) < abs(decoded[$1 * channels]) })
                #expect(abs(decoded[frame * channels]) > 0.05, "The click must survive encoding")
                print("Renderer presentation \(layout): timeline \(start), click at \(click) presented at \(presented(frame))")
                // One millisecond tolerates lossy impulse shaping, but not a packet or priming shift.
                #expect(abs(presented(frame) - click) <= 48, "Click at \(click) presented at \(presented(frame))")
            }
            let quietPeak = (priming..<priming + frames).lazy
                .filter { frame in !expected.contains { abs($0 - presented(frame)) < 2_400 } }
                .map { abs(decoded[$0 * channels]) }.max() ?? 0
            #expect(quietPeak < 0.01, "No pre-roll, padding or earlier timeline audio outside the clicks")
        }
    }
}
