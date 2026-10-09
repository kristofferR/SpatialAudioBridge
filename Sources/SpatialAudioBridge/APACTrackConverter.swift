import Foundation

public enum APACTrackConverter {
    /// Convenience conversion for a demuxed .thd or .dts elementary stream.
    public static func convert(elementaryStream input: URL, codec: SpatialAudioCodec,
                               output: URL, configuration: APACConfiguration = .init()) async throws -> APACConversionReport {
        let transcoder = try SpatialAudioTranscoder(codec: codec, destination: .file(output), configuration: configuration)
        let file = try FileHandle(forReadingFrom: input)
        defer { try? file.close() }
        do {
            while let data = try file.read(upToCount: 64 * 1024), !data.isEmpty {
                try await transcoder.append(data)
            }
            return try await transcoder.finish()
        } catch {
            await transcoder.cancel()
            throw error
        }
    }
}
