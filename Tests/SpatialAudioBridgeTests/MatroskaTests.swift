import CoreMedia
import Foundation
import Testing
@testable import SpatialAudioBridge

/// Writes the Matroska elements these tests need, using 8-byte sizes so offsets are easy to compute.
private enum MKV {
    static func id(_ id: UInt64) -> Data { withUnsafeBytes(of: id.bigEndian) { Data($0) }.drop { $0 == 0 } }
    static func element(_ id: UInt64, _ body: Data) -> Data {
        let bytes = Self.id(id)
        var size = withUnsafeBytes(of: UInt64(body.count).bigEndian) { Data($0) }
        size[size.startIndex] = 0x01
        return bytes + size + body
    }
    static func element(_ id: UInt64, _ children: [Data]) -> Data { element(id, children.reduce(Data(), +)) }
    static func uint(_ id: UInt64, _ value: UInt64) -> Data { element(id, withUnsafeBytes(of: value.bigEndian) { Data($0) }) }
    static func string(_ id: UInt64, _ value: String) -> Data { element(id, Data(value.utf8)) }
    static func float(_ id: UInt64, _ value: Double) -> Data { element(id, withUnsafeBytes(of: value.bitPattern.bigEndian) { Data($0) }) }

    /// A block for `track` at `milliseconds` relative to its cluster, with `lacing` already applied to `payload`.
    static func blockBody(track: UInt8, milliseconds: Int16, flags: UInt8, payload: Data) -> Data {
        Data([0x80 | track]) + withUnsafeBytes(of: milliseconds.bigEndian) { Data($0) } + Data([flags]) + payload
    }

    /// TrueHD-like frame: a 4-byte access unit header, then the major sync word when `sync`.
    static func trueHD(_ id: UInt8, sync: Bool) -> Data {
        Data([0xF0, id, 0x00, 0x00]) + (sync ? Data([0xF8, 0x72, 0x6F, 0xBA]) : Data([0x01, 0x02, 0x03, 0x04])) + Data([id])
    }
}

private struct Fixture {
    let url: URL
    /// TrueHD frames as stored, before header stripping, with their times in milliseconds.
    let trueHD: [(ms: Int64, frame: Data)]
    let dtsFrames: [Data]

    /// Header stripping removes the first two bytes of every TrueHD frame.
    static let stripped = Data([0xF0, 0x00])

