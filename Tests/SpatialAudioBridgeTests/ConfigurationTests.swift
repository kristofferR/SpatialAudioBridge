import Testing
import Foundation
@testable import SpatialAudioBridge

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func hlsCodecStringsIncludeTheChannelBasedProfileAndLevel() {
    #expect(SpatialAudioLayout.sevenOneFour.apacCodecString == "apac.31.03")
    #expect(SpatialAudioLayout.nineOneSix.apacCodecString == "apac.31.04")
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func defaultBitRateFollowsTheLayoutUntilSet() {
    var configuration = APACConfiguration()
    #expect(configuration.bitRate == 3_072_000)
    configuration.layout = .nineOneSix
    #expect(configuration.bitRate == 4_096_000)
    configuration.bitRate = 2_000_000
    configuration.layout = .sevenOneFour
    #expect(configuration.bitRate == 2_000_000)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func invalidConfigurationIsRejectedBeforeCreatingOutput() {
    #expect(throws: SpatialAudioError.self) {
        try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .file(URL(fileURLWithPath: "/unused.mp4")),
                                   configuration: .init(gainDB: .nan))
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func cancelledSessionRejectsFurtherInput() async throws {
    let converter = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .file(URL(fileURLWithPath: "/unused.mp4")))
    await converter.cancel()
    await #expect(throws: SpatialAudioError.self) { try await converter.append(Data([0])) }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func truncatedTrackCannotBeReportedAsSuccess() async throws {
    let converter = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .file(URL(fileURLWithPath: "/unused.mp4")))
    try await converter.append(Data([0x01, 0x02]))
    await #expect(throws: SpatialAudioError.self) { try await converter.finish() }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func hlsOutputRequiresANewDirectory() throws {
    #expect(throws: SpatialAudioError.self) {
        try APACHLSOutput(directory: FileManager.default.temporaryDirectory)
    }
}
