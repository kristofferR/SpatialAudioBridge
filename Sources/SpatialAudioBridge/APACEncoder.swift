import AVFoundation
import CoreMedia

/// Encodes interleaved Float32 PCM to APAC packets with Core Audio, using the same settings as the
/// asset-writer path, for renderers that accept compressed sample buffers.
final class APACEncoder {
    /// The APAC format, including the encoder's magic cookie and channel layout.
    let format: CMAudioFormatDescription
    /// Frames of encoder delay before the first input sample.
    let primingFrames: Int
    private let converter: AudioConverterRef
    private let channels: Int
    private let maximumPacketSize: Int
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
                                      (kAudioCodecPropertyASPFrequency, UInt32(configuration.syncPacketFrequency))] {
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
    }

    deinit {
        AudioConverterDispose(converter)
        feed?.deallocate()
    }

    /// Appends PCM and returns the packets it completes. The encoder holds about one sync period
    /// (1.6 s) before its first packet. `final` flushes the remaining audio.
    func encode(_ samples: ArraySlice<Float>, final: Bool = false) throws -> [Data] {
        pending.append(contentsOf: samples)
        draining = final
        let batch = 16
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: maximumPacketSize * batch, alignment: 16)
        defer { buffer.deallocate() }
        var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: batch)
        var dependencies = [AudioStreamPacketDependencyDescription](repeating: .init(), count: batch)
        var packets: [Data] = []
        while true {
            var count = UInt32(batch)
            var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(maximumPacketSize * batch), mData: buffer))
            // APAC's sync packets make it a format with packet dependencies, which needs this variant.
            let status = AudioConverterFillComplexBufferWithPacketDependencies(converter, { _, packets, data, _, context in
                Unmanaged<APACEncoder>.fromOpaque(context!).takeUnretainedValue().provide(packets, data)
            }, Unmanaged.passUnretained(self).toOpaque(), &count, &output, &descriptions, &dependencies)
            for description in descriptions.prefix(Int(count)) {
                packets.append(Data(bytes: buffer + Int(description.mStartOffset), count: Int(description.mDataByteSize)))
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
