import Foundation

/// Seeded mutations of valid synthetic input, for bounded fuzzing of the Swift parsers. A failure
/// names its seed; set `SAB_FUZZ_SEED` to replay it and `SAB_FUZZ_ITERATIONS` for longer runs.
struct Mutation {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    static var iterations: Int { ProcessInfo.processInfo.environment["SAB_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 200 }

    static func seeds(base: UInt64) -> [UInt64] {
        if let seed = ProcessInfo.processInfo.environment["SAB_FUZZ_SEED"].flatMap(UInt64.init) { return [seed] }
        return (0..<UInt64(iterations)).map { base &+ $0 }
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }

    /// Flips, overwrites, inserts, deletes, duplicates or truncates a few spans of `bytes`.
    mutating func mutate(_ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        for _ in 0..<(1 + below(4)) where !bytes.isEmpty {
            let at = below(bytes.count)
            switch below(6) {
            case 0: bytes[at] ^= UInt8(truncatingIfNeeded: 1 << below(8))
            case 1: bytes[at] = UInt8(truncatingIfNeeded: next())
            case 2: bytes.insert(contentsOf: (0..<(1 + below(16))).map { _ in UInt8(truncatingIfNeeded: next()) }, at: at)
            case 3: bytes.removeSubrange(at..<min(bytes.count, at + 1 + below(64)))
            case 4: bytes.insert(contentsOf: bytes[at..<min(bytes.count, at + 1 + below(256))], at: below(bytes.count))
            default: bytes.removeSubrange(at...)
            }
        }
        return bytes
    }

    /// Splits `count` bytes into chunks of varied size.
    mutating func chunks(_ count: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = [], offset = 0
        while offset < count {
            let end = min(count, offset + 1 + below(below(2) == 0 ? 64 : 20_000))
            ranges.append(offset..<end)
            offset = end
        }
        return ranges
    }
}
