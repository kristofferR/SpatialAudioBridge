import CoreMedia
import Foundation

/// An audio track in a Matroska file.
public struct MatroskaAudioTrack: Sendable, Hashable {
    /// The Matroska track number.
    public let number: UInt64
    /// The Matroska codec identifier, such as `A_TRUEHD`.
    public let codecID: String
    public let channels: Int
    public let sampleRate: Double
    /// BCP 47 language tag, when the file declares one.
    public let language: String?
    public let name: String?
    public let isDefault: Bool
    /// Bytes the muxer removed from the start of every frame (header-stripping compression).
    let strippedHeader: Data
    let unsupportedEncoding: String?

    /// The codec this library converts, or nil for other tracks. Whether a TrueHD track carries
    /// Atmos, or a DTS track DTS:X, is only known once decoding starts.
    public var codec: SpatialAudioCodec? {
        switch codecID {
        case "A_TRUEHD": .trueHDAtmos
        case "A_DTS": .dtsX
        default: nil
        }
    }
}

/// One compressed audio frame and its container presentation time.
public struct MatroskaPacket: Sendable {
    public let data: Data
    public let time: CMTime
    /// Whether decoding can start here: a TrueHD major sync or a DTS core sync.
    public let isSyncPoint: Bool
}

/// Reads audio tracks from a Matroska (MKV/MKA) file, seeking with its cues.
///
/// Only the selected track's frames are returned. Clusters are read in order, so a remote file's
/// video bytes are transferred as well; on a local network this costs about the file's bitrate.
public struct MatroskaFile: Sendable {
    public let audioTracks: [MatroskaAudioTrack]
    public let duration: CMTime?
    let source: any MediaByteSource
    let length: Int64
    let timestampScale: Int64
    let firstCluster: Int64
    let cues: [Cue]

    struct Cue: Sendable {
        let time: Int64
        let cluster: Int64
    }

    public static func open(_ source: any MediaByteSource) async throws -> MatroskaFile {
        let length = try await source.length()
        let window = ByteWindow(source: source, length: length, chunk: 256 * 1024)
        guard try await window.elementID() == EBML.header else { throw SpatialAudioError.source("Not a Matroska file") }
        let header = EBMLData(try await window.read(Int(try await window.elementSize() ?? 0)))
        let docType = header.child(EBML.docType)?.string ?? "matroska"
        guard docType == "matroska" || docType == "webm" else { throw SpatialAudioError.source("Unsupported document type \(docType)") }
        guard try await window.elementID() == EBML.segment else { throw SpatialAudioError.source("Matroska file has no segment") }
        let segmentSize = try await window.elementSize()
        let segmentStart = window.position
        let segmentEnd = segmentSize.map { segmentStart + Int64($0) } ?? length
        var scale: Int64 = 1_000_000, duration: Double?
        var tracks: [MatroskaAudioTrack] = []
        var cues: [Cue] = []
        var cuesPosition: Int64?
        var firstCluster: Int64?
        // Read the metadata before the first cluster; cues are usually at the end, found through the seek head.
        while window.position < segmentEnd, firstCluster == nil {
            let start = window.position
            guard let id = try await window.elementID() else { break }
            let size = try await window.elementSize()
            switch id {
            case EBML.cluster:
                firstCluster = start
            case EBML.info, EBML.tracks, EBML.seekHead, EBML.cues:
                guard let size else { throw SpatialAudioError.source("Matroska metadata has an unknown size") }
                let body = EBMLData(try await window.read(Int(size)))
                switch id {
                case EBML.info:
                    scale = Int64(body.child(EBML.timestampScale)?.uint ?? 1_000_000)
                    duration = body.child(EBML.duration)?.float
                case EBML.tracks:
                    tracks = body.children(EBML.trackEntry).compactMap(Self.audioTrack)
                case EBML.seekHead:
                    for seek in body.children(EBML.seek) where seek.child(EBML.seekID)?.uint == EBML.cues {
                        cuesPosition = seek.child(EBML.seekPosition).map { segmentStart + Int64($0.uint) }
                    }
                default:
                    cues = Self.cues(body, segmentStart: segmentStart)
                }
            default:
                guard let size else { throw SpatialAudioError.source("Unexpected Matroska element of unknown size") }
                try await window.skip(Int64(size))
            }
        }
        guard let firstCluster else { throw SpatialAudioError.source("Matroska file has no clusters") }
        if cues.isEmpty, let cuesPosition, cuesPosition < length {
            window.seek(to: cuesPosition)
            if try await window.elementID() == EBML.cues, let size = try await window.elementSize() {
                cues = Self.cues(EBMLData(try await window.read(Int(size))), segmentStart: segmentStart)
            }
        }
        return MatroskaFile(audioTracks: tracks,
                            duration: duration.map { CMTime(seconds: $0 * Double(scale) / 1e9, preferredTimescale: 1_000_000_000) },
                            source: source, length: length, timestampScale: scale,
                            firstCluster: firstCluster, cues: cues.sorted { $0.time < $1.time })
    }

