import Foundation
import SpatialAudioCore

@available(macOS 26, iOS 26, tvOS 26, *)
struct PCMBlock: Sendable {
    let samples: [Float]
    let frames: Int
    let sampleRate: Int
    let channels: Int
}

@available(macOS 26, iOS 26, tvOS 26, *)
private final class PCMCollector {
    var blocks: [PCMBlock] = []
}

/// Owned and serialized by SpatialAudioTranscoder. The C callback never escapes decode().
@available(macOS 26, iOS 26, tvOS 26, *)
final class Decoder: @unchecked Sendable {
    private let handle: OpaquePointer
    init(codec: SpatialAudioCodec, layout: SpatialAudioLayout, normalizesDialogue: Bool = false) throws {
        guard let handle = sab_create(codec.rawValue, layout.rawValue) else {
            throw SpatialAudioError.decoding("Could not create the spatial audio decoder")
        }
        sab_set_dialogue_normalisation(handle, normalizesDialogue ? 1 : 0)
        self.handle = handle
    }
    deinit { sab_destroy(handle) }

    func decode(_ bytes: UnsafeRawBufferPointer, end: Bool) throws -> [PCMBlock] {
        let collector = PCMCollector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let result = sab_push(handle, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, end ? 1 : 0, { context, pcm, frames, rate, channels in
            guard let context, let pcm else { return -1 }
            let collector = Unmanaged<PCMCollector>.fromOpaque(context).takeUnretainedValue()
            collector.blocks.append(PCMBlock(
                samples: Array(UnsafeBufferPointer(start: pcm, count: Int(frames) * Int(channels))),
                frames: Int(frames), sampleRate: Int(rate), channels: Int(channels)))
            return 0
        }, context)
        guard result == 0 else {
            var bytes = [CChar](repeating: 0, count: sab_error(handle, nil, 0))
            _ = sab_error(handle, &bytes, bytes.count)
            throw SpatialAudioError.decoding(String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return collector.blocks
    }
}
