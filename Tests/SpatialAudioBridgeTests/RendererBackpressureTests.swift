@preconcurrency import AVFoundation
import Synchronization
import Testing
@testable import SpatialAudioBridge

/// Records buffer metadata, never sends a CMSampleBuffer across an isolation boundary.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class ControlledRendererOutput: SpatialAudioRendererOutput, Sendable {
    struct Record: Sendable, Equatable {
        let time: Double
        let data: Data
        let trimmed: Bool
    }
    struct State {
        var capacity = Int.max
        var blockedChecks = 0
        var failed = false
        var failureReads = 0
        var muted = false
        var volume: Float = 1
        var records: [Record] = []
        var completions: [@Sendable (Bool) -> Void] = []
    }
    let storage = Mutex(State())

    var isReadyForMoreMediaData: Bool {
        storage.withLock {
            if $0.capacity == 0 { $0.blockedChecks += 1 }
            return $0.capacity > 0
        }
    }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { !records.isEmpty }
    var status: AVQueuedSampleBufferRenderingStatus {
        storage.withLock {
            if $0.failed { $0.failureReads += 1 }
            return $0.failed ? .failed : .rendering
        }
    }
    var error: (any Error)? { nil }
    var isMuted: Bool {
        get { storage.withLock { $0.muted } }
        set { storage.withLock { $0.muted = newValue } }
    }
    var volume: Float {
        get { storage.withLock { $0.volume } }
        set { storage.withLock { $0.volume = newValue } }
    }
    var records: [Record] { storage.withLock { $0.records } }
    var blockedChecks: Int { storage.withLock { $0.blockedChecks } }
    var failureReads: Int { storage.withLock { $0.failureReads } }

    func setCapacity(_ capacity: Int) { storage.withLock { $0.capacity = capacity } }
    func setFailed(_ failed: Bool) { storage.withLock { $0.failed = failed } }
    func enqueue(_ buffer: CMSampleBuffer) {
        let block = CMSampleBufferGetDataBuffer(buffer)!
        var data = Data(count: CMBlockBufferGetDataLength(block))
        _ = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        let record = Record(time: CMSampleBufferGetPresentationTimeStamp(buffer).seconds, data: data,
                            trimmed: CMGetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                                                     attachmentModeOut: nil) != nil)
        storage.withLock {
            // Record a violation as well, so a broken implementation cannot hide it by blocking here.
            #expect($0.capacity > 0)
            #expect(!$0.failed)
            $0.capacity = max(0, $0.capacity - 1)
            $0.records.append(record)
        }
    }
    func flush() { storage.withLock { $0.failed = false } }
    func flush(fromSourceTime time: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) {
        storage.withLock { $0.completions.append(completionHandler) }
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
private func outputPackets(_ count: Int) -> [APACEncoder.Packet] {
    (0..<count).map { .init(data: Data([UInt8($0)]), isIndependent: $0 == 0) }
}

@available(macOS 26, iOS 26, tvOS 26, *)
private func waitForOutput(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw SpatialAudioError.invalidState("Timed out waiting for the controlled renderer")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererWaitsForCapacityAtEveryPacket() async throws {
    let output = ControlledRendererOutput()
    output.setCapacity(1)
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    let task = Task { try await renderer.submit(outputPackets(3), generation: 0) }
    defer { task.cancel() }
    try await waitForOutput { output.blockedChecks > 0 }
    #expect(output.records.count == 1)
    output.setCapacity(1)
    try await waitForOutput { output.records.count == 2 }
    #expect(output.records.count == 2)
    output.setCapacity(1)
    try await task.value
    #expect(output.records.map(\.data) == [Data([0]), Data([1]), Data([2])])
    #expect(abs(output.records[2].time - output.records[0].time - 2048.0 / 48_000) < 1e-9)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererCancellationDuringCapacityWaitIsTerminal() async throws {
    let output = ControlledRendererOutput()
    output.setCapacity(1)
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    let task = Task { try await renderer.submit(outputPackets(3), generation: 0) }
    defer { task.cancel() }
    try await waitForOutput { output.blockedChecks > 0 }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    output.setCapacity(10)
    await #expect(throws: SpatialAudioError.self) { try await renderer.enqueue(Data(), time: .zero) }
    #expect(output.records.count == 1)
    try await renderer.begin(at: .zero)
    try await renderer.enqueue(Data(), time: .zero)
    try await renderer.submit(outputPackets(1), generation: 1)
    #expect(output.records.count == 2)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererResetDiscardsTheRestOfASuspendedBatch() async throws {
    let output = ControlledRendererOutput()
    output.setCapacity(1)
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    let task = Task { try await renderer.submit(outputPackets(3), generation: 0) }
    defer { task.cancel() }
    try await waitForOutput { output.blockedChecks > 0 }
    try await renderer.begin(at: CMTime(seconds: 10, preferredTimescale: 48_000))
    output.setCapacity(10)
    await #expect(throws: CancellationError.self) { try await task.value }
    try await renderer.submit(outputPackets(1), generation: 1)
    #expect(output.records.count == 2)
    #expect(abs(output.records[1].time - output.records[0].time - 10) < 1e-9)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test(arguments: [true, false])
func rendererIgnoresFlushCompletionAfterTimelineFailure(flushed: Bool) async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    try await renderer.submit(outputPackets(4), generation: 0)
    await renderer.refill(from: .zero)
    await #expect(throws: SpatialAudioError.self) {
        try await renderer.enqueue(Data(), time: CMTime(seconds: 120, preferredTimescale: 1))
    }
    // Execute the production callback handler deterministically after the failure, for both the
    // partial-flush success and full-requeue fallback paths.
    await renderer.enqueueAgain(from: .zero, flushed: flushed, generation: 0)
    await renderer.refill(from: nil)
    #expect(output.records.count == 4)
    await #expect(throws: SpatialAudioError.self) { try await renderer.endOfStream() }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererReplayPreservesPrimingAndWaitsForCapacityBeforeNewAudio() async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    try await renderer.submit(outputPackets(4), generation: 0)
    let original = output.records
    output.setCapacity(1)
    await renderer.refill(from: nil)
    try await waitForOutput { output.blockedChecks > 0 }
    #expect(output.records.count == 5)
    let task = Task { try await renderer.submit(outputPackets(1), generation: 0) }
    defer { task.cancel() }
    output.setCapacity(1)
    try await waitForOutput { output.records.count == 6 }
    #expect(output.records.last?.data == Data([1]))
    output.setCapacity(10)
    try await task.value
    let replay = Array(output.records[4..<8])
    #expect(replay.map(\.time) == original.map(\.time))
    #expect(replay.map(\.data) == original.map(\.data))
    #expect(replay.map(\.trimmed) == [true, true, false, false])
    #expect(output.records.count == 9)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererResetInvalidatesAnOldFlushWithoutUnblockingTheNewRefill() async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    try await renderer.submit(outputPackets(4), generation: 0)
    await renderer.refill(from: .zero)
    try await renderer.begin(at: .zero)
    try await renderer.submit(outputPackets(4), generation: 1)
    await renderer.refill(from: .zero)
    await renderer.enqueueAgain(from: .zero, flushed: false, generation: 0)
    #expect(output.records.count == 8)
    await renderer.enqueueAgain(from: .zero, flushed: true, generation: 1)
    try await waitForOutput { output.records.count == 10 }
    try await renderer.submit(outputPackets(1), generation: 1)
    #expect(output.records.count == 11)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererRestartsReplayAfterAnotherAutomaticFlush() async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    try await renderer.submit(outputPackets(4), generation: 0)
    let original = output.records
    output.setCapacity(1)
    await renderer.refill(from: nil)
    try await waitForOutput { output.blockedChecks > 0 }
    #expect(output.records.count == 5)
    // The second native flush loses that first replayed primer. It must be replayed again,
    // rather than continuing at replayIndex 1 and losing the sync packet.
    await renderer.refill(from: .zero)
    output.setCapacity(4)
    try await waitForOutput { output.records.count == 9 }
    let restarted = Array(output.records[5..<9])
    #expect(restarted.map(\.time) == original.map(\.time))
    #expect(restarted.map(\.data) == original.map(\.data))
    #expect(restarted.map(\.trimmed) == [true, true, false, false])
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererCoalescesNotificationsDuringAPendingNativeFlush() async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    try await renderer.submit(outputPackets(4), generation: 0)
    let original = output.records
    await renderer.refill(from: .zero)
    await renderer.refill(from: nil)
    await renderer.refill(from: CMTime(value: 1024, timescale: 48_000))
    #expect(output.records.count == 4)
    // A full refill is needed even if the original partial flush succeeded, because the newer
    // notifications may have dropped the sync/priming packets before that partial flush time.
    await renderer.enqueueAgain(from: .zero, flushed: true, generation: 0)
    try await waitForOutput { output.records.count == 8 }
    let restarted = Array(output.records[4..<8])
    #expect(restarted.map(\.time) == original.map(\.time))
    #expect(restarted.map(\.data) == original.map(\.data))
    #expect(restarted.map(\.trimmed) == [true, true, false, false])
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererFailureDuringBlockedReplayStaysTerminal() async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    try await renderer.submit(outputPackets(4), generation: 0)
    output.setCapacity(0)
    await renderer.refill(from: nil)
    try await waitForOutput { output.blockedChecks > 0 }
    output.setFailed(true)
    try await waitForOutput { output.failureReads > 0 }
    // Even if the native output subsequently clears its own error, the timeline remains failed.
    output.setFailed(false)
    output.setCapacity(10)
    await #expect(throws: SpatialAudioError.self) { try await renderer.submit(outputPackets(1), generation: 0) }
    #expect(output.records.count == 4)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test(arguments: [0, 1, 317])
func rendererEndsEmptyAndShortStreams(frames: Int) async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    if frames > 0 {
        let block = PCMBlock(samples: [Float](repeating: 0, count: frames * 12), frames: frames,
                             sampleRate: 48_000, channels: 12)
        try await renderer.play([block], generation: 0)
    }
    try await renderer.endOfStream()
    await #expect(throws: SpatialAudioError.self) { try await renderer.enqueue(Data(), time: .zero) }
    if frames > 0 { #expect(!output.records.isEmpty) }
    try await renderer.begin(at: .zero)
    try await renderer.enqueue(Data(), time: .zero)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererResetDuringFinalFlushDoesNotEndTheNewTimeline() async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    let block = PCMBlock(samples: [Float](repeating: 0, count: 317 * 12), frames: 317,
                         sampleRate: 48_000, channels: 12)
    try await renderer.play([block], generation: 0)
    output.setCapacity(0)
    let task = Task { try await renderer.endOfStream() }
    defer { task.cancel() }
    try await waitForOutput { output.blockedChecks > 0 }
    let waiting = Task { try await renderer.enqueue(Data(), time: .zero) }
    defer { waiting.cancel() }
    try await waitForOutput { await renderer.waitingInputCount == 1 }
    try await renderer.begin(at: CMTime(seconds: 10, preferredTimescale: 1))
    output.setCapacity(10)
    await #expect(throws: CancellationError.self) { try await task.value }
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(output.records.isEmpty)
    try await renderer.enqueue(Data(), time: CMTime(seconds: 10, preferredTimescale: 1))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererSerializesInputAndFinalizationBehindAnActiveFlush() async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    let block = PCMBlock(samples: [Float](repeating: 0, count: 317 * 12), frames: 317,
                         sampleRate: 48_000, channels: 12)
    try await renderer.play([block], generation: 0)
    output.setCapacity(1)
    let first = Task { try await renderer.endOfStream() }
    defer { first.cancel() }
    try await waitForOutput { output.blockedChecks > 0 }
    #expect(output.records.count == 1)
    let laterInput = Task { try await renderer.enqueue(Data(), time: .zero) }
    let laterEnd = Task { try await renderer.endOfStream() }
    defer { laterInput.cancel(); laterEnd.cancel() }
    try await waitForOutput { await renderer.waitingInputCount == 2 }
    #expect(output.records.count == 1)
    output.setCapacity(100)
    try await first.value
    await #expect(throws: SpatialAudioError.self) { try await laterInput.value }
    await #expect(throws: SpatialAudioError.self) { try await laterEnd.value }
    #expect(output.records.count > 1)
    // Rejecting the queued calls must leave the successfully ended timeline available for replay.
    let count = output.records.count
    await renderer.refill(from: nil)
    try await waitForOutput { output.records.count == count * 2 }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererCancellationWhileWaitingForInputOwnershipIsTerminal() async throws {
    let output = ControlledRendererOutput()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos,
        synchronizer: AVSampleBufferRenderSynchronizer(), output: output)
    let block = PCMBlock(samples: [Float](repeating: 0, count: 317 * 12), frames: 317,
                         sampleRate: 48_000, channels: 12)
    try await renderer.play([block], generation: 0)
    output.setCapacity(1)
    let first = Task { try await renderer.endOfStream() }
    defer { first.cancel() }
    try await waitForOutput { output.blockedChecks > 0 }
    let waiting = Task { try await renderer.enqueue(Data(), time: .zero) }
    defer { waiting.cancel() }
    try await waitForOutput { await renderer.waitingInputCount == 1 }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    output.setCapacity(100)
    await #expect(throws: SpatialAudioError.self) { try await first.value }
    #expect(output.records.count == 1)
    try await renderer.begin(at: .zero)
    try await renderer.enqueue(Data(), time: .zero)
}
