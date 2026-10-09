import Testing
import Foundation
@testable import SpatialAudioBridge

@Test func invalidConfigurationIsRejectedBeforeCreatingOutput() {
    #expect(throws: SpatialAudioError.self) {
        try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .file(URL(fileURLWithPath: "/unused.mp4")),
                                   configuration: .init(gainDB: .nan))
    }
}

@Test func cancelledSessionRejectsFurtherInput() async throws {
    let converter = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .file(URL(fileURLWithPath: "/unused.mp4")))
    await converter.cancel()
    await #expect(throws: SpatialAudioError.self) { try await converter.append(Data([0])) }
}

@Test func truncatedTrackCannotBeReportedAsSuccess() async throws {
    let converter = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: .file(URL(fileURLWithPath: "/unused.mp4")))
    try await converter.append(Data([0x01, 0x02]))
    await #expect(throws: SpatialAudioError.self) { try await converter.finish() }
}

@Test func hlsOutputRequiresANewDirectory() throws {
    #expect(throws: SpatialAudioError.self) {
        try APACHLSOutput(directory: FileManager.default.temporaryDirectory)
    }
}
