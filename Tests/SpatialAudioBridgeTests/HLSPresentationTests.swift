@preconcurrency import AVFoundation
import Foundation
import MediaToolbox
import Testing
@testable import SpatialAudioBridge

/// Interleaved silence with 0.75 impulses in the first channel at absolute source `clicks`.
@available(macOS 26, iOS 26, tvOS 26, *)
func clickPCM(frames: Range<Int>, clicks: [Int], channels: Int) -> [Float] {
    var pcm = [Float](repeating: 0, count: frames.count * channels)
    for click in clicks where frames.contains(click) { pcm[(click - frames.lowerBound) * channels] = 0.75 }
    return pcm
}

/// One conversion run on the grid, as `APACStream` starts them: its initialization segment and
/// media fragments by grid index.
@available(macOS 26, iOS 26, tvOS 26, *)
private struct GridRun {
    let initialization: Data
    let segments: [Int: APACSegment]

    /// Converts the synthetic source from segment `index` to the grid's end. Decoding starts
    /// `preRoll` frames before the run's first presented sample, as at a sync point before a seek.
    init(grid: APACSegmentGrid, from index: Int, early: Bool = false, preRoll: Int = 0, clicks: [Int]) async throws {
        var configuration = grid.configuration(from: index, early: early)
        let first = Int(configuration.startTime.value) - preRoll
        configuration.inputStartTime = CMTime(value: Int64(first), timescale: 48_000)
        let collector = SegmentCollector()
        let transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .segments(
            syncPeriodsPerSegment: APACSegmentGrid.syncPeriodsPerSegment, onSegment: { collector.append($0) }),
            configuration: configuration)
        let channels = grid.configuration.layout.channelCount
        let end = Int(grid.totalFrames)
        for offset in stride(from: first, to: end, by: 1_607) {
            let frames = offset..<min(offset + 1_607, end)
            try await transcoder.accumulate(PCMBlock(samples: clickPCM(frames: frames, clicks: clicks, channels: channels),
                                                     frames: frames.count, sampleRate: 48_000, channels: channels))
        }
        _ = try await transcoder.finish(paddingTo: grid.end(from: index, early: early))
        let delivered = collector.snapshot()
        initialization = try #require(delivered.first { $0.kind == .initialization }).data
        var segments: [Int: APACSegment] = [:]
        for segment in delivered where segment.kind == .media {
            let at = try #require(grid.index(of: segment))
            #expect(segments[at] == nil, "One fragment per grid segment")
            segments[at] = segment
        }
        // Every fragment lies on the grid: stored and reported at its segment's start, a whole
        // segment long except the last, which ends at the presentation's end.
        let firstIndex = index - (early ? 1 : 0)
        #expect(segments.keys.sorted() == Array(firstIndex..<grid.segmentCount))
        for (at, segment) in segments {
            let start = grid.start(of: at)
            let expected = min(grid.segmentFrames, grid.totalFrames - start.value)
            #expect(try fragmentTiming(segment.data).decodeTime == UInt64(start.value), "segment \(at)")
            #expect(segment.startTime.map { abs(CMTimeSubtract($0, start).seconds) <= 1.0 / 48_000 } == true)
            #expect(segment.duration.map { CMTimeConvertScale($0, timescale: 48_000, method: .default).value } == expected,
                    "segment \(at)")
        }
        self.segments = segments
    }
}

