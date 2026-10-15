import Foundation
import CoreMedia
import AudioToolbox

/// A compressed input format.
@available(macOS 26, iOS 26, tvOS 26, *)
public enum SpatialAudioCodec: UInt32, Sendable {
    /// Dolby TrueHD with Atmos object metadata, 48 kHz, one bed and point objects.
    case trueHDAtmos = 1
    /// DTS-HD Master Audio with the standard four-height DTS:X presentation, 48 kHz.
    case dtsX = 2
}

/// The speaker layout rendered and encoded as APAC, in Apple's Atmos channel order.
@available(macOS 26, iOS 26, tvOS 26, *)
public enum SpatialAudioLayout: UInt32, Sendable {
    /// 7.1.4: twelve channels, profile and level `apac.31.03`.
    case sevenOneFour = 12
    /// 9.1.6: sixteen channels, profile and level `apac.31.04`.
    case nineOneSix = 16
    /// Channels in the layout, for the HLS rendition's `CHANNELS` attribute.
    public var channelCount: Int { Int(rawValue) }
    /// Audio entry for the HLS variant's CODECS attribute, including profile and level.
    /// Apple's channel-based APAC profile 31 uses level 3 through 12 channels, 4 through 24.
    public var apacCodecString: String {
        switch self {
        case .sevenOneFour: "apac.31.03"
        case .nineOneSix: "apac.31.04"
        }
    }
    var tag: AudioChannelLayoutTag {
        switch self {
        case .sevenOneFour: kAudioChannelLayoutTag_Atmos_7_1_4
        case .nineOneSix: kAudioChannelLayoutTag_Atmos_9_1_6
        }
    }
}

/// How a session renders and encodes APAC.
@available(macOS 26, iOS 26, tvOS 26, *)
public struct APACConfiguration: Sendable {
    /// The rendered speaker layout. Defaults to 7.1.4: on the tested Apple TV, Dolby Atmos
    /// output carries 12 channels and folds 9.1.6's wides and top middles into their neighbours.
    public var layout: SpatialAudioLayout
    /// Gain before encoding, after the renderer's peak limiter, so a positive gain can exceed full
    /// scale. No automatic normalization is applied.
    public var gainDB: Float
    /// Total APAC bit rate in bits per second. Unless set, 256 kbit/s per channel of `layout`, at most
    /// 4.096 Mbit/s.
    public var bitRate: Int {
        get { explicitBitRate ?? min(layout.channelCount * 256_000, 4_096_000) }
        set { explicitBitRate = newValue }
    }
    private var explicitBitRate: Int?
    /// Presentation time of the first output sample. Fragment timestamps start here, less the
    /// encoder priming.
    public var startTime: CMTime
    /// Container time of the first decoded sample, when it differs from `startTime`.
    /// Earlier audio is discarded and a later start is padded with silence, so the output begins
    /// exactly at `startTime`. Use it after a seek, which starts decoding at an earlier sync point.
    public var inputStartTime: CMTime?
    /// APAC sync packets occur every 75 * 1024 / sampleRate seconds.
    public var syncPacketFrequency: Int
    /// Encodes with Apple's live profile (Capture dynamic range, spatial live content), which emits
    /// audio about 1.6 s behind its input. The default offline Movie profile analyzes about 20 s
    /// ahead for loudness and dynamic range, so it suits files rather than playback.
    /// `APACStream` and `SpatialAudioRenderer` always use the live profile.
    public var liveEncoding: Bool
    /// Attenuates TrueHD by its signalled dialogue level, as an AV receiver does: 4 dB at −27 dB.
    /// Off by default, as in Apple TV's own Atmos playback, so converted tracks play at the level of
    /// native Atmos content. DTS:X exposes no dialogue level.
    public var normalizesDialogue: Bool

    public init(layout: SpatialAudioLayout = .sevenOneFour, gainDB: Float = 0,
                bitRate: Int? = nil, startTime: CMTime = .zero, syncPacketFrequency: Int = 75,
                liveEncoding: Bool = false, normalizesDialogue: Bool = false) {
        self.layout = layout
        self.gainDB = gainDB
        explicitBitRate = bitRate
        self.startTime = startTime
        inputStartTime = nil
        self.syncPacketFrequency = syncPacketFrequency
        self.liveEncoding = liveEncoding
        self.normalizesDialogue = normalizesDialogue
    }

