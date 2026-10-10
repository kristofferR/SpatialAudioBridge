import CoreMedia
import Foundation
import os

/// Segment requests, restarts and wait times; visible in Console under this subsystem.
private let log = Logger(subsystem: "SpatialAudioBridge", category: "APACStream")

/// Plays a Matroska file's TrueHD Atmos or DTS:X track through AVPlayer as an APAC HLS rendition.
///
/// The stream serves a VOD playlist from the loopback interface and converts segments on demand,
/// so AVPlayer can seek anywhere. A request outside the converted range restarts conversion at
/// that segment. Every segment covers exactly two APAC sync periods on a fixed grid, so segments
/// from different conversion runs line up sample for sample.
///
/// ```swift
/// let file = try await MatroskaFile.open(HTTPByteSource(url: directPlayURL, headers: auth))
/// let stream = try await APACStream.start(file: file, videoMaster: serverVideoPlaylist)
/// player.replaceCurrentItem(with: AVPlayerItem(url: stream.masterPlaylistURL!))
/// ```
///
/// Native Atmos output also needs ``AtmosOutputActivator`` from SpatialAudioPlayback.
public final class APACStream: Sendable {
    public struct Options: Sendable {
        /// Layout, bitrate and sync interval. The stream manages the start times and always encodes live.
        public var configuration = APACConfiguration()
        /// The rendition name in the playlist and the player's audio menu.
        public var renditionName = "Spatial Audio"
        /// Segments converted ahead of the latest request, each about 3.2 seconds.
        public var lookahead = 6
        /// Segments kept behind the latest request, so skipping back plays from memory. Each
        /// segment holds about 1.6 MB at the default bit rate.
        public var keptBehind = 20
        /// How long a segment request waits for conversion before failing.
        public var segmentTimeout: Duration = .seconds(30)
        /// Chooses which of the video master's variants to offer, given each variant's playlist URL.
        /// Media servers often add transcoding fallbacks, which AVPlayer switches to when a segment
        /// is slow; Jellyfin's stream-copy variant is the one with `AllowVideoStreamCopy=true`.
        public var includesVideoVariant: @Sendable (URL) -> Bool = { _ in true }

        public init() {}
    }

    public let track: MatroskaAudioTrack
    /// The APAC rendition's media playlist, for audio-only playback.
    public let audioPlaylistURL: URL
    /// The video master's variants with the APAC rendition as their audio, when a video master was given.
    public let masterPlaylistURL: URL?
    public let renditionName: String
    private let server: LoopbackServer
    let engine: StreamEngine

    /// Starts serving `track` (by default the first convertible default track) and converts the
    /// segment containing `startTime`, failing early when the track cannot be converted.
    ///
    /// `videoMaster` is a multivariant playlist whose variants supply the video, such as a media
    /// server's HLS remux; it is fetched once with `videoHeaders`, and its own audio is replaced.
    /// `AVPlayer` then loads the variant playlists and video segments itself, without those
    /// headers, so their URLs must authenticate on their own, as Jellyfin's `ApiKey` parameter does.
    public static func start(file: MatroskaFile, track: MatroskaAudioTrack? = nil, videoMaster: URL? = nil,
                             videoHeaders: [String: String] = [:], startTime: CMTime = .zero,
                             options: Options = Options()) async throws -> APACStream {
        guard let track = track ?? file.audioTracks.first(where: { $0.codec != nil && $0.isDefault })
                ?? file.audioTracks.first(where: { $0.codec != nil }), let codec = track.codec else {
            throw SpatialAudioError.source("The file has no TrueHD or DTS track")
        }
        guard let duration = file.duration, duration.seconds > 0 else {
            throw SpatialAudioError.source("The file does not declare its duration")
        }
        var configuration = options.configuration
        guard (3...600).contains(configuration.syncPacketFrequency) else {
            throw SpatialAudioError.invalidConfiguration("The APAC sync interval must be 3 to 600 packets")
        }
        // The offline profile would delay every segment by about 20 s of audio.
        configuration.liveEncoding = true
        let segmentFrames = Int64(configuration.syncPacketFrequency * 1024 * StreamEngine.periods)
        let engine = StreamEngine(file: file, track: track, codec: codec, configuration: configuration,
                                  segmentFrames: segmentFrames,
                                  priming: Int64(try configuration.encoderPrimingDuration().value),
                                  totalFrames: Int64((duration.seconds * 48_000).rounded(.up)),
                                  lookahead: max(1, options.lookahead), keptBehind: max(2, options.keptBehind),
                                  timeout: options.segmentTimeout)
        var master: String?
        if let videoMaster {
            var request = URLRequest(url: videoMaster)
            for (field, value) in videoHeaders { request.setValue(value, forHTTPHeaderField: field) }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("#EXTM3U") else {
                throw SpatialAudioError.source("Could not load the video playlist")
            }
            let rendition = HLSPlaylists.rendition(name: options.renditionName, language: track.language,
                                                   channels: configuration.layout.channelCount)
            let rewritten = HLSPlaylists.master(rewriting: text, baseURL: videoMaster, rendition: rendition,
                                                codec: configuration.layout.apacCodecString, bitRate: configuration.bitRate,
                                                includesVariant: options.includesVideoVariant)
            guard rewritten.contains("#EXT-X-STREAM-INF:") else {
                throw SpatialAudioError.source("The video playlist has no variant to play")
            }
            master = rewritten
        }
        let token = UUID().uuidString.lowercased()
        let media = HLSPlaylists.media(totalFrames: engine.totalFrames, segmentFrames: segmentFrames, rate: 48_000)
        let server = try await LoopbackServer { [master] path in
            await Self.respond(to: path, token: token, master: master, media: media, engine: engine)
        }
        let base = URL(string: "http://127.0.0.1:\(server.port)/\(token)/")!
        let stream = APACStream(track: track, audioPlaylistURL: base.appendingPathComponent("audio.m3u8"),
                                masterPlaylistURL: master == nil ? nil : base.appendingPathComponent("master.m3u8"),
                                renditionName: options.renditionName, server: server, engine: engine)
        do {
            _ = try await engine.segment(engine.index(at: startTime))
        } catch {
            await stream.stop()
            throw error
        }
        return stream
    }

