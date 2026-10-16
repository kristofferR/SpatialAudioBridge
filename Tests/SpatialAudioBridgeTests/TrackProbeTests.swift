import Foundation
import Testing
@testable import SpatialAudioBridge

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func syncPointsAreRecognizedPerCodec() {
    let majorSync = Data([0xF0, 0x01, 0x00, 0x00, 0xF8, 0x72, 0x6F, 0xBA, 0x01])
    let minor = Data([0xF0, 0x01, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04])
    let dtsCore = Data([0x7F, 0xFE, 0x80, 0x01, 0x00])
    #expect(SpatialAudioCodec.trueHDAtmos.isSyncPoint(majorSync))
    #expect(!SpatialAudioCodec.trueHDAtmos.isSyncPoint(minor))
    #expect(!SpatialAudioCodec.trueHDAtmos.isSyncPoint(dtsCore))
    #expect(SpatialAudioCodec.dtsX.isSyncPoint(dtsCore))
    #expect(!SpatialAudioCodec.dtsX.isSyncPoint(majorSync))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func probingTooLittleAudioIsUndetermined() throws {
    #expect(try SpatialAudioCodec.trueHDAtmos.probe(Data()) == .undetermined)
    #expect(try SpatialAudioCodec.dtsX.probe(Data()) == .undetermined)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test(arguments: [("SAB_TRUEHD_FIXTURE", SpatialAudioCodec.trueHDAtmos), ("SAB_DTSX_FIXTURE", .dtsX),
                  ("SAB_DTSX_ALTERNATE_FIXTURE", .dtsX)])
func fixturesProbeAsRenderable(variable: String, codec: SpatialAudioCodec) throws {
    guard let path = ProcessInfo.processInfo.environment[variable] else { return }
    let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? source.close() }
    // More than a second at either codec's bitrate.
    let start = try #require(try source.read(upToCount: 4 * 1024 * 1024))
    #expect(try codec.probe(start) == .renderable)
}