    /// Frames of `track` starting at the last sync point at or before `time`, so decoding can begin
    /// there. Discard decoded audio before `time` to start exactly at it.
    public func packets(of track: MatroskaAudioTrack, from time: CMTime = .zero) -> MatroskaPackets {
        MatroskaPackets(file: self, track: track, target: time)
    }

    private static func audioTrack(_ entry: EBMLData) -> MatroskaAudioTrack? {
        guard entry.child(EBML.trackType)?.uint == 2, let number = entry.child(EBML.trackNumber)?.uint else { return nil }
        let audio = entry.child(EBML.audio)
        var stripped = Data(), unsupported: String?
        for encoding in entry.child(EBML.contentEncodings)?.children(EBML.contentEncoding) ?? [] {
            if encoding.child(EBML.contentEncryption) != nil {
                unsupported = "encrypted"
            } else if let compression = encoding.child(EBML.contentCompression) {
                if compression.child(EBML.contentCompAlgo)?.uint ?? 0 == 3 {
                    stripped = compression.child(EBML.contentCompSettings)?.bytes ?? Data()
                } else {
                    unsupported = "compressed"
                }
            }
        }
        return MatroskaAudioTrack(number: number, codecID: entry.child(EBML.codecID)?.string ?? "",
                                  channels: Int(audio?.child(EBML.channels)?.uint ?? 1),
                                  sampleRate: audio?.child(EBML.samplingFrequency)?.float ?? 8000,
                                  language: entry.child(EBML.languageBCP47)?.string ?? entry.child(EBML.language)?.string,
                                  name: entry.child(EBML.name)?.string,
                                  isDefault: entry.child(EBML.flagDefault)?.uint ?? 1 == 1,
                                  strippedHeader: stripped, unsupportedEncoding: unsupported)
    }

    private static func cues(_ body: EBMLData, segmentStart: Int64) -> [Cue] {
        body.children(EBML.cuePoint).compactMap { point in
            guard let time = point.child(EBML.cueTime)?.uint,
                  let position = point.child(EBML.cueTrackPositions)?.child(EBML.cueClusterPosition)?.uint else { return nil }
            return Cue(time: Int64(time), cluster: segmentStart + Int64(position))
        }
    }
}

/// The packets of one track, from a seek target. Iterate once.
public struct MatroskaPackets: AsyncSequence, Sendable {
    public typealias Element = MatroskaPacket
    let file: MatroskaFile
    let track: MatroskaAudioTrack
    let target: CMTime

    public func makeAsyncIterator() -> Iterator {
        Iterator(state: PacketReader(file: file, track: track, target: target))
    }

    public struct Iterator: AsyncIteratorProtocol {
        let state: PacketReader
        public mutating func next() async throws -> MatroskaPacket? { try await state.next() }
    }
}

/// Seeks to a cue before the target, then walks clusters and blocks, returning the track's frames
/// from the last sync point at or before the target.
final class PacketReader {
    private let file: MatroskaFile
    private let track: MatroskaAudioTrack
    private let target: Int64
    private let window: ByteWindow
    private var started = false
    private var seeking = true
    private var held: [MatroskaPacket] = []
    private var ready: [MatroskaPacket] = []
    private var clusterTime: Int64 = 0
    private var clusterEnd: Int64?

    init(file: MatroskaFile, track: MatroskaAudioTrack, target: CMTime) {
        self.file = file
        self.track = track
        self.target = Int64((max(target.seconds, 0) * 1e9 / Double(file.timestampScale)).rounded(.down))
        window = ByteWindow(source: file.source, length: file.length, chunk: 2 * 1024 * 1024)
    }

