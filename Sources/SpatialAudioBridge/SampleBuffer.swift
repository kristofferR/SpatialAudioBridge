import Accelerate
import AudioToolbox
import CoreMedia
import Foundation

@available(macOS 26, iOS 26, tvOS 26, *)
func pcmFormat(rate: Int, layout: SpatialAudioLayout) throws -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(layout.channelCount * 4), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(layout.channelCount * 4),
        mChannelsPerFrame: UInt32(layout.channelCount), mBitsPerChannel: 32, mReserved: 0)
    var channelLayout = AudioChannelLayout()
    channelLayout.mChannelLayoutTag = layout.tag
    var format: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 12, layout: &channelLayout, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format)
    guard status == noErr, let format else { throw SpatialAudioError.coreMedia(status) }
    return format
}

/// Writes `samples` scaled by `gain` into a new sample buffer and returns it with the scaled
/// samples' peak magnitude. Accelerate keeps this fast in unoptimized builds too.
@available(macOS 26, iOS 26, tvOS 26, *)
func pcmSampleBuffer(_ samples: ArraySlice<Float>, gain: Float, frames: Int, format: CMAudioFormatDescription,
                     time: CMTime, rate: Int) throws -> (buffer: CMSampleBuffer, peak: Float) {
    let size = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
        memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    guard status == noErr, let block else { throw SpatialAudioError.coreMedia(status) }
    var data: UnsafeMutablePointer<CChar>?
    let pointerStatus = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                    totalLengthOut: nil, dataPointerOut: &data)
    guard pointerStatus == noErr, let data else { throw SpatialAudioError.coreMedia(pointerStatus) }
    let output = UnsafeMutableRawPointer(data).bindMemory(to: Float.self, capacity: samples.count)
    var peak: Float = 0
    samples.withUnsafeBufferPointer { input in
        var gain = gain
        vDSP_vsmul(input.baseAddress!, 1, &gain, output, 1, vDSP_Length(input.count))
        vDSP_maxmgv(output, 1, &peak, vDSP_Length(input.count))
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                   presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let createStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
        dataBuffer: block, formatDescription: format, sampleCount: frames,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    guard createStatus == noErr, let sample else { throw SpatialAudioError.coreMedia(createStatus) }
    return (sample, peak)
}

@available(macOS 26, iOS 26, tvOS 26, *)
func layoutData(_ layout: SpatialAudioLayout) -> Data {
    var value = AudioChannelLayout()
    value.mChannelLayoutTag = layout.tag
    return withUnsafeBytes(of: &value) { Data($0.prefix(12)) }
}
