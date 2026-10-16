@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SpatialAudioBridge

@available(macOS 26, iOS 26, tvOS 26, *)
struct PresentedAudio {
    let firstTime: CMTime
    let samples: [Float]
    let channels: Int
    var frames: Int { samples.count / channels }

    /// A click's main peak, rather than the first nonzero sample, excludes low-level codec ringing.
    func clickFrame(in range: Range<Int>) throws -> Int {
        let frame = try #require(range.max { abs(samples[$0 * channels]) < abs(samples[$1 * channels]) })
        #expect(abs(samples[frame * channels]) > 0.05, "The click must survive encoding")
        return frame
    }
}

/// Read sample timestamps as well as PCM: flattening the data alone would hide a muxing offset.
@available(macOS 26, iOS 26, tvOS 26, *)
func readPresentedAudio(_ url: URL, layout: SpatialAudioLayout) async throws -> PresentedAudio {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatAPAC)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
        AVNumberOfChannelsKey: layout.channelCount, AVChannelLayoutKey: layoutData(layout),
    ])
    try #require(reader.canAdd(output))
    reader.add(output)
    try #require(reader.startReading())
    var samples: [Float] = []
    var firstTime: CMTime?
    while let buffer = output.copyNextSampleBuffer() {
        let count = CMSampleBufferGetNumSamples(buffer)
        try #require(count > 0)
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        try #require(time.isNumeric)
        if let firstTime {
            let expected = CMTimeAdd(firstTime, CMTime(value: Int64(samples.count / layout.channelCount), timescale: 48_000))
            #expect(abs(CMTimeSubtract(time, expected).seconds) <= 1.0 / 48_000,
                    "Decoded buffers must be contiguous")
        } else {
            firstTime = time
        }
        let block = try #require(CMSampleBufferGetDataBuffer(buffer))
        let bytes = CMBlockBufferGetDataLength(block)
        try #require(bytes == count * layout.channelCount * MemoryLayout<Float>.size)
        var pcm = [Float](repeating: 0, count: count * layout.channelCount)
        let status = pcm.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
        }
        try #require(status == noErr)
        #expect(pcm.allSatisfy { $0.isFinite })
        samples.append(contentsOf: pcm)
    }
    try #require(reader.status == .completed, "\(String(describing: reader.error))")
    return PresentedAudio(firstTime: try #require(firstTime), samples: samples, channels: layout.channelCount)
}

@Suite(.serialized)
struct PresentationTimingTests {
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [0, 96_037, 153_600])
    func clicksKeepTheirPresentedTimes(fragmented: Bool, startFrames: Int) async throws {
        // Every case owns a fresh session. The third starts at an earlier decoder sync point,
        // with a click in the discarded pre-roll that must not reach the new timeline.
        try await checkPresentation(fragmented: fragmented, startFrames: startFrames,
                                    discardedFrames: startFrames == 153_600 ? 4_800 : 0)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private func checkPresentation(fragmented: Bool, startFrames: Int, discardedFrames: Int) async throws {
        let layout = SpatialAudioLayout.sevenOneFour
        let channels = layout.channelCount
        let frames = 96_037 // Deliberately ends partway through a coded packet.
        let clicks = [12_000, frames - 12_000]
        let start = CMTime(value: Int64(startFrames), timescale: 48_000)
        var configuration = APACConfiguration(layout: layout, startTime: start, liveEncoding: fragmented)
        configuration.inputStartTime = CMTime(value: Int64(startFrames - discardedFrames), timescale: 48_000)
        let priming = try configuration.encoderPrimingDuration()
        #expect((Int(priming.value) + frames) % 1024 != 0)

        var pcm = [Float](repeating: 0, count: (frames + discardedFrames) * channels)
        for frame in clicks { pcm[(frame + discardedFrames) * channels] = 0.75 }
        if discardedFrames > 0 { pcm[(discardedFrames / 2) * channels] = 0.75 }
        let collector = SegmentCollector()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timing-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination: APACDestination = fragmented
            ? .segments(syncPeriodsPerSegment: 1, onSegment: { collector.append($0) }) : .file(url)
        let transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: destination,
                                                    configuration: configuration)
        // Exercise the production PCM accumulator, including partial blocks and seek pre-roll.
        for offset in stride(from: 0, to: frames + discardedFrames, by: 317) {
            let count = min(317, frames + discardedFrames - offset)
            try await transcoder.accumulate(PCMBlock(samples: Array(pcm[offset * channels..<(offset + count) * channels]),
                frames: count, sampleRate: 48_000, channels: channels))
        }
        let report = try await transcoder.finish()
        #expect(report.sampleFrames == Int64(frames))
        #expect(report.recovery.concealedFrames == 0)
        let recovery = await transcoder.recoveryStatistics
        #expect(report.recovery == recovery)

        if fragmented {
            let segments = collector.snapshot()
            #expect(segments.first?.kind == .initialization)
            let media = segments.filter { $0.kind == .media }
            try #require(media.count >= 2, "The clicks must span a fragment boundary")
            var end = max(.zero, CMTimeSubtract(start, priming))
            var codedFrames: Int64 = 0
            for segment in media {
                let time = try #require(segment.startTime)
                let duration = try #require(segment.duration)
                #expect(abs(CMTimeSubtract(time, end).seconds) <= 1.0 / 48_000)
                // Check the stored tfdt too: a standalone AVAssetReader rebases the decoded
                // timeline, so its PCM timestamps alone cannot establish the fragment origin.
                let stored = try fragmentTiming(segment.data)
                #expect(stored.decodeTime == UInt64(CMTimeConvertScale(end, timescale: 48_000, method: .default).value))
                codedFrames += CMTimeConvertScale(duration, timescale: 48_000, method: .default).value
                end = CMTimeAdd(time, duration)
            }
            #expect(codedFrames == Int64(frames) + priming.value, "Final fragment must exclude packet padding")
            try segments.reduce(into: Data()) { $0.append($1.data) }.write(to: url)
        }

        let decoded = try await readPresentedAudio(url, layout: layout)
        // Both standalone files and init+fragments read as one file present from movie time zero.
        // Assert that mapping explicitly; the stored fragment origin is checked separately above.
        let expectedStart = CMTime.zero
        print("APAC timing: fragmented=\(fragmented), sourceStart=\(startFrames), discarded=\(discardedFrames), priming=\(priming.value), decodedStart=\(decoded.firstTime.seconds), frames=\(decoded.frames)")
        #expect(abs(CMTimeSubtract(decoded.firstTime, expectedStart).seconds) <= 1.0 / 48_000)
        try #require(decoded.frames == frames, "Decoded duration must exclude priming and end padding")
        for click in clicks {
            let observed = try decoded.clickFrame(in: (click - 2_400)..<(click + 2_400))
            let presented = CMTimeAdd(decoded.firstTime, CMTime(value: Int64(observed), timescale: 48_000))
            let expected = CMTimeAdd(expectedStart, CMTime(value: Int64(click), timescale: 48_000))
            // One millisecond tolerates lossy impulse shaping, but not a packet or priming shift.
            #expect(abs(CMTimeSubtract(presented, expected).seconds) <= 0.001,
                    "Click at frame \(click) presented at \(presented.seconds), expected \(expected.seconds)")
        }
        // Detect leaked pre-roll, stale-session audio or a duplicate click outside either impulse.
        let quietPeak = (0..<frames).lazy
            .filter { frame in !clicks.contains { abs($0 - frame) < 2_400 } }
            .map { abs(decoded.samples[$0 * channels]) }.max() ?? 0
        #expect(quietPeak < 0.01, "No extra clicks outside the codec ringing windows")
    }
}
