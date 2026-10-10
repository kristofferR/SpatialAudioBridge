import AVFoundation
import AVKit
import SpatialAudioBridge
import SpatialAudioPlayback
import SwiftUI

/// Plays a Matroska file's TrueHD Atmos or DTS:X track as APAC beside a server's HLS video.
///
/// Configure with launch environment variables:
/// - `SAB_SOURCE_URL`: the MKV, reachable with HTTP range requests (a media server's direct-play URL).
/// - `SAB_HTTP_HEADER`: optional header for that URL, such as `Authorization: …`.
/// - `SAB_VIDEO_MASTER`: optional HLS multivariant playlist supplying the video.
/// - `SAB_START`: optional start time in seconds.
@main struct StreamPlayerApp: App {
    // devicectl --console reads stdout through a pipe; keep diagnostics line-buffered.
    init() { setvbuf(stdout, nil, _IOLBF, 0) }

    var body: some Scene { WindowGroup { PlayerScreen() } }
}

@MainActor @Observable final class StreamSession {
    let player = AVPlayer()
    var status = "Starting…"
    private var stream: APACStream?
    private var atmos: AtmosOutputActivator?
    private var monitor: Task<Void, Never>?

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
            let stream = try await APACStream.start(file: file, videoMaster: environment["SAB_VIDEO_MASTER"].flatMap(URL.init(string:)),
                                                    startTime: start)
            self.stream = stream
            log("ready in \(ContinuousClock.now - clock): track \(stream.track.number) \(stream.track.codecID) \(stream.track.language ?? "-")")
            if let url = Bundle.main.url(forResource: "silent-atmos", withExtension: "mp4", subdirectory: "Media") {
                let atmos = AtmosOutputActivator(silentAtmosStream: url)
                // The master offers only the APAC rendition, so every item plays APAC.
                atmos.attach(to: player)
                self.atmos = atmos
            } else {
                log("no silent Atmos stream bundled: receivers may not switch to Atmos")
            }
            player.replaceCurrentItem(with: AVPlayerItem(url: stream.masterPlaylistURL ?? stream.audioPlaylistURL))
            if start > .zero { await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) }
            player.play()
            status = stream.renditionName
            monitor = Task { [weak self] in await self?.report() }
        } catch {
            status = "\(error)"
            log("failed: \(error)")
        }
    }

    /// Prints playback state every five seconds for device diagnostics.
    private func report() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let item = player.currentItem
            // Only the file name: server URLs can carry credentials.
            let errors = item?.errorLog()?.events.suffix(2).map {
                "\($0.errorStatusCode) \($0.uri.flatMap(URL.init(string:))?.lastPathComponent ?? "-") \($0.errorComment ?? "")"
            } ?? []
            let speed = await stream?.conversionSpeed ?? 0
            log(String(format: "t=%.1f rate=%.1f item=%d silentAtmos=%@ conversion=%.2fx errors=%@", player.currentTime().seconds,
                       player.rate, item?.status.rawValue ?? -1, atmos?.isActive == true ? "on" : "off", speed,
                       errors.joined(separator: " | ")))
        }
    }

    private func log(_ message: String) { print("STREAM \(message)") }
}

struct PlayerScreen: View {
    @State private var session = StreamSession()

    var body: some View {
        PlayerView(player: session.player)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Text(session.status).font(.caption).padding(12).background(.black.opacity(0.5)).padding(40)
            }
            .task { await session.start() }
    }
}

struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
