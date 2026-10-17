import CoreMedia
import Foundation
import Testing
@testable import SpatialAudioBridge

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func gridPlacesSegmentsAndSessionsOnTwoSyncPeriods() throws {
    let grid = try APACSegmentGrid(duration: CMTime(value: 10, timescale: 1),
                                   configuration: APACConfiguration(liveEncoding: false))
    #expect(grid.configuration.liveEncoding)
    #expect(grid.segmentFrames == 153_600)
    #expect(grid.segmentCount == 4)
    #expect(grid.end == CMTime(value: 480_000, timescale: 48_000))
    #expect(grid.index(at: CMTime(value: 153_599, timescale: 48_000)) == 0)
    #expect(grid.index(at: CMTime(value: 153_600, timescale: 48_000)) == 1)
    #expect(grid.index(at: CMTime(value: 60, timescale: 1)) == 3)
    #expect(grid.start(of: 2) == CMTime(value: 307_200, timescale: 48_000))
    // A session's first fragment begins on the grid once the priming is presented.
    let priming = try grid.configuration.encoderPrimingDuration().value
    #expect(grid.primingFrames == priming)
    #expect(grid.configuration(from: 2).startTime.value == 307_200 + priming)
    #expect(grid.configuration(from: 2, early: true).startTime.value == 153_600 + priming)
    let fragment = APACSegment(kind: .media, data: Data(), startTime: CMTime(value: 307_199, timescale: 48_000),
                               duration: CMTime(value: 153_600, timescale: 48_000))
    #expect(grid.index(of: fragment) == 2)
    #expect(grid.index(of: APACSegment(kind: .initialization, data: Data(), startTime: nil, duration: nil)) == nil)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func gridPlaylistSharesATargetDurationAndNamesSegments() throws {
    let grid = try APACSegmentGrid(duration: CMTime(value: 7, timescale: 1))
    let playlist = grid.mediaPlaylist(minimumTargetDuration: 6, initializationURI: "a/init.mp4") { "a/\($0).m4s" }
    #expect(playlist.contains("#EXT-X-TARGETDURATION:6\n"))
    #expect(playlist.contains("#EXT-X-MAP:URI=\"a/init.mp4\""))
    #expect(playlist.contains("#EXTINF:0.600000,\na/2.m4s\n#EXT-X-ENDLIST"))
    #expect(grid.mediaPlaylist().contains("#EXT-X-TARGETDURATION:4\n"))
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func gridRejectsUnusableDurationsAndSyncIntervals() {
    #expect(throws: SpatialAudioError.self) { try APACSegmentGrid(duration: .indefinite) }
    #expect(throws: SpatialAudioError.self) { try APACSegmentGrid(duration: .zero) }
    var configuration = APACConfiguration()
    configuration.syncPacketFrequency = 2
    #expect(throws: SpatialAudioError.self) { try APACSegmentGrid(duration: CMTime(value: 1, timescale: 1), configuration: configuration) }
}
