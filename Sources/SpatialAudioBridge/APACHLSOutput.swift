import Foundation
import CoreMedia

/// Persists AVFoundation fragments and an EVENT playlist. Serve this directory over HTTP.
/// Call finish() only after the transcoder finishes; the player owns serving and cleanup.
public final class APACHLSOutput: @unchecked Sendable {
    public let playlistURL: URL
    public let encoderPrimingDuration: CMTime
    /// Use apacCodecString and channelCount when authoring the host's multivariant playlist.
    public let layout: SpatialAudioLayout
    private let directory: URL
    private let periods: Int
    private let targetDuration: Int
    private let lock = NSLock()
    private var initialized = false
    private var ended = false
    private var durations: [TimeInterval] = []

    public init(directory: URL, configuration: APACConfiguration = .init(), syncPeriodsPerSegment: Int = 2) throws {
        guard directory.isFileURL, !FileManager.default.fileExists(atPath: directory.path),
              (1...20).contains(syncPeriodsPerSegment), (3...600).contains(configuration.syncPacketFrequency) else {
            throw SpatialAudioError.invalidConfiguration("HLS requires a new directory and valid segment interval")
        }
        self.directory = directory
        self.layout = configuration.layout
        self.encoderPrimingDuration = try configuration.encoderPrimingDuration()
        self.periods = syncPeriodsPerSegment
        self.targetDuration = Int(ceil(Double(configuration.syncPacketFrequency * 1024 * syncPeriodsPerSegment) / 48_000 + 0.05))
        self.playlistURL = directory.appendingPathComponent("audio.m3u8")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Use the same configuration in the transcoder as in this output.
    public var destination: APACDestination {
        .segments(syncPeriodsPerSegment: periods, onSegment: { [self] in try consume($0) })
    }

    public func finish() throws {
        try lock.withLock {
            guard initialized, !durations.isEmpty else { throw SpatialAudioError.encoding("HLS output has no media segments") }
            ended = true
            try writePlaylist()
        }
    }

    private func consume(_ segment: APACSegment) throws {
        try lock.withLock {
            guard !ended else { throw SpatialAudioError.invalidState("HLS output is already finished") }
            switch segment.kind {
            case .initialization:
                guard !initialized else { throw SpatialAudioError.encoding("Unexpected second HLS initialization segment") }
                try segment.data.write(to: directory.appendingPathComponent("init.mp4"), options: .withoutOverwriting)
                initialized = true
            case .media:
                guard initialized, let duration = segment.duration?.seconds, duration.isFinite, duration > 0,
                      duration <= Double(targetDuration) else { throw SpatialAudioError.encoding("Invalid HLS segment duration or order") }
                try segment.data.write(to: directory.appendingPathComponent(filename(durations.count)), options: .withoutOverwriting)
                durations.append(duration)
                try writePlaylist()
            }
        }
    }

    private func filename(_ index: Int) -> String { String(format: "segment-%06d.m4s", index) }
    private func writePlaylist() throws {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(targetDuration)",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:EVENT", "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-MAP:URI=\"init.mp4\""]
        for (index, duration) in durations.enumerated() {
            lines.append(String(format: "#EXTINF:%.9f,", locale: Locale(identifier: "en_US_POSIX"), duration))
            lines.append(filename(index))
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: playlistURL, options: .atomic)
    }
}