    private init(track: MatroskaAudioTrack, audioPlaylistURL: URL, masterPlaylistURL: URL?, renditionName: String,
                 server: LoopbackServer, engine: StreamEngine) {
        self.track = track
        self.audioPlaylistURL = audioPlaylistURL
        self.masterPlaylistURL = masterPlaylistURL
        self.renditionName = renditionName
        self.server = server
        self.engine = engine
    }

    deinit {
        // A stream released without stop() must not keep serving or converting.
        server.stop()
        Task { [engine] in await engine.stop() }
    }

    /// Audio converted per second spent converting since the latest start or seek, as a multiple
    /// of real time, excluding time held at the lookahead; nil before the first segment. Below
    /// about 1.2, playback will stall.
    public var conversionSpeed: Double? {
        get async { await engine.conversionSpeed }
    }

    /// Stops conversion and the server. Create a new stream to play again.
    public func stop() async {
        server.stop()
        await engine.stop()
    }

    private static func respond(to path: String, token: String, master: String?, media: String,
                                engine: StreamEngine) async -> LoopbackServer.Response {
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { return .notFound() }
        let name = String(path.dropFirst(prefix.count))
        let playlist = "application/vnd.apple.mpegurl"
        do {
            switch name {
            case "master.m3u8":
                guard let master else { return .notFound() }
                return .init(status: 200, contentType: playlist, body: Data(master.utf8))
            case "audio.m3u8":
                return .init(status: 200, contentType: playlist, body: Data(media.utf8))
            case "init.mp4":
                return .init(status: 200, contentType: "audio/mp4", body: try await engine.initialization())
            default:
                guard name.hasPrefix("seg"), name.hasSuffix(".m4s"),
                      let index = Int(name.dropFirst(3).dropLast(4)) else { return .notFound() }
                return .init(status: 200, contentType: "audio/mp4", body: try await engine.segment(index))
            }
        } catch StreamError.outOfRange {
            return .notFound()
        } catch StreamError.superseded {
            return .init(status: 503, body: Data("A later request moved conversion elsewhere\n".utf8))
        } catch StreamError.timedOut {
            return .init(status: 504, body: Data("Conversion did not keep up\n".utf8))
        } catch {
            return .init(status: 500, body: Data("\(error)\n".utf8))
        }
    }
}

enum StreamError: Error {
    case outOfRange
    /// Conversion restarted elsewhere for a later request, so this segment will not arrive soon.
    case superseded
    case timedOut
}

