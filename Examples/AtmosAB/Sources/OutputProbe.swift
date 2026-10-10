import AudioToolbox
import AVFoundation
import MediaPlayer
import SwiftUI

/// Plays a channel sweep made by `make-test-media.swift sweep` and reports what tvOS does with the
/// output: the route, the hardware format and layout, and the session's audio format.
///
/// Launch with `--output-probe`, then optionally `--sweep=7.1.4` (default 9.1.6), `--atmos=mat` or
/// `--atmos=none` (default: the silent Atmos stream), and `--start=SECONDS` or `--sections=Lw,Rw`.
/// `--atmos=channels --channels=12` asks for that many output channels instead, and
/// `--no-playback` only reports the state after the request.
///
/// `--atmos=mat` asks for Dolby MAT Atmos output through private `AVAudioSession` methods instead of
/// the silent stream. They are not public API: use them for experiments only.
@MainActor @Observable final class OutputProbe {
    static let names = [
        "L": "Front left", "R": "Front right", "C": "Center", "LFE": "LFE",
        "Lw": "Left wide", "Rw": "Right wide", "Ls": "Side left", "Rs": "Side right",
        "Lrs": "Rear left", "Rrs": "Rear right", "Vhl": "Top front left", "Vhr": "Top front right",
        "Ltm": "Top middle left", "Rtm": "Top middle right", "Ltr": "Top rear left", "Rtr": "Top rear right"
    ]