    /// Whether the gain, bit rate and sync interval are within the encoder's range.
    var hasValidEncoderSettings: Bool {
        gainDB.isFinite && (-60...12).contains(gainDB) && (1...4_096_000).contains(bitRate)
            && (3...600).contains(syncPacketFrequency)
    }

    /// Frames to drop (positive) or pad with silence (negative) before the first decoded sample.
    func leadingFrames(rate: Int) -> Int {
        guard let inputStartTime else { return 0 }
        return Int((CMTimeSubtract(startTime, inputStartTime).seconds * Double(rate)).rounded())
    }

    /// The encoder's leading frames, queried from the installed Core Audio encoder: 2048 samples
    /// (42.7 ms) on tested systems. Fragmented timelines retain them before `startTime`; account
    /// for this offset when aligning the video rendition.
    public func encoderPrimingDuration() throws -> CMTime {
        let format = try pcmFormat(rate: 48_000, layout: layout)
        var source = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
        var output = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatAPAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(layout.channelCount), mBitsPerChannel: 0, mReserved: 0)
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&source, &output, &converter)
        guard status == noErr, let converter else { throw SpatialAudioError.coreMedia(status) }
        defer { AudioConverterDispose(converter) }
        var prime = AudioConverterPrimeInfo()
        var size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        let primeStatus = AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &size, &prime)
        guard primeStatus == noErr else { throw SpatialAudioError.coreMedia(primeStatus) }
        return CMTime(value: Int64(prime.leadingFrames), timescale: 48_000)
    }
}

/// One fragmented-MP4 segment from a ``APACDestination/segments(syncPeriodsPerSegment:onSegment:)`` destination.
@available(macOS 26, iOS 26, tvOS 26, *)
public struct APACSegment: Sendable {
    public enum Kind: Sendable { case initialization, media }
    public let kind: Kind
    /// The complete segment file: `init.mp4` content or one `.m4s` fragment.
    public let data: Data
    /// The fragment's coded start time, including encoder priming; nil for initialization.
    public let startTime: CMTime?
    /// The fragment's coded duration; nil for initialization.
    public let duration: CMTime?
}

/// Where a transcoder writes APAC.
@available(macOS 26, iOS 26, tvOS 26, *)
public enum APACDestination: Sendable {
    /// An MP4 file. Priming is trimmed from its presented duration.
    case file(URL)
    /// Called serially on an AVFoundation queue. Consume or persist data promptly.
    /// The interval is a whole number of APAC sync periods, keeping fragments seekable.
    case segments(syncPeriodsPerSegment: Int = 2, onSegment: @Sendable (APACSegment) throws -> Void)
}

/// What a finished session converted.
@available(macOS 26, iOS 26, tvOS 26, *)
public struct APACConversionReport: Sendable {
    public let sampleRate: Int
    /// Encoded frames, including any silence padding and excluding encoder priming.
    public let sampleFrames: Int64
    public let layout: SpatialAudioLayout
    /// The largest absolute sample before encoding; above 1 exceeds full scale.
    public let peakPCM: Float
    public var duration: TimeInterval { Double(sampleFrames) / Double(sampleRate) }
}

/// Why a session or source failed. Every error ends the session; fall back to the host's own
/// audio path or start a new session.
@available(macOS 26, iOS 26, tvOS 26, *)
public enum SpatialAudioError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    /// The call does not fit the session's state, such as appending after `finish()`.
    case invalidState(String)
    /// The input is malformed, truncated or uses unsupported metadata, such as Atmos ISF or an
    /// unknown DTS:X profile.
    case decoding(String)
    case encoding(String)
    /// The media source could not be read or is not a supported container.
    case source(String)
    case coreMedia(OSStatus)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message), .invalidState(let message),
             .decoding(let message), .encoding(let message), .source(let message): message
        case .coreMedia(let code): "CoreMedia error \(code)"
        }
    }
}
