# Play through AVPlayer

`APACStream` serves a Matroska file's TrueHD Atmos or DTS:X track to `AVPlayer` as an HLS audio rendition. It converts on demand, so the player can start anywhere and seek freely. Given the media server's video playlist, it adds APAC as the video's audio and returns one URL for an `AVPlayerItem`.

Use this path when the host already plays video with `AVPlayer` or `AVPlayerViewController`, such as Swiftfin's native player.

## Requirements

- tvOS 26 or later.
- The MKV, reachable as a local file or over HTTP with range requests, such as a media server's direct-play URL. M2TS and MP4 sources need the host's demuxer and the [conversion API](conversion.md).
- For video, an HLS multivariant playlist that `AVPlayer` can play, such as a media server's remux. [Media servers](media-servers.md) shows how to request one from Jellyfin.
- App Transport Security settings that allow the loopback playlist. The example app uses `NSAllowsLocalNetworking`, plus `NSAllowsArbitraryLoadsForMedia` for a plain-HTTP media server.
- A near-silent Dolby Atmos stream for `AtmosOutputActivator`; see [Atmos output](atmos-output.md).

## Play

```swift
import AVFoundation
import SpatialAudioBridge
import SpatialAudioPlayback

@MainActor final class SpatialPlayback {
    let player = AVPlayer()
    private var stream: APACStream?
    private var atmos: AtmosOutputActivator?

    func play(directPlay: URL, videoMaster: URL, headers: [String: String], from start: CMTime) async throws {
        try AtmosOutputActivator.configureAudioSession()
        let file = try await MatroskaFile.open(HTTPByteSource(url: directPlay, headers: headers))
        // Converts the segment at `start` before returning, so unsupported tracks fail here.
        let stream = try await APACStream.start(file: file, videoMaster: videoMaster,
                                                videoHeaders: headers, startTime: start)
        let silence = Bundle.main.url(forResource: "silent-atmos", withExtension: "mp4")!
        let atmos = AtmosOutputActivator(silentAtmosStream: silence)
        atmos.attach(to: player) // the master offers only APAC audio
        player.replaceCurrentItem(with: AVPlayerItem(url: stream.masterPlaylistURL!))
        await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        (self.stream, self.atmos) = (stream, atmos)
    }

    func stop() async {
        player.replaceCurrentItem(with: nil)
        atmos?.detach()
        await stream?.stop()
    }
}
```

On failure, `start` throws a `SpatialAudioError` and the host plays the item through its usual path. [StreamPlayer](../Examples/StreamPlayer/README.md) is a complete tvOS app built this way.

## Choose the track

By default the stream converts the first default TrueHD or DTS track, otherwise the first one. To honor the user's language or track choice, pick one from `file.audioTracks`:

```swift
let track = file.audioTracks.first { $0.codec != nil && $0.language == "de" }
let stream = try await APACStream.start(file: file, track: track, videoMaster: videoMaster)
```

`codec` is nil for tracks the library cannot convert. A TrueHD track's Atmos metadata, or a DTS track's DTS:X presentation, is only verified once decoding starts, which `start` does. To switch tracks during playback, stop the stream and start a new one at the current time.

## What the stream serves

The stream listens on `127.0.0.1` at a random port, under a random path, and serves:

| Path | Content |
|---|---|
| `master.m3u8` | The video master with the APAC rendition as every variant's audio. Only when `videoMaster` was given. |
| `audio.m3u8` | A VOD playlist of 3.2-second segments covering the whole file. Use it for audio-only playback. |
| `init.mp4`, `seg<N>.m4s` | One shared initialization segment and the media segments, converted on request. |

The master rewrite removes the server's audio renditions, replaces audio codecs in each variant's `CODECS` with `apac.31.04` (or `apac.31.03` for 7.1.4), adds the APAC bit rate to `BANDWIDTH`, and makes every URI absolute, so video segments still load directly from the server. Subtitle renditions are kept. The server's video variants may still carry muxed audio; `AVPlayer` plays the APAC rendition instead.

## Seeking and synchronization

Seek the player as usual. A segment request inside the converted range is served at once. A request outside it starts a new conversion run at that segment, which arrives once the run converts 3.2 s of audio and the encoder's 1.6 s live delay. Segments lie on a fixed grid, so every run produces the same timestamps and audio keeps its place on the video timeline after any seek. [Architecture](architecture.md#timing) explains the grid.

Pass the intended start position as `startTime`, so the first segment is ready when `AVPlayer` asks for it, and seek exactly (`toleranceBefore: .zero`) before playing.

## Options

```swift
var options = APACStream.Options()
options.configuration = APACConfiguration(layout: .sevenOneFour) // 12 channels at 3.072 Mbit/s
options.renditionName = "Dolby Atmos (Spatial Audio)"
options.lookahead = 6              // segments converted ahead of the newest request
options.segmentTimeout = .seconds(30)
let stream = try await APACStream.start(file: file, videoMaster: videoMaster, options: options)
```

The stream manages start times and always uses the live encoding profile, whatever `configuration` says. The default 9.1.6 layout uses 4.096 Mbit/s. A larger `lookahead` buffers more conversion ahead at about 1.6 MB per segment.

## Monitor

`await stream.conversionSpeed` reports seconds of audio converted per second of work since the latest start or seek, excluding time spent waiting for the player. Below about 1.2, playback will stall. `AVPlayerItem.errorLog()` names the failing segment; see [troubleshooting](troubleshooting.md) for common entries.

A track can also carry unsupported metadata partway through. The failed run returns an HTTP error for its segment, and `AVPlayer` reports a stall or item failure. Treat a failed item as a reason to fall back.

## Measured on Apple TV

Apple TV 4K (2nd generation), tvOS 27.2 beta, Jellyfin 12.2 over gigabit Ethernet, a 4K HDR10 HEVC remux with TrueHD Atmos 7.1, converted to 9.1.6:

| Measure | Result |
|---|---|
| `MatroskaFile.open` and `APACStream.start` at 7:00 | 2.4–2.5 s |
| Conversion speed | 2.6–2.7× real time, steady |
| Receiver | Dolby Atmos with `AtmosOutputActivator`; video and audio played together |

## Limits

- One audio track per stream; video on demand only.
- The stream needs the file's duration, which Matroska files declare.
- The host's media server must accept range requests. Its audio-only remux endpoints are unsuitable, because they start early and reset timestamps; see [media servers](media-servers.md).
- APAC requires an appropriate Apple playback route. Software PCM output cannot carry it.