    let sweep: String
    let atmosMode: String
    let order: [String]
    /// From `--sections=Lw,Rw`: play only these sections instead of the whole sweep.
    let sections: [String]
    private(set) var section = "Preparing"
    private(set) var status = ""
    private let player = AVPlayer()
    private var atmos: AtmosOutputActivator?
    private var nowPlaying: MPNowPlayingSession?
    private let engine = AVAudioEngine()

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        sweep = value("sweep") ?? "9.1.6"
        atmosMode = value("atmos") ?? "silent"
        let wide = sweep == "9.1.6"
        order = ["L", "R", "C", "LFE", "Lw", "Rw", "Ls", "Rs", "Lrs", "Rrs", "Vhl", "Vhr", "Ltm", "Rtm", "Ltr", "Rtr"]
            .filter { wide || !["Lw", "Rw", "Ltm", "Rtm"].contains($0) }
        sections = value("sections")?.split(separator: ",").map(String.init) ?? []
        let start = value("start").flatMap(Double.init) ?? 0
        Task { await run(from: start) }
    }

    private func run(from start: Double) async {
        do {
            try AtmosOutputActivator.configureAudioSession()
            report("configured")
            if atmosMode == "mat" {
                try requestMATAtmos()
                try await Task.sleep(for: .seconds(1))
                report("requested MAT Atmos")
            }
            if atmosMode == "channels" {
                let count = Int(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--channels=") }?.dropFirst(11) ?? "") ?? 12
                try AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(count)
                try await Task.sleep(for: .seconds(1))
                report("requested \(count) channels")
            }
            if ProcessInfo.processInfo.arguments.contains("--no-playback") {
                section = "Done"
                print("OUTPUT PROBE DONE")
                return
            }
            guard let url = Bundle.main.url(forResource: "channel-sweep-\(sweep).APAC", withExtension: "mp4", subdirectory: "Media") else {
                status = "Missing Media/channel-sweep-\(sweep).APAC.mp4"
                print("OUTPUT PROBE FAIL \(status)")
                return
            }
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            nowPlaying = MPNowPlayingSession(players: [player])
            if atmosMode == "silent" {
                atmos = AtmosOutputActivator()
                atmos?.attach(to: player)
            }
            print("OUTPUT PROBE sweep=\(sweep) atmos=\(atmosMode) order=\(order.joined(separator: ","))")
            _ = await nowPlaying?.becomeActiveIfPossible()
            if !sections.isEmpty {
                try await playSections()
                return
            }
            await player.seek(to: CMTime(seconds: start, preferredTimescale: 48_000))
            player.play()
            var last = ""
            var reported = false
            while true {
                try await Task.sleep(for: .milliseconds(250))
                let time = player.currentTime().seconds
                let index = Int((time - 2) / 10)
                let name = time < 2 ? "Lead-in" : order.indices.contains(index) ? order[index] : "End"
                if name != last {
                    last = name
                    section = name == "Lead-in" || name == "End" ? name : "\(Self.names[name] ?? name) (\(name))"
                    print("OUTPUT PROBE SECTION \(section) at \(String(format: "%.1f", time)) s")
                }
                if !reported, time >= start + 3 {
                    reported = true
                    report("playing")
                }
                if name == "End" || player.currentItem?.status == .failed { break }
            }
            report("ended")
            player.pause()
            print("OUTPUT PROBE DONE")
        } catch {
            status = error.localizedDescription
            print("OUTPUT PROBE FAIL \(error)")
        }
    }

    /// Plays only the listed sections, each once, with a pause between them.
    private func playSections() async throws {
        var reported = false
        for name in sections {
            guard let index = order.firstIndex(of: name) else { throw ProbeError("No \(name) section in the \(sweep) sweep") }
            section = "…"
            await player.seek(to: CMTime(seconds: 2 + Double(index) * 10, preferredTimescale: 48_000))
            try await Task.sleep(for: .seconds(1.5))
            section = "\(Self.names[name] ?? name) (\(name))"
            print("OUTPUT PROBE SECTION \(section)")
            player.play()
            try await Task.sleep(for: .seconds(3))
            if !reported {
                reported = true
                report("playing")
            }
            try await Task.sleep(for: .seconds(7))
            player.pause()
        }
        section = "Done"
        report("ended")
        print("OUTPUT PROBE DONE")
    }

    /// Asks the session for Dolby MAT Atmos output, `'mat+'`, through the private
    /// `-[AVAudioSession setPreferredAudioFormat:error:]`.
    private func requestMATAtmos() throws {
        let session = AVAudioSession.sharedInstance()
        let selector = NSSelectorFromString("setPreferredAudioFormat:error:")
        guard session.responds(to: selector) else { throw ProbeError("setPreferredAudioFormat:error: is unavailable") }
        typealias Setter = @convention(c) (AnyObject, Selector, Int, UnsafeMutablePointer<NSError?>?) -> Bool
        let set = unsafeBitCast(session.method(for: selector), to: Setter.self)
        var error: NSError?
        guard set(session, selector, Int(fourCC("mat+")), &error) else { throw error ?? ProbeError("setPreferredAudioFormat failed") }
    }

    private func report(_ phase: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { port in
            "\(port.portType.rawValue) \"\(port.portName)\" channels=\(port.channels?.count ?? 0) labels=\((port.channels ?? []).map { String($0.channelLabel) }.joined(separator: ","))"
        }
        let format = engine.outputNode.outputFormat(forBus: 0)
        let line = [
            "phase=\(phase)",
            "audioFormat=\(privateFourCC("audioFormat"))",
            "preferredAudioFormat=\(privateFourCC("preferredAudioFormat"))",
            "audioFormats=\(privateObject("audioFormats"))",
            "dolbyAtmosAvailable=\(privateBool("isDolbyAtmosAvailable"))",
            "outputChannels=\(session.outputNumberOfChannels)/\(session.maximumOutputNumberOfChannels)",
            "renderingMode=\(session.renderingMode.rawValue)",
            "hardware=\(format.channelCount)ch \(Int(format.sampleRate))Hz layout=\(hardwareLayout())",
            "route=[\(outputs.joined(separator: "; "))]",
            "silentAtmos=\(atmos?.isActive ?? false)"
        ].joined(separator: " ")
        status = line
        print("OUTPUT PROBE STATE \(line)")
    }

    /// The output unit's channel layout, which shows private tags the session API hides.
    private func hardwareLayout() -> String {
        let tag = engine.outputNode.outputFormat(forBus: 0).channelLayout.map { String(format: "0x%08X", $0.layoutTag) } ?? "none"
        guard let unit = engine.outputNode.audioUnit else { return tag }
        let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        var size: UInt32 = 0
        var status = AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Output, 0, &size, nil)
        guard status == noErr, size >= UInt32(header) else { return "\(tag) unit=\(status)" }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioChannelLayout>.size), alignment: 8)
        defer { raw.deallocate() }
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Output, 0, raw, &size)
        guard status == noErr else { return "\(tag) unit=\(status)" }
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        let descriptions = (raw + MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
            .assumingMemoryBound(to: AudioChannelDescription.self)
        let available = (Int(size) - MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!) / MemoryLayout<AudioChannelDescription>.stride
        let labels = (0..<min(count, available)).map { String(descriptions[$0].mChannelLabel) }
        return "\(tag) unit=" + String(format: "0x%08X", layout.pointee.mChannelLayoutTag) + (labels.isEmpty ? "" : " labels=\(labels.joined(separator: ","))")
    }

    private func privateFourCC(_ name: String) -> String {
        let selector = NSSelectorFromString(name)
        let session = AVAudioSession.sharedInstance()
        guard session.responds(to: selector) else { return "unavailable" }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int
        let value = unsafeBitCast(session.method(for: selector), to: Getter.self)(session, selector)
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - $0 * 8)) }
        return bytes.allSatisfy { (32..<127).contains($0) } ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(value)"
    }

    private func privateBool(_ name: String) -> String {
        let selector = NSSelectorFromString(name)
        let session = AVAudioSession.sharedInstance()
        guard session.responds(to: selector) else { return "unavailable" }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return "\(unsafeBitCast(session.method(for: selector), to: Getter.self)(session, selector))"
    }

    private func privateObject(_ name: String) -> String {
        let selector = NSSelectorFromString(name)
        let session = AVAudioSession.sharedInstance()
        guard session.responds(to: selector) else { return "unavailable" }
        return (session.perform(selector)?.takeUnretainedValue()).map { "\($0)".replacingOccurrences(of: "\n", with: " ") } ?? "nil"
    }

    private func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

private struct ProbeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct OutputProbeView: View {
    @State private var probe = OutputProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            // `--label=Run 1` replaces the route name for blind listening comparisons.
            Text(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--label=") }.map { String($0.dropFirst(8)) }
                 ?? "Output probe • \(probe.sweep) sweep • Atmos: \(probe.atmosMode)").font(.title2)
            Text(probe.section).font(.system(size: 96, weight: .bold))
            Text(probe.status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
