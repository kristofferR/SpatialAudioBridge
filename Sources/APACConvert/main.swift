import SpatialAudioBridge
import Foundation
import AVFoundation

@main struct APACConvert {
    static let usage = """
    usage: apac-convert <truehd|dtsx> <demuxed-input.thd|dts> <output.mp4>
           apac-convert mkv <input.mkv|https://…> <output.mp4> [--track N] [--start seconds] [--duration seconds]

    For HTTP sources, set SAB_HTTP_HEADER to a header such as "Authorization: …".
    """

    static func main() async {
        do { try await convert() }
        catch {
            FileHandle.standardError.write(Data("apac-convert: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func convert() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else { print(usage); return }
        let start = Date()
        let output = URL(fileURLWithPath: args[2])
        let report: APACConversionReport
        if args[0] == "mkv" {
            report = try await convertMatroska(input: args[1], output: output, options: Array(args.dropFirst(3)))
        } else if let codec = ["truehd": SpatialAudioCodec.trueHDAtmos, "dtsx": .dtsX][args[0]], args.count == 3 {
            report = try await APACTrackConverter.convert(elementaryStream: URL(fileURLWithPath: args[1]), codec: codec, output: output)
        } else {
            print(usage)
            return
        }
        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let descriptions = try await audio.first?.load(.formatDescriptions) ?? []
        let formats = descriptions.map { String(format: "%08x", CMFormatDescriptionGetMediaSubType($0)) }.joined(separator: ",")
        print("APAC \(report.layout.channelCount) channels, \(report.sampleRate) Hz, \(report.sampleFrames) frames, \(report.duration)s; peak=\(report.peakPCM); elapsed=\(Date().timeIntervalSince(start))s; codec=\(formats)")
    }

    /// Converts one Matroska audio track, optionally from a start time, reporting seek cost.
    private static func convertMatroska(input: String, output: URL, options: [String]) async throws -> APACConversionReport {
        func option(_ name: String) -> Double? {
            options.firstIndex(of: name).flatMap { options.indices.contains($0 + 1) ? Double(options[$0 + 1]) : nil }
        }
        var headers: [String: String] = [:]
        if let header = ProcessInfo.processInfo.environment["SAB_HTTP_HEADER"], let colon = header.firstIndex(of: ":") {
            headers[String(header[..<colon])] = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let base: any MediaByteSource
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            guard let url = URL(string: input) else { throw SpatialAudioError.source("Malformed URL: \(input)") }
            base = HTTPByteSource(url: url, headers: headers)
        } else {
            base = FileByteSource(url: URL(fileURLWithPath: input))
        }
        let source = CountingSource(base: base)
        let opened = Date()
        let file = try await MatroskaFile.open(source)
        for track in file.audioTracks {
            print("track \(track.number): \(track.codecID) \(track.channels)ch \(track.language ?? "-") \(track.name ?? "")\(track.isDefault ? " default" : "")")
        }
        let track = try option("--track").map { number in
            guard number >= 1, number.rounded() == number, number <= Double(UInt64.max),
                  let track = file.audioTracks.first(where: { $0.number == UInt64(number) }) else {
                throw SpatialAudioError.source("No audio track \(number)")
            }
            return track
        } ?? file.audioTracks.first { $0.codec != nil && $0.isDefault } ?? file.audioTracks.first { $0.codec != nil }
        guard let track, let codec = track.codec else { throw SpatialAudioError.source("No TrueHD or DTS track") }
        print("opened in \(String(format: "%.2f", Date().timeIntervalSince(opened)))s, \(source.bytes / 1024) KiB read")
        let target = CMTime(seconds: option("--start") ?? 0, preferredTimescale: 48000)
        let end = option("--duration").map { target.seconds + $0 }
        var transcoder: SpatialAudioTranscoder?
        let seekStarted = Date(), seekBytes = source.bytes
        for try await packet in file.packets(of: track, from: target) {
            if let end, packet.time.seconds >= end { break }
            if transcoder == nil {
                print("first packet at \(String(format: "%.3f", packet.time.seconds))s (sync \(packet.isSyncPoint)) after \(String(format: "%.2f", Date().timeIntervalSince(seekStarted)))s, \((source.bytes - seekBytes) / 1024) KiB read")
                // Decoding starts at the sync point; output starts exactly at the requested time.
                var configuration = APACConfiguration(startTime: target)
                configuration.inputStartTime = packet.time
                transcoder = try SpatialAudioTranscoder(codec: codec, destination: .file(output),
                                                        configuration: configuration)
            }
            try await transcoder!.append(packet.data)
        }
        guard let transcoder else { throw SpatialAudioError.source("The track has no audio after the start time") }
        let report = try await transcoder.finish()
        print("read \(source.bytes / 1_048_576) MiB in total")
        return report
    }
}

/// Counts the bytes a source transfers.
private final class CountingSource: MediaByteSource, @unchecked Sendable {
    let base: any MediaByteSource
    private let lock = NSLock()
    private var total: Int64 = 0
    var bytes: Int64 { lock.withLock { total } }

    init(base: any MediaByteSource) { self.base = base }

    func length() async throws -> Int64 { try await base.length() }

    func read(_ range: Range<Int64>) async throws -> Data {
        let data = try await base.read(range)
        lock.withLock { total += Int64(data.count) }
        return data
    }
}
