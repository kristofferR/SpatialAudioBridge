import AVFoundation
import AVKit
import os
import SpatialAudioBridge
import SpatialAudioPlayback
import SwiftUI

// Older SDKs omit the Sendable annotation that newer AVFoundation SDKs provide.
// This subclass adds no mutable state; the host controls the clock while SAB queues audio.
private final class PlaybackSynchronizer: AVSampleBufferRenderSynchronizer, @unchecked Sendable {}

/// Plays a Matroska file's TrueHD Atmos or DTS:X track as APAC beside a server's HLS video.
///
/// Configure with launch environment variables:
/// - `SAB_SOURCE_URL`: the MKV, reachable with HTTP range requests (a media server's direct-play URL).
/// - `SAB_HTTP_HEADER`: optional header for that URL, such as `Authorization: …`.
/// - `SAB_VIDEO_MASTER`: optional HLS multivariant playlist supplying the video.
/// - `SAB_VIDEO_VARIANT`: optional text the chosen video variant's URL must contain, such as
///   `AllowVideoStreamCopy=true` to keep Jellyfin from switching to a transcode.
/// - `SAB_START`: optional start time in seconds.
/// - `SAB_RENDERER=1`: plays the audio alone through `SpatialAudioRenderer` instead of AVPlayer.
/// - `SAB_SEEK_TEST=1`: seeks like a remote would and logs how long each seek takes to play again.
/// - `SAB_NO_ATMOS=1`: plays without `AtmosOutputActivator`, to compare routes that don't need it, such as AirPods.
@main struct StreamPlayerApp: App {
    // devicectl --console reads stdout through a pipe; keep diagnostics line-buffered.
    init() { setvbuf(stdout, nil, _IOLBF, 0) }

    var body: some Scene { WindowGroup { PlayerScreen() } }
}

@MainActor @Observable final class StreamSession {
    let player = AVPlayer()
    var status = "Starting…"
    private var stream: APACStream?
    private var synchronizer: PlaybackSynchronizer?
    private var atmos: AtmosOutputActivator?
    private var monitor: Task<Void, Never>?
    /// The latest seek target and when it was requested, until playback has resumed after it, so a
    /// stall recovery resumes there.
    private var pendingSeek: (target: CMTime, since: ContinuousClock.Instant)?
    private var recoveries = 0
    /// When AVPlayer gave up after a wait, such as during a server outage, the latest reload and how many.
    private var abandoned: (since: ContinuousClock.Instant, reloaded: ContinuousClock.Instant, attempts: Int)?
    private var ended = false
    private var endObserver: (any NSObjectProtocol)?
    /// The last logged audio route.
    private var route = ""

    /// Records a seek from the remote or the seek test.
    func noteSeek(to target: CMTime) { pendingSeek = (target, .now) }

