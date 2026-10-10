// Writes the silent Dolby Digital Plus Atmos stream that SpatialAudioPlayback bundles for AtmosOutputActivator.
//
//   swift scripts/make-silent-atmos.swift silent-atmos.ec3
//   ffmpeg -i silent-atmos.ec3 -c copy -fflags +bitexact -map_metadata -1 Sources/SpatialAudioPlayback/Resources/silent-atmos.mp4
//
// Every bit is written here from ETSI TS 102 366 (E-AC-3) and TS 103 420 (object audio); no encoder
// output or programme audio is involved. The 5.1 core codes no mantissas and turns dither off, so it
// decodes to digital silence. The frame header carries the Atmos extension flag, from which FFmpeg's
// MP4 muxer writes the dec3 extension that Apple reads as 'ec+3'. There is no object metadata: tvOS
// ignores it unless Dolby's keyed EMDF protection is valid (docs/atmos-output.md).
import Foundation

struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private(set) var count = 0

    mutating func write(_ value: Int, _ bits: Int) {
        precondition(value >> bits == 0, "\(value) does not fit in \(bits) bits")
        for shift in stride(from: bits - 1, through: 0, by: -1) {
            if count % 8 == 0 { bytes.append(0) }
            bytes[count / 8] |= UInt8((value >> shift) & 1) << (7 - count % 8)
            count += 1
        }
    }

    mutating func write(_ flag: Bool) { write(flag ? 1 : 0, 1) }

    mutating func pad(to bits: Int) {
        precondition(count <= bits, "frame content exceeds \(bits) bits")
        while count < bits { write(0, 1) }
    }
}

/// AC-3 CRC: polynomial x^16 + x^15 + x^2 + 1, most significant bit first.
func crc16<S: Sequence<UInt8>>(_ bytes: S) -> Int {
    var crc = 0
    for byte in bytes {
        crc ^= Int(byte) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? ((crc << 1) ^ 0x8005) & 0xFFFF : (crc << 1) & 0xFFFF }
    }
    return crc
}

let frameCount = 63  // 2.016 s; the activator loops it.
let frameBytes = 3_072  // 768 kbit/s, the common streaming rate for DD+ Atmos.
let fullBandwidthChannels = 5  // 3/2 with LFE, the core used by JOC streams.
let bandwidthCode = 60  // endmant 253, the full bandwidth of an uncoupled channel.
let objectCount = 16  // complexity_index_type_a of common DD+ Atmos streams.

/// D15 exponent groups that climb from the largest absolute exponent, 15, to the smallest level, 24.
func exponentGroups(count: Int) -> [Int] {
    // Each 7-bit group codes three deltas, offset by 2, as 25 * d0 + 5 * d1 + d2.
    let deltas = [2, 2, 2, 2, 1] + Array(repeating: 0, count: count * 3 - 5)
    return stride(from: 0, to: deltas.count, by: 3).map { 25 * (deltas[$0] + 2) + 5 * (deltas[$0 + 1] + 2) + deltas[$0 + 2] + 2 }
}

