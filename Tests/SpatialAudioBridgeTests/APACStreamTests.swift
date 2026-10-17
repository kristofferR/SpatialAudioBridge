import AVFoundation
import Foundation
import Network
import Testing
@testable import SpatialAudioBridge

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func mediaPlaylistListsFixedSegmentsAndAShorterLastOne() {
    let playlist = HLSPlaylists.media(totalFrames: 153_600 * 2 + 4_800, segmentFrames: 153_600, rate: 48_000)
    let lines = playlist.split(separator: "\n")
    #expect(lines.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    #expect(lines.contains("#EXT-X-TARGETDURATION:4"))
    #expect(lines.contains("#EXT-X-MAP:URI=\"init.mp4\""))
    #expect(lines.filter { $0.hasPrefix("#EXTINF:") } == ["#EXTINF:3.200000,", "#EXTINF:3.200000,", "#EXTINF:0.100000,"])
    #expect(lines.filter { !$0.hasPrefix("#") } == ["seg0.m4s", "seg1.m4s", "seg2.m4s"])
    #expect(lines.last == "#EXT-X-ENDLIST")
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func masterPlaylistReplacesAudioAndKeepsVideoAbsolute() {
    let upstream = """
    #EXTM3U
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",URI="audio/aac.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs/en.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=20000000,AVERAGE-BANDWIDTH=15000000,CODECS="hvc1.2.4.L153.B0,mp4a.40.2",RESOLUTION=3840x2160,AUDIO="aac",SUBTITLES="subs"
    main.m3u8?MediaSourceId=abc&api_key=key
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000000,CODECS="hvc1.2.4.L153.B0",URI="iframes.m3u8"
    #EXT-X-IMAGE-STREAM-INF:BANDWIDTH=7480,RESOLUTION=320x132,CODECS="jpeg",URI="Trickplay/320/tiles.m3u8?x=1"
    """
    let base = URL(string: "http://server:8096/videos/42/master.m3u8?x=1")!
    let rendition = HLSPlaylists.rendition(name: "Atmos \"9.1.6\"", language: "en", channels: 16)
    let master = HLSPlaylists.master(rewriting: upstream, baseURL: base, rendition: rendition, codec: "apac.31.04", bitRate: 4_096_000)
    let lines = master.split(separator: "\n").map(String.init)
    #expect(lines[1] == #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="spatial-audio",NAME="Atmos '9.1.6'",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="16",URI="audio.m3u8""#)
    #expect(!master.contains("aac.m3u8"))
    #expect(lines.contains(#"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="http://server:8096/videos/42/subs/en.m3u8""#))
    let variant = try! #require(lines.first { $0.hasPrefix("#EXT-X-STREAM-INF:") })
    #expect(HLSPlaylists.attribute("CODECS", in: variant) == "hvc1.2.4.L153.B0,apac.31.04")
    #expect(HLSPlaylists.attribute("AUDIO", in: variant) == "spatial-audio")
    #expect(HLSPlaylists.attribute("BANDWIDTH", in: variant) == "24096000")
    #expect(HLSPlaylists.attribute("AVERAGE-BANDWIDTH", in: variant) == "19096000")
    #expect(HLSPlaylists.attribute("SUBTITLES", in: variant) == "subs")
    #expect(lines.contains("http://server:8096/videos/42/main.m3u8?MediaSourceId=abc&api_key=key"))
    #expect(lines.contains(#"#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000000,CODECS="hvc1.2.4.L153.B0",URI="http://server:8096/videos/42/iframes.m3u8""#))
    #expect(lines.contains(#"#EXT-X-IMAGE-STREAM-INF:BANDWIDTH=7480,RESOLUTION=320x132,CODECS="jpeg",URI="http://server:8096/videos/42/Trickplay/320/tiles.m3u8?x=1""#))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func masterPlaylistLeavesOutRejectedVariants() {
    let upstream = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=128000,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.B0,mp4a.40.2"
    main.m3u8?AllowVideoStreamCopy=true
    #EXT-X-STREAM-INF:BANDWIDTH=128000,VIDEO-RANGE=SDR,CODECS="avc1.424029,mp4a.40.2"
    main.m3u8?VideoCodec=h264&AllowVideoStreamCopy=false
    """
    let master = HLSPlaylists.master(rewriting: upstream, baseURL: URL(string: "http://server/videos/42/master.m3u8")!,
                                     rendition: HLSPlaylists.rendition(name: "Atmos", language: nil, channels: 16),
                                     codec: "apac.31.04", bitRate: 4_096_000,
                                     includesVariant: { $0.query?.contains("AllowVideoStreamCopy=true") == true })
    #expect(master.components(separatedBy: "#EXT-X-STREAM-INF:").count == 2)
    #expect(master.contains("http://server/videos/42/main.m3u8?AllowVideoStreamCopy=true"))
    #expect(!master.contains("avc1"))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func masterPlaylistAddsNoCodecsToAVariantWithout() {
    let upstream = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=42000000\nmain.m3u8\n"
    let master = HLSPlaylists.master(rewriting: upstream, baseURL: URL(string: "http://server/master.m3u8")!,
                                     rendition: HLSPlaylists.rendition(name: "Atmos", language: nil, channels: 16),
                                     codec: "apac.31.04", bitRate: 4_096_000)
    #expect(!master.contains("CODECS"))
    #expect(master.contains("AUDIO="))
}

/// The transcoder times audio by its samples, so a gap or reset in packet times must end a run.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test func timestampGapsAndResetsBreakContinuity() {
    func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1000) }
    #expect(SpatialAudioTranscoder.continues(from: at(10), to: at(10.04), frames: 1, codec: .trueHDAtmos))
    #expect(!SpatialAudioTranscoder.continues(from: at(10), to: at(11), frames: 1, codec: .trueHDAtmos))
    #expect(!SpatialAudioTranscoder.continues(from: at(10), to: at(0), frames: 1, codec: .trueHDAtmos))
    // Laced frames share their block's time, so after 48 laced DTS frames the next block is 0.51 s on.
    #expect(SpatialAudioTranscoder.continues(from: at(10), to: at(10.512), frames: 48, codec: .dtsX))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func transcoderFailsAtATimestampJump() async throws {
    let transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos,
                                                destination: .segments(syncPeriodsPerSegment: 2, onSegment: { _ in }))
    try await transcoder.append(Data([0]), time: .zero)
    await #expect {
        try await transcoder.append(Data([0]), time: CMTime(seconds: 5, preferredTimescale: 1))
    } throws: { error in
        if case SpatialAudioError.discontinuity = error { true } else { false }
    }
    // The failure ends the session.
    await #expect(throws: SpatialAudioError.self) { try await transcoder.append(Data([0])) }
}

/// The stream's playlist follows the container, which may outlast the audio track. A run that
/// starts past the track's end decodes nothing and must still fill the remaining segments.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test func finishPadsWithSilenceToTheEndOnTheGrid() async throws {
    let priming = try APACConfiguration().encoderPrimingDuration().value
    final class Fragments: @unchecked Sendable {
        let lock = NSLock()
        var timings: [[Int64]] = []
    }
    let fragments = Fragments()
    let transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .segments(onSegment: { segment in
        guard let start = segment.startTime, let duration = segment.duration else { return }
        let frames = [start, duration].map { CMTimeConvertScale($0, timescale: 48_000, method: .default).value }
        fragments.lock.withLock { fragments.timings.append(frames) }
    }), configuration: APACConfiguration(startTime: CMTime(value: 153_600 + priming, timescale: 48_000), liveEncoding: true))
    let report = try await transcoder.finish(paddingTo: CMTime(value: 153_600 * 2 + 4_800, timescale: 48_000))
    #expect(report.sampleFrames == 153_600 + 4_800 - priming)
    #expect(fragments.lock.withLock { fragments.timings } == [[153_600, 153_600], [307_200, 4_800]])
    // An end too far to count in frames fails instead of trapping.
    let unbounded = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .segments(onSegment: { _ in }),
                                               configuration: APACConfiguration(liveEncoding: true))
    await #expect(throws: SpatialAudioError.self) {
        try await unbounded.finish(paddingTo: CMTime(seconds: -1e12, preferredTimescale: 1))
    }
}

/// HTTP/1.1 lets a client send its next request before the previous response arrives.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test(.timeLimit(.minutes(1))) func loopbackServerAnswersPipelinedRequests() async throws {
    let server = try await LoopbackServer { path in .init(status: 200, body: Data(path.utf8)) }
    defer { server.stop() }
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
    connection.start(queue: .global())
    defer { connection.cancel() }
    let requests = "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\nGET /b HTTP/1.1\r\nHost: localhost\r\n\r\n"
    connection.send(content: Data(requests.utf8), completion: .idempotent)
    var received = ""
    while received.components(separatedBy: "HTTP/1.1 200").count < 3 || !received.hasSuffix("/b") {
        let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
        guard let chunk, !chunk.isEmpty else { break }
        received += String(decoding: chunk, as: UTF8.self)
    }
    #expect(received.components(separatedBy: "HTTP/1.1 200").count == 3)
    #expect(received.hasSuffix("/b"))
}

/// After a seek, AVPlayer allows about 3 s for the first segment and requests every scrub
/// position; only segments the current run will reach within about two conversions are worth waiting for.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test func requestsWaitOnlyForSegmentsTheRunReachesSoon() {
    // A fresh run at 10 has converted nothing yet.
    #expect(StreamEngine.waits(for: 10, runStart: 10, converted: -1, ended: false))
    #expect(StreamEngine.waits(for: 11, runStart: 10, converted: -1, ended: false))
    #expect(!StreamEngine.waits(for: 12, runStart: 10, converted: -1, ended: false))
    #expect(!StreamEngine.waits(for: 9, runStart: 10, converted: -1, ended: false))
    // A run that has converted through 15.
    #expect(StreamEngine.waits(for: 17, runStart: 10, converted: 15, ended: false))
    #expect(!StreamEngine.waits(for: 18, runStart: 10, converted: 15, ended: false))
    #expect(!StreamEngine.waits(for: 14, runStart: 10, converted: 15, ended: false), "passed and dropped: restart")
    #expect(!StreamEngine.waits(for: 16, runStart: 10, converted: 15, ended: true))
}

/// After a start inside a video segment, AVPlayer may first ask for audio from that segment's
/// start; the run at the start time carries on as the helper instead of being replaced.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test func aRestartShortlyBehindARunKeepsIt() {
    #expect(StreamEngine.keepsAhead(5, runStart: 10, lookahead: 6, ended: false))
    #expect(StreamEngine.keepsAhead(4, runStart: 10, lookahead: 6, ended: false))
    #expect(!StreamEngine.keepsAhead(3, runStart: 10, lookahead: 6, ended: false), "beyond what the store keeps")
    #expect(!StreamEngine.keepsAhead(5, runStart: 10, lookahead: 6, ended: true))
    #expect(!StreamEngine.keepsAhead(10, runStart: 10, lookahead: 6, ended: false))
    #expect(!StreamEngine.keepsAhead(12, runStart: 10, lookahead: 6, ended: false))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func segmentStoreRecordsCleanEndsAndFailures() {
    let store = SegmentStore()
    let clean = UUID(), failed = UUID(), running = UUID()
    store.end(run: clean, failure: nil)
    store.end(run: failed, failure: SpatialAudioError.decoding("bad"))
    #expect(store.ended(run: clean) && store.failure(run: clean) == nil)
    #expect(store.ended(run: failed) && store.failure(run: failed) != nil)
    #expect(!store.ended(run: running))
}

@available(macOS 26, iOS 26, tvOS 26, *)
private func mediaSegment(_ index: Int) -> APACSegment {
    APACSegment(kind: .media, data: Data([UInt8(index)]), startTime: CMTime(value: Int64(index) * 153_600, timescale: 48_000),
                duration: CMTime(value: 153_600, timescale: 48_000))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func segmentStoreKeepsRecentSegmentsBehindTheRequest() {
    let store = SegmentStore()
    let run = UUID()
    store.begin(run: run, first: 0)
    for index in 0..<40 { store.deliver(mediaSegment(index), run: run, segmentFrames: 153_600) }
    store.keep(around: 30, behind: 20, ahead: 6)
    #expect(store.segment(9) == nil)
    #expect(store.segment(10) != nil)
    #expect(store.segment(38) != nil)
    #expect(store.segment(39) == nil)
}

/// A run kept behind a restart must not bring back its primed first segment, even one it has yet
/// to emit, and measures its speed from the restart.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test func segmentStoreRebasesAKeptRun() {
    let store = SegmentStore()
    let early = UUID(), advanced = UUID()
    store.begin(run: early, first: 10)
    #expect(store.rebase(run: early, from: 11, lookahead: 6))
    for index in 10...11 { store.deliver(mediaSegment(index), run: early, segmentFrames: 153_600) }
    #expect(store.segment(10) == nil, "the kept run's primed segment")
    #expect(store.segment(11) != nil && store.highest(run: early) == 11)
    store.begin(run: advanced, first: 20)
    for index in 20...26 { store.deliver(mediaSegment(index), run: advanced, segmentFrames: 153_600) }
    store.drop(20)
    #expect(store.rebase(run: advanced, from: 21, lookahead: 6))
    #expect(store.highest(run: advanced) == 26, "what it converted still counts for the hand-over")
    #expect(store.speed(run: advanced, segmentFrames: 153_600) == nil, "no conversion since the restart yet")
    store.deliver(mediaSegment(27), run: advanced, segmentFrames: 153_600)
    #expect(store.segment(20) == nil && store.segment(26) != nil && store.segment(27) != nil)
    #expect(store.speed(run: advanced, segmentFrames: 153_600) != nil)
}

/// Rebasing uses the latest progress, including callbacks that advanced past the new cache window.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test(arguments: [-1, 16, 19, 20, 100])
func segmentStoreRebasesOnlyRunsWithinTheNewCacheWindow(produced: Int) {
    let store = SegmentStore()
    let run = UUID()
    store.begin(run: run, first: 10)
    if produced >= 10 {
        for index in 10...produced { store.deliver(mediaSegment(index), run: run, segmentFrames: 153_600) }
    }
    #expect(store.rebase(run: run, from: 11, lookahead: 6) == (produced < 20))
    #expect(store.highest(run: run) == produced)
    #expect((store.speed(run: run, segmentFrames: 153_600) == nil) == (produced < 20),
            "a rejected rebase leaves progress unchanged")
}

/// Retention needs the audio at the join, not just the run's original start and high-water mark.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test func segmentStoreRejectsAMissingJoinWithoutRebasing() {
    let store = SegmentStore()
    let run = UUID()
    store.begin(run: run, first: 10)
    for index in 10...16 { store.deliver(mediaSegment(index), run: run, segmentFrames: 153_600) }
    store.drop(11)
    #expect(!store.rebase(run: run, from: 11, lookahead: 6), "the run cannot recreate an evicted join")
    #expect(store.speed(run: run, segmentFrames: 153_600) != nil)
    store.deliver(mediaSegment(11), run: run, segmentFrames: 153_600)
    #expect(store.segment(11) != nil, "a rejected rebase still accepts the run's earlier fragments")
    #expect(store.rebase(run: run, from: 11, lookahead: 6))
    #expect(store.speed(run: run, segmentFrames: 153_600) == nil)
}

/// A helper run's first fragment carries encoder priming, and a retired run may still emit one.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test func segmentStoreTakesEachRunFromItsFirstSegmentUntilRetired() {
    let store = SegmentStore()
    let run = UUID(), helper = UUID()
    store.begin(run: run, first: 10)
    store.begin(run: helper, first: 15)
    for index in 10...12 { store.deliver(mediaSegment(index), run: run, segmentFrames: 153_600) }
    for index in 14...16 { store.deliver(mediaSegment(index), run: helper, segmentFrames: 153_600) }
    #expect(store.segment(14) == nil, "the helper's priming fragment")
    #expect(store.segment(15) != nil && store.highest(run: helper) == 16)
    #expect(store.highest(run: run) == 12)
    store.retire(run: run)
    store.deliver(mediaSegment(13), run: run, segmentFrames: 153_600)
    #expect(store.segment(13) == nil && store.highest(run: run) == -1)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func loopbackServerAnswersGetsRangesAndUnknownPaths() async throws {
    let body = Data((0..<100).map { UInt8($0) })
    let server = try await LoopbackServer { path in
        path == "/file" ? .init(status: 200, contentType: "application/octet-stream", body: body) : .notFound()
    }
    defer { server.stop() }
    let url = URL(string: "http://127.0.0.1:\(server.port)/file")!
    let (data, response) = try await URLSession.shared.data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(data == body)
    var ranged = URLRequest(url: url)
    ranged.setValue("bytes=10-19", forHTTPHeaderField: "Range")
    let (part, partial) = try await URLSession.shared.data(for: ranged)
    #expect((partial as? HTTPURLResponse)?.statusCode == 206)
    #expect((partial as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes 10-19/100")
    #expect(part == body.subdata(in: 10..<20))
    let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)/missing")!)
    #expect((missing as? HTTPURLResponse)?.statusCode == 404)
}

/// A failing server may recover, so its errors fail like the network and a stream retries them;
/// a rejection repeats on every request and ends the stream.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test func httpSourceTellsServerErrorsFromRejections() async throws {
    let server = try await LoopbackServer { path in path == "/busy" ? .init(status: 503) : .notFound() }
    defer { server.stop() }
    let base = "http://127.0.0.1:\(server.port)"
    await #expect(throws: URLError.self) { try await HTTPByteSource(url: URL(string: "\(base)/busy")!).read(0..<10) }
    await #expect(throws: SpatialAudioError.self) { try await HTTPByteSource(url: URL(string: "\(base)/missing")!).read(0..<10) }
}

/// URLSession names the request URL in its errors, which may carry a media server's key, and the
/// stream logs read failures publicly.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test func httpSourceErrorsLeaveTheURLOut() async throws {
    let server = try await LoopbackServer { _ in .notFound() }
    let port = server.port
    server.stop()
    let url = URL(string: "http://127.0.0.1:\(port)/stream?ApiKey=secret-token")!
    let error = await #expect(throws: URLError.self) { try await HTTPByteSource(url: url).read(0..<10) }
    #expect(error.map { !String(describing: $0).contains("secret-token") } == true)
}

/// The base media decode time and sample count of a single-fragment segment.
@available(macOS 26, iOS 26, tvOS 26, *)
func fragmentTiming(_ data: Data) throws -> (decodeTime: UInt64, frames: Int) {
    var decodeTime: UInt64?, packets = 0
    func walk(_ range: Range<Int>) {
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size = Int(data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) })
            let kind = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            guard size >= 8, offset + size <= range.upperBound else { return }
            if ["moof", "traf"].contains(kind) { walk(offset + 8..<offset + size) }
            if kind == "tfdt" {
                let version = data[offset + 8]
                let field = data[offset + 12..<offset + (version == 1 ? 20 : 16)]
                decodeTime = field.reduce(0) { $0 << 8 | UInt64($1) }
            }
            if kind == "trun" { packets += Int(data[offset + 12..<offset + 16].reduce(0) { $0 << 8 | UInt32($1) }) }
            offset += size
        }
    }
    walk(0..<data.count)
    return (try #require(decodeTime), packets * 1024)
}

@available(macOS 26, iOS 26, tvOS 26, *)
private func decodedMono(_ segments: [Data]) async throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString).mp4")
    try segments.reduce(Data(), +).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
    reader.add(output)
    #expect(reader.startReading())
    var mono: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        let block = try #require(CMSampleBufferGetDataBuffer(buffer))
        var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        for frame in stride(from: 0, to: samples.count, by: 16) { mono.append(samples[frame..<frame + 16].reduce(0, +)) }
    }
    return mono
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"] != nil))
struct APACStreamFixtureTests {
    @available(macOS 26, iOS 26, tvOS 26, *)
    private func open() async throws -> MatroskaFile {
        try await MatroskaFile.open(FileByteSource(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"]!)))
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(url.lastPathComponent)")
        return data
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func segmentsLieOnTheGridAndARestartReproducesThem() async throws {
        let stream = try await APACStream.start(file: try await open())
        let base = stream.audioPlaylistURL.deletingLastPathComponent()
        let playlist = String(decoding: try await get(stream.audioPlaylistURL), as: UTF8.self)
        let names = playlist.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(names.count == 19) // 58.06 s in 3.2-second segments
        let initial = try await get(base.appendingPathComponent("init.mp4"))
        var continuous: [Int: Data] = [:]
        for index in 0...3 { continuous[index] = try await get(base.appendingPathComponent("seg\(index).m4s")) }
        // Jump ahead and back: both force new conversion runs.
        let far = try await get(base.appendingPathComponent("seg15.m4s"))
        let restarted = try await get(base.appendingPathComponent("seg3.m4s"))
        await stream.stop()
        for (index, data) in continuous.map({ ($0.key, $0.value) }) + [(15, far), (3, restarted)] {
            let timing = try fragmentTiming(data)
            #expect(timing.decodeTime == UInt64(index) * 153_600, "segment \(index)")
            #expect(timing.frames == 153_600, "segment \(index)")
        }
        // The restarted fragment starts with encoder priming, then matches the continuous one.
        let a = try await decodedMono([initial, continuous[3]!]), b = try await decodedMono([initial, restarted])
        #expect(a.count == b.count)
        var dot = 0.0, energyA = 0.0, energyB = 0.0
        for i in 4096..<min(a.count, b.count) {
            dot += Double(a[i]) * Double(b[i]); energyA += Double(a[i] * a[i]); energyB += Double(b[i] * b[i])
        }
        #expect(dot / sqrt(energyA * energyB) > 0.99, "restarted audio must be sample-aligned with continuous audio")
    }

    /// The helper run converts segment 5 onward from the start. Its segment must play on from
    /// segment 4 without the 42.7 ms of priming a restarted run's first segment carries.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func helperSegmentsMatchContinuousConversionFromTheirFirstSample() async throws {
        let file = try await open()
        let stream = try await APACStream.start(file: file)
        let base = stream.audioPlaylistURL.deletingLastPathComponent()
        let initial = try await get(base.appendingPathComponent("init.mp4"))
        let helped = try await get(base.appendingPathComponent("seg5.m4s"))
        await stream.stop()
        // The same segment from one run through the file, as steady playback converts it.
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var segments: [Int: Data] = [:]
        }
        let collector = Collector()
        let track = try #require(file.audioTracks.first { $0.codec == .trueHDAtmos })
        let priming = try APACConfiguration().encoderPrimingDuration()
        var transcoder: SpatialAudioTranscoder?
        for try await packet in file.packets(of: track, from: priming) {
            if packet.time.seconds > 22 { break }
            if transcoder == nil {
                var configuration = APACConfiguration(startTime: priming, liveEncoding: true)
                configuration.inputStartTime = packet.time
                transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .segments(onSegment: { segment in
                    guard let start = segment.startTime else { return }
                    collector.lock.withLock { collector.segments[Int(start.value * 48_000 / Int64(start.timescale)) / 153_600] = segment.data }
                }), configuration: configuration)
            }
            try await transcoder?.append(packet.data)
        }
        _ = try await transcoder?.finish()
        let (previous, continuous) = try collector.lock.withLock {
            (try #require(collector.segments[4]), try #require(collector.segments[5]))
        }
        #expect(try fragmentTiming(helped).decodeTime == 5 * 153_600)
        // Played on from segment 4, as AVPlayer does. Decoding trims priming only at the start, so
        // the join is where a restarted run's priming would replace 2048 frames of audio. A file
        // reader, unlike HLS, also needs the runs' fragment sequence numbers to continue.
        func renumbered(_ fragment: Data, after previous: Data) throws -> Data {
            let at = try #require(fragment.range(of: Data("mfhd".utf8))).upperBound + 4
            let sequence = try #require(previous.range(of: Data("mfhd".utf8))).upperBound + 4
            var result = fragment
            let next = previous[sequence..<sequence + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } + 1
            result.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: next.bigEndian) { Data($0) })
            return result
        }
        let a = try await decodedMono([initial, previous, continuous])
        let b = try await decodedMono([initial, previous, try renumbered(helped, after: previous)])
        let join = 153_600 - Int(priming.value)
        try #require(a.count > join + 2048 && b.count > join + 2048)
        var dot = 0.0, energyA = 0.0, energyB = 0.0
        for i in join..<join + 2048 {
            dot += Double(a[i]) * Double(b[i]); energyA += Double(a[i] * a[i]); energyB += Double(b[i] * b[i])
        }
        #expect(energyA > 1e-4, "the fixture has audio at 16 s")
        #expect(dot / sqrt(energyA * energyB) > 0.99, "the helper's segment must start with source audio")
    }

    /// AVPlayer may first ask for audio a few segments behind the start time. The run at the start
    /// carries on as the helper, so its segment 11 must play on from the new run's segment 10, and
    /// segment 10 must come from the new run, without the start run's priming.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func aRequestBehindTheStartKeepsTheStartRunAsHelper() async throws {
        let file = try await open()
        let stream = try await APACStream.start(file: file, startTime: CMTime(value: 10 * 153_600, timescale: 48_000))
        let base = stream.audioPlaylistURL.deletingLastPathComponent()
        let initial = try await get(base.appendingPathComponent("init.mp4"))
        var served: [Int: Data] = [:]
        for index in 6...12 { served[index] = try await get(base.appendingPathComponent("seg\(index).m4s")) }
        await stream.stop()
        for (index, data) in served {
            let timing = try fragmentTiming(data)
            #expect(timing.decodeTime == UInt64(index) * 153_600 && timing.frames == 153_600, "segment \(index)")
        }
        // The same segments from one run through the file, as steady playback converts them.
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var segments: [Int: Data] = [:]
        }
        let collector = Collector()
        let track = try #require(file.audioTracks.first { $0.codec == .trueHDAtmos })
        let priming = try APACConfiguration().encoderPrimingDuration()
        var transcoder: SpatialAudioTranscoder?
        for try await packet in file.packets(of: track, from: priming) {
            if packet.time.seconds > 42 { break }
            if transcoder == nil {
                var configuration = APACConfiguration(startTime: priming, liveEncoding: true)
                configuration.inputStartTime = packet.time
                transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .segments(onSegment: { segment in
                    guard let start = segment.startTime else { return }
                    collector.lock.withLock { collector.segments[Int(start.value * 48_000 / Int64(start.timescale)) / 153_600] = segment.data }
                }), configuration: configuration)
            }
            try await transcoder?.append(packet.data)
        }
        _ = try await transcoder?.finish()
        let continuous = collector.lock.withLock { collector.segments }
        // Read from segment 9 on, so neither priming trim at the start nor sequence numbers
        // differ: both sides decode the same segment 9 first.
        func renumbered(_ fragments: [Data]) throws -> [Data] {
            var result: [Data] = []
            for fragment in fragments {
                guard let previous = result.last else { result.append(fragment); continue }
                let at = try #require(fragment.range(of: Data("mfhd".utf8))).upperBound + 4
                let sequence = try #require(previous.range(of: Data("mfhd".utf8))).upperBound + 4
                var next = fragment
                let number = previous[sequence..<sequence + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } + 1
                next.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: number.bigEndian) { Data($0) })
                result.append(next)
            }
            return result
        }
        let reference = try [9, 10, 11].map { try #require(continuous[$0]) }
        let a = try await decodedMono([initial] + reference)
        let b = try await decodedMono([initial] + (try renumbered([continuous[9]!, served[10]!, served[11]!])))
        try #require(a.count == b.count)
        // Both joins: into the new run's segment 10, and on into the kept run's segment 11.
        for join in [153_600 - Int(priming.value), 2 * 153_600 - Int(priming.value)] {
            var dot = 0.0, energyA = 0.0, energyB = 0.0
            for i in join..<join + 4096 {
                dot += Double(a[i]) * Double(b[i]); energyA += Double(a[i] * a[i]); energyB += Double(b[i] * b[i])
            }
            #expect(energyA > 1e-4, "the fixture has audio at \(join)")
            #expect(dot / sqrt(energyA * energyB) > 0.99, "audio at the join \(join) must follow the source")
        }
    }

    /// A paused player stops requesting; conversion must wait instead of running past what it keeps.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func conversionHoldsAtTheLookaheadUntilPlaybackCatchesUp() async throws {
        var options = APACStream.Options()
        options.lookahead = 2
        options.segmentTimeout = .seconds(10)
        let stream = try await APACStream.start(file: try await open(), options: options)
        let base = stream.audioPlaylistURL.deletingLastPathComponent()
        // Unpaced, conversion would pass segment 6 within this pause even on a slow Mac.
        try await Task.sleep(for: .seconds(6))
        #expect(await stream.engine.converted <= 2)
        for index in 1...4 { _ = try await get(base.appendingPathComponent("seg\(index).m4s")) }
        #expect(await stream.engine.converted <= 6)
        await stream.stop()
    }

    /// A request served from the cache must not hold conversion back from a request waiting further ahead.
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func cachedRequestsKeepConvertingForAWaitingRequest() async throws {
        var options = APACStream.Options()
        options.lookahead = 2
        options.segmentTimeout = .seconds(10)
        let stream = try await APACStream.start(file: try await open(), options: options)
        let base = stream.audioPlaylistURL.deletingLastPathComponent()
        // Conversion holds at segment 2, close enough for a request for segment 4 to wait.
        while await stream.engine.converted < 2 { try await Task.sleep(for: .milliseconds(50)) }
        async let ahead = get(base.appendingPathComponent("seg4.m4s"))
        try await Task.sleep(for: .milliseconds(100))
        _ = try await get(base.appendingPathComponent("seg1.m4s"))
        _ = try await ahead
        await stream.stop()
        // A stopped stream refuses requests that were already on their way.
        await #expect(throws: StreamError.self) { try await stream.engine.segment(5) }
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func avPlayerPlaysAndSeeksTheStream() async throws {
        let stream = try await APACStream.start(file: try await open())
        let player = AVPlayer(url: stream.audioPlaylistURL)
        player.volume = 0
        player.play()
        func advances(past seconds: Double) async -> Bool {
            for _ in 0..<150 where player.currentTime().seconds < seconds { try? await Task.sleep(for: .milliseconds(100)) }
            return player.currentTime().seconds >= seconds
        }
        #expect(await advances(past: 1.5))
        await player.seek(to: CMTime(seconds: 40, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(await advances(past: 41.5))
        #expect(player.currentItem?.error == nil)
        player.pause()
        await stream.stop()
    }
}

/// The live profile emits each segment about one sync period (1.6 s) after its end; the offline
/// profile trails by about 20 s, which would stall every seek.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"] != nil))
func liveEncodingEmitsSegmentsSoonAfterTheirInput() async throws {
    let file = try await MatroskaFile.open(FileByteSource(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"]!)))
    let track = try #require(file.audioTracks.first { $0.codec == .trueHDAtmos })
    final class Lag: @unchecked Sendable {
        let lock = NSLock()
        var input = 0.0, worst = 0.0
    }
    let lag = Lag()
    let transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .segments(onSegment: { segment in
        guard segment.kind == .media, let start = segment.startTime, let duration = segment.duration else { return }
        lag.lock.withLock { lag.worst = max(lag.worst, lag.input - (start + duration).seconds) }
    }), configuration: APACConfiguration(liveEncoding: true))
    for try await packet in file.packets(of: track) {
        if packet.time.seconds > 30 { break }
        try await transcoder.append(packet.data)
        lag.lock.withLock { lag.input = packet.time.seconds }
    }
    _ = try await transcoder.finish()
    // A loaded machine delays the writer's callbacks, so allow margin above 1.6 s.
    #expect(lag.lock.withLock { lag.worst } < 5.0, "segments must follow their input by about one sync period")
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func masterPlaylistRoutesSubtitleRenditions() {
    let upstream = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="42/Subtitles/3/subtitles.m3u8?SegmentLength=30&ApiKey=key"
    #EXT-X-STREAM-INF:BANDWIDTH=42000000,SUBTITLES="subs"
    main.m3u8
    """
    var routed: [URL] = []
    let master = HLSPlaylists.master(rewriting: upstream, baseURL: URL(string: "http://server/Videos/42/master.m3u8")!,
                                     rendition: HLSPlaylists.rendition(name: "Atmos", language: nil, channels: 12),
                                     codec: "apac.31.03", bitRate: 3_072_000,
                                     subtitleURI: { routed.append($0); return "subtitles/\(routed.count - 1).m3u8" })
    #expect(routed == [URL(string: "http://server/Videos/42/42/Subtitles/3/subtitles.m3u8?SegmentLength=30&ApiKey=key")!])
    #expect(master.contains(#"NAME="English",URI="subtitles/0.m3u8""#))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test(.timeLimit(.minutes(1))) func subtitleProxyMovesWebVTTCuesOntoTheZeroBasedTimeline() async throws {
    // Jellyfin's WebVTT segments map cue 0 to MPEG-TS 10 s, which is right for its MPEG-TS output only.
    let upstream = try await LoopbackServer { path in
        switch path {
        case "/subs/subtitles.m3u8":
            .init(status: 200, body: Data("#EXTM3U\n#EXT-X-TARGETDURATION:30\n#EXTINF:30.0,\nstream.vtt?StartPositionTicks=0\n#EXTINF:30.0,\nimsc.m4s\n#EXT-X-BYTERANGE:400@0\n#EXTINF:30.0,\nranged.vtt\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:30.0,\nsealed.vtt\n#EXT-X-ENDLIST\n".utf8))
        case "/subs/stream.vtt":
            .init(status: 200, body: Data("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n00:01:59.161 --> 00:02:01.000\nHello\n".utf8))
        default: .notFound()
        }
    }
    defer { upstream.stop() }
    let proxy = SubtitleProxy()
    #expect(proxy.route(URL(string: "http://127.0.0.1:\(upstream.port)/subs/subtitles.m3u8")!) == "subtitles/0.m3u8")
    let playlist = String(decoding: try await proxy.respond(to: "0.m3u8").body, as: UTF8.self)
    // Only whole, clear WebVTT segments go through the proxy; IMSC1, byte ranges and encrypted segments load directly.
    let server = "http://127.0.0.1:\(upstream.port)/subs"
    #expect(playlist.split(separator: "\n").filter { !$0.hasPrefix("#") } == ["0/0.vtt", "\(server)/imsc.m4s", "\(server)/ranged.vtt", "\(server)/sealed.vtt"])
    let segment = String(decoding: try await proxy.respond(to: "0/0.vtt").body, as: UTF8.self)
    #expect(segment.contains("X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n"))
    #expect(segment.contains("00:01:59.161 --> 00:02:01.000\nHello"))
    #expect(try await proxy.respond(to: "0/1.vtt").status == 404)
    #expect(try await proxy.respond(to: "1.m3u8").status == 404)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func onlyJellyfinsWebVTTTimestampMapIsMoved() {
    #expect(HLSPlaylists.removingJellyfinTimestampOffset(in: "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000\n")
            == "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n")
    // A map whose local time already matches its MPEG-TS time has no offset to remove.
    let aligned = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:10.000,MPEGTS:900000\n"
    #expect(HLSPlaylists.removingJellyfinTimestampOffset(in: aligned) == aligned)
}
