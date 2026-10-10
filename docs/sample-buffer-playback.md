# Play through sample buffers

`SpatialAudioRenderer` decodes, renders and encodes compressed packets, then queues the APAC on an `AVSampleBufferAudioRenderer` in the host's `AVSampleBufferRenderSynchronizer`. No playlist, server or `AVPlayer` is involved.

Use this path when the host renders video itself, for example with `AVSampleBufferDisplayLayer` or `AVSampleBufferVideoRenderer`, and owns the playback clock. Engines built on FFmpeg, mpv or VLC typically decode audio to PCM internally; they need a hook that hands the selected track's compressed packets to this renderer instead.

## Play

```swift
import AVFoundation
import SpatialAudioBridge
import SpatialAudioPlayback

let synchronizer = AVSampleBufferRenderSynchronizer()
synchronizer.addRenderer(videoRenderer) // the host's video
let audio = try SpatialAudioRenderer(codec: .trueHDAtmos, synchronizer: synchronizer)
let atmos = AtmosOutputActivator(silentAtmosStream: silentAtmosURL)
atmos.attach(to: synchronizer)

try await audio.begin(at: start)
var started = false
for try await packet in file.packets(of: track, from: start) {
    try await audio.enqueue(packet.data, time: packet.time)
    if !started, await audio.isReadyToPlay {
        started = true
        synchronizer.setRate(1, time: start)
    }
}
try await audio.endOfStream()
```

`enqueue` suspends while the audio renderer is full, so the loop runs only as far ahead as the renderer buffers. Feed it from a task the host can cancel. `file` is a `MatroskaFile` here; a host demuxer's packets work the same way, with their container times.

## Timing

- **Start.** Call `begin(at:)` with the presentation time, then enqueue packets from a sync point at or before it. The first packet's time anchors the timeline; audio before `start` is discarded, and a source that begins after it is padded with silence, so audio starts exactly at `start`.
- **Readiness.** The live encoder holds about 1.6 s of input before its first packet. Start the synchronizer only when `isReadyToPlay` is true.
- **Seek.** Pause the synchronizer, call `begin(at:)` with the target, which flushes queued audio and resets the decoder and encoder, then feed packets from the target and start the clock again once ready. An `enqueue` still waiting from before the seek throws `CancellationError` instead of queuing stale audio.
- **Pause and rate.** The host sets the synchronizer's rate. `AtmosOutputActivator` follows it.
- **Discontinuities.** A timestamp jump or a format change needs `begin(at:)`, just like a seek.

Each packet's timestamp is shifted back by the encoder priming, so decoded audio lands at its presentation time.

## Status and errors

`renderingStatus` is `.rendering` once APAC plays and `.failed` if the renderer rejects it. `enqueue` throws for malformed or unsupported input and for a failed renderer; treat that as the end of the session and fall back to the host's audio path. Any failure, including cancellation, ends the timeline: further input is refused until `begin(at:)`, as after `endOfStream()`. Releasing the `SpatialAudioRenderer` removes it from the synchronizer.

## Device results

On an Apple TV 4K (2nd generation) with tvOS 27.2 beta, APAC played through `AVSampleBufferAudioRenderer` switched the receiver to Dolby Atmos only while `AtmosOutputActivator` ran, and a channel check placed every channel correctly, including the heights. That test fed APAC from a converted file.

The [StreamPlayer](../Examples/StreamPlayer/README.md) example's renderer mode then ran this API end to end, reading the MKV from Jellyfin: the synchronizer started 1.47 s after launch, the renderer reported `.rendering` and the silent Atmos stream played. Receiver output was not checked by listening in that run.

`SpatialAudioRenderer` encodes with Apple's medium quality tier, which matched the default tier on real Atmos content and encodes 1.25 to 1.5 times as fast.

On macOS, the same renderer rejected TrueHD packets as an unsupported format (`fmt?`) while playing 16-channel APAC, so the conversion is what makes this path possible.
