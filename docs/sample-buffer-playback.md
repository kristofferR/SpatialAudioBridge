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
let atmos = AtmosOutputActivator()
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

Capacity is checked before each output packet, including final encoder output and route-change replay. New audio waits behind a pending replay. Cancellation or failure ends the timeline; delayed flush completions cannot restart it. Call `begin(at:)` to reset it before feeding again.

Feed from one task that awaits each call. An `enqueue` or `endOfStream` made while another is still in progress on the same timeline throws `invalidState` and leaves the active call untouched. `begin(at:)` invalidates the active call, so a new timeline's feeder can start at once.

With Xcode 26, whose SDK does not mark `AVSampleBufferRenderSynchronizer` as `Sendable`, Swift 6 rejects handing the synchronizer to the renderer while the host keeps using it. Import AVFoundation with `@preconcurrency` in that file; with Xcode 27 the import makes no difference.

## Timing

- **Start.** Call `begin(at:)` with the presentation time, then enqueue packets from a sync point at or before it. The first packet's time anchors the timeline; audio before `start` is discarded, and a source that begins after it is padded with silence, so audio starts exactly at `start`.
- **Readiness.** The live encoder holds 71 packets (1.5 s) of input before its first packet. Start the synchronizer only when `isReadyToPlay` is true.
- **Host clocks.** A host that paces its own clock by submitted audio, as mpv does, can read `progress()`, which returns a fresh stream on each call. Each value holds the timeline's start, the presentation end of the APAC enqueued so far, and whether `endOfStream()` has enqueued everything, which also covers a stream that ends without audio. It reports only; the host keeps its own clock policy. A batch or final flush can enqueue enough to start playback and then wait for capacity before `enqueue` or `endOfStream()` returns, and `progress` shows that audio as soon as it is enqueued.
- **Seek.** Pause the synchronizer, call `begin(at:)` with the target, which flushes queued audio and resets the decoder and encoder, then feed packets from the target and start the clock again once ready. An `enqueue` still waiting from before the seek throws `CancellationError` instead of queuing stale audio.
- **Pause and rate.** The host sets the synchronizer's rate. `AtmosOutputActivator` follows it.
- **Route changes.** When the output route changes, such as headphones connecting, the system can drop queued audio or switch the output to another format. The renderer enqueues the audio again, from the flush time or the playhead, so the host needs to do nothing.
- **Mute and volume.** `setMuted(_:)` and `setVolume(_:)` control the APAC output and hold across timelines. Passthrough hosts need them: their own software volume and mute never reach the renderer.
- **Discontinuities.** A timestamp jump or a format change needs `begin(at:)`, just like a seek.

Each packet's timestamp is shifted back by the encoder priming, so decoded audio lands at its presentation time.

## Passthrough output

Players such as mpv and VLC never hand the app TrueHD or DTS packets, but their passthrough audio outputs deliver the compressed stream as IEC 61937 bursts, the same data an S/PDIF or HDMI bitstream carries. `IEC61937Unpacker` recovers the stream from them: TrueHD from MAT frames and DTS-HD from type IV bursts, in either 16-bit byte order, with bursts split anywhere and filler such as the zeros a paused player writes skipped.

```swift
var unpacker = IEC61937Unpacker()          // a new one for every timeline
try await renderer.begin(at: seekTime)
// For each buffer the player's audio output receives; firstTime is that of the first buffer since begin(at:).
let stream = try unpacker.unpack(bursts)
if !stream.isEmpty { try await renderer.enqueue(stream, time: firstTime + unpacker.skippedDuration) }
```

`SpatialAudioPassthroughSink` wraps both for an audio output's thread, which cannot await. Its methods return at once from any thread:

```swift
let sink = try SpatialAudioPassthroughSink(codec: .trueHDAtmos, synchronizer: synchronizer)
sink.begin(at: seekTime)          // whenever the player (re)starts the output
let taken = sink.write(bursts)    // offer the rest again; the buffer holds about 0.3 s
if sink.isReady { /* start the clock */ }
if let failure = sink.failure { /* a discontinuity: begin at the next write; otherwise fall back */ }
let delay = await sink.queuedAhead
let played = sink.progress?.submittedEnd  // for a clock run from submitted audio
sink.end()                        // drain at the end of the stream
sink.close()
```