func silentFrame() -> [UInt8] {
    var w = BitWriter()
    // syncinfo and bsi (TS 102 366 E.1.2.1-2)
    w.write(0x0B77, 16)
    w.write(0, 2)  // strmtyp: independent
    w.write(0, 3)  // substreamid
    w.write(frameBytes / 2 - 1, 11)  // frmsiz
    w.write(0, 2)  // fscod: 48 kHz
    w.write(3, 2)  // numblkscod: six blocks
    w.write(7, 3)  // acmod: 3/2
    w.write(true)  // lfeon
    w.write(16, 5)  // bsid
    w.write(27, 5)  // dialnorm: -27 dBFS
    w.write(false)  // compre
    w.write(false)  // mixmdate
    w.write(true)  // infomdate
    w.write(0, 3)  // bsmod: complete main
    w.write(true)  // copyrightb
    w.write(true)  // origbs
    w.write(0, 2)  // dsurexmod: not indicated
    w.write(false)  // audprodie
    w.write(false)  // sourcefscod
    w.write(true)  // addbsie
    w.write(1, 6)  // addbsil: two bytes follow
    w.write(1, 8)  // reserved 7 bits, flag_ec3_extension_type_a (TS 103 420 8.3)
    w.write(objectCount, 8)  // complexity_index_type_a

    // audfrm (E.1.2.3), with the strategy flags of common DD+ Atmos encoders.
    w.write(false)  // expstre: frame-based exponent strategies
    w.write(false)  // ahte
    w.write(0, 2)  // snroffststr: one SNR offset for the frame
    w.write(false)  // transproce
    w.write(false)  // blkswe
    w.write(true)  // dithflage
    w.write(true)  // bamode
    w.write(true)  // frmfgaincode
    w.write(false)  // dbaflde
    w.write(true)  // skipflde
    w.write(false)  // spxattene
    w.write(false)  // cplinu[0]
    for _ in 1..<6 { w.write(false) }  // cplstre[blk]: coupling stays off
    for _ in 0..<fullBandwidthChannels { w.write(0, 5) }  // frmchexpstr: D15, then reuse
    for block in 0..<6 { w.write(block == 0) }  // lfeexpstr: D15, then reuse
    for _ in 0..<fullBandwidthChannels { w.write(0, 5) }  // convexpstr, as frmchexpstr
    w.write(0, 6)  // frmcsnroffst
    w.write(0, 4)  // frmfsnroffst: both offsets 0 make every bap 0, so no mantissas are coded
    w.write(false)  // blkstrtinfoe

    // audblk (E.1.2.4)
    let endMantissa = (bandwidthCode + 12) * 3 + 37
    let channelGroups = exponentGroups(count: (endMantissa - 1) / 3)  // nchgrps for D15
    for block in 0..<6 {
        // Dither would fill the uncoded mantissas with noise at the exponent level, and the
        // lowest bins cannot reach the smallest exponent; the first one is coded as 15 at most.
        for _ in 0..<fullBandwidthChannels { w.write(false) }  // dithflag
        w.write(false)  // dynrnge
        w.write(false)  // spxinu in block 0, spxstre afterwards
        if block == 0 {
            for _ in 0..<fullBandwidthChannels { w.write(bandwidthCode, 6) }  // chbwcod
            for _ in 0..<fullBandwidthChannels {
                w.write(15, 4)  // exps[ch][0]
                for group in channelGroups { w.write(group, 7) }
                w.write(0, 2)  // gainrng
            }
            w.write(15, 4)  // lfeexps[0]
            for group in exponentGroups(count: 2) { w.write(group, 7) }
            w.write(true)  // baie, with the default parameters
            w.write(2, 2)  // sdcycod
            w.write(1, 2)  // fdcycod
            w.write(1, 2)  // sgaincod
            w.write(2, 2)  // dbpbcod
            w.write(7, 3)  // floorcod
        } else {
            w.write(false)  // baie
        }
        w.write(false)  // fgaincode
        w.write(false)  // convsnroffste
        w.write(false)  // skiple
    }

    // auxdata (E.1.2.5) and errorcheck (E.1.2.6)
    w.pad(to: frameBytes * 8 - 18)
    w.write(false)  // auxdatae
    w.write(false)  // encinfo
    var frame = w.bytes + [0, 0]
    let crc = crc16(frame[2..<(frameBytes - 2)])
    frame[frameBytes - 2] = UInt8(crc >> 8)
    frame[frameBytes - 1] = UInt8(crc & 0xFF)
    return frame
}

guard CommandLine.arguments.count == 2 else {
    print("Usage: swift scripts/make-silent-atmos.swift output.ec3")
    exit(1)
}
let frame = silentFrame()
precondition(frame.count == frameBytes)
let stream = (0..<frameCount).flatMap { _ in frame }
try Data(stream).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Wrote \(frameCount) frames, \(stream.count) bytes")