/// What an `MTAudioProcessingTap` on the player item received, timed by the item's own timeline.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class TapCapture: @unchecked Sendable {
    struct Span {
        let start: Double
        /// The largest magnitude over all channels, per frame.
        let magnitudes: [Float]
    }
    private let lock = NSLock()
    private var format: AudioStreamBasicDescription?
    private var captured: [Span] = []

    var rate: Double { lock.withLock { format?.mSampleRate ?? 0 } }
    var spans: [Span] { lock.withLock { captured } }
    var formatDescription: String {
        lock.withLock { format.map { "\($0.mSampleRate) Hz, \($0.mChannelsPerFrame) ch, flags \($0.mFormatFlags)" } ?? "none" }
    }

    func prepare(_ format: AudioStreamBasicDescription) { lock.withLock { self.format = format } }

    func record(_ range: CMTimeRange, _ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard let format = lock.withLock({ format }), format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, range.start.isNumeric, frames > 0 else { return }
        var magnitudes = [Float](repeating: 0, count: frames)
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let samples = data.assumingMemoryBound(to: Float.self)
            let available = min(frames, Int(buffer.mDataByteSize) / 4 / channels)
            for frame in 0..<available {
                for channel in 0..<channels {
                    magnitudes[frame] = max(magnitudes[frame], abs(samples[frame * channels + channel]))
                }
            }
        }
        lock.withLock { captured.append(Span(start: range.start.seconds, magnitudes: magnitudes)) }
    }

    /// The loudest captured frame within `window` seconds of `time`, and its presented time.
    func peak(near time: Double, window: Double = 0.05) -> (time: Double, magnitude: Float)? {
        let rate = rate
        var best: (time: Double, magnitude: Float)?
        for span in spans {
            for (frame, magnitude) in span.magnitudes.enumerated() {
                let at = span.start + Double(frame) / rate
                if abs(at - time) <= window, magnitude > best?.magnitude ?? -1 { best = (at, magnitude) }
            }
        }
        return best
    }

    /// The loudest captured frame in `range`, away from the `clicks` and their codec ringing.
    func quietPeak(in range: ClosedRange<Double>, clicks: [Double], window: Double = 0.05) -> Float {
        let rate = rate
        var loudest: Float = 0
        for span in spans {
            for (frame, magnitude) in span.magnitudes.enumerated() {
                let at = span.start + Double(frame) / rate
                if range.contains(at), !clicks.contains(where: { abs($0 - at) < window }) { loudest = max(loudest, magnitude) }
            }
        }
        return loudest
    }

    /// Joins in `range` where a span does not start where the previous one ended, in seconds.
    func discontinuities(in range: ClosedRange<Double>) -> [Double] {
        let rate = rate
        let spans = spans.filter { range.contains($0.start) }
        return zip(spans, spans.dropFirst()).compactMap { previous, next in
            let jump = next.start - (previous.start + Double(previous.magnitudes.count) / rate)
            return abs(jump) > 1.5 / rate ? jump : nil
        }
    }
}

