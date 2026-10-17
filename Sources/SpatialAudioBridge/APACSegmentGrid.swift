import CoreMedia
import Foundation

/// The fixed segment grid ``APACStream`` serves, for hosts that serve APAC HLS themselves.
///
/// Every segment covers two APAC sync periods, so segments from different conversion sessions line
/// up sample for sample. To convert from segment `index`:
///
/// ```swift
/// let grid = try APACSegmentGrid(duration: fileDuration)
/// var settings = grid.configuration(from: index)
/// settings.inputStartTime = firstPacket.time   // the sync point at or before grid.start(of: index)
/// let session = try SpatialAudioTranscoder(codec: codec, destination: .segments(
///     syncPeriodsPerSegment: APACSegmentGrid.syncPeriodsPerSegment, onSegment: { segment in
///         if segment.kind == .initialization { return storeInitialization(segment.data) }
///         if let at = grid.index(of: segment), at >= index { store(segment.data, at: at) }
///     }), configuration: settings)
/// // Append packets; at the track's end, pad and finish at grid.end(from: index).
/// ```
@available(macOS 26, iOS 26, tvOS 26, *)
public struct APACSegmentGrid: Sendable {
    /// Sync periods per segment: 3.2 seconds at the default interval of 75 packets.
    public static let syncPeriodsPerSegment = 2

    /// The encoder settings, always live: the offline profile delays every segment by about 20 s.
    public let configuration: APACConfiguration
    /// Frames per segment at 48 kHz; the last segment may be shorter.
    public let segmentFrames: Int64
    /// The presentation length, rounded up to a whole frame.
    public let totalFrames: Int64
    /// The encoder priming, which a session's first fragment carries in place of audio.
    public let primingFrames: Int64

    /// A grid for a presentation of `duration`, such as the container's.
    public init(duration: CMTime, configuration: APACConfiguration = .init()) throws {
        // A malformed duration may be infinite or too long to count in frames.
        guard duration.isNumeric, duration.seconds > 0, duration.seconds < 1e9 else {
            throw SpatialAudioError.invalidConfiguration("The grid needs a positive, finite duration")
        }
        guard (3...600).contains(configuration.syncPacketFrequency) else {
            throw SpatialAudioError.invalidConfiguration("The APAC sync interval must be 3 to 600 packets")
        }
        var configuration = configuration
        configuration.liveEncoding = true
        self.configuration = configuration
        segmentFrames = Int64(configuration.syncPacketFrequency * 1024 * Self.syncPeriodsPerSegment)
        totalFrames = CMTimeConvertScale(duration, timescale: 48_000, method: .roundTowardPositiveInfinity).value
        primingFrames = try configuration.encoderPrimingDuration().value
    }

    public var segmentCount: Int { Int((totalFrames + segmentFrames - 1) / segmentFrames) }

    /// Where the presentation ends.
    public var end: CMTime { CMTime(value: totalFrames, timescale: 48_000) }

    /// Where a session from segment `index` ends: ``end``, or one frame past the session's start
    /// when a last segment shorter than the priming would otherwise get no audio to write.
    /// Pad and finish the session here.
    public func end(from index: Int, early: Bool = false) -> CMTime {
        CMTime(value: max(totalFrames, configuration(from: index, early: early).startTime.value + 1), timescale: 48_000)
    }

    /// The segment that holds `time`, clamped to the grid.
    public func index(at time: CMTime) -> Int {
        guard time.isNumeric else { return time == .positiveInfinity ? segmentCount - 1 : 0 }
        // Rescaled exactly, so a boundary in another timescale stays in its segment.
        let frame = CMTimeConvertScale(time, timescale: 48_000, method: .roundTowardNegativeInfinity).value
        return Int(min(max(frame, 0), totalFrames - 1) / segmentFrames)
    }

    /// The presentation time segment `index` starts at.
    public func start(of index: Int) -> CMTime { CMTime(value: Int64(index) * segmentFrames, timescale: 48_000) }

    /// The segment a media fragment from a session on this grid belongs to.
    public func index(of segment: APACSegment) -> Int? {
        guard segment.kind == .media, let start = segment.startTime, start.isNumeric else { return nil }
        return Int((start.seconds * 48_000 / Double(segmentFrames)).rounded())
    }

    /// Settings for a session whose first fragment is segment `index`, or the segment before it
    /// when `early`. Set `inputStartTime` to the first packet's time.
    ///
    /// A session's first fragment carries the encoder priming in place of its first 42.7 ms of
    /// audio. That is expected right after a seek, but a session continuing another one's segments
    /// should start `early` and discard that fragment, or the join drops those 42.7 ms.
    public func configuration(from index: Int, early: Bool = false) -> APACConfiguration {
        var settings = configuration
        // The first fragment's presented audio follows the priming, so it begins exactly on the grid.
        settings.startTime = CMTime(value: Int64(index - (early ? 1 : 0)) * segmentFrames + primingFrames, timescale: 48_000)
        return settings
    }

    /// A VOD media playlist of the grid's segments. `minimumTargetDuration` lets it share a target
    /// duration with a video playlist.
    public func mediaPlaylist(minimumTargetDuration: Int = 0, initializationURI: String = "init.mp4",
                              segmentURI: (Int) -> String = { "seg\($0).m4s" }) -> String {
        HLSPlaylists.media(totalFrames: totalFrames, segmentFrames: segmentFrames, rate: 48_000,
                           minimumTargetDuration: minimumTargetDuration, initializationURI: initializationURI,
                           segmentURI: segmentURI)
    }
}
