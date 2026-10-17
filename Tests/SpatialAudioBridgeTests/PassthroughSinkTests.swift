@preconcurrency import AVFoundation
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
    // An ended timeline takes nothing more, and with no audio it is ready at once.
    sink.end()
    #expect(sink.write(Data(count: 4)) == 0)
    let deadline = ContinuousClock.now + .seconds(3)
    while !sink.isReady, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(sink.isReady)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func passthroughSinkReportsAFailureAndRefusesInputUntilTheNextTimeline() async throws {
    let sink = try SpatialAudioPassthroughSink(codec: .trueHDAtmos, synchronizer: AVSampleBufferRenderSynchronizer())
    defer { sink.close() }
    sink.begin(at: .zero)
    // An AC-3 burst cannot be unpacked to TrueHD.
    #expect(sink.write(burst(type: 0x01)) > 0)
    let deadline = ContinuousClock.now + .seconds(3)
    while sink.failure == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(sink.failure != nil)
    #expect(!sink.isReady)
    #expect(sink.write(burst(type: 0x01)) == 0)
    sink.begin(at: .zero)
    #expect(sink.failure == nil)
    #expect(sink.write(Data(count: 4)) == 4)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func passthroughSinkFailsATimelineThatEndsInsideABurst() async throws {
    let sink = try SpatialAudioPassthroughSink(codec: .trueHDAtmos, synchronizer: AVSampleBufferRenderSynchronizer())
    defer { sink.close() }
    sink.begin(at: .zero)
    #expect(sink.write(burst(type: 0x16).prefix(12)) == 12)
    sink.end()
    let deadline = ContinuousClock.now + .seconds(3)
    while sink.failure == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(sink.failure != nil)
    #expect(!sink.isReady)
    #expect(await sink.queuedAhead == .zero)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func passthroughSinkReportsAPauseBurstAsADiscontinuity() async throws {
    let sink = try SpatialAudioPassthroughSink(codec: .trueHDAtmos, synchronizer: AVSampleBufferRenderSynchronizer())
    defer { sink.close() }
    sink.begin(at: .zero)
    #expect(sink.write(burst(type: 0x03)) > 0)
    let deadline = ContinuousClock.now + .seconds(3)
    while sink.failure == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard case .discontinuity? = sink.failure as? SpatialAudioError else {
        Issue.record("Expected a discontinuity, got \(String(describing: sink.failure))")
        return
    }
    #expect(sink.progress == nil)
    // A new timeline is all it takes.
    sink.begin(at: CMTime(value: 2, timescale: 1))
    #expect(sink.failure == nil)
    #expect(sink.write(Data(count: 4)) == 4)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func passthroughSinkReportsProgressForItsTimeline() async throws {
    let sink = try SpatialAudioPassthroughSink(codec: .trueHDAtmos, synchronizer: AVSampleBufferRenderSynchronizer())
    defer { sink.close() }
    #expect(sink.progress == nil)
    let start = CMTime(value: 7, timescale: 1)
    sink.begin(at: start)
    var deadline = ContinuousClock.now + .seconds(3)
    while sink.progress == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(sink.progress == SpatialAudioRendererProgress(timelineStart: start, submittedEnd: start, isFinal: false))
    // Filler alone has nothing to play, and still reports its stream as final.
    #expect(sink.write(Data(count: 64)) == 64)
    sink.end()
    deadline = ContinuousClock.now + .seconds(3)
    while sink.progress?.isFinal != true, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(sink.progress == SpatialAudioRendererProgress(timelineStart: start, submittedEnd: start, isFinal: true))
    #expect(sink.isReady)
    // The next timeline starts without the previous one's progress.
    sink.begin(at: .zero)
    #expect(sink.progress == nil)
}
