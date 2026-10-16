@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers
import AudioToolbox

/// AVAssetWriter permits cancellation while its asynchronous finish is pending.
/// Only that operation is shared with the task's cancellation handler.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class WriterCancellation: @unchecked Sendable {
    private let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) { self.writer = writer }
    func cancel() { writer.cancelWriting() }
}

/// Delivers fragments in order, under one lock, so the last can be held and trimmed.
@available(macOS 26, iOS 26, tvOS 26, *)
final class SegmentDelegate: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    let handler: @Sendable (APACSegment) throws -> Void
    private let lock = NSLock()
    private var failure: String?
    private var holding = false
    private var closed = false
    private var held: APACSegment?
    private var coded = CMTime.zero
    /// The end of the latest accepted fragment and its bytes, to recognize a repeated fragment.
    private var acceptedEnd = CMTime.negativeInfinity
    private var accepted: Data?
    var error: String? { lock.withLock { failure } }
    init(_ handler: @escaping @Sendable (APACSegment) throws -> Void) { self.handler = handler }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        let track = segmentReport?.trackReports.first
        receive(APACSegment(kind: segmentType == .initialization ? .initialization : .media,
                            data: Data(data), startTime: track?.earliestPresentationTimeStamp,
                            duration: track?.duration))
    }

    func receive(_ segment: APACSegment) {
        lock.withLock {
            guard segment.kind == .media else { return deliver(segment) }
            guard !closed else { return record("APAC fragment arrived after the last one") }
            if let start = segment.startTime, let duration = segment.duration {
                // AVAssetWriter can repeat its final fragment while finishing, sometimes before
                // the original (#56). Keep the first copy; differing content is a real overlap.
                // Reported boundaries may round by a frame, so overlap means half a packet.
                if CMTimeAdd(start, CMTime(value: 512, timescale: 48_000)) < acceptedEnd {
                    if segment.data != accepted { record("APAC fragments overlap") }
                    return
                }
                acceptedEnd = CMTimeAdd(start, duration)
                accepted = segment.data
            }
            coded = CMTimeAdd(coded, segment.duration ?? .zero)
            guard holding else { return deliver(segment) }
            // While finishing, each fragment waits until the next shows it is not the last.
            if let held { deliver(held) }
            held = segment
        }
    }

    /// Holds back fragments from now on, so the last one can be trimmed once writing completes.
    func holdLastSegment() { lock.withLock { holding = true } }

    /// Delivers the held last fragment, ending it at the source's last frame: `sourceFrames` after
    /// the encoder's priming. Fragments otherwise end with the final packet's padding.
    func deliverLastSegment(sourceFrames: Int64, priming: Int64) {
        lock.withLock {
            closed = true
            guard let segment = held else { return }
            held = nil
            let padding = CMTimeConvertScale(coded, timescale: 48_000, method: .default).value - priming - sourceFrames
            guard let duration = segment.duration, (1..<1024).contains(padding), let trimmed = trimmingLastSample(of: segment.data, by: UInt32(padding)) else {
                return deliver(segment)
            }
            deliver(APACSegment(kind: .media, data: trimmed, startTime: segment.startTime,
                                duration: CMTimeSubtract(duration, CMTime(value: padding, timescale: 48_000))))
        }
    }

    /// Call with the lock held.
    private func deliver(_ segment: APACSegment) {
        do { try handler(segment) } catch { record(String(describing: error)) }
    }

    /// Call with the lock held.
    private func record(_ error: String) {
        if failure == nil { failure = error }
    }
}

