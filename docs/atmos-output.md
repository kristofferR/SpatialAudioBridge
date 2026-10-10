# Atmos output on Apple TV

APAC carries height channels, but on the tested Apple TV and receiver, APAC alone never switched the receiver to Atmos. Playing a second, near-silent Dolby Digital Plus Atmos (E-AC-3 + JOC) stream alongside it switched the output to Atmos, and a channel check then placed every APAC channel correctly, including the heights. Native Player 1.1.2 uses the same technique.

`AtmosOutputActivator`, in the `SpatialAudioPlayback` product, manages that second stream. The product does not link the Rust core.

## Set up

```swift
import SpatialAudioPlayback

try AtmosOutputActivator.configureAudioSession()
let atmos = AtmosOutputActivator(silentAtmosStream: silentAtmosURL)
```

Attach it to whatever drives playback:

```swift
// AVPlayer: return true while the item's selected audio is APAC.
atmos.attach(to: player) { item in
    item.currentMediaSelection.selectedMediaOption(in: audioGroup)?.displayName == "Spatial Audio"
}

// SpatialAudioRenderer: follows the synchronizer's rate.
atmos.attach(to: synchronizer)

// When leaving playback.
atmos.detach()
```

The predicate defaults to true, which suits `APACStream`'s master playlist: it offers only the APAC rendition. Pass a predicate when an item also offers other audio. The example above checks the selected rendition's name; `audioGroup` is the item's audible `AVMediaSelectionGroup`.

## Behavior

- The silent stream loops in its own unmuted `AVQueuePlayer` while the host plays, or waits to play, an item the predicate accepts. It starts inside the host's `play()` call, ahead of APAC output.
- It pauses with the host and re-evaluates when the item or its audio selection changes.
- For other items, it unloads the stream. Leaving it loaded made direct Dolby Digital Plus playback stutter.
- `isActive` reports whether the silent stream is playing. `error` reports why it failed to load.

`configureAudioSession()` sets the playback category, movie playback mode and multichannel content, then activates the session. Native Player manages with just playback and movie playback, so the multichannel setting may be unnecessary; the [A/B example](../Examples/AtmosAB/README.md) has launch arguments that isolate each part.

## Make a silent Atmos stream

The library does not distribute one. The stream must be:

- E-AC-3 with Joint Object Coding, signalled as Atmos in the MP4 `dec3` box,
- near-silent: the tested stream's compatible bed peaks around −105 dBFS, and
- a few seconds long; it loops. The tested stream lasts 2.016 s.

Encode near-silence with a Dolby Digital Plus Atmos encoder, or cut the quiet opening of a Dolby Digital Plus Atmos encode you made yourself. A stream copy keeps the Atmos signalling:

```sh
ffmpeg -i your-ddp-atmos-encode.mp4 -map 0:a:0 -c copy -t 2.016 silent-atmos.mp4
```

Verify the result:

```sh
ffprobe -v error -show_entries stream=codec_name,profile -of compact silent-atmos.mp4
# stream|codec_name=eac3|profile=Dolby Digital Plus + Dolby Atmos
ffmpeg -i silent-atmos.mp4 -af volumedetect -f null - 2>&1 | grep max_volume
```

Only bundle media you have the rights to distribute.

## How to tell it works

Use the receiver's format indicator and a channel check. On the tested tvOS 27.2 beta, `AVAudioSession.outputNumberOfChannels` reported eight channels for both APAC and Dolby Digital Plus, and the session's rendering mode and spatial audio flags did not distinguish Atmos output either.

## Tested

Apple TV 4K (2nd generation), tvOS 27.2 beta, HDMI to an Atmos receiver:

| Path | Without the activator | With the activator |
|---|---|---|
| `AVPlayer`, APAC file | No Atmos | Atmos; sounds like the Dolby Digital Plus version |
| `AVPlayer`, `APACStream` with Jellyfin video | Not tested | Atmos, with video |
| `AVSampleBufferAudioRenderer`, APAC packets | No Atmos | Atmos; a 7.1.4 channel check played every speaker in its place |

This is a measured workaround, not an Apple guarantee. Validate each target receiver and OS version. Atmos indication alone does not prove speaker placement, and the HDMI payload (Dolby MAT or otherwise) has not been inspected.
