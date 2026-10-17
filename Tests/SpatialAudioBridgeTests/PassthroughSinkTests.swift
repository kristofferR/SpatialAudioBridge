@preconcurrency import AVFoundation
import Synchronization
import Testing
@testable import SpatialAudioBridge

/// A big-endian IEC 61937 burst of `type` with a short payload.
@available(macOS 26, iOS 26, tvOS 26, *)
private func burst(type: UInt8) -> Data {
    Data([0xF8, 0x72, 0x4E, 0x1F, 0x00, type, 0x00, 0x10] + [UInt8](repeating: 0x0B, count: 2) + [UInt8](repeating: 0, count: 64))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func passthroughSinkTakesNothingWithoutATimelineAndBoundsItsBuffer() async throws {
    let sink = try SpatialAudioPassthroughSink(codec: .trueHDAtmos, synchronizer: AVSampleBufferRenderSynchronizer(),
                                               bufferLimit: 64)
    defer { sink.close() }
    #expect(sink.write(Data(count: 10)) == 0)
    sink.begin(at: .zero)
    // Zeros between bursts are skipped, but only what fits is taken at once.
    #expect(sink.write(Data(count: 200)) == 64)
    #expect(!sink.isReady)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func passthroughSinkReportsAFailureOnceAndRefusesInputUntilTheNextTimeline() async throws {
    let failures = Mutex(0)
    let sink = try SpatialAudioPassthroughSink(codec: .trueHDAtmos, synchronizer: AVSampleBufferRenderSynchronizer(),
                                               onFailure: { _ in failures.withLock { $0 += 1 } })
    defer { sink.close() }
    sink.begin(at: .zero)
    // An AC-3 burst cannot be unpacked to TrueHD.
    #expect(sink.write(burst(type: 0x01)) > 0)
    let deadline = ContinuousClock.now + .seconds(3)
    while sink.failure == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(sink.failure != nil)
    #expect(failures.withLock { $0 } == 1)
    #expect(sink.write(burst(type: 0x01)) == 0)
    sink.begin(at: .zero)
    #expect(sink.failure == nil)
    #expect(sink.write(Data(count: 4)) == 4)
}
