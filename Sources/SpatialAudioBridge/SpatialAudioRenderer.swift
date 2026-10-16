import Accelerate
import AVFoundation

/// The native output boundary, also used by deterministic capacity/flush tests.
@available(macOS 26, iOS 26, tvOS 26, *)
protocol SpatialAudioRendererOutput: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { get }
    var status: AVQueuedSampleBufferRenderingStatus { get }
    var error: (any Error)? { get }
    var isMuted: Bool { get set }
    var volume: Float { get set }
    func enqueue(_ buffer: CMSampleBuffer)
    func flush()
    func flush(fromSourceTime time: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void)
}

@available(macOS 26, iOS 26, tvOS 26, *)
extension AVSampleBufferAudioRenderer: SpatialAudioRendererOutput {}

@available(macOS 26, iOS 26, tvOS 26, *)
protocol SpatialAudioRendererDecoding: AnyObject {
    func decode(_ bytes: UnsafeRawBufferPointer, end: Bool) throws -> [PCMBlock]
}

@available(macOS 26, iOS 26, tvOS 26, *)
extension Decoder: SpatialAudioRendererDecoding {}

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
/// synchronizer. Native Atmos output also needs `AtmosOutputActivator` from SpatialAudioPlayback,
/// attached to the same synchronizer.
@available(macOS 26, iOS 26, tvOS 26, *)
public actor SpatialAudioRenderer {
    /// Joins the host's synchronizer, which controls its rate and time.
    private let audioRenderer: any SpatialAudioRendererOutput
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let configuration: APACConfiguration
    private let gain: Float
    private var decoder: any SpatialAudioRendererDecoding
    private let makeDecoder: @Sendable () throws -> any SpatialAudioRendererDecoding
    private var encoder: APACEncoder
    private var timeline = CMTime.zero
    private var inputStart: CMTime?
    private var discarding: Int?
    private var packets: Int64 = 0
    /// Counts timelines, so a call suspended across ``begin(at:)`` drops its stale output.
    private var generation = 0
    private var nextInput = 0
    private var activeInput = 0
    var waitingInputCount: Int { max(0, nextInput - activeInput - 1) }
    private var state = State.accepting
    private enum State { case accepting, ended, failed }
    /// Enqueued APAC packets that may not have played yet, from the latest sync packet before the
    /// playhead on, to enqueue again after an automatic flush.
    private var queued: [(buffer: CMSampleBuffer, start: CMTime, end: CMTime, isIndependent: Bool)] = []
    /// Set while a refill is pending, so new audio waits behind it and stays in order.
    private var refilling = false
    /// A second notification while a native partial flush is still awaiting its completion.
    private var refillAgain = false
    private var replay: [CMSampleBuffer] = []
    private var replayIndex = 0
    private var refillTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    /// Whether enough APAC is queued to start the synchronizer. The encoder holds 71 packets
    /// (1.5 s) before its first packet, so start the clock only once this is true.
    public var isReadyToPlay: Bool { audioRenderer.hasSufficientMediaDataForReliablePlaybackStart }

    /// Whether the renderer is playing APAC, or failed to decode it.
    public var renderingStatus: AVQueuedSampleBufferRenderingStatus { audioRenderer.status }

    /// Whether the output is muted. A passthrough host's own mute and volume never reach APAC.
    public var isMuted: Bool { audioRenderer.isMuted }

    /// The output volume, from 0 (silent) to 1 (full).
    public var volume: Float { audioRenderer.volume }

    /// Mutes or unmutes the output. It holds across timelines.
    public func setMuted(_ muted: Bool) {
        audioRenderer.isMuted = muted
    }

    /// Sets the output volume, clamped to 0...1. It holds across timelines.
    public func setVolume(_ volume: Float) {
        audioRenderer.volume = min(max(volume, 0), 1)
    }

    /// Adds the APAC renderer to `synchronizer`. Layout, gain, bitrate and sync interval come from
    /// `configuration`; encoding is always live.
    public init(codec: SpatialAudioCodec, configuration: APACConfiguration = .init(),
                synchronizer: AVSampleBufferRenderSynchronizer) throws {
        try self.init(codec: codec, configuration: configuration, synchronizer: synchronizer,
                      output: AVSampleBufferAudioRenderer())
    }

    init(codec: SpatialAudioCodec, configuration: APACConfiguration = .init(),
         synchronizer: AVSampleBufferRenderSynchronizer, output: sending any SpatialAudioRendererOutput,
         makeDecoder: (@Sendable () throws -> any SpatialAudioRendererDecoding)? = nil) throws {
        guard configuration.hasValidEncoderSettings else {
            throw SpatialAudioError.invalidConfiguration("Invalid APAC gain, bitrate or sync interval")
        }
        var configuration = configuration
        // Only the live profile streams; the offline profile holds about 20 s before its first packet.
        configuration.liveEncoding = true
        self.configuration = configuration
        gain = powf(10, configuration.gainDB / 20)
        let settings = configuration
        let factory: @Sendable () throws -> any SpatialAudioRendererDecoding = makeDecoder ?? {
            try Decoder(codec: codec, layout: settings.layout, normalizesDialogue: settings.normalizesDialogue)
        }
        self.makeDecoder = factory
        decoder = try factory()
        encoder = try APACEncoder(configuration: configuration)
        audioRenderer = output
        self.synchronizer = synchronizer
        if let native = output as? AVSampleBufferAudioRenderer { synchronizer.addRenderer(native) }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        refillTask?.cancel()
        audioRenderer.flush()
        if let native = audioRenderer as? AVSampleBufferAudioRenderer {
            synchronizer.removeRenderer(native, at: synchronizer.currentTime())
        }
    }

    /// Starts a new timeline at `time`: before the first packet, after a seek, at a discontinuity
    /// or after a failure. Queued audio is dropped. Then enqueue packets from a sync point at or
    /// before `time`; audio before `time` is discarded so playback starts exactly there.
    public func begin(at time: CMTime) throws {
        guard time.isNumeric else { throw SpatialAudioError.invalidConfiguration("The timeline must start at a finite time") }
        if observers.isEmpty { observeOutput() }
        generation += 1
        nextInput = 0
        activeInput = 0
        refillTask?.cancel()
        refillTask = nil
        replay = []
        replayIndex = 0
        audioRenderer.flush()
        queued = []
        refilling = false
        refillAgain = false
        state = .failed
        decoder = try makeDecoder()
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
            let input = try await acquireInput(generation: current)
            defer { releaseInput(input, generation: current) }
            try checkSubmission(generation: current)
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
            if state != .ended { fail(generation: current) }
            throw error
        }
    }

    /// Flushes the decoder and encoder. Call ``begin(at:)`` to play again.
    public func endOfStream() async throws {
        try checkAccepting()
        let current = generation
        do {
            let input = try await acquireInput(generation: current)
            defer { releaseInput(input, generation: current) }
            try checkSubmission(generation: current)
            let blocks = try decoder.decode(UnsafeRawBufferPointer(start: nil, count: 0), end: true)
            try await play(blocks, final: true, generation: current)
            try checkSubmission(generation: current)
            state = .ended
        } catch {
            if state != .ended { fail(generation: current) }
            throw error
        }
    }

    /// Actor reentrancy during capacity waits must not let later input advance the codecs first.
    private func acquireInput(generation current: Int) async throws -> Int {
        try checkSubmission(generation: current)
        let input = nextInput
        nextInput += 1
        while true {
            try checkSubmission(generation: current)
            if input == activeInput { return input }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func releaseInput(_ input: Int, generation current: Int) {
        guard generation == current else { return }
        activeInput = input + 1
    }

    private func fail(generation current: Int) {
        guard generation == current else { return }
        state = .failed
        refillTask?.cancel()
        refillTask = nil
        replay = []
        refilling = false
        refillAgain = false
    }

    private func checkSubmission(generation current: Int) throws {
        guard generation == current else { throw CancellationError() }
        try Task.checkCancellation()
        try checkAccepting()
    }

    private func checkAccepting() throws {
        if state == .accepting, audioRenderer.status == .failed {
            fail(generation: generation)
            throw audioRenderer.error ?? SpatialAudioError.encoding("The audio renderer could not play APAC")
        }
        switch state {
        case .accepting: return
        case .ended: throw SpatialAudioError.invalidState("Call begin(at:) after endOfStream()")
        case .failed: throw SpatialAudioError.invalidState("The timeline failed; call begin(at:) to play again")
        }
    }

    /// Encodes and queues decoded audio, first padding a source that starts after the timeline.
    func play(_ blocks: [PCMBlock], final: Bool = false, generation current: Int) async throws {
        try checkSubmission(generation: current)
        if discarding == nil, let inputStart, !blocks.isEmpty {
            discarding = Int((CMTimeSubtract(timeline, inputStart).seconds * 48_000).rounded())
        }
        // Silence keeps later timestamps aligned; a second at a time bounds its memory.
        while let remaining = discarding, remaining < 0 {
            let frames = min(-remaining, 48_000)
            try await submit(encoder.encode([Float](repeating: 0, count: frames * configuration.layout.channelCount)[...]),
                             generation: current)
            try checkSubmission(generation: current)
            discarding = remaining + frames
        }
        try checkSubmission(generation: current)
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
        // No normalization, as in the transcoder; the renderer has already limited the peaks.
        return gain == 1 ? pcm : vDSP.multiply(gain, pcm)
    }

    /// Enqueues packets with timestamps shifted back by the encoder priming, so decoded audio lands
    /// at its presentation time, as the asset-writer path does.
    func submit(_ encoded: [APACEncoder.Packet], generation current: Int) async throws {
        do {
            try checkSubmission(generation: current)
            // Capacity can disappear after any packet, including during a final encoder flush.
            for packet in encoded {
                while true {
                    try checkSubmission(generation: current)
                    if !refilling, audioRenderer.isReadyForMoreMediaData { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let start = CMTimeSubtract(CMTimeAdd(timeline, CMTime(value: packets * 1024, timescale: 48_000)),
                                           CMTime(value: Int64(encoder.primingFrames), timescale: 48_000))
                let buffer = try Self.sampleBuffer([packet.data], format: encoder.format, at: start)
                audioRenderer.enqueue(buffer)
                packets += 1
                queued.append((buffer, start, CMTimeAdd(start, CMTime(value: 1024, timescale: 48_000)), packet.isIndependent))
                // Keep unplayed audio from its preceding sync packet, even during a long batch.
                let now = synchronizer.currentTime()
                if let unplayed = queued.firstIndex(where: { $0.end > now }),
                   let sync = queued[...unplayed].lastIndex(where: \.isIndependent), sync > 0 {
                    queued.removeFirst(sync)
                }
            }
        } catch {
            fail(generation: current)
            throw error
        }
    }

    /// When the route changes, such as headphones connecting, the renderer may drop queued audio or
    /// find the output in another format; either way it needs the audio enqueued again.
    private func observeOutput() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: audioRenderer, queue: nil) { [weak self] notification in
                let time = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
                Task { await self?.refill(from: time) }
            },
            center.addObserver(forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: audioRenderer, queue: nil) { [weak self] _ in
                Task { await self?.refill(from: nil) }
            },
        ]
    }

    /// Enqueues again what an automatic flush dropped, from the flush time on, or with no time
    /// everything yet to play. Audio enqueued while the notification was on its way may have survived
    /// the flush, so flush from that time first.
    func refill(from time: CMTime?) {
        guard state != .failed, !queued.isEmpty else { return }
        guard audioRenderer.status != .failed else { return fail(generation: generation) }
        if refilling {
            if refillTask == nil {
                // Let the native flush finish before replaying; otherwise its late completion
                // could drop the replacement packets. Multiple notifications need one full refill.
                refillAgain = true
            } else {
                // A second flush may have dropped packets already replayed. Rewind from the sync
                // packet and let the existing capacity poll continue with the replacement replay.
                requeue()
            }
            return
        }
        guard let time, time.isNumeric else { return requeue() }
        let current = generation
        refilling = true
        audioRenderer.flush(fromSourceTime: time) { [weak self] flushed in
            Task { await self?.enqueueAgain(from: time, flushed: flushed, generation: current) }
        }
    }

    func enqueueAgain(from time: CMTime, flushed: Bool, generation current: Int) {
        // A newer timeline has reset the refill, and may have started its own.
        guard generation == current, state != .failed else { return }
        guard audioRenderer.status != .failed else { return fail(generation: current) }
        if refillAgain {
            refillAgain = false
            return requeue()
        }
        // Too close to the playhead to flush part of the queue: start over from what has yet to play.
        guard flushed else { return requeue() }
        startReplay(queued.filter { $0.start >= time }.map(\.buffer))
    }

    /// Flushes and enqueues everything yet to play again, which also reconfigures the output for it.
    /// The flush resets the decoder, so it starts at the sync packet before the playhead; the packets
    /// before the playhead only prime the decoder.
    private func requeue() {
        guard state != .failed else { return }
        guard audioRenderer.status != .failed else { return fail(generation: generation) }
        audioRenderer.flush()
        let now = synchronizer.currentTime()
        guard let unplayed = queued.firstIndex(where: { $0.end > now }) else {
            return startReplay([])
        }
        let sync = queued[...unplayed].lastIndex(where: \.isIndependent) ?? unplayed
        var buffers: [CMSampleBuffer] = []
        for (index, entry) in queued.enumerated() where index >= sync {
            guard index < unplayed, let primer = Self.trimmed(entry.buffer) else {
                buffers.append(entry.buffer)
                continue
            }
            buffers.append(primer)
        }
        startReplay(buffers)
    }

    private func startReplay(_ buffers: [CMSampleBuffer]) {
        refilling = true
        replay = buffers
        replayIndex = 0
        guard refillTask == nil else { return }
        let current = generation
        // Release the actor between polls, so a blocked replay does not keep the renderer alive.
        refillTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard await self?.replayAvailable(generation: current) == true else { return }
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
    }

    /// All replay buffers stay actor-owned; only the need to poll again leaves the actor.
    private func replayAvailable(generation current: Int) -> Bool {
        guard generation == current, state != .failed else { return false }
        while replayIndex < replay.count {
            if Task.isCancelled || audioRenderer.status == .failed {
                fail(generation: current)
                return false
            }
            guard audioRenderer.isReadyForMoreMediaData else { return true }
            audioRenderer.enqueue(replay[replayIndex])
            replayIndex += 1
        }
        replay = []
        refilling = false
        refillTask = nil
        return false
    }

    /// A copy of a one-packet buffer that the renderer decodes but does not play.
    private static func trimmed(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleBufferOut: &copy) == noErr,
              let copy else { return nil }
        CMSetAttachment(copy, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                        value: CMTimeCopyAsDictionary(CMTime(value: 1024, timescale: 48_000), allocator: kCFAllocatorDefault),
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
        return copy
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
