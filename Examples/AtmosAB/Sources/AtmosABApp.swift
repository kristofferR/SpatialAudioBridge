import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

struct Sample: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    /// What the app lists and Auto plays. A layout comparison leaves out the static channel check and
    /// starts with the object path test, rendered by the Rust crate's `object_path` example, when bundled.
    static let listed: [Sample] = {
        guard Version.compareLayouts else { return all }
        let test = Sample(id: "object-path", name: "Object path: ear level, then overhead")
        let bundled = [Version.apac, .apac916].allSatisfy { $0.url(for: test) != nil }
        return (bundled ? [test] : []) + all.filter { !$0.id.hasPrefix("channel-check") }
    }()
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
    case apac = "APAC"
    case apac916 = "APAC 9.1.6"
    case baseline = "Old APAC"
    case ddp = "DD+ Atmos"
    case pcm = "PCM 7.1"
    var suffix: String {
        switch self {
        case .baseline: "APAC-baseline"
        case .apac: "APAC"
        case .apac916: "APAC-9.1.6"
        case .ddp: "DDP"
        case .pcm: "PCM"
        }
    }
    var detail: String {
        switch self {
        case .apac: "TrueHD rendered to APAC by this build"
        case .apac916: "TrueHD rendered to APAC 9.1.6 by this build"
        case .baseline: "TrueHD rendered to APAC by an earlier build"
        case .ddp: "Deezy’s Dolby Digital Plus Atmos conversion of the same source"
        case .pcm: "The TrueHD track’s own 7.1 mix as PCM, as other players output it, without heights"
        }
    }
    var isAPAC: Bool { self == .baseline || self == .apac || self == .apac916 }

    /// `--compare-layouts`: blind Auto compares this build's default 7.1.4 render with its 9.1.6
    /// render, without a reference; see `Sample.listed` for the samples.
    static let compareLayouts = ProcessInfo.processInfo.arguments.contains("--compare-layouts")

    /// Plain PCM is uncompressed LPCM in QuickTime; FLAC in MP4 failed on the tested Apple TV.
    func url(for sample: Sample) -> URL? {
        Bundle.main.url(forResource: "\(sample.id).\(suffix)", withExtension: self == .pcm ? "mov" : "mp4", subdirectory: "Media")
    }

    /// APAC and DD+ are always offered. The 9.1.6 render, the baseline (an APAC conversion from
    /// an earlier library build) and plain PCM are offered when every sample has one. With a
    /// baseline, Auto mode becomes a blind comparison against the DD+ reference.
    static let available: [Version] = allCases.filter { version in
        version == .apac || version == .ddp || Sample.all.allSatisfy { version.url(for: $0) != nil }
    }
}

struct AutoExcerpt {
    let sample: Sample
    let start: CMTime
    var end: CMTime { start + CMTime(seconds: 20, preferredTimescale: 48000) }
}

/// One playback in Auto mode. Blind steps are labelled X and Y, after an optional Reference.
struct AutoStep {
    let excerpt: Int
    let version: Version
    let label: String
}

enum Verdict: String, CaseIterable {
    case x = "X"
    case y = "Y"
    case same = "No difference"
}

/// The listener's answer to which of X and Y sounded closer to the reference, or better without one.
struct BlindResult {
    let sample: Sample
    let x: Version
    let y: Version
    let verdict: Verdict
    var closer: Version? {
        switch verdict {
        case .x: x
        case .y: y
        case .same: nil
        }
    }
}

