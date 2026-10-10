import Foundation
import CoreMedia
import AudioToolbox

public enum SpatialAudioCodec: UInt32, Sendable {
    case trueHDAtmos = 1
    case dtsX = 2
}

public enum SpatialAudioLayout: UInt32, Sendable {
    case sevenOneFour = 12
    case nineOneSix = 16
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

public struct APACConfiguration: Sendable {
    public var layout: SpatialAudioLayout
    /// Gain before encoding. No automatic normalization or clipping is applied.
    public var gainDB: Float
    public var bitRate: Int
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

    public init(layout: SpatialAudioLayout = .nineOneSix, gainDB: Float = 0,
                bitRate: Int? = nil, startTime: CMTime = .zero, syncPacketFrequency: Int = 75,
                liveEncoding: Bool = false) {
        self.layout = layout
        self.gainDB = gainDB
        self.bitRate = bitRate ?? min(layout.channelCount * 256_000, 4_096_000)
        self.startTime = startTime
        inputStartTime = nil
        self.syncPacketFrequency = syncPacketFrequency
        self.liveEncoding = liveEncoding
    }

    /// Frames to drop (positive) or pad with silence (negative) before the first decoded sample.
    func leadingFrames(rate: Int) -> Int {
        guard let inputStartTime else { return 0 }
        return Int((CMTimeSubtract(startTime, inputStartTime).seconds * Double(rate)).rounded())
    }

    /// Leading frames are retained in fragmented-media timelines.
    /// Account for this offset when aligning the video rendition.
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

public struct APACSegment: Sendable {
    public enum Kind: Sendable { case initialization, media }
    public let kind: Kind
    public let data: Data
    public let startTime: CMTime?
    public let duration: CMTime?
}

public enum APACDestination: Sendable {
    case file(URL)
    /// Called serially on an AVFoundation queue. Consume or persist data promptly.
    /// The interval is a whole number of APAC sync periods, keeping fragments seekable.
    case segments(syncPeriodsPerSegment: Int = 2, onSegment: @Sendable (APACSegment) throws -> Void)
}

public struct APACConversionReport: Sendable {
    public let sampleRate: Int
    public let sampleFrames: Int64
    public let layout: SpatialAudioLayout
    public let peakPCM: Float
    public var duration: TimeInterval { Double(sampleFrames) / Double(sampleRate) }
}

public enum SpatialAudioError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidState(String)
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
