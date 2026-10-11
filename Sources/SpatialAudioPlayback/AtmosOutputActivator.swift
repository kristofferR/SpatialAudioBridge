import AVFoundation

/// Keeps Apple TV HDMI output in Dolby Atmos while a host `AVPlayer` plays APAC.
///
/// On the tested Apple TV and receiver route, APAC alone did not switch the output to Atmos.
/// A second, unmuted player looping a silent E-AC-3 stream signalled as Dolby Atmos did.
/// Validate each target route and OS: receiver Atmos indication does not prove speaker placement.
@available(macOS 26, iOS 26, tvOS 26, *)
@MainActor
public final class AtmosOutputActivator {
    private let stream: URL
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private weak var host: AVPlayer?
    private weak var synchronizer: AVSampleBufferRenderSynchronizer?
    private var rateObserver: NSObjectProtocol?
    private var playsAPAC: @MainActor (AVPlayerItem) -> Bool = { _ in true }
    private var observations: [NSKeyValueObservation] = []
    private var selectionObserver: NSObjectProtocol?

    /// Whether the silent Atmos stream is currently playing.
    public var isActive: Bool { player.timeControlStatus == .playing }
    /// Why the silent Atmos stream could not play, if it failed to load.
    public var error: (any Error)? { looper?.error }

    /// Loops the bundled stream: 2 s of digital silence in E-AC-3 signalled as Dolby Atmos,
    /// written by `scripts/make-silent-atmos.swift`.
    public convenience init() {
        self.init(silentAtmosStream: Self.bundledStream)
    }

    /// `silentAtmosStream` must be a silent or near-silent E-AC-3 file signalled as Dolby Atmos. It is looped.
    public init(silentAtmosStream: URL) {
        stream = silentAtmosStream
        player.automaticallyWaitsToMinimizeStalling = false
    }

    isolated deinit { detach() }

    static var bundledStream: URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        // The example apps compile these sources into the app, which copies the resource.
        let bundle = Bundle(for: AtmosOutputActivator.self)
        #endif
        return bundle.url(forResource: "silent-atmos", withExtension: "mp4")!
    }

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

    /// Plays the silent stream while `synchronizer` runs, for hosts that render APAC with
    /// `SpatialAudioRenderer` instead of AVPlayer.
    public func attach(to synchronizer: AVSampleBufferRenderSynchronizer) {
        detach()
        self.synchronizer = synchronizer
        rateObserver = NotificationCenter.default.addObserver(
            forName: AVSampleBufferRenderSynchronizer.rateDidChangeNotification, object: synchronizer, queue: .main
        ) { [weak self] _ in
            Self.onMain { self?.update() }
        }
        update()
    }

    /// Stops following the host and releases the silent stream.
    public func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        if let rateObserver { NotificationCenter.default.removeObserver(rateObserver) }
        rateObserver = nil
        host = nil
        synchronizer = nil
        follow(nil)
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
        if let synchronizer {
            if synchronizer.rate != 0 { play() } else { player.pause() }
            return
        }
        guard let host, let item = host.currentItem, playsAPAC(item) else {
            // A prerolled silent stream competes with other E-AC-3 playback; keep none loaded.
            release()
            return
        }
        guard host.timeControlStatus != .paused else {
            player.pause()
            return
        }
        play()
    }

    private func play() {
        if looper == nil {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: stream))
        }
        player.play()
    }

    private func release() {
        guard looper != nil else { return }
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
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
@available(macOS 26, iOS 26, tvOS 26, *)
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
