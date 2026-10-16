import CoreMedia
import Foundation

/// Whether a track renders, as found by decoding its start.
@available(macOS 26, iOS 26, tvOS 26, *)
public enum SpatialAudioTrackSupport: Sendable, Equatable {
    /// The decoder produced spatial audio: TrueHD with Atmos objects, or DTS:X.
    case renderable
    /// The track will never render, such as TrueHD without Atmos or DTS-HD MA without DTS:X.
    case unsupported(String)
    /// The audio ended before the decoder could tell; probe more of it.
    case undetermined
}

@available(macOS 26, iOS 26, tvOS 26, *)
extension SpatialAudioCodec {
    /// Whether decoding can start with `packet`: a TrueHD major sync or a DTS core sync.
    public func isSyncPoint(_ packet: Data) -> Bool {
        let bytes = [UInt8](packet.prefix(8))
        switch self {
        case .trueHDAtmos: return bytes.count == 8 && bytes[4...7] == [0xF8, 0x72, 0x6F, 0xBA]
        case .dtsX: return bytes.starts(with: [0x7F, 0xFE, 0x80, 0x01])
        }
    }

    /// Decodes the start of a track to tell whether it renders, without encoding, so a host can
    /// choose its usual audio path before playback starts. Pass compressed audio from a sync point;
    /// a second of it always decides. Damaged input throws `SpatialAudioError.decoding`.
    public func probe(_ data: Data) throws -> SpatialAudioTrackSupport {
        let decoder = try Decoder(codec: self, layout: .sevenOneFour)
        var rendered = false
        do {
            // All of it: DTS entered between lossless sync points first yields silence unchecked.
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = min(4096, bytes.count - offset)
                    let blocks = try decoder.decode(UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + count]), end: false)
                    rendered = rendered || !blocks.isEmpty
                    offset += count
                }
            }
        } catch SpatialAudioError.unsupported(let reason) {
            return .unsupported(reason)
        }
        return rendered ? .renderable : .undetermined
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
extension MatroskaFile {
    /// Decodes `duration` of `track` from the sync point at or before `time` to tell whether it
    /// renders, without encoding; see ``SpatialAudioCodec/probe(_:)``.
    public func probe(_ track: MatroskaAudioTrack, from time: CMTime = .zero,
                      duration: CMTime = CMTime(value: 1, timescale: 1)) async throws -> SpatialAudioTrackSupport {
        guard let codec = track.codec else {
            return .unsupported("Matroska track \(track.number) is \(track.codecID), not TrueHD or DTS")
        }
        var data = Data(), first: CMTime?
        do {
            for try await packet in packets(of: track, from: time) {
                let start = first ?? packet.time
                first = start
                if CMTimeSubtract(packet.time, start) >= duration { break }
                data += packet.data
            }
        } catch SpatialAudioError.unsupported(let reason) {
            return .unsupported(reason)
        }
        return try codec.probe(data)
    }
}