    /// With `metadataAfterClusters`, the info and tracks follow the clusters and only the seek head points at them.
    static func make(metadataAfterClusters late: Bool = false) throws -> Fixture {
        var trueHD: [(Int64, Data)] = []
        func audioBlock(_ ms: Int16, cluster: Int64, sync: Bool, id: UInt8) -> Data {
            var frame = MKV.trueHD(id, sync: sync)
            frame[frame.startIndex + 1] = 0x00 // matches the stripped header
            trueHD.append((cluster + Int64(ms), frame))
            return MKV.element(EBML.simpleBlock, MKV.blockBody(track: 2, milliseconds: ms, flags: 0x80, payload: frame.dropFirst(2)))
        }
        let video = MKV.element(EBML.simpleBlock, MKV.blockBody(track: 1, milliseconds: 0, flags: 0x80, payload: Data(repeating: 0xAA, count: 4096)))
        let dts = [Data([0x7F, 0xFE, 0x80, 0x01, 1]), Data([0x7F, 0xFE, 0x80, 0x01, 2, 2]), Data([0x7F, 0xFE, 0x80, 0x01, 3, 3, 3])]
        // EBML lacing: frame count - 1, the first size, then the signed difference biased by 63.
        let laced = Data([2, 0x80 | 5, 0x80 | UInt8(63 + 1)]) + dts.reduce(Data(), +)
        let cluster1 = MKV.element(EBML.cluster, [
            MKV.uint(EBML.timestamp, 0), video,
            audioBlock(0, cluster: 0, sync: true, id: 1),
            audioBlock(10, cluster: 0, sync: false, id: 2),
            MKV.element(EBML.blockGroup, [MKV.element(EBML.block, MKV.blockBody(track: 2, milliseconds: 20, flags: 0, payload: {
                var frame = MKV.trueHD(3, sync: true); frame[frame.startIndex + 1] = 0x00
                trueHD.append((20, frame)); return frame.dropFirst(2)
            }()))]),
            audioBlock(30, cluster: 0, sync: false, id: 4),
            MKV.element(EBML.simpleBlock, MKV.blockBody(track: 3, milliseconds: 30, flags: 0x80 | 0x06, payload: laced)),
        ])
        let cluster2 = MKV.element(EBML.cluster, [
            MKV.uint(EBML.timestamp, 1000), video,
            audioBlock(0, cluster: 1000, sync: true, id: 5),
            audioBlock(10, cluster: 1000, sync: false, id: 6),
            audioBlock(20, cluster: 1000, sync: true, id: 7),
            audioBlock(30, cluster: 1000, sync: false, id: 8),
        ])
        let info = MKV.element(EBML.info, [MKV.uint(EBML.timestampScale, 1_000_000), MKV.float(EBML.duration, 1040)])
        let tracks = MKV.element(EBML.tracks, [
            MKV.element(EBML.trackEntry, [MKV.uint(EBML.trackNumber, 1), MKV.uint(EBML.trackType, 1), MKV.string(EBML.codecID, "V_MPEGH/ISO/HEVC")]),
            MKV.element(EBML.trackEntry, [
                MKV.uint(EBML.trackNumber, 2), MKV.uint(EBML.trackType, 2), MKV.string(EBML.codecID, "A_TRUEHD"),
                MKV.string(EBML.language, "eng"), MKV.uint(EBML.flagDefault, 1),
                MKV.element(EBML.audio, [MKV.float(EBML.samplingFrequency, 48000), MKV.uint(EBML.channels, 8)]),
                MKV.element(EBML.contentEncodings, [MKV.element(EBML.contentEncoding, [MKV.element(EBML.contentCompression, [
                    MKV.uint(EBML.contentCompAlgo, 3), MKV.element(EBML.contentCompSettings, stripped)])])]),
            ]),
            MKV.element(EBML.trackEntry, [
                MKV.uint(EBML.trackNumber, 3), MKV.uint(EBML.trackType, 2), MKV.string(EBML.codecID, "A_DTS"),
                MKV.string(EBML.languageBCP47, "nb-NO"), MKV.uint(EBML.flagDefault, 0), MKV.string(EBML.name, "Kommentar"),
                MKV.element(EBML.audio, [MKV.float(EBML.samplingFrequency, 48000), MKV.uint(EBML.channels, 6)]),
            ]),
        ])
        // The seek head has a fixed size, so the positions can be computed before writing it.
        func seekHead(_ entries: [(id: UInt64, position: Int)]) -> Data {
            MKV.element(EBML.seekHead, entries.map { MKV.element(EBML.seek, [MKV.element(EBML.seekID, MKV.id($0.id)), MKV.uint(EBML.seekPosition, UInt64($0.position))]) })
        }
        let sought = late ? [EBML.info, EBML.tracks, EBML.cues] : [EBML.cues]
        let clusters = seekHead(sought.map { ($0, 0) }).count + (late ? 0 : info.count + tracks.count)
        let cues = MKV.element(EBML.cues, [
            MKV.element(EBML.cuePoint, [MKV.uint(EBML.cueTime, 0), MKV.element(EBML.cueTrackPositions, [MKV.uint(0xF7, 1), MKV.uint(EBML.cueClusterPosition, UInt64(clusters))])]),
            MKV.element(EBML.cuePoint, [MKV.uint(EBML.cueTime, 1000), MKV.element(EBML.cueTrackPositions, [MKV.uint(0xF7, 1), MKV.uint(EBML.cueClusterPosition, UInt64(clusters + cluster1.count))])]),
        ])
        let end = clusters + cluster1.count + cluster2.count
        let elements = late
            ? [seekHead([(EBML.info, end), (EBML.tracks, end + info.count), (EBML.cues, end + info.count + tracks.count)]), cluster1, cluster2, info, tracks, cues]
            : [seekHead([(EBML.cues, end)]), info, tracks, cluster1, cluster2, cues]
        let segment = MKV.element(EBML.segment, elements)
        let file = MKV.element(EBML.header, [MKV.string(EBML.docType, "matroska")]) + segment
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("matroska-\(UUID().uuidString).mkv")
        try file.write(to: url)
        return Fixture(url: url, trueHD: trueHD, dtsFrames: dts)
    }
}

private func collect(_ packets: MatroskaPackets) async throws -> [MatroskaPacket] {
    var result: [MatroskaPacket] = []
    for try await packet in packets { result.append(packet) }
    return result
}

@Test func matroskaListsAudioTracksWithLanguageAndDefaults() async throws {
    let fixture = try Fixture.make()
    let file = try await MatroskaFile.open(FileByteSource(url: fixture.url))
    #expect(file.audioTracks.map(\.number) == [2, 3])
    #expect(file.audioTracks.map(\.codec) == [.trueHDAtmos, .dtsX])
    #expect(file.audioTracks.map(\.language) == ["eng", "nb-NO"])
    #expect(file.audioTracks.map(\.isDefault) == [true, false])
    #expect(file.audioTracks.map(\.channels) == [8, 6])
    #expect(file.audioTracks[1].name == "Kommentar")
    #expect(abs((file.duration?.seconds ?? 0) - 1.04) < 1e-9)
}

