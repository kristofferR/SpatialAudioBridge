#if os(macOS)
import CryptoKit
import Darwin
import Dispatch
import Foundation
import Testing
@testable import SpatialAudioBridge

@Suite(.serialized)
struct EncoderPerformanceTests {
    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_ENCODER_PROFILE"] == "1"),
          .timeLimit(.minutes(3)), arguments: [12, 16], [317, 1024])
    func profileDirectEncoder(channels: Int, chunk: Int) throws {
        let frames = 192_000
        let layout: SpatialAudioLayout = channels == 12 ? .sevenOneFour : .nineOneSix
        let configuration = APACConfiguration(layout: layout, liveEncoding: true)
        var pcm = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let frequency = channel == 3 ? 60.0 : 211.0 + Double(channel) * 173
                pcm[frame * channels + channel] = Float(0.2 * sin(2 * .pi * frequency * Double(frame) / 48_000))
            }
        }
        var expectedHash: String?
        // Pass zero warms the codec; keep its result visible but exclude it from timing comparisons.
        for pass in 0..<6 {
            var before = rusage()
            try #require(getrusage(RUSAGE_SELF, &before) == 0)
            let start = DispatchTime.now().uptimeNanoseconds
            let encoder = try APACEncoder(configuration: configuration)
            var packets: [APACEncoder.Packet] = []
            var firstOutput: Int?
            for offset in stride(from: 0, to: frames, by: chunk) {
                let end = min(offset + chunk, frames)
                let output = try encoder.encode(pcm[offset * channels..<end * channels])
                if !output.isEmpty && firstOutput == nil { firstOutput = end }
                packets += output
            }
            packets += try encoder.encode([], final: true)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            var after = rusage()
            try #require(getrusage(RUSAGE_SELF, &after) == 0)
            try #require(!packets.isEmpty)
            #expect(packets.first?.isIndependent == true)
            // Hash packet boundaries and dependency flags as well as bytes, outside the timed region.
            var hash = SHA256()
            for packet in packets {
                var size = UInt64(packet.data.count).bigEndian
                withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
                hash.update(data: Data([packet.isIndependent ? 1 : 0]))
                hash.update(data: packet.data)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            if let expectedHash { #expect(digest == expectedHash) }
            expectedHash = digest
            let seconds = Double(elapsed) / 1_000_000_000
            let values: [String: Any] = [
                "channels": channels, "chunkFrames": chunk, "inputFrames": frames, "pass": pass,
                "warmup": pass == 0, "wallSeconds": seconds,
                "cpuSeconds": cpuSeconds(after) - cpuSeconds(before),
                "inputFramesPerSecond": Double(frames) / seconds,
                "processPeakRSSBytes": after.ru_maxrss,
                "packets": packets.count, "packetBytes": packets.reduce(0) { $0 + $1.data.count },
                "packetSHA256": digest, "primingFrames": encoder.primingFrames,
                "firstOutputAtSubmittedFrames": firstOutput.map { $0 as Any } ?? NSNull(),
                "bitRate": configuration.bitRate, "syncPacketFrequency": configuration.syncPacketFrequency,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
            ]
            let json = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            print("SAB_ENCODER_PROFILE \(String(decoding: json, as: UTF8.self))")
        }
    }

    private func cpuSeconds(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
