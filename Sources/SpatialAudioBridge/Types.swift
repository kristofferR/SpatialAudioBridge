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
    /// APAC sync packets occur every 75 * 1024 / sampleRate seconds.
    public var syncPacketFrequency: Int

    public init(layout: SpatialAudioLayout = .nineOneSix, gainDB: Float = 0,
                bitRate: Int? = nil, startTime: CMTime = .zero, syncPacketFrequency: Int = 75) {
        self.layout = layout
        self.gainDB = gainDB
        self.bitRate = bitRate ?? min(layout.channelCount * 256_000, 4_096_000)
        self.startTime = startTime
        self.syncPacketFrequency = syncPacketFrequency
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
    case coreMedia(OSStatus)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message), .invalidState(let message),
             .decoding(let message), .encoding(let message): message
        case .coreMedia(let code): "CoreMedia error \(code)"
        }
    }
}