    func next() async throws -> MatroskaPacket? {
        if !started {
            started = true
            if let unsupported = track.unsupportedEncoding {
                throw SpatialAudioError.source("Matroska track \(track.number) is \(unsupported)")
            }
            // Audio is interleaved near, not exactly at, video keyframes; start two seconds early.
            let margin = Int64(2e9 / Double(file.timestampScale))
            let cue = file.cues.last { $0.time <= target - margin }
            window.seek(to: cue?.cluster ?? file.firstCluster)
        }
        while ready.isEmpty {
            guard let packets = try await nextBlock() else {
                // At the end, start from whatever sync point was found.
                ready = seeking ? held : []
                seeking = false
                held = []
                return ready.isEmpty ? nil : ready.removeFirst()
            }
            for packet in packets { accept(packet) }
        }
        return ready.removeFirst()
    }

    private func accept(_ packet: MatroskaPacket) {
        guard seeking else { ready.append(packet); return }
        let ticks = Int64((packet.time.seconds * 1e9 / Double(file.timestampScale)).rounded())
        if ticks <= target {
            if packet.isSyncPoint { held = [packet] } else if !held.isEmpty { held.append(packet) }
        } else if !held.isEmpty || packet.isSyncPoint {
            // The target lies before this packet; begin at the last sync at or before it,
            // or here when the stream starts after the target.
            ready = held.isEmpty ? [packet] : held + [packet]
            held = []
            seeking = false
        }
    }

    /// The track's frames in the next block, or nil at the end of the file.
    private func nextBlock() async throws -> [MatroskaPacket]? {
        while true {
            if let end = clusterEnd, window.position >= end { clusterEnd = nil }
            guard window.position < file.length, let id = try await window.elementID() else { return nil }
            let size = try await window.elementSize()
            switch id {
            case EBML.cluster:
                clusterEnd = size.map { window.position + Int64($0) }
                clusterTime = 0
            case EBML.timestamp:
                clusterTime = Int64(EBMLData.uint(try await window.read(Int(size ?? 0))))
            case EBML.blockGroup:
                // Descend into the group; its Block is handled below and other children skipped.
                continue
            case EBML.simpleBlock, EBML.block:
                guard let size else { throw SpatialAudioError.source("Matroska block has an unknown size") }
                if let packets = try await block(size: Int64(size)) { return packets }
            default:
                guard let size else {
                    if EBML.topLevel.contains(id) { continue }
                    throw SpatialAudioError.source("Unexpected Matroska element of unknown size")
                }
                try await window.skip(Int64(size))
            }
        }
    }

    private func block(size: Int64) async throws -> [MatroskaPacket]? {
        let start = window.position
        guard let number = try await window.vint() else { throw SpatialAudioError.source("Malformed Matroska block") }
        let headerLength = window.position - start
        guard number == track.number else {
            try await window.skip(size - headerLength)
            return nil
        }
        let body = try await window.read(Int(size - headerLength))
        guard body.count >= 3 else { throw SpatialAudioError.source("Truncated Matroska block") }
        let relative = Int64(Int16(bitPattern: UInt16(body[body.startIndex]) << 8 | UInt16(body[body.startIndex + 1])))
        let flags = body[body.startIndex + 2]
        let frames = try Self.frames(body.dropFirst(3), lacing: (flags >> 1) & 3)
        let nanoseconds = (clusterTime + relative) * file.timestampScale
        let time = CMTime(value: nanoseconds, timescale: 1_000_000_000)
        return frames.map { frame in
            let data = track.strippedHeader + frame
            return MatroskaPacket(data: data, time: time, isSyncPoint: Self.isSyncPoint(data, codec: track.codec))
        }
    }

