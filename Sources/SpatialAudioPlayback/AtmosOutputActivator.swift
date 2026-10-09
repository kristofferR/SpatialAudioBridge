import AVFoundation

/// Keeps Apple TV HDMI output in Dolby Atmos while a host `AVPlayer` plays APAC.
///
/// On the tested Apple TV and receiver route, APAC alone did not switch the output to Atmos.
/// A second, unmuted player looping a near-silent E-AC-3 + JOC (Dolby Atmos) stream did.
/// Supply that stream; this library does not ship one.
/// Validate each target route and OS: receiver Atmos indication does not prove speaker placement.
@MainActor
public final class AtmosOutputActivator {
    private let stream: URL
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private weak var host: AVPlayer?
    private var playsAPAC: @MainActor (AVPlayerItem) -> Bool = { _ in true }
    private var observations: [NSKeyValueObservation] = []
    private var selectionObserver: NSObjectProtocol?

    /// Whether the silent Atmos stream is currently playing.
    public var isActive: Bool { player.timeControlStatus == .playing }
    /// Why the silent Atmos stream could not play, if it failed to load.
    public var error: (any Error)? { looper?.error }

    /// `silentAtmosStream` must be a near-silent E-AC-3 file signalled as JOC (Dolby Atmos). It is looped.
    public init(silentAtmosStream: URL) {
        stream = silentAtmosStream
        player.automaticallyWaitsToMinimizeStalling = false
    }

    isolated deinit { detach() }

    /// Plays the silent stream whenever `player` is playing, or waiting to play, an item for which
    /// `playsAPAC` returns true. Pauses with the host and re-evaluates on item and audio selection changes.
    /// Pass a predicate when an item offers APAC and other audio renditions.
    public func attach(to player: AVPlayer, playsAPAC: @escaping @MainActor (AVPlayerItem) -> Bool = { _ in true }) {
        detach()
        host = player
        self.playsAPAC = playsAPAC
        // Host play() changes timeControlStatus synchronously on the main thread, so the stream
        // starts inside that call, ahead of APAC output.
        observations = [
            player.observe(\.currentItem, options: [.initial]) { [weak self] _, _ in
                Self.onMain { self?.follow(self?.host?.currentItem) }
            },
            player.observe(\.timeControlStatus) { [weak self] _, _ in
                Self.onMain { self?.update() }
            },
        ]
    }

    /// Stops following the host and releases the silent stream.
    public func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        host = nil
        follow(nil)
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }

    private func follow(_ item: AVPlayerItem?) {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = item.map {
            NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification,
                                                   object: $0, queue: .main) { [weak self] _ in
                Self.onMain { self?.update() }
            }
        }
        update()
    }

    private func update() {
        guard let host, host.timeControlStatus != .paused, let item = host.currentItem, playsAPAC(item) else {
            player.pause()
            return
        }
        if looper == nil {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: stream))
        }
        player.play()
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }
}

#if os(tvOS) || os(iOS)
extension AtmosOutputActivator {
    /// Configures and activates the shared session as in the tested setup: playback, movie playback mode
    /// and multichannel content. Call before playback when the host does not manage its own session.
    public static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setSupportsMultichannelContent(true)
        try session.setActive(true)
    }
}
#endif
