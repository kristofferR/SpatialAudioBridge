import AVFoundation
import CoreMedia

/// Encodes interleaved Float32 PCM to APAC packets with Core Audio, using the same settings as the
/// asset-writer path, for renderers that accept compressed sample buffers.
@available(macOS 26, iOS 26, tvOS 26, *)
final class APACEncoder {
    /// The APAC format, including the encoder's magic cookie and channel layout.
    let format: CMAudioFormatDescription
    /// Frames of encoder delay before the first input sample.
    let primingFrames: Int
    private let converter: AudioConverterRef
    private let channels: Int
    private let maximumPacketSize: Int
    private static let packetBatch = 16
    private let outputBuffer: UnsafeMutableRawPointer
    private var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: APACEncoder.packetBatch)
    private var dependencies = [AudioStreamPacketDependencyDescription](repeating: .init(), count: APACEncoder.packetBatch)
    private var pending: [Float] = []
    private var feed: UnsafeMutableRawPointer?
    private var feedCapacity = 0
    private var draining = false

    /// Status the input callback returns when it has no PCM yet; conversion resumes on the next call.
    private static let needsInput: OSStatus = 0x6E65_6564 // 'need'

    init(configuration: APACConfiguration) throws {
        let layout = configuration.layout
        channels = layout.channelCount
        var source = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 4),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var destination = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatAPAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        var created: AudioConverterRef?
        try Self.check(AudioConverterNew(&source, &destination, &created))
        guard let converter = created else { throw SpatialAudioError.encoding("Could not create the APAC encoder") }
        self.converter = converter
        do {
            var channelLayout = AudioChannelLayout()
            channelLayout.mChannelLayoutTag = layout.tag
            let layoutSize = UInt32(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
            try Self.check(AudioConverterSetProperty(converter, kAudioConverterInputChannelLayout, layoutSize, &channelLayout))
            try Self.check(AudioConverterSetProperty(converter, kAudioConverterOutputChannelLayout, layoutSize, &channelLayout))
            for (property, value) in [(kAudioConverterEncodeBitRate, UInt32(configuration.bitRate)),
                                      (kAudioCodecPropertyContentSource, UInt32(configuration.contentSource.rawValue)),
                                      (kAudioCodecPropertyDynamicRangeControlConfiguration, UInt32(configuration.dynamicRangeConfiguration.rawValue)),
                                      (kAudioCodecPropertyASPFrequency, UInt32(configuration.syncPacketFrequency)),
                                      // Medium matched high on real Atmos content (48.4 against 47.0 dB
                                      // signal-to-error) at less CPU. Low is faster still but lost up to
                                      // 42 dB on height-only content. Medium is Core Audio's default and
                                      // the tier AVAssetWriter encodes APAC at, whatever its settings say.
                                      (kAudioConverterCodecQuality, kAudioConverterQuality_Medium)] {
                var value = value
                try Self.check(AudioConverterSetProperty(converter, property, 4, &value))
            }
            var prime = AudioConverterPrimeInfo()
            var size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
            try Self.check(AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &size, &prime))
            primingFrames = Int(prime.leadingFrames)
            var packetSize: UInt32 = 0
            size = 4
            try Self.check(AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &packetSize))
            maximumPacketSize = Int(packetSize)
            var cookieSize: UInt32 = 0
            try Self.check(AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &cookieSize, nil))
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            try Self.check(AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &cookieSize, &cookie))
            var description: CMAudioFormatDescription?
            try Self.check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &destination,
                layoutSize: Int(layoutSize), layout: &channelLayout, magicCookieSize: Int(cookieSize), magicCookie: cookie,
                extensions: nil, formatDescriptionOut: &description))
            guard let description else { throw SpatialAudioError.encoding("Could not describe the APAC format") }
            format = description
        } catch {
            AudioConverterDispose(converter)
            throw error
        }
        outputBuffer = .allocate(byteCount: maximumPacketSize * Self.packetBatch, alignment: 16)
    }

    deinit {
        AudioConverterDispose(converter)
        feed?.deallocate()
        outputBuffer.deallocate()
    }

    /// One encoded packet, and whether it decodes without the packets before it: an APAC sync packet.
    struct Packet {
        let data: Data
        let isIndependent: Bool
    }

    /// Appends PCM and returns the packets it completes. The live encoder holds 71 packets (1.5 s)
    /// before its first packet. `final` flushes the remaining audio.
    func encode(_ samples: ArraySlice<Float>, final: Bool = false) throws -> [Packet] {
        pending.append(contentsOf: samples)
        draining = final
        // A call per TrueHD access unit is common. Waiting for a packet's worth of PCM avoids a
        // conversion pass for each one, saving about 20% of encoding CPU.
        guard final || pending.count >= 1024 * channels else { return [] }
        var packets: [Packet] = []
        while true {
            var count = UInt32(Self.packetBatch)
            var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(maximumPacketSize * Self.packetBatch), mData: outputBuffer))
            // APAC's sync packets make it a format with packet dependencies, which needs this variant.
            let status = AudioConverterFillComplexBufferWithPacketDependencies(converter, { _, packets, data, _, context in
                Unmanaged<APACEncoder>.fromOpaque(context!).takeUnretainedValue().provide(packets, data)
            }, Unmanaged.passUnretained(self).toOpaque(), &count, &output, &descriptions, &dependencies)
            for (description, dependency) in zip(descriptions.prefix(Int(count)), dependencies) {
                packets.append(Packet(data: Data(bytes: outputBuffer + Int(description.mStartOffset), count: Int(description.mDataByteSize)),
                                      isIndependent: dependency.mIsIndependentlyDecodable != 0))
            }
            if status == Self.needsInput || (status == noErr && count == 0) { break }
            try Self.check(status)
        }
        return packets
    }

    /// Supplies all pending PCM, or none: then end-of-stream when draining, otherwise a pause.
    private func provide(_ packets: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let frames = pending.count / channels
        guard frames > 0 else {
            packets.pointee = 0
            data.pointee.mBuffers.mDataByteSize = 0
            return draining ? noErr : Self.needsInput
        }
        let bytes = frames * channels * 4
        if feedCapacity < bytes {
            feed?.deallocate()
            feed = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
            feedCapacity = bytes
        }
        // The converter reads this buffer until the next callback, so it outlives `pending`.
        pending.withUnsafeBytes { feed!.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        pending.removeFirst(frames * channels)
        packets.pointee = UInt32(frames)
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes), mData: feed)
        return noErr
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SpatialAudioError.coreMedia(status) }
    }
}
