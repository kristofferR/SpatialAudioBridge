import AVFoundation
import Foundation

@MainActor enum RouteProbe {
    private struct AutoStep: Codable {
        let step: Int
        let sample: String
        let version: String
        let start: Double
        let end: Double
        let position: Double
        let carrierRate: Float
    }

    private struct ProbeFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func runAuto(playback: Playback) async {
        let output = URL.cachesDirectory.appendingPathComponent("auto-probe.json")
        do {
            playback.startAuto()
            var steps: [AutoStep] = []
            let deadline = Date().addingTimeInterval(Double(Sample.all.count * 48 + 30))
            while playback.autoRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(250))
                if let error = playback.error { throw ProbeFailure(message: error) }
                guard playback.playing, !playback.loading, let excerpt = playback.autoExcerpt,
                      playback.position >= excerpt.start.seconds + 1,
                      steps.last?.step != playback.autoIndex + 1 else { continue }
                let index = playback.autoIndex
                guard index == steps.count,
                      playback.sample == Sample.all[index / 2],
                      playback.version == (index.isMultiple(of: 2) ? .apac : .ddp),
                      let item = playback.player.currentItem,
                      abs(item.forwardPlaybackEndTime.seconds - excerpt.end.seconds) < 0.0001,
                      playback.carrierRate == (playback.version == .apac ? 1 : 0) else {
                    throw ProbeFailure(message: "Unexpected sequence, endpoint or carrier at step \(index + 1).")
                }
                steps.append(AutoStep(step: index + 1, sample: playback.sample.id,
                                      version: playback.version.suffix, start: excerpt.start.seconds,
                                      end: excerpt.end.seconds, position: playback.position,
                                      carrierRate: playback.carrierRate))
                try JSONEncoder().encode(steps).write(to: output, options: .atomic)
                print("AUTO PROBE OBSERVED step=\(index + 1) carrier=\(playback.carrierRate)")
                if index == 0 {
                    playback.pause()
                    let pausedTime = playback.player.currentTime().seconds
                    try await Task.sleep(for: .seconds(1))
                    guard playback.autoRunning, playback.autoIndex == 0, playback.player.rate == 0,
                          playback.carrierRate == 0, abs(playback.player.currentTime().seconds - pausedTime) < 0.01 else {
                        throw ProbeFailure(message: "Pause advanced the excerpt or left the carrier running.")
                    }
                    playback.toggle()
                    print("AUTO PROBE PAUSE/RESUME PASS")
                }
            }
            guard playback.autoCompleted, steps.count == Sample.all.count * 2, !playback.playing, playback.carrierRate == 0 else {
                throw ProbeFailure(message: "Auto did not complete every excerpt and stop playback.")
            }
            for index in stride(from: 0, to: steps.count, by: 2) {
                guard steps[index].start == steps[index + 1].start,
                      steps[index].end == steps[index + 1].end,
                      abs(steps[index].end - steps[index].start - 20) < 0.0001 else {
                    throw ProbeFailure(message: "The paired excerpts differ.")
                }
            }
            // Stop while preparing, then while playing; neither may advance or resume later.
            playback.startAuto()
            playback.stopAuto()
            try await Task.sleep(for: .seconds(1))
            guard !playback.autoRunning, !playback.loading, playback.player.rate == 0, playback.carrierRate == 0 else {
                throw ProbeFailure(message: "Stopping preparation did not cancel playback.")
            }
            playback.startAuto()
            for _ in 0..<100 {
                if playback.playing, !playback.loading, playback.position >= (playback.autoExcerpt?.start.seconds ?? .infinity) + 1 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard playback.playing else { throw ProbeFailure(message: "Cancellation check did not start playback.") }
            playback.stopAuto()
            let stoppedItem = playback.player.currentItem
            try await Task.sleep(for: .seconds(2))
            guard !playback.autoRunning, !playback.loading, playback.player.rate == 0, playback.carrierRate == 0,
                  playback.player.currentItem === stoppedItem else {
                throw ProbeFailure(message: "Stopping Auto did not cancel playback and advancement.")
            }
            playback.seek(playback.duration - 1)
            try await Task.sleep(for: .milliseconds(500))
            playback.toggle()
            for _ in 0..<50 {
                if playback.player.rate > 0 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard playback.player.rate > 0 else { throw ProbeFailure(message: "Manual playback did not resume after Stop Auto.") }
            try await Task.sleep(for: .seconds(2))
            guard playback.player.rate == 0, playback.carrierRate == 0 else {
                throw ProbeFailure(message: "Manual playback after Stop Auto did not stop the carrier at the track end.")
            }
            print("AUTO PROBE PASS: \(steps.count) matched 20-second excerpts; pause/resume; carrier lifecycle; preparation and playback cancellation; manual playback after Stop. \(output.path)")
        } catch {
            playback.stopAuto()
            print("AUTO PROBE FAIL: \(error.localizedDescription)")
        }
    }

    static func run(playback: Playback) async {
        var reports: [[String: Any]] = []
        let output = URL.cachesDirectory.appendingPathComponent("route-probe.json")
        let cases: [(Sample, Version)] = ProcessInfo.processInfo.arguments.contains("--all-pairs")
            ? Sample.all.flatMap { sample in Version.allCases.map { (sample, $0) } }
            : [(Sample.all[0], .apac), (Sample.all[0], .ddp), (Sample.all[0], .apac)]
        do {
            for (sample, version) in cases {
                playback.load(sample: sample, version: version, resume: true)
                for _ in 0..<100 {
                    if !playback.loading { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                playback.seek(30)
                var states: [[String: Any]] = []
                for second in 1...5 {
                    try await Task.sleep(for: .seconds(1))
                    let state: [String: Any] = [
                        "second": second,
                        "sample": playback.sample.id,
                        "version": playback.version.suffix,
                        "position": playback.position,
                        "playing": playback.playing,
                        "loading": playback.loading,
                        "status": playback.trackStatus,
                        "error": playback.error ?? "",
                        "outputChannels": playback.outputChannels,
                        "maximumChannels": AVAudioSession.sharedInstance().maximumOutputNumberOfChannels,
                        "carrierRate": playback.carrierRate
                    ]
                    states.append(state)
                    print("ROUTE \(sample.id) \(version.suffix) second=\(second) channels=\(playback.outputChannels) carrier=\(playback.carrierRate) position=\(playback.position) status=\(playback.trackStatus) error=\(playback.error ?? "")")
                }
                reports.append(["sample": sample.id, "version": version.suffix, "states": states])
                try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            }
            playback.pause()
            print("ROUTE PROBE COMPLETE \(output.path)")
        } catch {
            playback.pause()
            print("ROUTE ERROR \(error)")
        }
    }
}
