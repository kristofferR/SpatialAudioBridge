# Atmos output on Apple TV

APAC carries height channels, but on the tested Apple TV and receiver, APAC alone never switched the receiver to Atmos. Playing a second, silent Dolby Digital Plus Atmos stream alongside it switched the output to Atmos, and a channel check then placed every APAC channel correctly, including the heights.

`AtmosOutputActivator`, in the `SpatialAudioPlayback` product, manages that second stream and bundles it. The product does not link the Rust core.

## Set up

```swift
import SpatialAudioPlayback

try AtmosOutputActivator.configureAudioSession()
let atmos = AtmosOutputActivator()
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
- It keeps playing while the host pauses, so the route stays in Atmos for the resume; it re-evaluates when the item or its audio selection changes. Pausing it with the host made the route leave Atmos on every pause, and on one AirPlay route the programme stayed silent after resuming until a seek.
- For other items, it unloads the stream. Leaving it loaded made direct Dolby Digital Plus playback stutter.
- `isActive` reports whether the silent stream is playing. `error` reports why it failed to load.

`configureAudioSession()` sets the playback category, movie playback mode and multichannel content, then activates the session. The [A/B example](../Examples/AtmosAB/README.md) has launch arguments that isolate each part.

## The bundled stream

[`scripts/make-silent-atmos.swift`](../scripts/make-silent-atmos.swift) writes every bit of the stream from the E-AC-3 and object audio specifications, ETSI TS 102 366 and TS 103 420; no encoder output or programme audio goes into it. It is 2.016 s of 5.1 E-AC-3 at 768 kbit/s that codes no mantissas and turns dither off, so it decodes to digital silence. Each frame header carries the Atmos extension flag with a complexity index of 16, as common Dolby Digital Plus Atmos streams do. FFmpeg's MP4 muxer turns that flag into the `dec3` extension, from which Apple's frameworks offer the object audio format `'ec+3'`.

The stream carries no object metadata. Dolby Digital Plus Atmos sends its objects and joint object coding parameters in an EMDF container whose protection bits are keyed, and only Dolby's encoder holds the key. In a blind test on the tested Apple TV, a Dolby Digital Plus Atmos track with only its protection bits altered lost its heights, like one whose metadata could not be found. The output switch does not depend on objects: with the bundled stream, the output switched to Atmos, and APAC sounded the same as with a near-silent cut from a Dolby encode.

The Apple TV decodes the stream itself and sends the receiver Dolby MAT, as for any Atmos app, so a receiver that plays Atmos from Apple TV apps should need nothing more. Only one Apple TV, tvOS version and receiver have been tested. A tvOS release that switched only for validated objects would no longer switch for the bundled stream; `init(silentAtmosStream:)` takes a stream from a licensed Dolby Digital Plus Atmos encoder instead. Such a stream must be signalled as Atmos in its `dec3` box, should be silent or near-silent, and loops.

Regenerate and check the bundled stream:

```sh
swift scripts/make-silent-atmos.swift silent-atmos.ec3
ffmpeg -i silent-atmos.ec3 -c copy -fflags +bitexact -map_metadata -1 Sources/SpatialAudioPlayback/Resources/silent-atmos.mp4
ffprobe -v error -show_entries stream=codec_name,profile -of compact Sources/SpatialAudioPlayback/Resources/silent-atmos.mp4
# stream|codec_name=eac3|profile=Dolby Digital Plus + Dolby Atmos
```

## How to tell it works

Use the receiver's format indicator and a channel check. On the tested tvOS 27.2 beta, `AVAudioSession.outputNumberOfChannels` reported eight channels for both APAC and Dolby Digital Plus, and the session's rendering mode and spatial audio flags did not distinguish Atmos output either. For diagnosis, the [AtmosAB output probe](../Examples/AtmosAB/README.md#output-probe) reads the session's private current hardware format: `'mat+'` with MAT output, `'lpcm'` without. MAT output is not the receiver's Atmos indication: APAC played without the activator read `'mat+'` throughout while the soundbar showed no Atmos, so only the receiver's indicator confirms Atmos.

## Output format

With the activator, the tested Apple TV switched its HDMI output to Dolby MAT Atmos with 12 output channels. tvOS mixes into 7.1.4 before HDMI, so a 9.1.6 stream still plays but its extra channels are folded: on a soundbar with wide drivers, a 9.1.6 channel sweep played the wides and top middles from neighbouring speakers, the top middles from both the front and rear heights.

The default layout is therefore 7.1.4. In a blind comparison of our 7.1.4 and 9.1.6 renders of seven Dolby demo and film excerpts and a synthetic object circling the room, neither layout was consistently preferred, while 9.1.6 costs a third more bit rate and about half again the encoding time. `.nineOneSix` remains available for routes that keep 16 channels.

## Requesting Atmos output directly

The session also takes a preferred hardware format through the private `-[AVAudioSession setPreferredAudioFormat:error:]`. Requesting `'mat+'` switched the output to MAT Atmos without the silent stream, and the soundbar showed Atmos. In an A/B of the same height channels, though, the heights sounded lower, vaguer and quieter than with the activator. The public `setPreferredOutputNumberOfChannels(_:)` with 12 or 16 channels left the output at 8-channel LPCM. The library keeps the silent stream, which also needs no private API.

## Tested

Apple TV 4K (2nd generation), tvOS 27.2 beta, HDMI to an Atmos receiver:

| Path | Without the activator | With the activator |
|---|---|---|
| `AVPlayer`, APAC file | No Atmos | Atmos; sounds like the Dolby Digital Plus version |
| `AVPlayer`, `APACStream` with Jellyfin video | Not tested | Atmos, with video |
| `AVSampleBufferAudioRenderer`, APAC packets | No Atmos | Atmos; a 7.1.4 channel check played every speaker in its place |

These runs used a near-silent cut from a Dolby encode. The bundled stream replaced it after the comparison described above, with `AVPlayer` and APAC files on the same route.

This is a measured workaround, not an Apple guarantee. Validate each target receiver and OS version. Atmos indication alone does not prove speaker placement, and while tvOS reports Dolby MAT Atmos output, the HDMI payload itself has not been inspected.