    static func isSyncPoint(_ data: Data, codec: SpatialAudioCodec?) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        switch codec {
        case .trueHDAtmos: return bytes.count == 8 && bytes[4...7] == [0xF8, 0x72, 0x6F, 0xBA]
        case .dtsX: return bytes.starts(with: [0x7F, 0xFE, 0x80, 0x01])
        case nil: return true
        }
    }

    /// Splits a block body into frames for no (0), Xiph (1), fixed-size (2) or EBML (3) lacing.
    static func frames(_ payload: Data, lacing: UInt8) throws -> [Data] {
        guard lacing != 0 else { return [Data(payload)] }
        var data = Data(payload), index = 1
        guard let first = data.first else { throw SpatialAudioError.source("Truncated Matroska lacing") }
        let count = Int(first) + 1
        var sizes: [Int] = []
        switch lacing {
        case 1:
            for _ in 1..<count {
                var size = 0
                while true {
                    guard index < data.count else { throw SpatialAudioError.source("Truncated Matroska lacing") }
                    let byte = Int(data[index]); index += 1
                    size += byte
                    if byte < 255 { break }
                }
                sizes.append(size)
            }
        case 3:
            guard count > 1 else { break }
            var previous = 0
            for frame in 1..<count {
                guard let (value, length) = EBMLData.vint(data, at: index) else { throw SpatialAudioError.source("Truncated Matroska lacing") }
                index += length
                // Later sizes are signed differences, biased by half the VINT range.
                previous = frame == 1 ? Int(value) : previous + Int(value) - ((1 << (7 * length - 1)) - 1)
                sizes.append(previous)
            }
        default:
            let each = (data.count - index) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        let laced = sizes.reduce(0, +)
        guard laced <= data.count - index else { throw SpatialAudioError.source("Malformed Matroska lacing") }
        sizes.append(data.count - index - laced)
        data = data.dropFirst(index)
        var frames: [Data] = [], offset = data.startIndex
        for size in sizes {
            frames.append(data[offset..<offset + size])
            offset += size
        }
        return frames
    }
}

/// A sequential read position over a ``MediaByteSource``, fetching it in chunks and skipping
/// unread bytes without transferring them when they extend past the buffer.
final class ByteWindow {
    private let source: any MediaByteSource
    private let length: Int64
    private let chunk: Int
    private var buffer = Data()
    private var bufferStart: Int64 = 0
    private(set) var position: Int64 = 0

    init(source: any MediaByteSource, length: Int64, chunk: Int) {
        self.source = source
        self.length = length
        self.chunk = chunk
    }

    func seek(to offset: Int64) {
        position = offset
        if offset < bufferStart || offset > bufferStart + Int64(buffer.count) {
            buffer = Data()
            bufferStart = offset
        }
    }

    func skip(_ count: Int64) async throws { seek(to: position + count) }

    /// Reads `count` bytes, failing at the end of the file.
    func read(_ count: Int) async throws -> Data {
        guard try await fill(count) else { throw SpatialAudioError.source("Unexpected end of Matroska file") }
        let start = buffer.startIndex + Int(position - bufferStart)
        position += Int64(count)
        return Data(buffer[start..<start + count])
    }

    /// An element ID, keeping its length marker, or nil at the end of the file.
    func elementID() async throws -> UInt64? {
        guard try await fill(1) else { return nil }
        let length = EBMLData.vintLength(buffer[buffer.startIndex + Int(position - bufferStart)])
        guard length <= 4 else { throw SpatialAudioError.source("Malformed Matroska element ID") }
        return EBMLData.uint(try await read(length))
    }

    /// An element size, or nil for an unknown size.
    func elementSize() async throws -> UInt64? {
        guard try await fill(1) else { throw SpatialAudioError.source("Unexpected end of Matroska file") }
        let length = EBMLData.vintLength(buffer[buffer.startIndex + Int(position - bufferStart)])
        guard length <= 8 else { throw SpatialAudioError.source("Malformed Matroska element size") }
        let bytes = try await read(length)
        guard let (value, _) = EBMLData.vint(bytes, at: 0) else { throw SpatialAudioError.source("Malformed Matroska element size") }
        return value == (1 << (7 * UInt64(length))) - 1 ? nil : value
    }

    /// A size-style VINT, such as a block's track number.
    func vint() async throws -> UInt64? {
        guard try await fill(1) else { return nil }
        let length = EBMLData.vintLength(buffer[buffer.startIndex + Int(position - bufferStart)])
        return EBMLData.vint(try await read(length), at: 0)?.value
    }

    /// Whether `count` bytes are available at the position, fetching more as needed.
    private func fill(_ count: Int) async throws -> Bool {
        let available = bufferStart + Int64(buffer.count) - position
        if available >= Int64(count) { return true }
        if position + Int64(count) > length { return false }
        // Keep the unread tail and append the next chunk.
        let keep = buffer.suffix(Int(max(available, 0)))
        let fetchStart = position + max(available, 0)
        let fetchEnd = min(length, fetchStart + Int64(max(chunk, count)))
        let data = try await source.read(fetchStart..<fetchEnd)
        buffer = keep + data
        bufferStart = position
        return Int64(buffer.count) >= Int64(count)
    }
}

