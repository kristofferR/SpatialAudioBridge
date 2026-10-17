import CoreMedia
import Foundation
import Testing
@testable import SpatialAudioBridge

@available(macOS 26, iOS 26, tvOS 26, *)
private func box(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(UInt32(body.count + 8)) + Array(type.utf8) + body }
@available(macOS 26, iOS 26, tvOS 26, *)
private func be32(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }
@available(macOS 26, iOS 26, tvOS 26, *)
private func read32(_ bytes: [UInt8], _ index: Int) -> UInt32 { bytes[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) } }

/// A fragment shaped like AVAssetWriter's: default durations in tfhd, sizes in two runs.
@available(macOS 26, iOS 26, tvOS 26, *)
private func fragment(sizes: [[UInt32]], sequence: UInt32 = 1) -> (data: Data, payload: [UInt8]) {
    let payload = sizes.joined().enumerated().flatMap { index, size in [UInt8](repeating: UInt8(index), count: Int(size)) }
    let tfhd = box("tfhd", be32(0x02_0038) + be32(1) + be32(1024) + be32(5) + be32(0x0001_0000))
    let tfdt = box("tfdt", be32(0) + be32(93_952))
    func moof(offsets: [UInt32]) -> [UInt8] {
        let runs = zip(sizes, offsets).flatMap { run, offset in
            box("trun", be32(0x201) + be32(UInt32(run.count)) + be32(offset) + run.flatMap(be32))
        }
        return box("moof", box("mfhd", be32(0) + be32(sequence)) + box("traf", tfhd + tfdt + runs))
    }
    // Data offsets count from the moof's start to each run's first byte in the mdat.
    let length = UInt32(moof(offsets: sizes.map { _ in 0 }).count) + 8
    let offsets = sizes.indices.map { length + sizes[..<$0].joined().reduce(0, +) }
    return (Data(moof(offsets: offsets) + box("mdat", payload)), payload)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func trimmingShortensOnlyTheLastSampleAndKeepsDataOffsets() throws {
    let (data, payload) = fragment(sizes: [[10, 11, 12], [13, 14]])
    let trimmed = [UInt8](try #require(trimmingLastSample(of: data, by: 640)))
    // moof > traf > last trun, which now carries a duration before each size.
    let traf = 8 + 16
    let tfhdEnd = traf + 8 + 28, firstRun = tfhdEnd + 16
    let lastRun = firstRun + Int(read32(trimmed, firstRun))
    #expect(read32(trimmed, lastRun + 8) & 0xFF_FFFF == 0x301)
    #expect(read32(trimmed, lastRun + 20) == 1024 && read32(trimmed, lastRun + 24) == 13)
    #expect(read32(trimmed, lastRun + 28) == 384 && read32(trimmed, lastRun + 32) == 14)
    // Every run still points at its own bytes in the media data.
    for (run, first) in [(firstRun, 0), (lastRun, 3)] {
        let offset = Int(read32(trimmed, run + 16))
        #expect(trimmed[offset] == UInt8(first))
    }
    #expect(Array(trimmed.suffix(payload.count)) == payload)
    #expect(Int(read32(trimmed, 0)) == trimmed.count - payload.count - 8)
    #expect(trimmingLastSample(of: data, by: 1024) == nil)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func segmentDelegateDropsARepeatedFinalFragmentAndStillTrimsIt() throws {
    let collector = SegmentCollector()
    let delegate = SegmentDelegate { collector.append($0) }
    func media(_ data: Data, start: Int64, packets: Int64) -> APACSegment {
        APACSegment(kind: .media, data: data, startTime: CMTime(value: start, timescale: 48_000),
                    duration: CMTime(value: packets * 1024, timescale: 48_000))
    }
    let (last, _) = fragment(sizes: [[10, 11, 12], [13, 14]])
    // The writer repeats the fragment's samples under the next sequence number.
    let (repeated, _) = fragment(sizes: [[10, 11, 12], [13, 14]], sequence: 2)
    delegate.receive(APACSegment(kind: .initialization, data: Data([0]), startTime: nil, duration: nil))
    delegate.receive(media(Data([1]), start: 0, packets: 75))
    delegate.holdLastSegment()
    delegate.receive(media(last, start: 76_800, packets: 5))
    delegate.receive(media(repeated, start: 76_800, packets: 5))
    #expect(delegate.error == nil)
    // 80 packets minus 2048 priming frames and 640 frames of final padding.
    delegate.deliverLastSegment(sourceFrames: 80 * 1024 - 2048 - 640, priming: 2048)
    delegate.receive(media(last, start: 76_800, packets: 5))
    let segments = collector.snapshot()
    let trimmed = try #require(trimmingLastSample(of: last, by: 640))
    #expect(segments.map(\.data) == [Data([0]), Data([1]), trimmed])
    #expect(segments.last?.duration == CMTime(value: 5 * 1024 - 640, timescale: 48_000))
    #expect(delegate.error != nil, "A fragment after the last one is reported")
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func segmentDelegateRejectsOverlappingFragmentsWithDifferentContent() {
    let delegate = SegmentDelegate { _ in }
    let duration = CMTime(value: 1024, timescale: 48_000)
    delegate.receive(APACSegment(kind: .media, data: Data([1]), startTime: .zero, duration: duration))
    // A boundary rounded by one frame is not an overlap.
    delegate.receive(APACSegment(kind: .media, data: Data([2]), startTime: CMTime(value: 1023, timescale: 48_000),
                                 duration: duration))
    #expect(delegate.error == nil)
    delegate.receive(APACSegment(kind: .media, data: Data([3]), startTime: CMTime(value: 1024, timescale: 48_000),
                                 duration: duration))
    #expect(delegate.error != nil)
}
