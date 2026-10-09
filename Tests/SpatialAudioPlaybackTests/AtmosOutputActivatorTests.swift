import AVFoundation
import Testing
@testable import SpatialAudioPlayback

@MainActor @Suite(.serialized) struct AtmosOutputActivatorTests {
    private func silence(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
        buffer.frameLength = buffer.frameCapacity
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<60 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func followsHostPlaybackAndPause() async throws {
        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let host = AVPlayer(url: try silence("apac"))
        host.volume = 0
        activator.attach(to: host)
        #expect(!activator.isActive)
        host.play()
        #expect(await eventually { activator.isActive })
        #expect(activator.error == nil)
        host.pause()
        #expect(await eventually { !activator.isActive })
        host.play()
        #expect(await eventually { activator.isActive })
        activator.detach()
        #expect(!activator.isActive)
        host.pause()
    }

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