/// Serves the grid's media playlist with the given fragments, plays it with `AVPlayer` from
/// `start` until `end` and returns what a processing tap on the item received. The item's tracks
/// and audio mix belong to the main actor.
@available(macOS 26, iOS 26, tvOS 26, *)
@MainActor
private func play(grid: APACSegmentGrid, initialization: Data, segments: [Int: Data],
                  from start: Double, until end: Double, variant: Int = 0) async throws -> TapCapture {
    let playlist = Data(grid.mediaPlaylist().utf8)
    let server = try await LoopbackServer { path in
        switch path {
        case "/audio.m3u8": return .init(status: 200, contentType: "application/vnd.apple.mpegurl", body: playlist)
        case "/init.mp4": return .init(status: 200, contentType: "audio/mp4", body: initialization)
        default:
            guard path.hasPrefix("/seg"), path.hasSuffix(".m4s"), let index = Int(path.dropFirst(4).dropLast(4)),
                  let data = segments[index] else { return .notFound() }
            return .init(status: 200, contentType: "audio/mp4", body: data)
        }
    }
    defer { server.stop() }
    let item = AVPlayerItem(url: try #require(URL(string: "http://127.0.0.1:\(server.port)/audio.m3u8")))
    let capture = TapCapture()
    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(capture).toOpaque()),
        init: { _, clientInfo, storage in storage.pointee = clientInfo },
        finalize: { tap in Unmanaged<TapCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
        prepare: { tap, _, format in
            Unmanaged<TapCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
        },
        unprepare: nil,
        process: { tap, frames, _, list, framesOut, flagsOut in
            var range = CMTimeRange()
            guard MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, &range, framesOut) == noErr else { return }
            Unmanaged<TapCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                .record(range, list, frames: framesOut.pointee)
        })
    var tap: MTAudioProcessingTap?
    try #require(MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, variant == 2 ? kMTAudioProcessingTapCreationFlag_PostEffects : kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr)
    if variant == 3 {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = 1
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }
    let player = AVPlayer(playerItem: item)
    player.volume = variant == 0 ? 0 : 1
    for _ in 0..<200 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
    try #require(item.status == .readyToPlay, "\(String(describing: item.error))")
    if variant != 3 {
    let track = item.tracks.compactMap(\.assetTrack).first { $0.mediaType == .audio }
    print("HLS presentation: item tracks \(item.tracks.map { $0.assetTrack?.mediaType.rawValue ?? "nil" }), audio track \(track.map { "\($0.trackID)" } ?? "none")")
    let parameters = AVMutableAudioMixInputParameters(track: track)
    parameters.audioTapProcessor = tap
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameters]
    item.audioMix = mix
    }

    await player.seek(to: CMTime(seconds: start, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    player.play()
    for _ in 0..<300 where player.currentTime().seconds < end { try await Task.sleep(for: .milliseconds(50)) }
    let reached = player.currentTime().seconds
    player.pause()
    print("HLS presentation: variant \(variant) from \(start) reached \(reached) s, tap format \(capture.formatDescription), spans \(capture.spans.count), first \(capture.spans.first?.start ?? -1), last \(capture.spans.last?.start ?? -1), item error \(String(describing: item.error))")
    #expect(item.error == nil)
    #expect(reached >= end, "AVPlayer must play through the checked range")
    return capture
}

@Suite(.serialized)
struct HLSPresentationTests {
    /// `APACStream` serves fragments from several conversion runs on one playlist: a run restarted at
    /// a seek, whose first fragment carries the encoder priming, and a helper that starts a segment
    /// early so its first served fragment plays on from the run before it. `AVPlayer` must present
    /// a click at its source time on either side of those joins.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(3)), arguments: [SpatialAudioLayout.sevenOneFour, .nineOneSix])
    func clicksKeepTheirTimesAcrossRestartedRuns(layout: SpatialAudioLayout) async throws {
        let grid = try APACSegmentGrid(duration: CMTime(value: 3 * 153_600 + 20_000, timescale: 48_000),
                                       configuration: APACConfiguration(layout: layout))
        let segment = Int(grid.segmentFrames), priming = Int(grid.primingFrames)
        let join = 2 * segment
        // Near the start, either side of the join at segment 2 (the first also in the seek run's
        // discarded pre-roll) and in the shortened last segment.
        let clicks = [12_000, join - 3_000, join + priming + 12_000, 3 * segment + 10_000]
        let continuous = try await GridRun(grid: grid, from: 0, clicks: clicks)
        let restarted = try await GridRun(grid: grid, from: 2, preRoll: 9_600, clicks: clicks)
        let helper = try await GridRun(grid: grid, from: 2, early: true, clicks: clicks)
        let initialization = continuous.initialization
        print("HLS presentation: initialization segments match: \([restarted, helper].map { $0.initialization == initialization })")
        func data(_ run: GridRun, _ indices: ClosedRange<Int>) -> [Int: Data] {
            Dictionary(uniqueKeysWithValues: indices.compactMap { index in run.segments[index].map { (index, $0.data) } })
        }
        let first = data(continuous, 0...1)
        if let directory = ProcessInfo.processInfo.environment["SAB_DRC_OUTPUTS_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (name, run) in [("continuous", continuous), ("restarted", restarted), ("helper", helper)] {
                try run.initialization.write(to: output.appendingPathComponent("init-\(layout)-\(name).mp4"))
                for (index, segment) in run.segments { try segment.data.write(to: output.appendingPathComponent("seg-\(layout)-\(name)-\(index).m4s")) }
            }
        }
        for variant in 1...3 {
            _ = try await play(grid: grid, initialization: initialization, segments: data(continuous, 0...3), from: 0, until: 0.6, variant: variant)
        }
        let seconds = clicks.map { Double($0) / 48_000 }
        let joinTime = Double(join) / 48_000

        // From zero, through the first run's own segments.
        let opening = try await play(grid: grid, initialization: initialization, segments: data(continuous, 0...3),
                                     from: 0, until: 0.6)
        // Played on into the helper's first segment, as steady playback after a seek does.
        let helped = try await play(grid: grid, initialization: initialization, segments: first.merging(data(helper, 2...3)) { $1 },
                                    from: joinTime - 0.4, until: joinTime + 0.5)
        // A seek to the restarted run's first segment, and on to the end.
        let sought = try await play(grid: grid, initialization: initialization, segments: first.merging(data(restarted, 2...3)) { $1 },
                                    from: joinTime, until: grid.end.seconds - 0.05)

        for (name, capture, range) in [("opening", opening, 0.1...0.55), ("helper join", helped, (joinTime - 0.35)...(joinTime + 0.45)),
                                       ("seek", sought, joinTime...(grid.end.seconds - 0.1))] {
            let expected = seconds.filter { range.contains($0) }
            try #require(!expected.isEmpty)
            for click in expected {
                let peak = try #require(capture.peak(near: click), "\(name): no audio near \(click) s")
                print("HLS presentation \(layout): \(name) click at \(click) s presented at \(peak.time) s, magnitude \(peak.magnitude)")
                #expect(peak.magnitude > 0.05, "\(name): the click at \(click) s must reach the player")
                // One millisecond tolerates lossy impulse shaping, but not a packet or priming shift.
                #expect(abs(peak.time - click) <= 0.001, "\(name): click at \(click) s presented at \(peak.time) s")
            }
            let quiet = capture.quietPeak(in: range, clicks: expected)
            #expect(quiet < 0.01, "\(name): no other clicks, including the seek run's discarded pre-roll (\(quiet))")
            #expect(capture.discontinuities(in: range).isEmpty, "\(name): the presented audio must be continuous")
        }
    }
}