    func start() async {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["SAB_SOURCE_URL"].flatMap(URL.init(string:)) else {
            status = "Set SAB_SOURCE_URL"
            return
        }
        var headers: [String: String] = [:]
        if let header = environment["SAB_HTTP_HEADER"], let colon = header.firstIndex(of: ":") {
            headers[String(header[..<colon])] = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let start = CMTime(seconds: environment["SAB_START"].flatMap(Double.init) ?? 0, preferredTimescale: 600)
        do {
            try AtmosOutputActivator.configureAudioSession()
            let clock = ContinuousClock.now
            let file = try await MatroskaFile.open(HTTPByteSource(url: source, headers: headers))
            if environment["SAB_RENDERER"] == "1" {
                try await playThroughRenderer(file, from: start, since: clock)
                return
            }
            var options = APACStream.Options()
            if let variant = environment["SAB_VIDEO_VARIANT"] {
                options.includesVideoVariant = { $0.absoluteString.contains(variant) }
            }
            let stream = try await APACStream.start(file: file, videoMaster: environment["SAB_VIDEO_MASTER"].flatMap(URL.init(string:)),
                                                    startTime: start, options: options)
            self.stream = stream
            log("ready in \(ContinuousClock.now - clock): track \(stream.track.number) \(stream.track.codecID) \(stream.track.language ?? "-")")
            // The master offers only the APAC rendition, so every item plays APAC.
            activateAtmos { $0.attach(to: player) }
            player.replaceCurrentItem(with: AVPlayerItem(url: stream.masterPlaylistURL ?? stream.audioPlaylistURL))
            if start > .zero { await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) }
            player.play()
            status = stream.renditionName
            monitor = Task { [weak self] in await self?.report() }
            Task { [weak self] in await self?.logDurations(file: file, stream: stream) }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: nil, queue: .main) { [weak self] notification in
                // The activator's silent stream loops through its own item; only the film's end counts.
                let item = (notification.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, item == self.player.currentItem.map(ObjectIdentifier.init) else { return }
                    self.noteEnd()
                }
            }
            if environment["SAB_SEEK_TEST"] == "1" { await seekTest() }
        } catch {
            status = "\(error)"
            log("failed: \(error)")
        }
    }

    /// Plays the audio alone, as a player with its own video pipeline would: packets go to
    /// `SpatialAudioRenderer`, and the synchronizer starts once enough APAC is queued.
    private func playThroughRenderer(_ file: MatroskaFile, from start: CMTime, since clock: ContinuousClock.Instant) async throws {
        guard let track = file.audioTracks.first(where: { $0.codec != nil && $0.isDefault })
                ?? file.audioTracks.first(where: { $0.codec != nil }), let codec = track.codec else {
            throw SpatialAudioError.source("The file has no TrueHD or DTS track")
        }
        let synchronizer = PlaybackSynchronizer()
        self.synchronizer = synchronizer
        let renderer = try SpatialAudioRenderer(codec: codec, synchronizer: synchronizer)
        activateAtmos { $0.attach(to: synchronizer) }
        try await renderer.begin(at: start)
        status = "Renderer: \(track.codecID)"
        var started = false
        func play() {
            started = true
            synchronizer.setRate(1, time: start)
            log("renderer playing \(track.codecID) after \(ContinuousClock.now - clock)")
            monitor = Task { [weak self] in await self?.reportRenderer(renderer) }
        }
        for try await packet in file.packets(of: track, from: start) {
            try await renderer.enqueue(packet.data, time: packet.time)
            if !started, await renderer.isReadyToPlay { play() }
        }
        try await renderer.endOfStream()
        // A track shorter than the encoder's buffering queues its audio only when flushed.
        if !started { play() }
    }

    private func activateAtmos(_ attach: (AtmosOutputActivator) -> Void) {
        logRoute()
        guard ProcessInfo.processInfo.environment["SAB_NO_ATMOS"] != "1" else { return }
        let atmos = AtmosOutputActivator()
        attach(atmos)
        self.atmos = atmos
    }

    /// Skips, scrubs and jumps, each step issued without waiting for the previous seek, as the
    /// remote does, then times how long playback takes to move past the final target.
    private func seekTest() async {
        let scenarios: [(name: String, offsets: [Double], gap: Duration)] = [
            ("skip back 10 s", [-10], .zero),
            ("skip back 10 s x3", [-10, -10, -10], .milliseconds(300)),
            ("skip forward 10 s", [10], .zero),
            ("scrub forward 2 min", Array(repeating: 10, count: 12), .milliseconds(170)),
            ("scrub back 1 min", Array(repeating: -10, count: 6), .milliseconds(170)),
            ("jump forward 10 min", [600], .zero),
            ("jump back 5 min", [-300], .zero),
            ("double jump forward", [60, 60], .milliseconds(500)),
        ]
        let ready = ContinuousClock.now
        while player.timeControlStatus != .playing, ContinuousClock.now - ready < .seconds(30) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.timeControlStatus == .playing else {
            log("SEEKTEST could not start: item status \(player.currentItem?.status.rawValue ?? -1), \(player.currentItem?.error.map(String.init(describing:)) ?? "no error")")
            return
        }
        var results: [String] = []
        for scenario in scenarios {
            try? await Task.sleep(for: .seconds(10))
            guard player.currentItem?.status == .readyToPlay else { break }
            var target = player.currentTime().seconds
            let clock = ContinuousClock.now, recovered = recoveries
            for offset in scenario.offsets {
                target = max(0, target + offset)
                let time = CMTime(seconds: target, preferredTimescale: 600)
                noteSeek(to: time)
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                try? await Task.sleep(for: scenario.gap)
            }
            var resumed: Duration?
            var pressedPlay = false
            // A stall recovery replaces the item, which then loads before it is ready again.
            while ContinuousClock.now - clock < .seconds(40), let item = player.currentItem, item.status != .failed {
                // AVPlayer pauses itself when a server segment times out; a viewer would press play.
                if player.timeControlStatus == .paused {
                    player.play()
                    pressedPlay = true
                }
                // Just past the target: before a backward seek lands, the old position is past it too.
                let position = player.currentTime().seconds
                if player.timeControlStatus == .playing, position >= target + 0.3, position < target + 3 {
                    resumed = ContinuousClock.now - clock
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let result = "\(scenario.name) to \(Int(target)) s: " + (resumed.map { String(format: "%.2f s", $0 / .seconds(1)) }
                ?? (player.currentItem?.status == .failed ? "item failed" : "did not resume in 40 s"))
                + (pressedPlay ? " (pressed play)" : "") + (recoveries > recovered ? " (recovered a stall)" : "")
            log("SEEKTEST \(result)")
            results.append(result)
        }
        log("SEEKTEST done: " + results.joined(separator: "; "))
    }

    private func reportRenderer(_ renderer: SpatialAudioRenderer) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard let synchronizer else { return }
            logRoute()
            let rendering = await renderer.renderingStatus
            log(String(format: "t=%.1f rate=%.1f renderer=%d silentAtmos=%@ footprint=%d MB available=%d MB", synchronizer.currentTime().seconds,
                       synchronizer.rate, rendering.rawValue, atmos?.isActive == true ? "on" : "off",
                       Self.footprintMB(), os_proc_available_memory() / 1_000_000))
        }
    }

    /// Prints playback state every five seconds, and each wait for media with its duration, for
    /// device diagnostics.
    private func report() async {
        var status = player.timeControlStatus
        var previous = status
        var changed = ContinuousClock.now
        for tick in 1... {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            previous = status
            if player.timeControlStatus != status {
                let now = ContinuousClock.now
                log(String(format: "%@ → %@ after %.2f s at t=%.1f", Self.name(status), Self.name(player.timeControlStatus),
                           (now - changed) / .seconds(1), player.currentTime().seconds))
                (status, changed) = (player.timeControlStatus, now)
            }
            // Five seconds of playback since the seek mean it resolved, wherever it landed.
            if let seek = pendingSeek, status == .playing, ContinuousClock.now - max(changed, seek.since) > .seconds(5) {
                pendingSeek = nil
            }
            // AVPlayer can wedge after rapid seeks, when Jellyfin aborts a segment mid-response or
            // AVPlayer drops a connection, and then stops requesting media. A fresh item recovers:
            // at the seek target if playback never reached it, otherwise where it stopped. Seeks
            // took up to 15 s to resume on a long-GOP title, so 20 s of waiting means a wedge.
            if abandoned == nil, status == .waitingToPlayAtSpecifiedRate, ContinuousClock.now - changed > .seconds(20),
               let asset = player.currentItem?.asset as? AVURLAsset {
                let position = pendingSeek?.target ?? player.currentTime()
                log(String(format: "recovering a stalled item at t=%.1f, resuming at %.1f", player.currentTime().seconds, position.seconds))
                recoveries += 1
                player.replaceCurrentItem(with: AVPlayerItem(url: asset.url))
                await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                changed = .now
            }
            // AVPlayer gives up and pauses after a wait it cannot satisfy, or fails the item, for
            // example while the server is unreachable. Reload where it stopped, backing off.
            if !ended, abandoned == nil, player.currentItem?.status == .failed
                || status == .paused && previous == .waitingToPlayAtSpecifiedRate {
                abandoned = (.now, .now, 0)
                log(String(format: "playback stopped at t=%.1f: %@", player.currentTime().seconds,
                           player.currentItem?.error.map(String.init(describing:)) ?? "gave up waiting"))
            }
            if let lost = abandoned {
                if status == .playing {
                    log(String(format: "resumed after %.1f s and %d reloads", (ContinuousClock.now - lost.since) / .seconds(1), lost.attempts))
                    abandoned = nil
                } else if ContinuousClock.now - lost.reloaded > .seconds(5 * Double(1 << min(lost.attempts, 3))),
                          let asset = player.currentItem?.asset as? AVURLAsset {
                    let position = pendingSeek?.target ?? player.currentTime()
                    abandoned = (lost.since, .now, lost.attempts + 1)
                    log(String(format: "reloading at %.1f (attempt %d)", position.seconds, lost.attempts + 1))
                    recoveries += 1
                    player.replaceCurrentItem(with: AVPlayerItem(url: asset.url))
                    await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                    changed = .now
                }
            }
            guard tick % 20 == 0 else { continue }
            logRoute()
            let item = player.currentItem
            // Only the file name: server URLs can carry credentials.
            let errors = item?.errorLog()?.events.suffix(2).map {
                "\($0.errorStatusCode) \($0.uri.flatMap(URL.init(string:))?.lastPathComponent ?? "-") \($0.errorComment ?? "")"
            } ?? []
            let speed = await stream?.conversionSpeed ?? 0
            log(String(format: "t=%.1f rate=%.1f item=%d silentAtmos=%@ conversion=%.2fx footprint=%d MB available=%d MB errors=%@",
                       player.currentTime().seconds, player.rate, item?.status.rawValue ?? -1,
                       atmos?.isActive == true ? "on" : "off", speed, Self.footprintMB(), os_proc_available_memory() / 1_000_000,
                       errors.joined(separator: " | ")))
        }
    }

    private func noteEnd() {
        ended = true
        log(String(format: "ended at t=%.3f, item duration %.3f", player.currentTime().seconds,
                   player.currentItem?.duration.seconds ?? .nan))
    }

    /// The process's physical footprint, the figure jetsam limits apply to.
    private static func footprintMB() -> Int {
        // Swift 6 rejects the global `mach_task_self_`; the trap returns a reference to release.
        let task = task_self_trap()
        defer { mach_port_deallocate(task, task) }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(task, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_000_000) : -1
    }

    /// Logs the source's duration beside the audio and video playlists' and the item's, so an
    /// early or late ending can be traced to one of them.
    private func logDurations(file: MatroskaFile, stream: APACStream) async {
        func total(_ url: URL) async -> Double? {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let text = String(data: data, encoding: .utf8) else { return nil }
            return text.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
                .compactMap { Double($0.dropFirst(8).prefix { $0 != "," }) }.reduce(0, +)
        }
        var video: Double?
        if let master = stream.masterPlaylistURL, let (data, _) = try? await URLSession.shared.data(from: master),
           let text = String(data: data, encoding: .utf8),
           let variant = text.split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.isEmpty }),
           let url = URL(string: String(variant), relativeTo: master) {
            video = await total(url)
        }
        let audio = await total(stream.audioPlaylistURL)
        try? await Task.sleep(for: .seconds(10))
        log(String(format: "durations: source %.3f, audio playlist %.3f, video playlist %.3f, item %.3f",
                   file.duration?.seconds ?? .nan, audio ?? .nan, video ?? .nan, player.currentItem?.duration.seconds ?? .nan))
    }

    private static func name(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unknown"
        }
    }

    /// Logs the audio route and whether it spatializes, such as AirPods with spatial audio on iPhone,
    /// whenever it changes.
    private func logRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portType.rawValue) \($0.portName) spatial=\($0.isSpatialAudioEnabled)" }.joined(separator: ", ")
        guard outputs != route else { return }
        route = outputs
        log("route: " + outputs)
    }

    private func log(_ message: String) { print("STREAM \(message)") }
}

struct PlayerScreen: View {
    @State private var session = StreamSession()
    @State private var showsStatus = true

    var body: some View {
        PlayerView(player: session.player, onSeek: session.noteSeek(to:))
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if showsStatus {
                    Text(session.status).font(.caption).padding(12).background(.black.opacity(0.5)).padding(40)
                }
            }
            .task { await session.start() }
            // Shown briefly after each change: a label left on screen through a film burns into OLED panels.
            .task(id: session.status) {
                showsStatus = true
                guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
                showsStatus = false
            }
    }
}

struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    /// Receives the target of each skip or scrub from the remote.
    let onSeek: (CMTime) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let onSeek: (CMTime) -> Void
        init(onSeek: @escaping (CMTime) -> Void) { self.onSeek = onSeek }

        #if os(tvOS)
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  timeToSeekAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) -> CMTime {
            onSeek(targetTime)
            return targetTime
        }
        #endif
    }
}