/// Streaming, bounded conversion of one continuous demuxed track. Create a new session after a seek.
@available(macOS 26, iOS 26, tvOS 26, *)
public actor SpatialAudioTranscoder {
    private let decoder: Decoder
    private let configuration: APACConfiguration
    private let destination: APACDestination
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var delegate: SegmentDelegate?
    private var format: CMAudioFormatDescription?
    private var sampleRate = 0
    private var frames: Int64 = 0
    private var peak: Float = 0
    private var pendingPCM: [Float] = []
    private var pendingRate = 0
    /// Decoded frames still to drop before `startTime`; nil until the first block.
    private var discarding: Int?
    private var busy = false
    private enum State { case accepting, finished, cancelled, failed }
    private var state = State.accepting
    private let codec: SpatialAudioCodec
    /// The latest packet time passed to `append`, and how many packets have shared it.
    private var packetTime: CMTime?
    private var laced = 0
    /// Whether the decoder holds input to flush.
    private var hasInput = false

    /// Validates `configuration` and prepares the decoder. The encoder starts with the first
    /// decoded audio, once the input's sample rate is known.
    public init(codec: SpatialAudioCodec, destination: APACDestination,
                configuration: APACConfiguration = .init()) throws {
        guard configuration.hasValidEncoderSettings,
              configuration.startTime.isNumeric, configuration.startTime >= .zero,
              configuration.inputStartTime.map({ $0.isNumeric && abs(CMTimeSubtract(configuration.startTime, $0).seconds) <= 60 }) ?? true else {
            throw SpatialAudioError.invalidConfiguration("Invalid APAC gain, bitrate, timestamp or sync interval")
        }
        if case .segments(let periods, _) = destination, !(1...20).contains(periods) {
            throw SpatialAudioError.invalidConfiguration("Segment sync periods must be between 1 and 20")
        }
        self.configuration = configuration
        self.destination = destination
        self.codec = codec
        self.decoder = try Decoder(codec: codec, layout: configuration.layout, normalizesDialogue: configuration.normalizesDialogue)
    }

    /// Pass the compressed audio payload, including DTS-HD extensions. MKV/TS bytes must be demuxed first.
    /// Await each call before appending again. Timestamps advance by decoded samples without drift.
    /// With `time`, the packet's container time, a gap or reset in those times fails the session,
    /// because decoded samples alone cannot span it. Frames laced into one block may share a time.
    public func append(_ data: Data, time: CMTime? = nil) async throws {
        try beginOperation()
        defer { busy = false }
        hasInput = true
        do {
            if let time { try follow(time) }
            var offset = 0
            while offset < data.count {
                try checkActive()
                let count = min(4096, data.count - offset)
                let blocks = try data.withUnsafeBytes { bytes in
                    try decoder.decode(UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + count]), end: false)
                }
                for block in blocks { try await accumulate(block) }
                offset += count
            }
        } catch { fail(); throw error }
    }

    /// Flushes the decoder and encoder and completes the file or final segment. Output that would
    /// end before the presentation time `end` is padded with silence up to it, for example to fill
    /// a playlist that follows a container whose video outlasts the audio.
    public func finish(paddingTo end: CMTime? = nil) async throws -> APACConversionReport {
        try beginOperation()
        defer { busy = false }
        do {
            try checkActive()
            try await flush()
            if let end { try await appendSilence(until: end) }
            if !pendingPCM.isEmpty {
                try await encode(pendingPCM[...], rate: pendingRate)
                pendingPCM.removeAll()
            }
            guard let writer, let input, frames > 0 else { throw SpatialAudioError.decoding("The track produced no spatial PCM") }
            let priming = try configuration.encoderPrimingDuration()
            delegate?.holdLastSegment()
            input.markAsFinished()
            let cancellation = WriterCancellation(writer)
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    writer.finishWriting { continuation.resume() }
                }
            } onCancel: {
                cancellation.cancel()
            }
            try checkActive()
            guard writer.status == .completed else { throw encoderError(writer) }
            delegate?.deliverLastSegment(sourceFrames: frames, priming: priming.value)
            try checkActive()
            state = .finished
            return APACConversionReport(sampleRate: sampleRate, sampleFrames: frames,
                                        layout: configuration.layout, peakPCM: peak,
                                        recovery: decoder.recoveryStatistics)
        } catch { fail(); throw error }
    }

    /// Ends the input and pads the output with silence up to the presentation time `end`, so a
    /// stream can pad a long silent tail a segment at a time before `finish`. Append nothing after.
    func pad(to end: CMTime) async throws {
        try beginOperation()
        defer { busy = false }
        do {
            try checkActive()
            try await flush()
            try await appendSilence(until: end)
        } catch { fail(); throw error }
    }

    /// Ends the session without completing its output. Cancelling the calling task does the same.
    public func cancel() {
        guard state == .accepting else { return }
        state = .cancelled
        writer?.cancelWriting()
    }

    private func follow(_ time: CMTime) throws {
        if let previous = packetTime, time != previous {
            guard Self.continues(from: previous, to: time, frames: laced, codec: codec) else {
                throw SpatialAudioError.source(String(format: "The audio timestamps jump from %.3f to %.3f s",
                                                      previous.seconds, time.seconds))
            }
            laced = 0
        }
        packetTime = time
        laced += 1
    }

    /// Whether a packet continues the previous one's timeline. The previous time's `frames` packets
    /// were laced into one block, so the step may span them all, at most a TrueHD access unit or the
    /// longest DTS frame each. A step half a second longer than that, or back by more than 0.1 s,
    /// is a discontinuity.
    static func continues(from previous: CMTime, to time: CMTime, frames: Int, codec: SpatialAudioCodec) -> Bool {
        let longestFrame = codec == .trueHDAtmos ? 40.0 / 48_000 : 4096.0 / 48_000
        let step = CMTimeSubtract(time, previous).seconds
        return step >= -0.1 && step < 0.5 + Double(frames) * longestFrame
    }

    private func beginOperation() throws {
        guard state == .accepting, !busy else { throw SpatialAudioError.invalidState("Session ended or another append is still in progress") }
        busy = true
    }
    private func checkActive() throws {
        try Task.checkCancellation()
        guard state == .accepting else { throw CancellationError() }
        if let error = delegate?.error { throw SpatialAudioError.encoding("APAC segment consumer failed: \(error)") }
    }
    private func fail() { if state == .accepting { state = .failed; writer?.cancelWriting() } }
    private func encoderError(_ writer: AVAssetWriter) -> SpatialAudioError {
        .encoding(writer.error?.localizedDescription ?? "APAC encoder stopped")
    }

    /// Accepts renderer output. Internal so synthetic PCM can exercise muxing and timing without media fixtures.
    func accumulate(_ block: PCMBlock) async throws {
        guard block.channels == configuration.layout.channelCount,
              pendingRate == 0 || pendingRate == block.sampleRate else {
            throw SpatialAudioError.encoding("Audio format changed; begin a new session at a discontinuity")
        }
        pendingRate = block.sampleRate
        var samples = block.samples[...]
        if discarding == nil {
            let leading = configuration.leadingFrames(rate: block.sampleRate)
            discarding = max(leading, 0)
            // A source starting after startTime is padded so its timestamps stay aligned.
            try await appendSilence(frames: -leading, rate: block.sampleRate)
        }
        if let remaining = discarding, remaining > 0 {
            let dropped = min(remaining, block.frames)
            samples = samples.dropFirst(dropped * block.channels)
            discarding = remaining - dropped
        }
        pendingPCM.append(contentsOf: samples)
        try await encodeFullBlocks(rate: block.sampleRate)
    }

    /// Decodes what the decoder still holds. A session without input, such as one started past
    /// the end of its track, has nothing to flush and only pads.
    private func flush() async throws {
        guard hasInput else { return }
        hasInput = false
        let blocks = try decoder.decode(UnsafeRawBufferPointer(start: nil, count: 0), end: true)
        for block in blocks { try await accumulate(block) }
    }

    /// Appends silence until the output reaches the presentation time `end`.
    private func appendSilence(until end: CMTime) async throws {
        let span = CMTimeSubtract(end, configuration.startTime).seconds
        guard span.isFinite, abs(span) < 1e9 else { throw SpatialAudioError.invalidConfiguration("Invalid end time") }
        // A session that decoded nothing pads at the only supported rate.
        if pendingRate == 0 { pendingRate = 48_000 }
        let total = Int((span * Double(pendingRate)).rounded())
        try await appendSilence(frames: total - Int(frames) - pendingPCM.count / configuration.layout.channelCount,
                                rate: pendingRate)
    }

    /// Appends `count` frames of silence, if positive, one block at a time so a long gap does not
    /// hold all of it in memory.
    private func appendSilence(frames count: Int, rate: Int) async throws {
        let channels = configuration.layout.channelCount
        var silence = max(count, 0) * channels
        while silence > 0 {
            let samples = min(silence, 1024 * channels)
            pendingPCM.append(contentsOf: repeatElement(0, count: samples))
            silence -= samples
            try await encodeFullBlocks(rate: rate)
        }
    }

    /// Encodes every complete 1024-frame block of pending PCM.
    private func encodeFullBlocks(rate: Int) async throws {
        let size = 1024 * configuration.layout.channelCount
        var offset = 0
        while pendingPCM.count - offset >= size {
            try await encode(pendingPCM[offset..<offset + size], rate: rate)
            offset += size
        }
        pendingPCM.removeFirst(offset)
    }

    private func prepare(rate: Int) throws {
        guard rate == 48_000 else { throw SpatialAudioError.invalidConfiguration("The initial renderer supports 48 kHz spatial tracks") }
        sampleRate = rate
        let format = try pcmFormat(rate: rate, layout: configuration.layout)
        self.format = format
        let writer: AVAssetWriter
        switch destination {
        case .file(let url): writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        case .segments(let periods, let handler):
            writer = AVAssetWriter(contentType: .mpeg4Movie)
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            writer.preferredOutputSegmentInterval = CMTime(value: Int64(configuration.syncPacketFrequency * 1024 * periods), timescale: CMTimeScale(rate))
            writer.initialSegmentStartTime = configuration.startTime
            let delegate = SegmentDelegate(handler)
            self.delegate = delegate
            writer.delegate = delegate
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAPAC, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: configuration.layout.channelCount,
            AVChannelLayoutKey: layoutData(configuration.layout),
            AVEncoderBitRateKey: configuration.bitRate,
            AVEncoderContentSourceKey: configuration.contentSource.rawValue,
            AVEncoderDynamicRangeControlConfigurationKey: configuration.dynamicRangeConfiguration.rawValue,
            AVEncoderASPFrequencyKey: configuration.syncPacketFrequency,
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw SpatialAudioError.encoding("APAC encoding is unavailable with this configuration")
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw SpatialAudioError.encoding("Could not add APAC audio input") }
        writer.add(input)
        guard writer.startWriting() else { throw encoderError(writer) }
        writer.startSession(atSourceTime: configuration.startTime)
        self.writer = writer
        self.input = input
    }

    /// Encodes interleaved PCM in the configured layout.
    private func encode(_ samples: ArraySlice<Float>, rate: Int) async throws {
        try checkActive()
        if writer == nil { try prepare(rate: rate) }
        guard rate == sampleRate else {
            throw SpatialAudioError.encoding("Audio format changed; begin a new session at a discontinuity")
        }
        guard let writer, let input, let format else { throw SpatialAudioError.encoding("APAC writer was not initialized") }
        let count = samples.count / configuration.layout.channelCount
        let time = CMTimeAdd(configuration.startTime, CMTime(value: frames, timescale: CMTimeScale(sampleRate)))
        let (sample, blockPeak) = try pcmSampleBuffer(samples, gain: powf(10, configuration.gainDB / 20), frames: count,
                                                      format: format, time: time, rate: sampleRate)
        peak = max(peak, blockPeak)
        while !input.isReadyForMoreMediaData {
            try checkActive()
            guard writer.status == .writing else { throw encoderError(writer) }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard input.append(sample) else { throw encoderError(writer) }
        frames += Int64(count)
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
extension APACConfiguration {
    /// The content source and dynamic-range profile for the chosen encoding mode.
    var contentSource: AVAudioContentSource { liveEncoding ? .appleAV_Spatial_Live : .appleAV_Spatial_Offline }
    var dynamicRangeConfiguration: AVAudioDynamicRangeControlConfiguration {
        disablesDynamicRangeControl ? .none : (liveEncoding ? .capture : .movie)
    }
}