@MainActor @Observable final class Playback {
    let player = AVPlayer()
    var sample = Sample.listed[0]
    var version = Version.apac
    var position = 0.0
    var duration = 0.0
    var playing = false
    var loading = false
    var error: String?
    /// A failure to set up Atmos output, kept apart from track errors so loading cannot clear it.
    private(set) var setupError: String?
    private(set) var autoRunning = false
    private(set) var autoCompleted = false
    private(set) var autoIndex = 0
    /// Set after the last blind step of an excerpt, until the listener answers or replays it.
    private(set) var awaitingVerdict = false
    private(set) var results: [BlindResult] = []
    /// The version blind Auto compares with this build's render: its 9.1.6 render when
    /// comparing layouts, otherwise the baseline. Without one, Auto is not blind.
    let challenger: Version? = [Version.compareLayouts ? .apac916 : .baseline].first { Version.available.contains($0) }
    var blind: Bool { challenger != nil }
    /// Blind Auto plays the DD+ reference before X and Y, except when comparing layouts.
    let reference: Version? = Version.compareLayouts ? nil : .ddp
    let autoSamples = Sample.listed
    /// The versions each Auto excerpt plays.
    var autoVersions: [Version] { challenger.map { (reference.map { [$0] } ?? []) + [.apac, $0] } ?? Version.available }
    /// Blind Auto plays the reference, X and Y; otherwise every available version plays in turn.
    var stepsPerExcerpt: Int { blind ? (reference == nil ? 2 : 3) : Version.available.count }
    private var autoExcerpts: [AutoExcerpt] = []
    private(set) var autoSteps: [AutoStep] = []
    private var autoPreparation: Task<Void, Never>?
    private var autoGeneration = UUID()
    private var observer: Any?
    private var itemObserver: NSKeyValueObservation?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var wantsPlayback = false
    private var atmos: AtmosOutputActivator?
    private var endObserver: NSObjectProtocol?
    private var nowPlaying: MPNowPlayingSession?
    private var playOperation: Task<Void, Never>?

    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        player.automaticallyWaitsToMinimizeStalling = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 48000), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if time.seconds.isFinite { self.position = time.seconds }
                self.playing = self.player.timeControlStatus == .playing
            }
        }
        // Launch arguments isolate each part of the tested Atmos setup on a device.
        let arguments = ProcessInfo.processInfo.arguments
        do {
            if arguments.contains("--plain-session") {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } else {
                try AtmosOutputActivator.configureAudioSession()
            }
        } catch { setupError = error.localizedDescription }
        if !arguments.contains("--without-now-playing") {
            nowPlaying = MPNowPlayingSession(players: [player])
            nowPlaying?.automaticallyPublishesNowPlayingInfo = true
        }
        if !arguments.contains("--without-silent-atmos") {
            atmos = AtmosOutputActivator()
            atmos?.attach(to: player) { [weak self] _ in self?.version.isAPAC == true }
        }
        print("ATMOS SETUP session=\(arguments.contains("--plain-session") ? "plain" : "multichannel") nowPlaying=\(nowPlaying != nil) silentAtmos=\(atmos != nil)")
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
        playing = false
        sample = nextSample
        version = nextVersion
        error = nil
        loading = true
        operation?.cancel()
        let token = UUID()
        generation = token
        guard let url = version.url(for: sample) else {
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

    var autoStep: AutoStep? {
        guard autoRunning, autoSteps.indices.contains(autoIndex) else { return nil }
        return autoSteps[autoIndex]
    }

    var autoExcerpt: AutoExcerpt? {
        autoStep.map { autoExcerpts[$0.excerpt] }
    }

    /// What the player shows for the current version; blind steps hide which APAC plays.
    var versionLabel: String {
        if blind, let step = autoStep { return step.label }
        return version.rawValue
    }

    func startAuto() {
        stopAuto()
        error = nil
        loading = true
        autoRunning = true
        autoIndex = 0
        results = []
        let token = autoGeneration
        let samples = autoSamples, versions = autoVersions
        autoPreparation = Task { [weak self] in
            do {
                var excerpts: [AutoExcerpt] = []
                for sample in samples {
                    var sharedDuration = Double.infinity
                    for version in versions {
                        guard let url = version.url(for: sample) else {
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
                self.autoSteps = excerpts.indices.flatMap { index -> [AutoStep] in
                    guard let challenger = self.challenger else {
                        return Version.available.map { AutoStep(excerpt: index, version: $0, label: $0.rawValue) }
                    }
                    let (x, y) = Bool.random() ? (Version.apac, challenger) : (challenger, .apac)
                    return (self.reference.map { [AutoStep(excerpt: index, version: $0, label: "Reference")] } ?? [])
                        + [AutoStep(excerpt: index, version: x, label: "X"), AutoStep(excerpt: index, version: y, label: "Y")]
                }
                self.playAutoStep()
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
    }

    private func cancelAuto() {
        autoPreparation?.cancel()
        autoPreparation = nil
        autoGeneration = UUID()
        autoRunning = false
        autoCompleted = false
        awaitingVerdict = false
        autoExcerpts = []
        autoSteps = []
        player.currentItem?.forwardPlaybackEndTime = .invalid
    }

    private func playAutoStep() {
        guard let step = autoStep, let excerpt = autoExcerpt else { return }
        loadTrack(sample: excerpt.sample, version: step.version, at: excerpt.start, resume: true, end: excerpt.end)
    }

    private func trackEnded() {
        if autoRunning, let step = autoStep {
            print("AUTO END step=\(autoIndex + 1) sample=\(sample.id) version=\(version.suffix) actual=\(player.currentTime().seconds)")
            let next = autoIndex + 1
            if blind, !autoSteps.indices.contains(next) || autoSteps[next].excerpt != step.excerpt {
                // Ask which of X and Y was closer to the reference, or better, before moving on.
                awaitingVerdict = true
            } else if autoSteps.indices.contains(next) {
                autoIndex = next
                playAutoStep()
                return
            } else {
                cancelAuto()
                autoCompleted = true
            }
        }
        pause()
    }

    func answer(_ verdict: Verdict) {
        guard awaitingVerdict, let step = autoStep else { return }
        let blindSteps = autoSteps.filter { $0.excerpt == step.excerpt && $0.version.isAPAC }
        let result = BlindResult(sample: autoExcerpts[step.excerpt].sample, x: blindSteps[0].version,
                                 y: blindSteps[1].version, verdict: verdict)
        results.append(result)
        print("BLIND RESULT sample=\(result.sample.id) x=\(result.x.suffix) y=\(result.y.suffix) verdict=\(verdict.rawValue) closer=\(result.closer?.suffix ?? "none")")
        awaitingVerdict = false
        if autoSteps.indices.contains(autoIndex + 1) {
            autoIndex += 1
            playAutoStep()
        } else {
            cancelAuto()
            autoCompleted = true
        }
    }

    /// Plays the current excerpt's steps again before answering.
    func replayExcerpt() {
        guard awaitingVerdict, let step = autoStep,
              let first = autoSteps.firstIndex(where: { $0.excerpt == step.excerpt }) else { return }
        awaitingVerdict = false
        autoIndex = first
        playAutoStep()
    }

    private func fail(_ message: String) {
        error = message
        stopAuto()
    }

    func toggle() {
        guard !loading, !awaitingVerdict else { return }
        if wantsPlayback { pause() } else { startPlayback() }
    }

    func pause() {
        playOperation?.cancel()
        player.pause()
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
        // The activator follows the player and plays the silent Atmos stream for APAC only.
        player.play()
        wantsPlayback = true
    }

    var silentAtmosEnabled: Bool { atmos != nil }
    var silentAtmosActive: Bool { atmos?.isActive ?? false }

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
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--output-probe") { OutputProbeView() } else { ComparisonView() }
        }
    }
}

struct ComparisonView: View {
    private enum FocusTarget: Hashable {
        case sample(String)
        case version(Version)
        case auto
        case verdict(Verdict?)
    }

    @State private var playback = Playback()
    @FocusState private var focused: FocusTarget?
    private let channelNames = ["Front L", "Front R", "Center", "LFE", "Side L", "Side R", "Rear L", "Rear R", "Top front L", "Top front R", "Top rear L", "Top rear R"]

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 24) {
                Text(playback.blind && playback.reference != nil ? "Atmos A/B/C" : "Atmos A/B").font(.largeTitle.bold())
                Button {
                    if playback.autoRunning { playback.stopAuto() } else { playback.startAuto() }
                } label: {
                    Label(playback.autoRunning ? "Stop Auto" : "Auto mode", systemImage: playback.autoRunning ? "stop.fill" : "arrow.triangle.2.circlepath")
                        .frame(width: 330, alignment: .leading)
                }
                .focused($focused, equals: .auto)
                .onMoveCommand { direction in
                    if direction == .right { focused = versionFocus }
                }
                AutoStatusView(playback: playback)
                if playback.awaitingVerdict {
                    Text(playback.reference == nil ? "Which sounded better?" : "Which was closer to the reference?").font(.headline)
                    ForEach(Verdict.allCases, id: \.self) { verdict in
                        Button(verdict.rawValue) { playback.answer(verdict) }
                            .frame(width: 330, alignment: .leading)
                            .focused($focused, equals: .verdict(verdict))
                    }
                    Button("Replay excerpt") { playback.replayExcerpt() }
                        .frame(width: 330, alignment: .leading)
                        .focused($focused, equals: .verdict(nil))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(Sample.listed) { sample in
                            Button { playback.load(sample: sample, version: playback.version) } label: {
                                HStack {
                                    Text(sample.name)
                                    Spacer()
                                    if playback.sample == sample { Image(systemName: "checkmark") }
                                }.frame(width: 330)
                            }
                            .focused($focused, equals: .sample(sample.id))
                            .onMoveCommand { direction in
                                if direction == .right { focused = versionFocus }
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
                Label("\(playback.trackStatus): \(playback.versionLabel)", systemImage: playback.playing ? "speaker.wave.2.fill" : "pause.circle")
                    .font(.title2)
                // Blind Auto keeps the description hidden along with the version.
                if !(playback.blind && playback.autoRunning) {
                    Text(playback.version.detail).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    let versions = Version.available
                    ForEach(versions, id: \.self) { version in
                        // Blind Auto hides which APAC version is playing.
                        let selected = playback.version == version && !(playback.blind && playback.autoRunning)
                        Button { playback.load(sample: playback.sample, version: version) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .opacity(selected ? 1 : 0)
                                Text(version.rawValue)
                            }
                        }
                            .overlay {
                                Capsule()
                                    .stroke(selected ? Color.green : Color.clear, lineWidth: 3)
                            }
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .focused($focused, equals: .version(version))
                            .onMoveCommand { direction in
                                let index = versions.firstIndex(of: version) ?? 0
                                if direction == .left {
                                    focused = index == 0 ? .sample(playback.sample.id) : .version(versions[index - 1])
                                } else if direction == .right, index + 1 < versions.count {
                                    focused = .version(versions[index + 1])
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
                if let error = playback.setupError { Text(error).foregroundStyle(.red) }
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
                if let challenger = playback.challenger {
                    let order = "\(Version.apac.rawValue) and \(challenger.rawValue) as X and Y in random order"
                    Text(playback.reference == nil ? "Auto plays \(order)." : "Auto plays the DD+ reference, then \(order).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Output: \(playback.route) • Keep Apple TV audio on Auto with Dolby Atmos enabled.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
        }
        .padding(48)
        .onPlayPauseCommand { playback.toggle() }
        .onChange(of: playback.awaitingVerdict) { _, awaiting in
            if awaiting { focused = .verdict(.x) }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--probe") { await RouteProbe.run(playback: playback) }
            if ProcessInfo.processInfo.arguments.contains("--auto-probe") { await RouteProbe.runAuto(playback: playback) }
        }
    }

    /// Where moving right lands in the version row. Blind Auto must not focus the playing version.
    private var versionFocus: FocusTarget {
        .version(playback.blind && playback.autoRunning ? Version.available[0] : playback.version)
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
            if let step = playback.autoStep, let excerpt = playback.autoExcerpt {
                Text("Excerpt \(step.excerpt + 1) of \(playback.autoSamples.count) • \(step.label)")
                Text("\(Int(min(20, max(0, playback.position - excerpt.start.seconds)))) / 20 seconds")
                    .monospacedDigit()
                ProgressView(value: min(20, max(0, playback.position - excerpt.start.seconds)), total: 20)
            } else if playback.autoRunning {
                Text("Preparing Auto mode…")
            } else if playback.autoCompleted, let challenger = playback.challenger {
                let picked = { (version: Version?) in playback.results.filter { $0.closer == version }.count }
                Text("Blind comparison complete")
                Text("\(Version.apac.rawValue): \(picked(.apac)) • \(challenger.rawValue): \(picked(challenger)) • No difference: \(picked(nil))")
                ForEach(playback.results, id: \.sample.id) { result in
                    Text("\(result.sample.name): X was \(result.x.rawValue), picked \(result.verdict.rawValue)")
                }
            } else if playback.autoCompleted {
                Text("Auto complete • All \(playback.autoSamples.count) excerpts played")
            } else if playback.blind {
                Text("\(playback.reference == nil ? "X and Y" : "Reference, X and Y") for 20 seconds each, all \(playback.autoSamples.count) excerpts.")
            } else {
                Text("20 seconds per version, all \(playback.autoSamples.count) excerpts.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 330, alignment: .leading)
    }
}
