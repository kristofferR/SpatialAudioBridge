import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

struct Sample: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    static let all: [Sample] = {
        let originals = [
            Sample(id: "helicopter", name: "Helicopter"),
            Sample(id: "amaze", name: "Amaze"),
            Sample(id: "natures-fury", name: "Nature’s Fury"),
            Sample(id: "channel-check-7.1.4", name: "7.1.4 Channel Check")
        ]
        guard let url = Bundle.main.url(forResource: "extra-samples", withExtension: "json", subdirectory: "Media") else { return originals }
        do {
            let extras = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
            var ids = Set(originals.map(\.id))
            return originals + extras.filter { !$0.id.isEmpty && !$0.name.isEmpty && ids.insert($0.id).inserted }
        } catch {
            print("EXTRA SAMPLES ERROR: \(error.localizedDescription)")
            return originals
        }
    }()
}

enum Version: String, CaseIterable {
    case apac = "TrueHD → APAC 9.1.6"
    case ddp = "DDP Atmos (Deezy)"
    var suffix: String { self == .apac ? "APAC" : "DDP" }
}

struct AutoExcerpt {
    let sample: Sample
    let start: CMTime
    var end: CMTime { start + CMTime(seconds: 20, preferredTimescale: 48000) }
}

@MainActor @Observable final class Playback {
    let player = AVPlayer()
    var sample = Sample.all[0]
    var version = Version.apac
    var position = 0.0
    var duration = 0.0
    var playing = false
    var loading = false
    var error: String?
    private(set) var autoRunning = false
    private(set) var autoCompleted = false
    private(set) var autoIndex = 0
    private var autoExcerpts: [AutoExcerpt] = []
    private var autoPreparation: Task<Void, Never>?
    private var autoGeneration = UUID()
    private var observer: Any?
    private var itemObserver: NSKeyValueObservation?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var wantsPlayback = false
    private let carrier = AVQueuePlayer()
    private var carrierLooper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    private var nowPlaying: MPNowPlayingSession?
    private var playOperation: Task<Void, Never>?

    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        player.automaticallyWaitsToMinimizeStalling = false
        carrier.automaticallyWaitsToMinimizeStalling = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 48000), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if time.seconds.isFinite { self.position = time.seconds }
                self.playing = self.player.timeControlStatus == .playing
            }
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
        } catch { self.error = error.localizedDescription }
        nowPlaying = MPNowPlayingSession(players: [player])
        nowPlaying?.automaticallyPublishesNowPlayingInfo = true
        load(sample: sample, version: version, resume: false)
    }

    func load(sample nextSample: Sample, version nextVersion: Version, resume: Bool? = nil) {
        let sameSample = sample == nextSample
        let time = sameSample ? player.currentTime() : .zero
        let shouldPlay = resume ?? wantsPlayback
        cancelAuto()
        loadTrack(sample: nextSample, version: nextVersion, at: time, resume: shouldPlay)
    }

    private func loadTrack(sample nextSample: Sample, version nextVersion: Version, at time: CMTime, resume shouldPlay: Bool, end: CMTime = .invalid) {
        wantsPlayback = shouldPlay
        player.pause()
        playOperation?.cancel()
        stopCarrier()
        playing = false
        sample = nextSample
        version = nextVersion
        error = nil
        loading = true
        operation?.cancel()
        let token = UUID()
        generation = token
        guard let url = Bundle.main.url(forResource: "\(sample.id).\(version.suffix)", withExtension: "mp4", subdirectory: "Media") else {
            fail("Sample file is missing. Run prepare-media.sh and rebuild.")
            return
        }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // End on the media timeline, so preparation and buffering do not consume the excerpt.
        item.forwardPlaybackEndTime = end
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.generation == token else { return }
                self?.trackEnded()
            }
        }
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let message = item.status == .failed ? (item.error?.localizedDescription ?? "Playback failed") : nil
            if let message {
                Task { @MainActor [weak self] in
                    guard self?.generation == token else { return }
                    self?.fail(message)
                }
            }
        }
        player.replaceCurrentItem(with: item)
        operation = Task { [weak self] in
            do {
                let length = try await asset.load(.duration).seconds
                guard let self, !Task.isCancelled, self.generation == token else { return }
                guard length.isFinite, length > 0 else {
                    self.fail("The sample has no playable duration.")
                    return
                }
                self.duration = length
                let target = CMTimeMinimum(time.isNumeric ? CMTimeMaximum(.zero, time) : .zero,
                                           CMTime(seconds: max(0, length - 0.05), preferredTimescale: 48000))
                let sought = await self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled, self.generation == token else { return }
                self.loading = false
                guard sought else {
                    self.fail("Could not seek to the selected excerpt.")
                    return
                }
                self.position = self.player.currentTime().seconds
                if self.autoRunning {
                    print("AUTO READY step=\(self.autoIndex + 1) sample=\(self.sample.id) version=\(self.version.suffix) start=\(target.seconds) actual=\(self.position) end=\(end.seconds)")
                }
                if shouldPlay { self.startPlayback() }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    var autoExcerpt: AutoExcerpt? {
        guard autoRunning, autoExcerpts.indices.contains(autoIndex / 2) else { return nil }
        return autoExcerpts[autoIndex / 2]
    }

    func startAuto() {
        stopAuto()
        error = nil
        loading = true
        autoRunning = true
        autoIndex = 0
        let token = autoGeneration
        autoPreparation = Task { [weak self] in
            do {
                var excerpts: [AutoExcerpt] = []
                for sample in Sample.all {
                    var sharedDuration = Double.infinity
                    for version in Version.allCases {
                        guard let url = Bundle.main.url(forResource: "\(sample.id).\(version.suffix)", withExtension: "mp4", subdirectory: "Media") else {
                            throw NSError(domain: "AtmosAB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sample file is missing: \(sample.name) \(version.suffix)."])
                        }
                        let duration = try await AVURLAsset(url: url).load(.duration).seconds
                        try Task.checkCancellation()
                        guard duration.isFinite, duration >= 20 else {
                            throw NSError(domain: "AtmosAB", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(sample.name) needs at least 20 seconds in both formats."])
                        }
                        sharedDuration = min(sharedDuration, duration)
                    }
                    let maximumStart = max(0, sharedDuration - 20 - 0.05)
                    let start = CMTime(value: Int64(Double.random(in: 0...maximumStart) * 48000), timescale: 48000)
                    excerpts.append(AutoExcerpt(sample: sample, start: start))
                }
                guard let self, !Task.isCancelled, self.autoGeneration == token, self.autoRunning else { return }
                self.autoExcerpts = excerpts
                self.playAutoExcerpt()
            } catch {
                guard let self, !Task.isCancelled, self.autoGeneration == token else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func stopAuto() {
        cancelAuto()
        operation?.cancel()
        loading = false
        pause()
        stopCarrier()
    }

    private func cancelAuto() {
        autoPreparation?.cancel()
        autoPreparation = nil
        autoGeneration = UUID()
        autoRunning = false
        autoCompleted = false
        autoExcerpts = []
        player.currentItem?.forwardPlaybackEndTime = .invalid
    }

    private func playAutoExcerpt() {
        guard let excerpt = autoExcerpt else { return }
        loadTrack(sample: excerpt.sample, version: autoIndex.isMultiple(of: 2) ? .apac : .ddp,
                  at: excerpt.start, resume: true, end: excerpt.end)
    }

    private func trackEnded() {
        if autoRunning, autoExcerpt != nil {
            print("AUTO END step=\(autoIndex + 1) sample=\(sample.id) version=\(version.suffix) actual=\(player.currentTime().seconds)")
            if autoIndex + 1 < autoExcerpts.count * 2 {
                autoIndex += 1
                playAutoExcerpt()
                return
            }
            cancelAuto()
            autoCompleted = true
        }
        pause()
        stopCarrier()
    }

    private func fail(_ message: String) {
        error = message
        stopAuto()
    }

    func toggle() {
        guard !loading else { return }
        if wantsPlayback { pause() } else { startPlayback() }
    }

    func pause() {
        playOperation?.cancel()
        player.pause()
        carrier.pause()
        playing = false
        wantsPlayback = false
    }

    private func startPlayback() {
        wantsPlayback = true
        let token = generation
        playOperation?.cancel()
        playOperation = Task { [weak self] in
            guard let self else { return }
            _ = await self.nowPlaying?.becomeActiveIfPossible()
            guard !Task.isCancelled, self.generation == token, self.wantsPlayback else { return }
            self.playPreparedTrack()
        }
    }

    private func playPreparedTrack() {
        if version == .apac {
            guard let url = Bundle.main.url(forResource: "silent-atmos-carrier", withExtension: "mp4", subdirectory: "Media") else {
                fail("Atmos carrier is missing. Rebuild the app with its media.")
                return
            }
            // The near-silent JOC stream activates the HDMI Atmos route independently of APAC.
            if carrierLooper == nil {
                carrierLooper = AVPlayerLooper(player: carrier, templateItem: AVPlayerItem(url: url))
            }
            carrier.play()
        }
        player.play()
        wantsPlayback = true
    }

    private func stopCarrier() {
        carrier.pause()
        carrierLooper?.disableLooping()
        carrierLooper = nil
        carrier.removeAllItems()
    }

    var carrierRate: Float { carrier.rate }

    var outputChannels: Int {
        AVAudioSession.sharedInstance().outputNumberOfChannels
    }

    func seek(_ seconds: Double) {
        if autoRunning { stopAuto() }
        player.seek(to: CMTime(seconds: min(max(0, seconds), max(0, duration - 0.05)), preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var route: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
    }

    var trackStatus: String {
        if error != nil { return "Playback error" }
        if loading { return "Loading" }
        return playing ? "Playing" : "Paused"
    }
}

@main struct AtmosABApp: App {
    var body: some Scene { WindowGroup { ComparisonView() } }
}

struct ComparisonView: View {
    private enum FocusTarget: Hashable {
        case sample(String)
        case version(Version)
        case auto
    }

    @State private var playback = Playback()
    @FocusState private var focused: FocusTarget?
    private let channelNames = ["Front L", "Front R", "Center", "LFE", "Side L", "Side R", "Rear L", "Rear R", "Top front L", "Top front R", "Top rear L", "Top rear R"]

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 24) {
                Text("Atmos A/B").font(.largeTitle.bold())
                Button {
                    if playback.autoRunning { playback.stopAuto() } else { playback.startAuto() }
                } label: {
                    Label(playback.autoRunning ? "Stop Auto" : "Auto mode", systemImage: playback.autoRunning ? "stop.fill" : "arrow.triangle.2.circlepath")
                        .frame(width: 330, alignment: .leading)
                }
                .focused($focused, equals: .auto)
                .onMoveCommand { direction in
                    if direction == .right { focused = .version(playback.version) }
                }
                AutoStatusView(playback: playback)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(Sample.all) { sample in
                            Button { playback.load(sample: sample, version: playback.version) } label: {
                                HStack {
                                    Text(sample.name)
                                    Spacer()
                                    if playback.sample == sample { Image(systemName: "checkmark") }
                                }.frame(width: 330)
                            }
                            .focused($focused, equals: .sample(sample.id))
                            .onMoveCommand { direction in
                                if direction == .right { focused = .version(playback.version) }
                            }
                        }
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 24)
                }
            }
            .frame(width: 390, alignment: .leading)
            .focusSection()
            VStack(alignment: .leading, spacing: 20) {
                Text(playback.sample.name).font(.largeTitle)
                Label("\(playback.trackStatus): \(playback.version.rawValue)", systemImage: playback.playing ? "speaker.wave.2.fill" : "pause.circle")
                    .font(.title2)
                HStack(spacing: 24) {
                    ForEach(Version.allCases, id: \.self) { version in
                        Button { playback.load(sample: playback.sample, version: version) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .opacity(playback.version == version ? 1 : 0)
                                Text(version.rawValue)
                            }
                        }
                            .overlay {
                                Capsule()
                                    .stroke(playback.version == version ? Color.green : Color.clear, lineWidth: 3)
                            }
                            .accessibilityAddTraits(playback.version == version ? .isSelected : [])
                            .focused($focused, equals: .version(version))
                            .onMoveCommand { direction in
                                if direction == .left {
                                    focused = version == .apac ? .sample(playback.sample.id) : .version(.apac)
                                } else if direction == .right && version == .apac {
                                    focused = .version(.ddp)
                                }
                            }
                    }
                }
                .focusSection()
                Text("\(clock(playback.position)) / \(clock(playback.duration))").font(.title.monospacedDigit())
                ProgressView(value: min(playback.position, playback.duration), total: max(1, playback.duration))
                HStack(spacing: 24) {
                    Button("−10 seconds") { playback.seek(playback.position - 10) }.disabled(playback.autoRunning)
                    Button(playback.playing ? "Pause" : "Play") { playback.toggle() }
                    Button("+10 seconds") { playback.seek(playback.position + 10) }.disabled(playback.autoRunning)
                    Button("Restart") { playback.seek(0) }.disabled(playback.autoRunning)
                }.disabled(playback.loading)
                if playback.loading { Text("Loading sample…").foregroundStyle(.secondary) }
                if let error = playback.error { Text(error).foregroundStyle(.red) }
                if playback.sample.id == "channel-check-7.1.4" {
                    Text("Jump into a speaker’s test section").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 4), spacing: 20) {
                        ForEach(channelNames.indices, id: \.self) { index in
                            Button(channelNames[index]) { playback.seek(Double(30 + index * 60)) }
                        }
                    }.disabled(playback.loading || playback.autoRunning)
                }
                Text("Switching keeps the position and play/pause state. There is a short switching gap.").font(.callout).foregroundStyle(.secondary)
                Text("APAC is our rendering of the TrueHD source. DDP Atmos is Deezy’s conversion of the same source.").font(.callout).foregroundStyle(.secondary)
                Text("Output: \(playback.route) • Keep Apple TV audio on Auto with Dolby Atmos enabled.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
        }
        .padding(48)
        .onPlayPauseCommand { playback.toggle() }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--probe") { await RouteProbe.run(playback: playback) }
            if ProcessInfo.processInfo.arguments.contains("--auto-probe") { await RouteProbe.runAuto(playback: playback) }
        }
    }

    private func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct AutoStatusView: View {
    let playback: Playback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let excerpt = playback.autoExcerpt {
                Text("Pair \(playback.autoIndex / 2 + 1) of \(Sample.all.count) • \(playback.version == .apac ? "TrueHD → APAC" : "DDP")")
                Text("\(Int(min(20, max(0, playback.position - excerpt.start.seconds)))) / 20 seconds")
                    .monospacedDigit()
                ProgressView(value: min(20, max(0, playback.position - excerpt.start.seconds)), total: 20)
            } else if playback.autoRunning {
                Text("Preparing Auto mode…")
            } else if playback.autoCompleted {
                Text("Auto complete • All \(Sample.all.count) pairs played")
            } else {
                Text("20 seconds per format, all \(Sample.all.count) pairs.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 330, alignment: .leading)
    }
}
