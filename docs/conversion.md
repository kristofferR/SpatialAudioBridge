# Convert and package APAC

The conversion API turns compressed TrueHD Atmos or DTS:X into APAC files or fragmented MP4. `APACStream` and `SpatialAudioRenderer` are built on it. Use it directly to convert files, to feed packets from the host's own demuxer, or to build a custom HLS presentation.

## Convert a file

```swift
let report = try await APACTrackConverter.convert(
    elementaryStream: URL(fileURLWithPath: "movie.thd"),
    codec: .trueHDAtmos, // or .dtsX
    output: URL(fileURLWithPath: "movie.apac.mp4")
)
print(report.duration, report.layout.channelCount, report.peakPCM)
```

Input is a demuxed elementary stream, such as FFmpeg's `-c copy -f truehd` output. DTS input must include both its core and DTS-HD extensions.

## Stream packets

`SpatialAudioTranscoder` accepts compressed bytes incrementally:

```swift
let audio = try SpatialAudioTranscoder(
    codec: .trueHDAtmos,
    destination: .file(outputURL),
    configuration: APACConfiguration(layout: .sevenOneFour, startTime: firstAudioPTS)
)
for try await packet in demuxedAudioPackets {
    try await audio.append(packet.data)
}
let report = try await audio.finish()
```

- **Input.** Pass only the selected track's payloads, in order and without container framing. Chunk boundaries do not matter: the decoded audio is bit-identical whether bytes arrive in 4096- or 317-byte pieces.
- **Start.** Begin at a TrueHD major sync or a DTS core sync. TrueHD may start at any later major sync, such as one reached by a seek: audio before the first object metadata, usually 7.5–20 ms, is held and rendered at the first known object positions.
- **Timing.** Output timestamps start at `startTime` and advance by decoded samples, without drift.
- **Seeking.** A seek, timestamp gap or format change needs a new session. A seek normally lands on a sync point before the target; set `inputStartTime` to that packet's time and `startTime` to the target, and the session discards audio before the target:

  ```swift
  var configuration = APACConfiguration(startTime: target)
  configuration.inputStartTime = firstPacket.time
  ```

  A source starting after `startTime` is padded with silence instead.
- **Backpressure.** Await each call. `append` suspends while Apple's writer catches up and rejects overlapping calls.
- **Ending.** `finish()` flushes and returns an `APACConversionReport`. `cancel()` or cancelling the task ends the session without output. Any failure is terminal: create a new session to recover.

### Read packets from Matroska

`MatroskaFile` provides those packets for MKV and MKA files, without a host demuxer:

```swift
let file = try await MatroskaFile.open(HTTPByteSource(url: directPlayURL, headers: authorization))
guard let track = file.audioTracks.first(where: { $0.codec != nil }), let codec = track.codec else { return }
var audio: SpatialAudioTranscoder?
for try await packet in file.packets(of: track, from: target) {
    if audio == nil {
        var configuration = APACConfiguration(startTime: target)
        configuration.inputStartTime = packet.time
        audio = try SpatialAudioTranscoder(codec: codec, destination: .file(outputURL), configuration: configuration)
    }
    try await audio?.append(packet.data)
}
```

`packets(of:from:)` starts at the last sync point at or before `from` and reports each frame's container time and whether it is a sync point. The reader handles header-stripping compression and Xiph, EBML and fixed lacing. It rejects encrypted or zlib-compressed tracks. Seeks start from the cue two seconds before the target, because audio is interleaved near, not exactly at, video keyframes. `FileByteSource` reads local files and `HTTPByteSource` sends range requests with optional headers. Implement `MediaByteSource` for other storage.

## Write HLS

`APACHLSOutput` persists fragments and an EVENT playlist into a new directory:

```swift
let configuration = APACConfiguration(layout: .nineOneSix, startTime: firstAudioPTS)
let hls = try APACHLSOutput(directory: newDirectoryURL, configuration: configuration)
let audio = try SpatialAudioTranscoder(codec: .trueHDAtmos, destination: hls.destination,
                                       configuration: configuration)
for try await packet in demuxedAudioPackets { try await audio.append(packet.data) }
_ = try await audio.finish()
try hls.finish()
// Serve hls.playlistURL with init.mp4 and the .m4s fragments beside it.
```

