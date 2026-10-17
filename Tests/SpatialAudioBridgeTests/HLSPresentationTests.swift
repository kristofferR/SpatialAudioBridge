@preconcurrency import AVFoundation
import Foundation
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
    let segments: [Int: Data]

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
        var segments: [Int: Data] = [:]
        for segment in delivered where segment.kind == .media {
            // Every fragment lies on the grid: stored and reported at its segment's start, a whole
            // segment long except the last, which ends at the presentation's end.
            let at = try #require(grid.index(of: segment))
            let start = grid.start(of: at)
            #expect(segments[at] == nil, "One fragment per grid segment")
            #expect(try fragmentTiming(segment.data).decodeTime == UInt64(start.value), "segment \(at)")
            #expect(segment.startTime.map { abs(CMTimeSubtract($0, start).seconds) <= 1.0 / 48_000 } == true)
            #expect(segment.duration.map { CMTimeConvertScale($0, timescale: 48_000, method: .default).value }
                    == min(grid.segmentFrames, grid.totalFrames - start.value), "segment \(at)")
            segments[at] = segment.data
        }
        #expect(segments.keys.sorted() == Array(index - (early ? 1 : 0)..<grid.segmentCount))
        self.segments = segments
    }

    func fragments(_ indices: ClosedRange<Int>) throws -> [Int: Data] {
        try Dictionary(uniqueKeysWithValues: indices.map { ($0, try #require(segments[$0])) })
    }
}

/// Plays the grid's media playlist, served with `segments`, from `start` until `end` and reports
/// how far `AVPlayer` got and how often it stopped playing on the way.
@available(macOS 26, iOS 26, tvOS 26, *)
@MainActor
private func playThrough(grid: APACSegmentGrid, initialization: Data, segments: [Int: Data],
                         from start: Double, until end: Double) async throws -> (reached: Double, stalls: Int) {
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
    let player = AVPlayer(playerItem: item)
    player.volume = 0
    for _ in 0..<200 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
    try #require(item.status == .readyToPlay, "\(String(describing: item.error))")
    await player.seek(to: CMTime(seconds: start, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    player.play()
    // A stall is a return to waiting after playback began; reaching the item's end pauses instead.
    var playing = false, stalls = 0
    for _ in 0..<600 where player.currentTime().seconds < end {
        try await Task.sleep(for: .milliseconds(25))
        switch player.timeControlStatus {
        case .playing: playing = true
        case .waitingToPlayAtSpecifiedRate where playing: (playing, stalls) = (false, stalls + 1)
        default: break
        }
    }
    let reached = player.currentTime().seconds
    player.pause()
    #expect(item.error == nil)
    return (reached, stalls)
}

@Suite(.serialized)
struct HLSPresentationTests {
    /// `APACStream` serves fragments from several conversion runs on one playlist: a run restarted at
    /// a seek, whose first fragment carries the encoder priming, and a helper that starts a segment
    /// early so its first served fragment plays on from the run before it. Across those joins each
    /// click must decode at its source time, and `AVPlayer` must play on without stopping.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.timeLimit(.minutes(3)), arguments: [SpatialAudioLayout.sevenOneFour, .nineOneSix])
    func restartedRunsJoinOnTheGrid(layout: SpatialAudioLayout) async throws {
        let grid = try APACSegmentGrid(duration: CMTime(value: 3 * 153_600 + 20_000, timescale: 48_000),
                                       configuration: APACConfiguration(layout: layout))
        let segment = Int(grid.segmentFrames), priming = Int(grid.primingFrames), channels = layout.channelCount
        let join = 2 * segment
        // Near the start; either side of segment 2's start, the second where a restart's priming
        // replaces the audio and both in the restarted run's discarded pre-roll; after the
        // restarted run's first presented sample; in the shortened last segment.
        let clicks = [12_000, join - 3_000, join + 1_000, join + priming + 12_000, 3 * segment + 10_000]
        let continuous = try await GridRun(grid: grid, from: 0, clicks: clicks)
        let restarted = try await GridRun(grid: grid, from: 2, preRoll: 9_600, clicks: clicks)
        let helper = try await GridRun(grid: grid, from: 2, early: true, clicks: clicks)
        let initialization = continuous.initialization
        let played = try continuous.fragments(0...3)
        let helped = try continuous.fragments(0...1).merging(try helper.fragments(2...3)) { $1 }
        let resumed = try restarted.fragments(2...3)
        let sought = try continuous.fragments(0...1).merging(resumed) { $1 }

        // What playback presents, read as one file from its first fragment: from the start, on from
        // the first run into the helper's segments, and from a seek to the restarted run. The reader
        // starts at the first fragment's presented audio, after the priming.
        let reads: [(String, [Int: Data], Int)] = [("continuous", played, priming), ("helper join", helped, priming),
                                                   ("seek", resumed, join + priming)]
        for (name, fragments, start) in reads {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("join-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            // A file reader, unlike HLS, needs fragment sequence numbers to increase across runs.
            var file = initialization
            for (sequence, index) in fragments.keys.sorted().enumerated() {
                var fragment = try #require(fragments[index])
                let at = try #require(fragment.range(of: Data("mfhd".utf8))).upperBound + 4
                fragment.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: UInt32(sequence + 1).bigEndian) { Data($0) })
                file.append(fragment)
            }
            try file.write(to: url)
            let decoded = try await readPresentedAudio(url, layout: layout)
            try #require(decoded.frames == Int(grid.totalFrames) - start, "\(name): presented duration")
            let expected = clicks.filter { $0 >= start }
            for click in expected {
                let frame = try decoded.clickFrame(in: (click - start - 2_400)..<(click - start + 2_400)) + start
                // One millisecond tolerates lossy impulse shaping, but not a packet or priming shift.
                #expect(abs(frame - click) <= 48, "\(name): click at \(click) decoded at \(frame)")
            }
            // Detects leaked pre-roll, audio from the wrong run or a click repeated across a join.
            let ringing = expected.map { ($0 - start - 2_400)..<($0 - start + 2_400) }
            var quietPeak: Float = 0
            for frame in 0..<decoded.frames where !ringing.contains(where: { $0.contains(frame) }) {
                quietPeak = max(quietPeak, abs(decoded.samples[frame * channels]))
            }
            #expect(quietPeak < 0.01, "\(name): no other clicks")
        }

        // AVPlayer plays the joined playlist through each join without failing or waiting.
        let joinTime = Double(join) / 48_000
        let playbacks: [(String, [Int: Data], Double, Double)] = [("helper join", helped, joinTime - 0.5, joinTime + 1),
                                                                  ("seek", sought, joinTime, grid.end.seconds - 0.05)]
        for (name, segments, start, end) in playbacks {
            let playback = try await playThrough(grid: grid, initialization: initialization, segments: segments,
                                                 from: start, until: end)
            print("HLS playback \(layout), \(name): from \(start) s reached \(playback.reached) s, stalls \(playback.stalls)")
            #expect(playback.reached >= end, "\(name): AVPlayer must play through the join")
            #expect(playback.stalls == 0, "\(name): AVPlayer must not wait at the join")
        }
    }
}
