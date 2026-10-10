// Writes synthetic APAC test media for AtmosAB.
//
//   swift make-test-media.swift sweep 7.1.4|9.1.6 channel-sweep-9.1.6.APAC.mp4
//     Pulsed pink noise in one channel at a time; OutputProbe.swift shows the same section order.
//   swift make-test-media.swift encode 7.1.4|9.1.6 input.f32le output.mp4
//     Encodes interleaved Float32 speaker feeds, such as the Rust crate's object_path example.
import AudioToolbox
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4, ["sweep", "encode"].contains(arguments[1]), ["7.1.4", "9.1.6"].contains(arguments[2]),
      arguments[1] == "sweep" ? arguments.count == 4 : arguments.count == 5 else {
    print("Usage: swift make-test-media.swift sweep 7.1.4|9.1.6 output.mp4")
    print("       swift make-test-media.swift encode 7.1.4|9.1.6 input.f32le output.mp4")
    exit(1)
}
let wide = arguments[2] == "9.1.6"
// Channel order of kAudioChannelLayoutTag_Atmos_9_1_6 and _7_1_4.
let channels = wide
    ? ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs", "Lw", "Rw", "Vhl", "Vhr", "Ltm", "Rtm", "Ltr", "Rtr"]
    : ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs", "Vhl", "Vhr", "Ltr", "Rtr"]
let count = channels.count
let rate = 48_000

func check(_ status: OSStatus, _ step: String) {
    guard status != noErr else { return }
    print("\(step) failed: \(status)")
    exit(1)
}

/// Encodes interleaved Float32 feeds at the library's bit rate, 256 kbit/s per channel.
func encode(_ samples: inout [Float], to url: URL) {
    var client = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(count * 4),
        mFramesPerPacket: 1, mBytesPerFrame: UInt32(count * 4), mChannelsPerFrame: UInt32(count),
        mBitsPerChannel: 32, mReserved: 0)
    var file = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatAPAC, mFormatFlags: 0,
        mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(count),
        mBitsPerChannel: 0, mReserved: 0)
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = wide ? kAudioChannelLayoutTag_Atmos_9_1_6 : kAudioChannelLayoutTag_Atmos_7_1_4
    let layoutSize = UInt32(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
    var output: ExtAudioFileRef?
    check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileMPEG4Type, &file, &layout, AudioFileFlags.eraseFile.rawValue, &output), "Create")
    check(ExtAudioFileSetProperty(output!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client), "Client format")
    check(ExtAudioFileSetProperty(output!, kExtAudioFileProperty_ClientChannelLayout, layoutSize, &layout), "Client layout")
    var converter: AudioConverterRef?
    var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
    check(ExtAudioFileGetProperty(output!, kExtAudioFileProperty_AudioConverter, &size, &converter), "Converter")
    var bitRate = UInt32(count * 256_000)
    check(AudioConverterSetProperty(converter!, kAudioConverterEncodeBitRate, 4, &bitRate), "Bit rate")
    // A null configuration makes the file pick up the converter's new bit rate.
    var config: Unmanaged<CFArray>?
    check(ExtAudioFileSetProperty(output!, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), &config), "Converter config")
    let frames = samples.count / count
    for start in stride(from: 0, to: frames, by: 4096) {
        let length = min(4096, frames - start)
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(count),
                mDataByteSize: UInt32(length * count * 4), mData: raw.baseAddress! + start * count * 4))
            check(ExtAudioFileWrite(output!, UInt32(length), &list), "Write")
        }
    }
    check(ExtAudioFileDispose(output!), "Close")
    print("Wrote \(url.path): \(frames) frames, \(count) channels")
}

if arguments[1] == "encode" {
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
    guard !data.isEmpty, data.count % (count * 4) == 0 else {
        print("\(arguments[3]) is not whole frames of \(count)-channel Float32: \(data.count) bytes")
        exit(1)
    }
    var samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    encode(&samples, to: URL(fileURLWithPath: arguments[4]))
    exit(0)
}

// Front to back, ear level then heights, so neighbours can be compared in turn.
let order = ["L", "R", "C", "LFE", "Lw", "Rw", "Ls", "Rs", "Lrs", "Rrs", "Vhl", "Vhr", "Ltm", "Rtm", "Ltr", "Rtr"]
    .filter(channels.contains)
let lead = 2 * rate
let section = 10 * rate
var samples = [Float](repeating: 0, count: (lead + order.count * section) * count)
var random = SystemRandomNumberGenerator()
for (index, name) in order.enumerated() {
    let channel = channels.firstIndex(of: name)!
    // Paul Kellet's economy pink noise filter; LFE gets a two-pole 80 Hz low-pass instead.
    var (b0, b1, b2): (Float, Float, Float) = (0, 0, 0)
    var (l1, l2): (Float, Float) = (0, 0)
    let lowpass = 1 - expf(-2 * .pi * 80 / Float(rate))
    for frame in 0..<section {
        let white = Float.random(in: -1...1, using: &random)
        var value: Float
        if name == "LFE" {
            l1 += lowpass * (white - l1)
            l2 += lowpass * (l1 - l2)
            value = l2 * 9
        } else {
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            value = (b0 + b1 + b2 + white * 0.1848) * 0.06
        }
        // Half a second on, half a second off, with 10 ms ramps against clicks.
        let phase = frame % rate
        let on = rate / 2
        let ramp = rate / 100
        let gain: Float = phase >= on ? 0 : Float(min(phase, on - phase, ramp)) / Float(ramp)
        samples[(lead + index * section + frame) * count + channel] = value * gain
    }
}
encode(&samples, to: URL(fileURLWithPath: arguments[3]))
print("\(order.count) sections of 10 s after 2 s: \(order.joined(separator: " "))")
