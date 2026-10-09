import Foundation
import CoreMedia
import AudioToolbox

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

func pcmSampleBuffer(_ samples: [Float], frames: Int, format: CMAudioFormatDescription,
                     time: CMTime, rate: Int) throws -> CMSampleBuffer {
    let size = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
        memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block)
    guard status == noErr, let block else { throw SpatialAudioError.coreMedia(status) }
    let copyStatus = samples.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                      offsetIntoDestination: 0, dataLength: size)
    }
    guard copyStatus == noErr else { throw SpatialAudioError.coreMedia(copyStatus) }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                   presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let createStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
        dataBuffer: block, formatDescription: format, sampleCount: frames,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    guard createStatus == noErr, let sample else { throw SpatialAudioError.coreMedia(createStatus) }
    return sample
}

func layoutData(_ layout: SpatialAudioLayout) -> Data {
    var value = AudioChannelLayout()
    value.mChannelLayoutTag = layout.tag
    return withUnsafeBytes(of: &value) { Data($0.prefix(12)) }
}