/// A parsed EBML master element's children.
struct EBMLData {
    private let data: Data

    init(_ data: Data) { self.data = data }

    var uint: UInt64 { Self.uint(data) }
    var string: String { String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
    var bytes: Data { data }
    var float: Double? {
        switch data.count {
        case 4: Double(Float(bitPattern: UInt32(truncatingIfNeeded: uint)))
        case 8: Double(bitPattern: uint)
        default: nil
        }
    }

    func child(_ id: UInt64) -> EBMLData? { children(id).first }

    func children(_ id: UInt64) -> [EBMLData] {
        var result: [EBMLData] = [], index = 0
        while index < data.count {
            let idLength = Self.vintLength(data[data.startIndex + index])
            guard idLength <= 4, index + idLength <= data.count else { break }
            let elementID = Self.uint(data[data.startIndex + index..<data.startIndex + index + idLength])
            index += idLength
            guard let (size, sizeLength) = Self.vint(data, at: index) else { break }
            index += sizeLength
            let end = min(data.count, index + Int(clamping: size))
            if elementID == id { result.append(EBMLData(data[data.startIndex + index..<data.startIndex + end])) }
            index = end
        }
        return result
    }

    static func vintLength(_ first: UInt8) -> Int { first.leadingZeroBitCount + 1 }

    /// A size-style VINT at `index` and its length, with the length marker removed.
    static func vint(_ data: Data, at index: Int) -> (value: UInt64, length: Int)? {
        guard index < data.count else { return nil }
        let first = data[data.startIndex + index]
        let length = vintLength(first)
        guard length <= 8, index + length <= data.count else { return nil }
        var value = UInt64(first) & ((1 << (8 - UInt64(length))) - 1)
        for offset in 1..<length { value = value << 8 | UInt64(data[data.startIndex + index + offset]) }
        return (value, length)
    }

    static func uint<D: DataProtocol>(_ bytes: D) -> UInt64 { bytes.reduce(0) { $0 << 8 | UInt64($1) } }
}

enum EBML {
    static let header: UInt64 = 0x1A45DFA3, docType: UInt64 = 0x4282
    static let segment: UInt64 = 0x18538067, seekHead: UInt64 = 0x114D9B74, info: UInt64 = 0x1549A966
    static let tracks: UInt64 = 0x1654AE6B, cues: UInt64 = 0x1C53BB6B, cluster: UInt64 = 0x1F43B675
    static let topLevel: Set<UInt64> = [segment, seekHead, info, tracks, cues, cluster,
                                        0x1043A770, 0x1254C367, 0x1941A469] // chapters, tags, attachments
    static let seek: UInt64 = 0x4DBB, seekID: UInt64 = 0x53AB, seekPosition: UInt64 = 0x53AC
    static let timestampScale: UInt64 = 0x2AD7B1, duration: UInt64 = 0x4489
    static let trackEntry: UInt64 = 0xAE, trackNumber: UInt64 = 0xD7, trackType: UInt64 = 0x83
    static let codecID: UInt64 = 0x86, name: UInt64 = 0x536E, language: UInt64 = 0x22B59C
    static let languageBCP47: UInt64 = 0x22B59D, flagDefault: UInt64 = 0x88
    static let audio: UInt64 = 0xE1, samplingFrequency: UInt64 = 0xB5, channels: UInt64 = 0x9F
    static let contentEncodings: UInt64 = 0x6D80, contentEncoding: UInt64 = 0x6240
    static let contentCompression: UInt64 = 0x5034, contentCompAlgo: UInt64 = 0x4254
    static let contentCompSettings: UInt64 = 0x4255, contentEncryption: UInt64 = 0x5035
    static let cuePoint: UInt64 = 0xBB, cueTime: UInt64 = 0xB3, cueTrackPositions: UInt64 = 0xB7
    static let cueClusterPosition: UInt64 = 0xF1
    static let timestamp: UInt64 = 0xE7, simpleBlock: UInt64 = 0xA3, blockGroup: UInt64 = 0xA0, block: UInt64 = 0xA1
}