@Test func matroskaReturnsOneTrackWithItsStrippedHeaderRestored() async throws {
    let fixture = try Fixture.make()
    let file = try await MatroskaFile.open(FileByteSource(url: fixture.url))
    let packets = try await collect(file.packets(of: file.audioTracks[0]))
    #expect(packets.map(\.data) == fixture.trueHD.map(\.frame))
    #expect(packets.map { Int64(($0.time.seconds * 1000).rounded()) } == fixture.trueHD.map(\.ms))
    #expect(packets.map(\.isSyncPoint) == [true, false, true, false, true, false, true, false])
}

@Test func matroskaSeeksToTheLastSyncPointAtOrBeforeTheTarget() async throws {
    let fixture = try Fixture.make()
    let file = try await MatroskaFile.open(FileByteSource(url: fixture.url))
    let track = file.audioTracks[0]
    let mid = try await collect(file.packets(of: track, from: CMTime(value: 1015, timescale: 1000)))
    #expect(mid.first.map { $0.time.seconds } == 1.0)
    #expect(mid.count == 4)
    let exact = try await collect(file.packets(of: track, from: CMTime(value: 1020, timescale: 1000)))
    #expect(exact.first.map { $0.time.seconds } == 1.02)
    let inFirstCluster = try await collect(file.packets(of: track, from: CMTime(value: 25, timescale: 1000)))
    #expect(inFirstCluster.first.map { $0.time.seconds } == 0.02)
}

@Test func matroskaSplitsLacedFrames() async throws {
    let fixture = try Fixture.make()
    let file = try await MatroskaFile.open(FileByteSource(url: fixture.url))
    let packets = try await collect(file.packets(of: file.audioTracks[1]))
    #expect(packets.map(\.data) == fixture.dtsFrames)
    #expect(packets.allSatisfy { $0.isSyncPoint })
    // Seeking into the block keeps every frame laced into it.
    let atBlock = try await collect(file.packets(of: file.audioTracks[1], from: CMTime(value: 35, timescale: 1000)))
    #expect(atBlock.map(\.data) == fixture.dtsFrames)
}

@Test func matroskaFindsMetadataAfterTheClustersThroughTheSeekHead() async throws {
    let fixture = try Fixture.make(metadataAfterClusters: true)
    let file = try await MatroskaFile.open(FileByteSource(url: fixture.url))
    #expect(file.audioTracks.map(\.number) == [2, 3])
    #expect(abs((file.duration?.seconds ?? 0) - 1.04) < 1e-9)
    #expect(file.cues.map(\.time) == [0, 1000])
    let packets = try await collect(file.packets(of: file.audioTracks[0]))
    #expect(packets.map(\.data) == fixture.trueHD.map(\.frame))
}

@Test func xiphAndFixedLacingSplitFrames() throws {
    let xiph = Data([2, 255, 1, 3]) + Data(repeating: 1, count: 256) + Data(repeating: 2, count: 3) + Data([9])
    #expect(try PacketReader.frames(xiph, lacing: 1).map(\.count) == [256, 3, 1])
    let fixed = Data([2]) + Data(repeating: 7, count: 9)
    #expect(try PacketReader.frames(fixed, lacing: 2).map(\.count) == [3, 3, 3])
}

@Test func malformedLacingIsRejected() {
    // EBML lacing whose second size, 1 + (58 - 63), is negative.
    let negative = Data([2, 0x80 | 1, 0x80 | 58]) + Data(repeating: 0, count: 8)
    #expect(throws: SpatialAudioError.self) { try PacketReader.frames(negative, lacing: 3) }
}

@Test func nonMatroskaInputIsRejected() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-mkv-\(UUID().uuidString).bin")
    try Data(repeating: 0x42, count: 64).write(to: url)
    await #expect(throws: SpatialAudioError.self) { try await MatroskaFile.open(FileByteSource(url: url)) }
}

/// Reads a real file's TrueHD track and compares it with an FFmpeg extraction of the same track.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"] != nil
               && ProcessInfo.processInfo.environment["SAB_TRUEHD_FIXTURE"] != nil))
func realMatroskaTrackMatchesTheElementaryStream() async throws {
    let environment = ProcessInfo.processInfo.environment
    let file = try await MatroskaFile.open(FileByteSource(url: URL(fileURLWithPath: environment["SAB_MKV_FIXTURE"]!)))
    let track = try #require(file.audioTracks.first { $0.codec == .trueHDAtmos })
    var bytes = Data()
    for try await packet in file.packets(of: track) { bytes.append(packet.data) }
    let expected = try Data(contentsOf: URL(fileURLWithPath: environment["SAB_TRUEHD_FIXTURE"]!))
    #expect(bytes == expected)
    let seeked = try await collect(file.packets(of: track, from: CMTime(seconds: 30, preferredTimescale: 1000)))
    let first = try #require(seeked.first)
    #expect(first.isSyncPoint)
    #expect(first.time.seconds <= 30 && first.time.seconds > 29.9)
}
