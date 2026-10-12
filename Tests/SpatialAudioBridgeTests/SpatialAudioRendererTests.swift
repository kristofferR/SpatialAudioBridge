import AVFoundation
import Foundation
import Testing
@testable import SpatialAudioBridge

/// Decodes APAC packets with Core Audio into interleaved Float32.
@available(macOS 26, iOS 26, tvOS 26, *)
private func decode(_ packets: [Data], format: CMAudioFormatDescription, channels: Int) throws -> [Float] {
    var source = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
    var destination = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 4),
        mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32, mReserved: 0)
    var converter: AudioConverterRef?
    #expect(AudioConverterNew(&source, &destination, &converter) == noErr)
    let decoder = try #require(converter)
    defer { AudioConverterDispose(decoder) }
    var cookieSize = 0
    let cookie = try #require(CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieSize))
    #expect(AudioConverterSetProperty(decoder, kAudioConverterDecompressionMagicCookie, UInt32(cookieSize), cookie) == noErr)
    /// Owns the packet bytes and description the decoder reads until its next callback.
    final class Feed {
        var packets: [Data]
        var storage: UnsafeMutableRawPointer?
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        init(_ packets: [Data]) { self.packets = packets }
        deinit { storage?.deallocate(); description.deallocate() }
    }
    let feed = Feed(packets)
    var output: [Float] = []
    let capacity = 4096
    var buffer = [Float](repeating: 0, count: capacity * channels)
    while true {
        var frames = UInt32(capacity)
        let status = buffer.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            return AudioConverterFillComplexBuffer(decoder, { _, count, data, descriptions, context in
                let feed = Unmanaged<Feed>.fromOpaque(context!).takeUnretainedValue()
                guard !feed.packets.isEmpty else { count.pointee = 0; return noErr }
                let packet = feed.packets.removeFirst()
                feed.storage?.deallocate()
                feed.storage = UnsafeMutableRawPointer.allocate(byteCount: max(packet.count, 1), alignment: 16)
                packet.withUnsafeBytes { feed.storage!.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
                feed.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
                count.pointee = 1
                data.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
                data.pointee.mBuffers.mData = feed.storage
                descriptions?.pointee = feed.description
                return noErr
            }, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil)
        }
        output += buffer.prefix(Int(frames) * channels)
        if frames == 0 || status != noErr { break }
    }
    return output
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func encoderKeepsEveryChannelInPlaceAndReportsItsPriming() throws {
    let encoder = try APACEncoder(configuration: APACConfiguration(layout: .nineOneSix))
    let channels = 16, frames = 48_000
    // A distinct tone per channel; LFE stays low.
    var pcm = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        for channel in 0..<channels {
            let frequency = channel == 3 ? 60.0 : 200.0 + Double(channel) * 150
            pcm[frame * channels + channel] = Float(0.2 * sin(2 * .pi * frequency * Double(frame) / 48_000))
        }
    }
    var packets = try encoder.encode(pcm[..<(frames / 2 * channels)])
    packets += try encoder.encode(pcm[(frames / 2 * channels)...], final: true)
    #expect(encoder.primingFrames == 2048)
    let decoded = try decode(packets, format: encoder.format, channels: channels)
    #expect(decoded.count / channels >= frames + encoder.primingFrames)
    // After the priming, each decoded channel correlates with its own tone and not its neighbour's.
    for channel in 0..<channels {
        let neighbour = (channel + 1) % channels
        var own = 0.0, other = 0.0, energyIn = 0.0, energyOut = 0.0, energyOther = 0.0
        for frame in 4_800..<frames - 4_800 {
            let output = Double(decoded[(frame + encoder.primingFrames) * channels + channel])
            let input = Double(pcm[frame * channels + channel]), next = Double(pcm[frame * channels + neighbour])
            own += input * output; other += next * output
            energyIn += input * input; energyOut += output * output; energyOther += next * next
        }
        #expect(own / sqrt(energyIn * energyOut) > 0.98, "channel \(channel)")
        #expect(abs(other / sqrt(energyOther * energyOut)) < 0.1, "channel \(channel) leaks into \(neighbour)")
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"] != nil))
func rendererPlaysMatroskaAudioFromASeek() async throws {
    let file = try await MatroskaFile.open(FileByteSource(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"]!)))
    let track = try #require(file.audioTracks.first { $0.codec == .trueHDAtmos })
    let synchronizer = AVSampleBufferRenderSynchronizer()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos, synchronizer: synchronizer)
    let start = CMTime(seconds: 20, preferredTimescale: 48_000)
    try await renderer.begin(at: start)
    var started = false
    for try await packet in file.packets(of: track, from: start) {
        try await renderer.enqueue(packet.data, time: packet.time)
        if !started, await renderer.isReadyToPlay {
            started = true
            synchronizer.setRate(1, time: start)
        }
        if packet.time.seconds > 26 { break }
    }
    #expect(await renderer.renderingStatus == .rendering)
    #expect(synchronizer.currentTime().seconds > 20.5)
    synchronizer.rate = 0
}

/// A route change, such as headphones connecting, makes the audio renderer drop queued audio by
/// itself; the renderer enqueues it again and keeps playing.
@available(macOS 26, iOS 26, tvOS 26, *)
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"] != nil))
func rendererRefillsAfterAnAutomaticFlush() async throws {
    let file = try await MatroskaFile.open(FileByteSource(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAB_MKV_FIXTURE"]!)))
    let track = try #require(file.audioTracks.first { $0.codec == .trueHDAtmos })
    let synchronizer = AVSampleBufferRenderSynchronizer()
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos, synchronizer: synchronizer)
    let start = CMTime(seconds: 20, preferredTimescale: 48_000)
    try await renderer.begin(at: start)
    var started = false, refills = 0
    for try await packet in file.packets(of: track, from: start) {
        try await renderer.enqueue(packet.data, time: packet.time)
        if !started, await renderer.isReadyToPlay {
            started = true
            synchronizer.setRate(1, time: start)
        }
        // As the automatic flush would, half a second ahead of the playhead, then as an output
        // format change would, with no time.
        if started, refills == 0, synchronizer.currentTime().seconds > 21.5 {
            refills += 1
            await renderer.refill(from: CMTimeAdd(synchronizer.currentTime(), CMTime(value: 1, timescale: 2)))
        } else if refills == 1, synchronizer.currentTime().seconds > 22.5 {
            refills += 1
            await renderer.refill(from: nil)
        }
        if packet.time.seconds > 30 { break }
    }
    #expect(refills == 2)
    #expect(await renderer.renderingStatus == .rendering)
    #expect(synchronizer.currentTime().seconds > 23)
    synchronizer.rate = 0
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererRejectsInvalidSettings() {
    #expect(throws: SpatialAudioError.self) {
        try SpatialAudioRenderer(codec: .trueHDAtmos, configuration: APACConfiguration(bitRate: -1),
                                 synchronizer: AVSampleBufferRenderSynchronizer())
    }
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererMuteAndVolumeHoldAcrossTimelines() async throws {
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos, synchronizer: AVSampleBufferRenderSynchronizer())
    await renderer.setMuted(true)
    await renderer.setVolume(1.5)
    try await renderer.begin(at: .zero)
    #expect(await renderer.isMuted)
    #expect(await renderer.volume == 1)
    await renderer.setVolume(-1)
    #expect(await renderer.volume == 0)
}

@available(macOS 26, iOS 26, tvOS 26, *)
@Test func rendererRefusesInputAfterAFailureUntilANewTimeline() async throws {
    let renderer = try SpatialAudioRenderer(codec: .trueHDAtmos, synchronizer: AVSampleBufferRenderSynchronizer())
    try await renderer.begin(at: .zero)
    // A first packet two minutes from the timeline fails, and the timeline stays failed.
    await #expect(throws: SpatialAudioError.self) { try await renderer.enqueue(Data([0]), time: CMTime(seconds: 120, preferredTimescale: 1)) }
    await #expect(throws: SpatialAudioError.self) { try await renderer.enqueue(Data([0]), time: .zero) }
    try await renderer.begin(at: .zero)
    try await renderer.enqueue(Data([0]), time: .zero)
}