/// Converts and caches segments, restarting conversion where playback needs it.
actor StreamEngine {
    /// Sync periods per segment: 3.2 seconds at the default interval of 75 packets.
    static let periods = 2

    nonisolated let totalFrames: Int64
    private let file: MatroskaFile
    private let track: MatroskaAudioTrack
    private let codec: SpatialAudioCodec
    private let configuration: APACConfiguration
    private let segmentFrames: Int64
    private let priming: Int64
    private let lookahead: Int
    private let keptBehind: Int
    private let timeout: Duration
    private let store = SegmentStore()
    private var run: Run?
    private var requested = 0
    /// A decoding or encoding failure, which ends the stream so the host can fall back.
    private var failure: (any Error)?

    private struct Run {
        let id: UUID
        let start: Int
        let task: Task<Void, Never>
    }

    init(file: MatroskaFile, track: MatroskaAudioTrack, codec: SpatialAudioCodec, configuration: APACConfiguration,
         segmentFrames: Int64, priming: Int64, totalFrames: Int64, lookahead: Int, keptBehind: Int, timeout: Duration) {
        self.file = file
        self.track = track
        self.codec = codec
        self.configuration = configuration
        self.segmentFrames = segmentFrames
        self.priming = priming
        self.totalFrames = totalFrames
        self.lookahead = lookahead
        self.keptBehind = keptBehind
        self.timeout = timeout
    }

    var segmentCount: Int { Int((totalFrames + segmentFrames - 1) / segmentFrames) }

    nonisolated func index(at time: CMTime) -> Int {
        let frame = Int64((max(time.seconds, 0) * 48_000).rounded(.down))
        return Int(min(frame, totalFrames - 1) / segmentFrames)
    }

    func initialization() async throws -> Data {
        try checkFailure()
        if let data = store.initialization { return data }
        if run == nil { startRun(at: requested) }
        return try await wait(until: { $0.initialization })
    }

    func segment(_ index: Int) async throws -> Data {
        guard (0..<segmentCount).contains(index) else { throw StreamError.outOfRange }
        try checkFailure()
        requested = index
        store.keep(around: index, behind: keptBehind, ahead: lookahead)
        if let data = store.segment(index) {
            log.debug("seg\(index) from cache")
            return data
        }
        if !waitsForRun(index) {
            log.info("seg\(index) restarts conversion; run started at \(self.run?.start ?? -1), converted \(self.store.highest)")
            startRun(at: index)
        }
        let waited = ContinuousClock.now
        do {
            let data = try await wait(until: { $0.segment(index) }, while: { waitsForRun(index) })
            log.info("seg\(index) after \(Int((ContinuousClock.now - waited) / .milliseconds(1))) ms")
            return data
        } catch {
            log.error("seg\(index) failed after \(Int((ContinuousClock.now - waited) / .milliseconds(1))) ms: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func stop() {
        run?.task.cancel()
        run = nil
    }

    var conversionSpeed: Double? {
        guard let run else { return nil }
        return store.speed(from: run.start, segmentFrames: segmentFrames)
    }

    /// The highest segment the current run has produced.
    var converted: Int { store.highest }

    /// Whether the current run will deliver segment `index` sooner than a new run would.
    private func waitsForRun(_ index: Int) -> Bool {
        guard let run else { return false }
        return Self.waits(for: index, runStart: run.start, converted: store.highest, ended: store.ended(run: run.id))
    }

    /// A new run delivers its first segment in about two segments' conversion time, while each
    /// segment after the converted one costs one more. AVPlayer abandons a seek whose first segment
    /// takes longer than about 3 s, so wait only up to two segments past the converted point;
    /// restart behind the run, past that, or at a segment the run passed but no longer holds.
    static func waits(for index: Int, runStart: Int, converted: Int, ended: Bool) -> Bool {
        !ended && index >= runStart && index > converted && index <= max(runStart + 1, converted + 2)
    }

    /// Throws a failure that ends the stream, recording one the current run has just reported.
    /// Malformed or unsupported media fails the same way on every attempt, while network errors
    /// may not, so only decoding, encoding and configuration failures end the stream.
    private func checkFailure() throws {
        if failure == nil, let run, let error = store.failure(run: run.id), let spatial = error as? SpatialAudioError {
            switch spatial {
            case .decoding, .encoding, .invalidConfiguration: failure = spatial
            case .source, .invalidState, .coreMedia: break
            }
        }
        if let failure { throw failure }
    }

    private func wait(until value: (SegmentStore) -> Data?, while wanted: () -> Bool = { true }) async throws -> Data {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let data = value(store) { return data }
            try checkFailure()
            if let run, let failure = store.failure(run: run.id) { throw failure }
            // A later request restarted conversion elsewhere; the player has moved on.
            guard wanted() else { throw StreamError.superseded }
            guard ContinuousClock.now < deadline else { throw StreamError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Converts from segment `index`: decoding starts at the last sync before its first presented
    /// sample, which follows the encoder priming so the fragment begins exactly on the grid.
    private func startRun(at index: Int) {
        run?.task.cancel()
        let start = CMTime(value: Int64(index) * segmentFrames + priming, timescale: 48_000)
        let (file, track, codec, configuration, store, segmentFrames) =
            (self.file, self.track, self.codec, self.configuration, self.store, self.segmentFrames)
        let id = UUID()
        store.begin(run: id)
        let task = Task.detached { [weak self] in
            do {
                var transcoder: SpatialAudioTranscoder?
                for try await packet in file.packets(of: track, from: start) {
                    try Task.checkCancellation()
                    if transcoder == nil {
                        var settings = configuration
                        settings.startTime = start
                        settings.inputStartTime = packet.time
                        transcoder = try SpatialAudioTranscoder(codec: codec, destination: .segments(
                            syncPeriodsPerSegment: Self.periods,
                            onSegment: { store.deliver($0, run: id, segmentFrames: segmentFrames) }),
                            configuration: settings)
                    }
                    try await transcoder?.append(packet.data)
                    // The engine is gone once its stream is released; stop converting.
                    guard let self else { break }
                    await self.paceRun(id)
                }
                if let transcoder { _ = try await transcoder.finish() }
                store.end(run: id, failure: nil)
            } catch is CancellationError {
                store.end(run: id, failure: nil)
            } catch {
                store.end(run: id, failure: error)
            }
        }
        run = Run(id: id, start: index, task: task)
    }

    /// Holds the run while it is `lookahead` segments ahead of the latest request.
    private func paceRun(_ id: UUID) async {
        guard run?.id == id, store.highest >= requested + lookahead else { return }
        store.holding(true, run: id)
        while run?.id == id, !Task.isCancelled, store.highest >= requested + lookahead {
            try? await Task.sleep(for: .milliseconds(50))
        }
        store.holding(false, run: id)
    }
}

/// Segments shared between conversion callbacks and requests.
final class SegmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var initData: Data?
    private var segments: [Int: Data] = [:]
    private var window = 0..<Int.max
    private var current: UUID?
    private var produced = -1
    private var started = ContinuousClock.now
    private var held = Duration.zero
    private var holdStarted: ContinuousClock.Instant?
    private var ends: [UUID: (any Error)?] = [:]

    var initialization: Data? { lock.withLock { initData } }
    /// The highest segment the current run has produced.
    var highest: Int { lock.withLock { produced } }

    func segment(_ index: Int) -> Data? { lock.withLock { segments[index] } }

    func begin(run: UUID) {
        lock.withLock { current = run; produced = -1; started = .now; held = .zero; holdStarted = nil }
    }

    /// Stores a fragment under the grid index of its start time; repeated fragments replace nothing.
    func deliver(_ segment: APACSegment, run: UUID, segmentFrames: Int64) {
        lock.withLock {
            guard run == current else { return }
            switch segment.kind {
            case .initialization:
                // Every run writes the same initialization apart from creation times.
                if initData == nil { initData = segment.data }
            case .media:
                guard let start = segment.startTime else { return }
                let index = Int((start.seconds * 48_000 / Double(segmentFrames)).rounded())
                if window.contains(index), segments[index] == nil { segments[index] = segment.data }
                produced = max(produced, index)
            }
        }
    }

    /// Marks the run as waiting for playback, or as converting again.
    func holding(_ waiting: Bool, run: UUID) {
        lock.withLock {
            guard run == current else { return }
            if waiting {
                holdStarted = .now
            } else if let holdStarted {
                held += .now - holdStarted
                self.holdStarted = nil
            }
        }
    }

    /// Seconds of audio produced per second of conversion since the run began at segment `start`.
    func speed(from start: Int, segmentFrames: Int64) -> Double? {
        lock.withLock {
            guard produced >= start else { return nil }
            let audio = Double(Int64(produced - start + 1) * segmentFrames) / 48_000
            let now = ContinuousClock.now
            let busy = now - started - held - (holdStarted.map { now - $0 } ?? .zero)
            return audio / (Double(busy.components.seconds) + Double(busy.components.attoseconds) / 1e18)
        }
    }

    func end(run: UUID, failure: (any Error)?) {
        // Subscript assignment of nil would remove the entry; a clean end must be recorded too.
        lock.withLock { _ = ends.updateValue(failure, forKey: run) }
    }

    func ended(run: UUID) -> Bool { lock.withLock { ends[run] != nil } }

    func failure(run: UUID) -> (any Error)? { lock.withLock { ends[run] ?? nil } }

    /// Keeps segments near the playback position and drops the rest.
    func keep(around index: Int, behind: Int, ahead: Int) {
        lock.withLock {
            window = max(0, index - behind)..<(index + ahead + 3)
            segments = segments.filter { window.contains($0.key) }
        }
    }
}
