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
    /// Waits up to 10 s: hosted runners can take seconds to start playback.
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    #if os(macOS)
    /// A movie whose audio tracks form one alternate group, each titled as given, like HLS audio renditions.
    @available(macOS 26, *)
    private func alternateAudio(titled titles: [String]) async throws -> URL {
        let source = AVURLAsset(url: try silence("source"))
        let sourceTrack = try #require(try await source.loadTracks(withMediaType: .audio).first)
        let range = try await sourceTrack.load(.timeRange)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alternates-\(UUID().uuidString).mov")
        let movie = try AVMutableMovie(settingsFrom: nil, options: nil)
        movie.defaultMediaDataStorage = AVMediaDataStorage(url: url)
        for (index, title) in titles.enumerated() {
            let track = try #require(movie.addMutableTrack(withMediaType: .audio, copySettingsFrom: nil, options: nil))
            try track.insertTimeRange(range, of: sourceTrack, at: .zero, copySampleData: true)
            track.alternateGroupID = 1
            track.isEnabled = index == 0
            let name = AVMutableMetadataItem()
            name.identifier = .quickTimeMetadataTitle
            name.value = title as NSString
            track.metadata = [name]
        }
        try movie.writeHeader(to: url, fileType: .mov, options: [])
        return url
    }
    #endif

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

    /// Eight-second items outlast the silent stream's start, which can take seconds on a hosted
    /// runner; tests then seek to just before the end instead of waiting for it.
    @available(macOS 26, iOS 26, tvOS 26, *)
    private func nearEnd(_ host: AVPlayer) async {
        await host.seek(to: CMTime(value: 75, timescale: 10), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func stopsWhenTheHostItemEnds() async throws {
        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let host = AVPlayer(url: try silence("apac", frames: 64_000))
        host.volume = 0
        activator.attach(to: host)
        host.play()
        #expect(await eventually { activator.isActive })
        await nearEnd(host)
        #expect(await eventually { activator.player.items().isEmpty })
        #expect(!activator.isActive)
        activator.detach()
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func stopsAtTheEndOfAHostThatTakesNoAction() async throws {
        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let host = AVPlayer(url: try silence("apac", frames: 64_000))
        host.volume = 0
        host.actionAtItemEnd = .none
        activator.attach(to: host)
        host.play()
        #expect(await eventually { activator.isActive })
        await nearEnd(host)
        #expect(await eventually { activator.player.items().isEmpty })
        // Seeking back resumes the item, and the stream with it.
        await host.seek(to: .zero)
        #expect(await eventually { activator.isActive })
        activator.detach()
        host.pause()
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    @Test func keepsPlayingAcrossQueuedItems() async throws {
        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let second = AVPlayerItem(url: try silence("second", frames: 64_000))
        let host = AVQueuePlayer(items: [AVPlayerItem(url: try silence("first", frames: 64_000)), second])
        host.volume = 0
        activator.attach(to: host)
        host.play()
        #expect(await eventually { activator.isActive })
        await nearEnd(host)
        #expect(await eventually { host.currentItem === second })
        #expect(activator.isActive)
        // The queue ends with no current item.
        await nearEnd(host)
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

    #if os(macOS)
    @available(macOS 26, *)
    @Test func playsOnlyWhileANamedRenditionIsSelected() async throws {
        let asset = AVURLAsset(url: try await alternateAudio(titled: ["Stereo", "Spatial Audio"]))
        let (group, named) = try #require(await AtmosOutputActivator.audibleOptions(titled: ["Spatial Audio"], in: asset))
        #expect(group.options.count == 2)
        let spatial = try #require(named.first)
        #expect(named.count == 1)
        let stereo = try #require(group.options.first { $0 != spatial })

        let activator = AtmosOutputActivator(silentAtmosStream: try silence("stream"))
        let item = AVPlayerItem(asset: asset)
        let host = AVPlayer(playerItem: item)
        host.volume = 0
        item.select(stereo, in: group)
        activator.attach(to: host, apacRenditions: ["Spatial Audio"])
        host.play()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!activator.isActive)
        #expect(activator.player.items().isEmpty)
        item.select(spatial, in: group)
        #expect(await eventually { activator.isActive })
        // Other audio must not share playback with a prerolled silent stream.
        item.select(stereo, in: group)
        #expect(await eventually { activator.player.items().isEmpty })
        #expect(!activator.isActive)
        activator.detach()
        host.pause()
    }
    #endif
}
