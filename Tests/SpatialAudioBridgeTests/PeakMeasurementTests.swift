@preconcurrency import AVFoundation
import Accelerate
import Foundation
import Testing
@testable import SpatialAudioBridge

/// A four-times, 33-tap Blackman-windowed sinc estimate, not a certified true-peak meter.
@available(macOS 26, iOS 26, tvOS 26, *)
private func reconstructedPeak(_ samples: [Float], channels: Int) -> Float {
    let frames = samples.count / channels
    let radius = 16
    var peak = samples.reduce(Float(0)) { max($0, abs($1)) }
    let padded = [Float](repeating: 0, count: radius * channels) + samples
        + [Float](repeating: 0, count: radius * channels)
    var output = [Float](repeating: 0, count: frames)
    for phase in 1...3 {
        let fraction = Double(phase) / 4
        var filter = (-radius...radius).map { tap -> Float in
            let x = fraction - Double(tap)
            guard abs(x) <= Double(radius) else { return 0 }
            let window = 0.42 + 0.5 * cos(.pi * x / Double(radius))
                + 0.08 * cos(2 * .pi * x / Double(radius))
            return Float(sin(.pi * x) / (.pi * x) * window)
        }
        let sum = filter.reduce(0, +)
        filter = filter.map { $0 / sum }
        for channel in 0..<channels {
            padded.withUnsafeBufferPointer { source in
                filter.withUnsafeBufferPointer { coefficients in
                    output.withUnsafeMutableBufferPointer { destination in
                        vDSP_conv(source.baseAddress! + channel, vDSP_Stride(channels),
                                  coefficients.baseAddress!, 1, destination.baseAddress!, 1,
                                  vDSP_Length(frames), vDSP_Length(filter.count))
                    }
                }
            }
            var phasePeak: Float = 0
            vDSP_maxmgv(output, 1, &phasePeak, vDSP_Length(frames))
            peak = max(peak, phasePeak)
        }
    }
    return peak
}

@available(macOS 26, iOS 26, tvOS 26, *)
private func samplePeak(_ samples: [Float]) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}

@available(macOS 26, iOS 26, tvOS 26, *)
private func probePCM(_ directory: URL, signal: String, channels: Int, stage: String) throws -> [Float] {
    let data = try Data(contentsOf: directory.appendingPathComponent("\(signal)-\(channels)-\(stage).f32"))
    try #require(data.count == 96_000 * channels * 4)
    let samples = data.withUnsafeBytes { bytes in
        stride(from: 0, to: data.count, by: 4).map {
            Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
        }
    }
    try #require(samples.allSatisfy { $0.isFinite })
    return samples
}

@Suite(.serialized)
struct PeakMeasurementTests {
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func reconstructionDetectsAnIntersamplePeak() {
        // Quarter-rate sinusoid: sampled peaks are sqrt(1/2), the halfway peak is 1.
        let samples = (0..<4096).map { Float(sin(Double($0) * .pi / 2 + .pi / 4)) }
        #expect(abs(samplePeak(samples) - Float(sqrt(0.5))) < 0.0001)
        // Silence padding introduces boundary ringing. Test a long, smoothly tapered tone.
        let tapered = samples.enumerated().map { index, value in
            value * Float(min(1.0, Double(min(index, samples.count - 1 - index)) / 128))
        }
        #expect(abs(reconstructedPeak(tapered, channels: 1) - 1) < 0.005)
        let interleaved = tapered.flatMap { [Float(0), $0] }
        #expect(abs(reconstructedPeak(interleaved, channels: 2) - 1) < 0.005)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_PEAK_PROBES_DIR"] != nil),
          .timeLimit(.minutes(5)), arguments: [false, true], [12, 16])
    func measureAPACPeaks(live: Bool, channels: Int) async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SAB_PEAK_PROBES_DIR"]))
        let layout: SpatialAudioLayout = channels == 12 ? .sevenOneFour : .nineOneSix
        for signal in ["tone1k", "tone8k", "transients", "multichannel"] {
            let input = try probePCM(directory, signal: signal, channels: channels, stage: "input")
            let limited = try probePCM(directory, signal: signal, channels: channels, stage: "limited")
            try #require(samplePeak(input) > 1)
            try #require(samplePeak(limited) <= 0.988_554)
            let limitedReconstructed = reconstructedPeak(limited, channels: channels)
            for gainDB in [Float(0), Float(3)] {
                let configuration = APACConfiguration(layout: layout, gainDB: gainDB, liveEncoding: live)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("peaks-\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: url) }
                let collector = SegmentCollector()
                let destination: APACDestination = live
                    ? .segments(syncPeriodsPerSegment: 1, onSegment: { collector.append($0) }) : .file(url)
                let transcoder = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: destination,
                                                            configuration: configuration)
                for offset in stride(from: 0, to: 96_000, by: 317) {
                    let count = min(317, 96_000 - offset)
                    try await transcoder.accumulate(PCMBlock(
                        samples: Array(limited[offset * channels..<(offset + count) * channels]),
                        frames: count, sampleRate: 48_000, channels: channels))
                }
                let report = try await transcoder.finish()
                try #require(report.sampleFrames == 96_000)
                if live {
                    try collector.snapshot().reduce(into: Data()) { $0.append($1.data) }.write(to: url)
                }
                let decoded = try await readPresentedAudio(url, layout: layout)
                try #require(decoded.frames == 96_000)
                let scaled = limited.map { $0 * powf(10, gainDB / 20) }
                #expect(abs(report.peakPCM - samplePeak(scaled)) < 0.00001)
                let measurements: [String: Any] = [
                    "signal": signal, "channels": channels, "live": live, "gainDB": gainDB,
                    "sampleRate": 48_000, "bitRate": configuration.bitRate,
                    "syncPacketFrequency": configuration.syncPacketFrequency,
                    "primingFrames": try configuration.encoderPrimingDuration().value,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "inputSamplePeak": samplePeak(input), "limitedSamplePeak": samplePeak(limited),
                    "limitedReconstructedPeak4x": limitedReconstructed,
                    "encoderInputSamplePeak": report.peakPCM,
                    "encoderInputReconstructedPeak4x": limitedReconstructed * powf(10, gainDB / 20),
                    "decodedSamplePeak": samplePeak(decoded.samples),
                    "decodedReconstructedPeak4x": reconstructedPeak(decoded.samples, channels: channels),
                ]
                let json = try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys])
                print("SAB_PEAK_MEASUREMENT \(String(decoding: json, as: UTF8.self))")
            }
        }
    }
}
