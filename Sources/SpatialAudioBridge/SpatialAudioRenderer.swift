import Accelerate
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
/// The host owns the synchronizer's rate and time. Releasing the renderer removes it from the
/// synchronizer. Native Atmos output also needs ``AtmosOutputActivator`` from SpatialAudioPlayback,
/// attached to the same synchronizer.
public actor SpatialAudioRenderer {
    /// Joins the host's synchronizer, which controls its rate and time.
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let codec: SpatialAudioCodec
    private let configuration: APACConfiguration
    private let gain: Float
    private var decoder: Decoder
    private var encoder: APACEncoder
    private var timeline = CMTime.zero
    private var inputStart: CMTime?
    private var discarding: Int?
    private var packets: Int64 = 0
    /// Counts timelines, so a call suspended across ``begin(at:)`` drops its stale output.
    private var generation = 0
    private var state = State.accepting
    private enum State { case accepting, ended, failed }

    /// Whether enough APAC is queued to start the synchronizer. The encoder holds about one sync
    /// period (1.6 s) before its first packet, so start the clock only once this is true.
    public var isReadyToPlay: Bool { audioRenderer.hasSufficientMediaDataForReliablePlaybackStart }

    /// Whether the renderer is playing APAC, or failed to decode it.
    public var renderingStatus: AVQueuedSampleBufferRenderingStatus { audioRenderer.status }

    /// Adds the APAC renderer to `synchronizer`. Layout, gain, bitrate and sync interval come from
    /// `configuration`; encoding is always live.
    public init(codec: SpatialAudioCodec, configuration: APACConfiguration = .init(),
                synchronizer: AVSampleBufferRenderSynchronizer) throws {
        guard configuration.hasValidEncoderSettings else {
            throw SpatialAudioError.invalidConfiguration("Invalid APAC gain, bitrate or sync interval")
        }
        var configuration = configuration
        // Only the live profile streams; the offline profile holds about 20 s before its first packet.
        configuration.liveEncoding = true
        self.codec = codec
        self.configuration = configuration
        gain = powf(10, configuration.gainDB / 20)
        decoder = try Decoder(codec: codec, layout: configuration.layout)
        encoder = try APACEncoder(configuration: configuration)
        self.synchronizer = synchronizer
        synchronizer.addRenderer(audioRenderer)
    }

    isolated deinit {
        audioRenderer.flush()
        synchronizer.removeRenderer(audioRenderer, at: synchronizer.currentTime())
    }

    /// Starts a new timeline at `time`: before the first packet, after a seek, at a discontinuity
    /// or after a failure. Queued audio is dropped. Then enqueue packets from a sync point at or
    /// before `time`; audio before `time` is discarded so playback starts exactly there.
    public func begin(at time: CMTime) throws {
        guard time.isNumeric else { throw SpatialAudioError.invalidConfiguration("The timeline must start at a finite time") }
        generation += 1
        audioRenderer.flush()
        state = .failed
        decoder = try Decoder(codec: codec, layout: configuration.layout)
        encoder = try APACEncoder(configuration: configuration)
        timeline = time
        inputStart = nil
        discarding = nil
        packets = 0
        state = .accepting
    }

    /// Decodes, renders and encodes one compressed packet, waiting while the renderer is full.
    /// `time` is the packet's container time; only the first packet after ``begin(at:)`` uses it.
    /// A failure, including cancellation, ends the timeline until the next ``begin(at:)``.
    public func enqueue(_ packet: Data, time: CMTime) async throws {
        try checkAccepting()
        let current = generation
        do {
            if inputStart == nil {
                // Within the transcoder's bound, so a misplaced packet cannot demand minutes of silence.
                guard time.isNumeric, abs(CMTimeSubtract(timeline, time).seconds) <= 60 else {
                    throw SpatialAudioError.invalidConfiguration("The first packet must be within 60 s of the timeline")
                }
                // Decoded audio starts at the first packet, even when the decoder holds it back for a while.
                inputStart = time
            }
            var blocks: [PCMBlock] = []
            for start in stride(from: 0, to: packet.count, by: 65_536) {
                let end = min(packet.count, start + 65_536)
                blocks += try packet.withUnsafeBytes { try decoder.decode(UnsafeRawBufferPointer(rebasing: $0[start..<end]), end: false) }
            }
            try await play(blocks, generation: current)
        } catch {
            if generation == current { state = .failed }
            throw error
        }
    }

    /// Flushes the decoder and encoder. Call ``begin(at:)`` to play again.
    public func endOfStream() async throws {
        try checkAccepting()
        let current = generation
        do {
            let blocks = try decoder.decode(UnsafeRawBufferPointer(start: nil, count: 0), end: true)
            try await play(blocks, final: true, generation: current)
            state = .ended
        } catch {
            if generation == current { state = .failed }
            throw error
        }
    }

    private func checkAccepting() throws {
        if state == .accepting, audioRenderer.status == .failed {
            state = .failed
            throw audioRenderer.error ?? SpatialAudioError.encoding("The audio renderer could not play APAC")
        }
        switch state {
        case .accepting: return
        case .ended: throw SpatialAudioError.invalidState("Call begin(at:) after endOfStream()")
        case .failed: throw SpatialAudioError.invalidState("The timeline failed; call begin(at:) to play again")
        }
    }

    /// Encodes and queues decoded audio, first padding a source that starts after the timeline.
    private func play(_ blocks: [PCMBlock], final: Bool = false, generation current: Int) async throws {
        if discarding == nil, let inputStart, !blocks.isEmpty {
            discarding = Int((CMTimeSubtract(timeline, inputStart).seconds * 48_000).rounded())
        }
        // Silence keeps later timestamps aligned; a second at a time bounds its memory.
        while let remaining = discarding, remaining < 0 {
            let frames = min(-remaining, 48_000)
            try await submit(encoder.encode([Float](repeating: 0, count: frames * configuration.layout.channelCount)[...]),
                             generation: current)
            discarding = remaining + frames
        }
        try await submit(encoder.encode(timed(blocks)[...], final: final), generation: current)
    }

    /// Interleaved PCM aligned to the timeline, with audio before it discarded and the gain applied.
    private func timed(_ blocks: [PCMBlock]) throws -> [Float] {
        var pcm: [Float] = []
        for block in blocks {
            guard block.sampleRate == 48_000, block.channels == configuration.layout.channelCount else {
                throw SpatialAudioError.encoding("Audio format changed; call begin(at:) at a discontinuity")
            }
            var samples = block.samples[...]
            if let remaining = discarding {
                let dropped = min(remaining, block.frames)
                samples = samples.dropFirst(dropped * block.channels)
                discarding = remaining - dropped
            }
            pcm.append(contentsOf: samples)
        }
        // No normalization or limiting, as in the transcoder.
        return gain == 1 ? pcm : vDSP.multiply(gain, pcm)
    }

    /// Enqueues packets with timestamps shifted back by the encoder priming, so decoded audio lands
    /// at its presentation time, as the asset-writer path does.
    private func submit(_ encoded: [Data], generation current: Int) async throws {
        guard !encoded.isEmpty else { return }
        while !audioRenderer.isReadyForMoreMediaData {
            if audioRenderer.status == .failed { break }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        // begin(at:) started another timeline while this call waited; its audio is stale.
        guard generation == current else { throw CancellationError() }
        if audioRenderer.status == .failed {
            throw audioRenderer.error ?? SpatialAudioError.encoding("The audio renderer could not play APAC")
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
