import AVFoundation

/// Plays TrueHD Atmos or DTS:X as APAC through `AVSampleBufferAudioRenderer`, for players that
/// render video themselves with an `AVSampleBufferRenderSynchronizer`. No HLS or server is involved.
///
/// ```swift
/// let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos, synchronizer: synchronizer)
/// try await renderer.begin(at: seekTime)
/// for try await packet in file.packets(of: track, from: seekTime) {
///     try await renderer.enqueue(packet.data, time: packet.time)
/// }
/// try await renderer.endOfStream()
/// ```
///
/// The host owns the synchronizer's rate and time. Native Atmos output also needs
/// ``AtmosOutputActivator`` from SpatialAudioPlayback, attached to the same synchronizer.
public actor SpatialAudioRenderer {
    /// Joins the host's synchronizer, which controls its rate and time.
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let codec: SpatialAudioCodec
    private let configuration: APACConfiguration
    private var decoder: Decoder
    private var encoder: APACEncoder
    private var timeline = CMTime.zero
    private var inputStart: CMTime?
    private var discarding: Int?
    private var packets: Int64 = 0
    private var ended = false

    /// Whether enough APAC is queued to start the synchronizer. The encoder holds about one sync
    /// period (1.6 s) before its first packet, so start the clock only once this is true.
    public var isReadyToPlay: Bool { audioRenderer.hasSufficientMediaDataForReliablePlaybackStart }

    /// Whether the renderer is playing APAC, or failed to decode it.
    public var renderingStatus: AVQueuedSampleBufferRenderingStatus { audioRenderer.status }

    /// Adds the APAC renderer to `synchronizer`. Layout, bitrate and sync interval come from
    /// `configuration`; encoding is always live.
    public init(codec: SpatialAudioCodec, configuration: APACConfiguration = .init(),
                synchronizer: AVSampleBufferRenderSynchronizer) throws {
        var configuration = configuration
        // Only the live profile streams; the offline profile holds about 20 s before its first packet.
        configuration.liveEncoding = true
        self.codec = codec
        self.configuration = configuration
        decoder = try Decoder(codec: codec, layout: configuration.layout)
        encoder = try APACEncoder(configuration: configuration)
        synchronizer.addRenderer(audioRenderer)
    }

    /// Starts a new timeline at `time`: before the first packet, after a seek or at a discontinuity.
    /// Queued audio is dropped. Then enqueue packets from a sync point at or before `time`; audio
    /// before `time` is discarded so playback starts exactly there.
    public func begin(at time: CMTime) throws {
        audioRenderer.flush()
        decoder = try Decoder(codec: codec, layout: configuration.layout)
        encoder = try APACEncoder(configuration: configuration)
        timeline = time
        inputStart = nil
        discarding = nil
        packets = 0
        ended = false
    }

    /// Decodes, renders and encodes one compressed packet, waiting while the renderer is full.
    /// `time` is the packet's container time; only the first packet after ``begin(at:)`` uses it.
    public func enqueue(_ packet: Data, time: CMTime) async throws {
        guard !ended else { throw SpatialAudioError.invalidState("Call begin(at:) after endOfStream()") }
        // Decoded audio starts at the first packet, even when the decoder holds it back for a while.
        if inputStart == nil { inputStart = time }
        var blocks: [PCMBlock] = []
        for start in stride(from: 0, to: packet.count, by: 65_536) {
            let end = min(packet.count, start + 65_536)
            blocks += try packet.withUnsafeBytes { try decoder.decode(UnsafeRawBufferPointer(rebasing: $0[start..<end]), end: false) }
        }
        try await submit(encoder.encode(timed(blocks)[...]))
    }

    /// Flushes the decoder and encoder. Call ``begin(at:)`` to play again.
    public func endOfStream() async throws {
        let blocks = try decoder.decode(UnsafeRawBufferPointer(start: nil, count: 0), end: true)
        try await submit(encoder.encode(timed(blocks)[...], final: true))
        ended = true
    }

    /// Interleaved PCM aligned to the timeline: audio before it is discarded and a later start padded.
    private func timed(_ blocks: [PCMBlock]) throws -> [Float] {
        if discarding == nil, let inputStart {
            discarding = Int((CMTimeSubtract(timeline, inputStart).seconds * 48_000).rounded())
        }
        var pcm: [Float] = []
        for block in blocks {
            guard block.sampleRate == 48_000, block.channels == configuration.layout.channelCount else {
                throw SpatialAudioError.encoding("Audio format changed; call begin(at:) at a discontinuity")
            }
            var samples = block.samples[...]
            if let remaining = discarding {
                // A source starting after the timeline is padded so its timestamps stay aligned.
                if remaining < 0 { pcm.append(contentsOf: repeatElement(0, count: -remaining * block.channels)) }
                let dropped = min(max(remaining, 0), block.frames)
                samples = samples.dropFirst(dropped * block.channels)
                discarding = max(remaining, 0) - dropped
            }
            pcm.append(contentsOf: samples)
        }
        return pcm
    }

    /// Enqueues packets with timestamps shifted back by the encoder priming, so decoded audio lands
    /// at its presentation time, as the asset-writer path does.
    private func submit(_ encoded: [Data]) async throws {
        guard !encoded.isEmpty else { return }
        while !audioRenderer.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        let start = CMTimeSubtract(CMTimeAdd(timeline, CMTime(value: packets * 1024, timescale: 48_000)),
                                   CMTime(value: Int64(encoder.primingFrames), timescale: 48_000))
        audioRenderer.enqueue(try Self.sampleBuffer(encoded, format: encoder.format, at: start))
        packets += Int64(encoded.count)
    }

    private static func sampleBuffer(_ encoded: [Data], format: CMAudioFormatDescription, at time: CMTime) throws -> CMSampleBuffer {
        let size = encoded.reduce(0) { $0 + $1.count }
        var block: CMBlockBuffer?
        try Self.check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: size,
            flags: 0, blockBufferOut: &block))
        guard let block else { throw SpatialAudioError.encoding("Could not allocate APAC packets") }
        var descriptions: [AudioStreamPacketDescription] = []
        var offset = 0
        for packet in encoded {
            try packet.withUnsafeBytes {
                try Self.check(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: packet.count))
            }
            descriptions.append(AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                                                             mDataByteSize: UInt32(packet.count)))
            offset += packet.count
        }
        var buffer: CMSampleBuffer?
        try Self.check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: encoded.count, presentationTimeStamp: time,
            packetDescriptions: descriptions, sampleBufferOut: &buffer))
        guard let buffer else { throw SpatialAudioError.encoding("Could not create an APAC sample buffer") }
        return buffer
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SpatialAudioError.coreMedia(status) }
    }
}
