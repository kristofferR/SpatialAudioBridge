@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers
import AudioToolbox

private final class SegmentDelegate: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    let handler: @Sendable (APACSegment) throws -> Void
    private let lock = NSLock()
    private var failure: String?
    var error: String? { lock.withLock { failure } }
    init(_ handler: @escaping @Sendable (APACSegment) throws -> Void) { self.handler = handler }
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        let track = segmentReport?.trackReports.first
        do {
            try handler(APACSegment(kind: segmentType == .initialization ? .initialization : .media,
                                   data: Data(data), startTime: track?.earliestPresentationTimeStamp,
                                   duration: track?.duration))
        } catch { lock.withLock { if failure == nil { failure = String(describing: error) } } }
    }
}

/// Streaming, bounded conversion of one continuous demuxed track. Create a new session after a seek.
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
    private var busy = false
    private enum State { case accepting, finished, cancelled, failed }
    private var state = State.accepting

    public init(codec: SpatialAudioCodec, destination: APACDestination,
                configuration: APACConfiguration = .init()) throws {
        guard configuration.gainDB.isFinite, (-60...12).contains(configuration.gainDB),
              configuration.bitRate > 0, configuration.bitRate <= 4_096_000,
              configuration.startTime.isNumeric, configuration.startTime >= .zero,
              (3...600).contains(configuration.syncPacketFrequency) else {
            throw SpatialAudioError.invalidConfiguration("Invalid APAC gain, bitrate, timestamp or sync interval")
        }
        if case .segments(let periods, _) = destination, !(1...20).contains(periods) {
            throw SpatialAudioError.invalidConfiguration("Segment sync periods must be between 1 and 20")
        }
        self.configuration = configuration
        self.destination = destination
        self.decoder = try Decoder(codec: codec, layout: configuration.layout)
    }

    /// Pass the compressed audio payload, including DTS-HD extensions. MKV/TS bytes must be demuxed first.
    /// Await each call before appending again. Timestamps advance by decoded samples without drift.
    public func append(_ data: Data) async throws {
        try beginOperation()
        defer { busy = false }
        do {
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

    public func finish() async throws -> APACConversionReport {
        try beginOperation()
        defer { busy = false }
        do {
            try checkActive()
            let blocks = try decoder.decode(UnsafeRawBufferPointer(start: nil, count: 0), end: true)
            for block in blocks { try await accumulate(block) }
            if !pendingPCM.isEmpty {
                try await encode(PCMBlock(samples: pendingPCM, frames: pendingPCM.count / configuration.layout.channelCount,
                                          sampleRate: pendingRate, channels: configuration.layout.channelCount))
                pendingPCM.removeAll()
            }
            guard let writer, let input, frames > 0 else { throw SpatialAudioError.decoding("The track produced no spatial PCM") }
            input.markAsFinished()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    writer.finishWriting { continuation.resume() }
                }
            } onCancel: {
                writer.cancelWriting()
            }
            try checkActive()
            guard writer.status == .completed else { throw encoderError(writer) }
            state = .finished
            return APACConversionReport(sampleRate: sampleRate, sampleFrames: frames,
                                        layout: configuration.layout, peakPCM: peak)
        } catch { fail(); throw error }
    }

    public func cancel() {
        guard state == .accepting else { return }
        state = .cancelled
        writer?.cancelWriting()
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

    private func accumulate(_ block: PCMBlock) async throws {
        guard block.channels == configuration.layout.channelCount,
              pendingRate == 0 || pendingRate == block.sampleRate else {
            throw SpatialAudioError.encoding("Audio format changed; begin a new session at a discontinuity")
        }
        pendingRate = block.sampleRate
        pendingPCM.append(contentsOf: block.samples)
        let size = 1024 * configuration.layout.channelCount
        while pendingPCM.count >= size {
            let pcm = Array(pendingPCM.prefix(size))
            pendingPCM.removeFirst(size)
            try await encode(PCMBlock(samples: pcm, frames: 1024, sampleRate: block.sampleRate, channels: block.channels))
        }
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
            AVEncoderContentSourceKey: AVAudioContentSource.appleAV_Spatial_Offline.rawValue,
            AVEncoderDynamicRangeControlConfigurationKey: AVAudioDynamicRangeControlConfiguration.movie.rawValue,
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

    private func encode(_ block: PCMBlock) async throws {
        try checkActive()
        if writer == nil { try prepare(rate: block.sampleRate) }
        guard block.sampleRate == sampleRate, block.channels == configuration.layout.channelCount else {
            throw SpatialAudioError.encoding("Audio format changed; begin a new session at a discontinuity")
        }
        guard let writer, let input, let format else { throw SpatialAudioError.encoding("APAC writer was not initialized") }
        let gain = powf(10, configuration.gainDB / 20)
        let pcm = block.samples.map { $0 * gain }
        peak = max(peak, pcm.lazy.map { abs($0) }.max() ?? 0)
        let time = CMTimeAdd(configuration.startTime, CMTime(value: frames, timescale: CMTimeScale(sampleRate)))
        let sample = try pcmSampleBuffer(pcm, frames: block.frames, format: format, time: time, rate: sampleRate)
        while !input.isReadyForMoreMediaData {
            try checkActive()
            guard writer.status == .writing else { throw encoderError(writer) }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard input.append(sample) else { throw encoderError(writer) }
        frames += Int64(block.frames)
    }
}
