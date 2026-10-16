@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SpatialAudioBridge

@available(macOS 26, iOS 26, tvOS 26, *)
final class SegmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [APACSegment] = []
    func append(_ segment: APACSegment) { lock.withLock { segments.append(segment) } }
    func snapshot() -> [APACSegment] { lock.withLock { segments } }
}

@Suite(.serialized)
struct FixtureTests {
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_TRUEHD_FIXTURE"] != nil))
    func realAtmosProducesAPACAndSampleAccurateDuration() async throws {
        try await validateFile(variable: "SAB_TRUEHD_FIXTURE", codec: .trueHDAtmos)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_DTSX_FIXTURE"] != nil))
    func realDTSXProducesAPACAndSampleAccurateDuration() async throws {
        try await validateFile(variable: "SAB_DTSX_FIXTURE", codec: .dtsX)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_DTSX_ALTERNATE_FIXTURE"] != nil))
    func realAlternateDTSXProducesAPACAndSampleAccurateDuration() async throws {
        try await validateFile(variable: "SAB_DTSX_ALTERNATE_FIXTURE", codec: .dtsX)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private func validateFile(variable: String, codec: SpatialAudioCodec) async throws {
        let input = URL(fileURLWithPath: ProcessInfo.processInfo.environment[variable]!)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sab-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        // 9.1.6 exercises every output channel.
        let report = try await APACTrackConverter.convert(elementaryStream: input, codec: codec, output: output,
                                                          configuration: APACConfiguration(layout: .nineOneSix))
        #expect(report.sampleFrames > 0)
        #expect(report.sampleRate == 48_000)
        #expect(report.peakPCM > 0 && report.peakPCM.isFinite)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try #require(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try #require(formats.first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatAPAC)
        let stream = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format))
        #expect(stream.pointee.mChannelsPerFrame == 16)
        let channelLayout = try #require(CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: nil))
        #expect(channelLayout.pointee.mChannelLayoutTag == SpatialAudioLayout.nineOneSix.tag)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - report.duration) < 0.025)
        // Decode the generated file through Apple's decoder, verifying nonempty spatial PCM.
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 16,
            AVChannelLayoutKey: layoutData(.nineOneSix),
        ])
        reader.add(decoded)
        #expect(reader.startReading())
        var decodedFrames: Int64 = 0
        var heightEnergy = 0.0
        while let buffer = decoded.copyNextSampleBuffer() {
            decodedFrames += Int64(CMSampleBufferGetNumSamples(buffer))
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            #expect(status == noErr)
            for (i, value) in data.enumerated() where i % 16 >= 10 { heightEnergy += Double(value * value) }
        }
        #expect(reader.status == .completed)
        #expect(abs(decodedFrames - report.sampleFrames) <= 1024)
        #expect(heightEnergy > 0)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_TRUEHD_FIXTURE"] != nil))
    func fragmentsHaveInitializationAndContinuousTimedAudio() async throws {
        for startTime in [CMTime.zero, CMTime(value: 2, timescale: 1)] {
            let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAB_TRUEHD_FIXTURE"]!))
            defer { try? source.close() }
            let collector = SegmentCollector()
            var configuration = APACConfiguration(layout: .sevenOneFour, startTime: startTime)
            // Dropping 480 frames makes the final packet padded, whatever the fixture's length.
            configuration.inputStartTime = CMTimeSubtract(startTime, CMTime(value: 480, timescale: 48_000))
            let converter = try SpatialAudioTranscoder(codec: .trueHDAtmos,
                destination: .segments(onSegment: { collector.append($0) }),
                configuration: configuration)
            #expect(await converter.conversionSpeed == nil)
            while let data = try source.read(upToCount: 64 * 1024), !data.isEmpty { try await converter.append(data) }
            #expect((await converter.conversionSpeed ?? 0) > 1)
            let report = try await converter.finish()
            let segments = collector.snapshot()
            #expect(segments.first?.kind == .initialization)
            let media = segments.filter { $0.kind == .media }
            #expect(media.count > 1)
            var end: CMTime?
            var duration = 0.0
            for segment in media {
                #expect(!segment.data.isEmpty)
                let start = try #require(segment.startTime)
                let length = try #require(segment.duration)
                if let end { #expect(abs(CMTimeSubtract(start, end).seconds) < 0.025) }
                #expect(length.seconds > 0)
                end = CMTimeAdd(start, length)
                duration += length.seconds
            }
            let priming = try APACConfiguration(layout: .sevenOneFour).encoderPrimingDuration()
            let firstPTS = try #require(media.first?.startTime?.seconds)
            #expect(abs(firstPTS - max(0, startTime.seconds - priming.seconds)) < 0.001)
            #expect((Int(report.sampleFrames) + Int(priming.value)) % 1024 != 0)
            // The last fragment ends at the last source frame, without the final packet's padding.
            #expect(abs(duration - Double(report.sampleFrames) / 48_000 - priming.seconds) < 1e-6)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sab-hls-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = try APACHLSOutput(directory: directory, configuration: configuration)
            guard case .segments(_, let persist) = output.destination else { Issue.record("Expected segmented output"); return }
            for segment in segments { try persist(segment) }
            try output.finish()
            let playlist = try String(contentsOf: output.playlistURL, encoding: .utf8)
            #expect(playlist.contains("#EXT-X-ENDLIST"))
            for filename in playlist.split(separator: "\n") where !filename.hasPrefix("#") {
                #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(String(filename)).path))
            }
            let fragmentedFile = directory.appendingPathComponent("check.mp4")
            try segments.reduce(into: Data()) { $0.append($1.data) }.write(to: fragmentedFile)
            let fragmentedAsset = AVURLAsset(url: fragmentedFile)
            let fragmentedTracks = try await fragmentedAsset.loadTracks(withMediaType: .audio)
            let fragmentedTrack = try #require(fragmentedTracks.first)
            let formats = try await fragmentedTrack.load(.formatDescriptions)
            let format = try #require(formats.first)
            #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatAPAC)
            let stream = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format))
            #expect(stream.pointee.mChannelsPerFrame == 12)
            let channelLayout = try #require(CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: nil))
            #expect(channelLayout.pointee.mChannelLayoutTag == SpatialAudioLayout.sevenOneFour.tag)
            let reader = try AVAssetReader(asset: fragmentedAsset)
            let pcm = AVAssetReaderTrackOutput(track: fragmentedTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(pcm)
            #expect(reader.startReading())
            let first = try #require(pcm.copyNextSampleBuffer())
            var decodedFrames = CMSampleBufferGetNumSamples(first)
            while let buffer = pcm.copyNextSampleBuffer() { decodedFrames += CMSampleBufferGetNumSamples(buffer) }
            #expect(decodedFrames == Int(report.sampleFrames))
            #expect(reader.status == .completed)
        }
    }
}
