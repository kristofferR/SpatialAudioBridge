import AVFoundation
import Foundation
import Testing
@testable import SpatialAudioBridge

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

/// The base media decode time and sample count of a single-fragment segment.
private func fragmentTiming(_ data: Data) throws -> (decodeTime: UInt64, frames: Int) {
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
    private func open() async throws -> MatroskaFile {
        try await MatroskaFile.open(FileByteSource(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"]!)))
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(url.lastPathComponent)")
        return data
    }

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

    /// A paused player stops requesting; conversion must wait instead of running past what it keeps.
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