To handle fragments in memory, use `.segments(syncPeriodsPerSegment:onSegment:)` as the destination. The callback runs serially on an AVFoundation queue; each `APACSegment` carries the bytes, kind, coded start time and duration. A thrown error ends the session. Segments last a whole number of APAC sync periods, 3.2 s by default, so each starts with a sync packet and can be decoded independently.

In the multivariant playlist, list `layout.apacCodecString` (`apac.31.04` for 9.1.6, `apac.31.03` for 7.1.4) in the variant's `CODECS` and `layout.channelCount` as the rendition's `CHANNELS`. Do not label this channel-based output as JOC. `APACStream` shows a complete arrangement, including restarts that keep segments on one timeline; see [Architecture](architecture.md#the-segment-grid).

## Configuration

| Property | Default | Notes |
|---|---|---|
| `layout` | `.nineOneSix` | `.sevenOneFour` for 12 channels |
| `bitRate` | 256 kbit/s per channel, at most 4.096 Mbit/s | 4.096 Mbit/s for 9.1.6, 3.072 Mbit/s for 7.1.4 |
| `gainDB` | 0 | −60 to +12 dB, applied before encoding. No normalization or limiting. |
| `startTime` | zero | Presentation time of the first output sample |
| `inputStartTime` | nil | Container time of the first input packet, after a seek |
| `syncPacketFrequency` | 75 | APAC packets between sync packets: 1.6 s at 48 kHz |
| `liveEncoding` | false | The live profile trails input by about 1.6 s instead of about 20 s; see [live and offline encoding](architecture.md#live-and-offline-encoding) |

Offline encoding uses the `AppleAV_Spatial_Offline` content source with Movie dynamic range; live encoding uses `AppleAV_Spatial_Live` with Capture. On macOS 27.0.1 the generic `AV_Spatial_Offline` source failed `canApply`, while the Apple spatial sources succeeded for both layouts. Recheck this on target OS versions.

The encoder has three effort tiers at the same bit rate. Medium matched the default high tier on real Atmos content (48.4 against 47.0 dB signal-to-error on a film) and encodes 1.25 to 1.5 times as fast; low is three times as fast but lost up to 42 dB on height-only content. `AVAssetWriter` ignores the quality setting for APAC, so files and HLS fragments use the default tier, while `SpatialAudioRenderer` uses medium.

`report.peakPCM` is the largest sample before encoding. Values above 1 exceed full scale; lower `gainDB` if that matters for the material.

## Encoder priming

`configuration.encoderPrimingDuration()`, also exposed as `APACHLSOutput.encoderPrimingDuration`, queries the installed encoder: 2048 frames (42.7 ms) on tested systems. MP4 files trim it from the presented duration. Fragmented output keeps it in the coded timeline, so segment durations add up to the source duration plus the priming, and the first fragment starts at `startTime` minus the priming. With a zero `startTime`, timestamps cannot go below zero, so audio lands one priming duration late. Apple's decoder trims the priming. Fragments cannot trim the final packet's padding, so decoded audio ends on a 1024-frame boundary: up to 21 ms of silence after the last source sample. MP4 files trim both.

## Command line

`apac-convert` wraps the same API:

```sh
swift run -j 1 apac-convert truehd movie.thd movie.apac.mp4
swift run -j 1 apac-convert dtsx movie.dts movie.apac.mp4
swift run -j 1 apac-convert mkv movie.mkv excerpt.apac.mp4 --start 600 --duration 30
swift run -j 1 apac-convert mkv "http://jellyfin:8096/Videos/ID/stream?static=true&ApiKey=…" excerpt.apac.mp4 --track 2
```

For servers that authenticate with a header, set it in `SAB_HTTP_HEADER`, such as `SAB_HTTP_HEADER="Authorization: …"`.

The `mkv` mode lists the audio tracks, then reports the bytes read and the time taken to open the file and to reach the first packet, which is useful for checking a server's range support.

## Specifications

Apple requires profile and level in HLS codec strings in its [HLS authoring specification](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html), and describes APAC and its sync packets in the [APAC technical note](https://developer.apple.com/av-foundation/Apple-Positional-Audio-Codec.pdf). The codec strings follow the platform encoder's channel-count mapping. Object metadata timing follows [ETSI TS 103 448](https://www.etsi.org/deliver/etsi_ts/103400_103499/103448/01.01.01_60/ts_103448v010101p.pdf): update offsets in units of 32 samples, and gain ramps lasting the signalled duration plus one sample.
