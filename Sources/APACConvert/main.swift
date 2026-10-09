import SpatialAudioBridge
import Foundation
import AVFoundation

@main struct APACConvert {
    static func main() async {
        do { try await convert() }
        catch {
            FileHandle.standardError.write(Data("apac-convert: \(error)\n".utf8))
            exit(1)
        }
    }
    private static func convert() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let codec = ["truehd": SpatialAudioCodec.trueHDAtmos, "dtsx": .dtsX][args[0]] else {
            print("usage: apac-convert <truehd|dtsx> <demuxed-input.thd|dts> <output.mp4>")
            return
        }
        let start = Date()
        let output = URL(fileURLWithPath: args[2])
        let report = try await APACTrackConverter.convert(elementaryStream: URL(fileURLWithPath: args[1]), codec: codec, output: output)
        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let descriptions = try await audio.first?.load(.formatDescriptions) ?? []
        let formats = descriptions.map { String(format: "%08x", CMFormatDescriptionGetMediaSubType($0)) }.joined(separator: ",")
        print("APAC \(report.layout.channelCount) channels, \(report.sampleRate) Hz, \(report.sampleFrames) frames, \(report.duration)s; peak=\(report.peakPCM); elapsed=\(Date().timeIntervalSince(start))s; codec=\(formats)")
    }
}