`write` takes bytes only up to its buffer limit while the renderer is full, so the player's own buffering provides the backpressure. A failure stops the timeline, sets `failure` and refuses input until the next `begin(at:)`; poll it as the output polls for its own failure. A `SpatialAudioError.discontinuity`, such as an IEC 61937 pause burst, ends the timeline and drops the rest of that write; resume as after a seek, with `begin(at:)` at the time of the next audio the player writes. mpv's passthrough sends no pause bursts: paused, it writes zeros, which the sink skips. Any other failure means falling back to the player's own output, and after `.unsupported` the track will never play. A host whose clock follows the audio it has handed over, as mpv's does, can read `progress`: how far the enqueued audio reaches, and whether `end()` has enqueued all of it, also when there was nothing to play. The host still owns the synchronizer's rate, `AtmosOutputActivator` and the audio session.

After a seek, or when attaching to a running output, the bursts may resume between TrueHD major syncs, where decoding cannot start, or even inside an access unit. The unpacker drops the data up to the first major sync and adds its duration to `skippedDuration`, measured by its share of the 20 ms MAT frames and so accurate to about one access unit (0.8 ms). Adding it to the first buffer's time keeps audio on the timeline. DTS-HD frames each start with a core sync and need no adjustment. Other burst types, such as AC-3 or DTS core alone, throw; let the player keep its own output for them.

### mpv

An mpv host adds an audio output of its own that feeds the renderer, listed before its usual output (`ao=<own output>,audiounit`), and passes only these codecs through (`audio-spdif=truehd,dts-hd`). The output starts a new timeline with a new unpacker whenever mpv (re)starts it, and refuses other formats, such as DTS core alone, so mpv uses its usual output for them.

- mpv's passthrough creates FFmpeg's `spdif` muxer on the first packet. Without it, mpv drops the audio track instead of falling back to PCM, so FFmpeg builds configured with `--disable-muxers` need `--enable-muxer=spdif`.
- When the library refuses a track, such as DTS-HD MA without DTS:X, mpv has to decode it to PCM instead. Two ways worked on the Apple TV:
  - On the player's mpv thread, rather than the audio output's, remove that codec from `audio-spdif`, then set `aid` to `no` and back to the same track. mpv rebuilds the decoder and output as for a track switch and decodes to PCM, about 40 ms after the refusal. Restore the full `audio-spdif` before the next `loadfile`.
  - Report the failure from the output and refuse that format when mpv reopens it, so mpv falls back to PCM itself, about 0.6 s after the refusal, with no host code. This needs two mpv fixes for reopening a failed output: drop the frame held for the old output, and wake the output chain after the reset. Without them, the reopen never reached PCM.
- mpv's software volume and mute never reach passthrough. An output can forward mpv's gain, which already combines volume, mute and replaygain, to `setVolume(_:)`. mpv sets the gain once before it opens the output.

## Status and errors

`renderingStatus` is `.rendering` once APAC plays and `.failed` if the renderer rejects it. `enqueue` throws for malformed or unsupported input and for a failed renderer; treat that as the end of the session and fall back to the host's audio path. Any failure, including cancellation, ends the timeline: further input is refused until `begin(at:)`, as after `endOfStream()`. Releasing the `SpatialAudioRenderer` removes it from the synchronizer.

## Device results

On an Apple TV 4K (2nd generation) with tvOS 27.2 beta, APAC played through `AVSampleBufferAudioRenderer` switched the receiver to Dolby Atmos only while `AtmosOutputActivator` ran, and a channel check placed every channel correctly, including the heights. That test fed APAC from a converted file.

The [StreamPlayer](../Examples/StreamPlayer/README.md) example's renderer mode then ran this API end to end, reading the MKV from Jellyfin: the synchronizer started 1.47 s after launch, the renderer reported `.rendering` and the silent Atmos stream played. Receiver output was not checked by listening in that run.

`SpatialAudioRenderer` encodes with Apple's medium quality tier, the same tier `AVAssetWriter` uses for `APACStream` and file conversion.

On macOS, the same renderer rejected TrueHD packets as an unsupported format (`fmt?`) while playing 16-channel APAC, so the conversion is what makes this path possible.
