import AVFoundation
import Testing
@testable import SpatialAudioPlayback

@MainActor @Suite(.serialized) struct AtmosOutputActivatorTests {
    @available(macOS 26, iOS 26, tvOS 26, *)
    private func silence(_ name: String, frames: AVAudioFrameCount = 80_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = buffer.frameCapacity
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<60 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func startsWithTheHostAndKeepsPlayingThroughPauses() async throws {
        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let host = AVPlayer(url: try silence("apac"))
        host.volume = 0
        activator.attach(to: host)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!activator.isActive)
        host.play()
        #expect(await eventually { activator.isActive })
        #expect(activator.error == nil)
        host.pause()
        try await Task.sleep(for: .milliseconds(300))
        #expect(activator.isActive)
        host.play()
        #expect(activator.isActive)
        activator.detach()
        #expect(!activator.isActive)
        host.pause()
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func stopsWhenTheHostItemEnds() async throws {
        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let host = AVPlayer(url: try silence("apac", frames: 4_000))
        host.volume = 0
        activator.attach(to: host)
        host.play()
        #expect(await eventually { activator.isActive })
        #expect(await eventually { activator.player.items().isEmpty })
        #expect(!activator.isActive)
        activator.detach()
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func keepsPlayingAcrossQueuedItems() async throws {
        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let second = AVPlayerItem(url: try silence("second", frames: 4_000))
        let host = AVQueuePlayer(items: [AVPlayerItem(url: try silence("first", frames: 4_000)), second])
        host.volume = 0
        activator.attach(to: host)
        host.play()
        #expect(await eventually { activator.isActive })
        #expect(await eventually { host.currentItem === second })
        #expect(activator.isActive)
        // The queue ends with no current item.
        #expect(await eventually { activator.player.items().isEmpty })
        activator.detach()
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func bundledStreamIsSignalledAsAtmosAndPlays() async throws {
        let asset = AVURLAsset(url: AtmosOutputActivator.bundledStream)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        var size = 0
        let list = try #require(CMAudioFormatDescriptionGetFormatList(description, sizeOut: &size))
        let formats = (0..<size / MemoryLayout<AudioFormatListItem>.size).map { list[$0].mASBD.mFormatID }
        // CoreMedia offers the object-audio format 'ec+3' only when dec3 signals Atmos.
        #expect(formats.contains(0x6563_2B33))
        #expect(formats.contains(kAudioFormatEnhancedAC3))

        let activator = AtmosOutputActivator()
        let host = AVPlayer(url: try silence("apac"))
        host.volume = 0
        activator.attach(to: host)
        host.play()
        #expect(await eventually { activator.isActive })
        #expect(activator.error == nil)
        activator.detach()
        host.pause()
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func followsARenderSynchronizer() async throws {
        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let synchronizer = AVSampleBufferRenderSynchronizer()
        activator.attach(to: synchronizer)
        #expect(!activator.isActive)
        synchronizer.setRate(1, time: .zero)
        #expect(await eventually { activator.isActive })
        synchronizer.rate = 0
        try await Task.sleep(for: .milliseconds(300))
        #expect(activator.isActive)
        activator.detach()
        #expect(!activator.isActive)
        #expect(activator.player.items().isEmpty)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func unplayableStreamReportsAnErrorInsteadOfActivity() async throws {
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID().uuidString).mp4")
        try Data("not media".utf8).write(to: invalid)
        let activator = AtmosOutputActivator(silentAtmosStream: invalid)
        let host = AVPlayer(url: try silence("apac"))
        host.volume = 0
        activator.attach(to: host)
        host.play()
        #expect(await eventually { activator.error != nil })
        #expect(!activator.isActive)
        activator.detach()
        host.pause()
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func playsOnlyForItemsSelectedByThePredicate() async throws {
        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let apac = AVPlayerItem(url: try silence("apac"))
        let other = AVPlayerItem(url: try silence("other"))
        let host = AVPlayer(playerItem: other)
        host.volume = 0
        activator.attach(to: host) { $0 === apac }
        host.play()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!activator.isActive)
        #expect(activator.player.items().isEmpty)
        host.replaceCurrentItem(with: apac)
        host.play()
        #expect(await eventually { activator.isActive })
        // Other audio must not share playback with a prerolled silent stream.
        host.replaceCurrentItem(with: AVPlayerItem(url: try silence("other")))
        host.play()
        #expect(await eventually { activator.player.items().isEmpty })
        #expect(!activator.isActive)
        activator.detach()
        #expect(!activator.isActive)
        host.pause()
    }
}
