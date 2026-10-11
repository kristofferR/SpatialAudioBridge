# Play through AVPlayer

`APACStream` serves a Matroska file's TrueHD Atmos or DTS:X track to `AVPlayer` as an HLS audio rendition. It converts on demand, so the player can start anywhere and seek freely. Given the media server's video playlist, it adds APAC as the video's audio and returns one URL for an `AVPlayerItem`.

Use this path when the host already plays video with `AVPlayer` or `AVPlayerViewController`, such as Swiftfin's native player.

## Requirements

- tvOS 26 or later.
- The MKV, reachable as a local file or over HTTP with range requests, such as a media server's direct-play URL. M2TS and MP4 sources need the host's demuxer and the [conversion API](conversion.md).
- For video, an HLS multivariant playlist that `AVPlayer` can play, such as a media server's remux. [Media servers](media-servers.md) shows how to request one from Jellyfin.
- App Transport Security settings that allow the loopback playlist. The example app uses `NSAllowsLocalNetworking`, plus `NSAllowsArbitraryLoadsForMedia` for a plain-HTTP media server.

`AtmosOutputActivator` brings its own silent Atmos stream; see [Atmos output](atmos-output.md).

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
        let atmos = AtmosOutputActivator()
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

`videoHeaders` authorizes only the request for the master playlist inside `start`. `AVPlayer` then loads the variant playlists and video segments itself, without those headers, so the master and every URL it references must authenticate on their own, for example with Jellyfin's `ApiKey` parameter.

On failure, `start` throws a `SpatialAudioError` and the host plays the item through its usual path. [StreamPlayer](../Examples/StreamPlayer/README.md) is a complete tvOS app built this way.

## Choose the track

By default the stream converts the first default TrueHD or DTS track, otherwise the first one. To honor the user's language or track choice, pick one from `file.audioTracks`:

```swift
guard let track = file.audioTracks.first(where: { $0.codec != nil && $0.language == "de" }) else {
    return playThroughUsualPath() // no convertible track in the chosen language
}
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
| `subtitles/<N>.m3u8`, `subtitles/<N>/<M>.vtt` | The master's subtitle playlists and their whole WebVTT segments, fetched from the server on request without headers. Other subtitle segments load directly from the server. |

The master rewrite removes the server's audio renditions, replaces audio codecs in each variant's `CODECS` with `apac.31.03` (or `apac.31.04` for 9.1.6), adds the APAC bit rate to `BANDWIDTH`, and makes every URI absolute, so video segments still load directly from the server. Subtitle renditions are kept but served through the stream. Jellyfin's WebVTT segments map their cues for its MPEG-TS output (`X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000`), which showed every cue 10 s late against stream-copy fMP4 video; the stream changes that map to `MPEGTS:0`, so cues count from the start of the timeline that APAC and the video share. Other maps are kept, and other subtitle formats, such as IMSC1, and byte-range segments load directly from the server as before. Like the video playlists, subtitle URLs must authenticate on their own. To select a subtitle rendition, use its position or its `commonMetadata` title, which is the rendition's `NAME`: on macOS 27, `AVMediaSelectionOption.displayName` gave the language ("English") for all three of Jellyfin's. The server's video variants may still carry muxed audio; `AVPlayer` plays the APAC rendition instead.

## Seeking and synchronization

The APAC rendition starts at media time 0, so the video variants must too, as Jellyfin's stream-copy fMP4 remux does; video on another timeline, such as MPEG-TS starting at 10 s, would play out of sync. Seek the player as usual. Segments lie on a fixed grid, so every conversion run produces the same timestamps and audio keeps its place on the video timeline after any seek. [Architecture](architecture.md#timing) explains the grid.

- Segments already converted are served at once: the lookahead ahead of the playhead, and the last 20 segments (about 64 s) behind it, so skipping back over recent audio is immediate.
- Other requests start a new conversion run, whose first segment arrives about 2 s later and each following one about 0.7 s apart on Apple TV 4K (2nd generation), 1 s apart at 9.1.6. The stream restarts instead of waiting whenever that is sooner, because `AVPlayer` abandons a seek whose first segment takes more than about 3 s. Once the first segment is ready, a second run converts from 5 segments ahead at the same time, so the segments `AVPlayer` asks for next are often ready; see [concurrency](architecture.md#concurrency-bounds-and-failure).
- While scrubbing, `AVPlayer` requests a segment at each intermediate position. Each restarts conversion, and requests a later restart replaced are answered with status 503 at once.
- A gap or reset in the track's own timestamps ends the stream with an error. Conversion times audio by its samples, so it cannot keep audio aligned past the jump; the host falls back as for any other conversion failure.

After a seek, `AVPlayer` asks for audio from the start of the video segment before the target, so the time to resume depends on the video. With Jellyfin's stream-copy remux of a title with 10.4-second keyframe intervals, that meant up to 20 s of audio before the target: short skips resumed after 6–7.5 s and scrubs and long jumps after 5.5–12.5 s. At 9.1.6, long jumps took 9–11 s with the helper run and 11–14 s before it, and on a remux with keyframes under a second apart, 5–8 s. Skips within already converted audio resumed after 1–1.5 s.

Pass the intended start position as `startTime`, so the first segment is ready when `AVPlayer` asks for it, and seek exactly (`toleranceBefore: .zero`) before playing.

## Options

```swift
var options = APACStream.Options()
options.configuration.layout = .nineOneSix // 16 channels at 4.096 Mbit/s instead of 7.1.4
options.renditionName = "Dolby Atmos (Spatial Audio)"
options.lookahead = 6              // segments converted ahead of the newest request
options.keptBehind = 20            // played segments kept for skipping back
options.segmentTimeout = .seconds(30)
// Offer only the server's stream-copy variant, never its transcoding fallbacks.
options.includesVideoVariant = { $0.query?.contains("AllowVideoStreamCopy=true") == true }
let stream = try await APACStream.start(file: file, videoMaster: videoMaster, options: options)
```

The stream manages start times and always uses the live encoding profile, whatever `configuration` says. The default 7.1.4 layout uses 3.072 Mbit/s, about 1.2 MB per segment, so the defaults keep at most about 42 MB of converted audio; 9.1.6 raises that to about 56 MB. Apple TV folds 9.1.6 into 12 channels; see [Atmos output](atmos-output.md#output-format).

`includesVideoVariant` matters with media servers that add transcoding variants. When a stream-copy video segment was slow, `AVPlayer` switched to Jellyfin's SDR variant and the server started a full 4K transcode. `start` throws when no variant remains.

## Monitor

`await stream.conversionSpeed` reports seconds of audio converted per second of work since the latest start or seek, excluding time spent waiting for the player. Below about 1.2, playback will stall. `AVPlayerItem.errorLog()` names the failing segment; see [troubleshooting](troubleshooting.md) for common entries.

The stream logs each segment request, restart and wait time to the unified log under subsystem `SpatialAudioBridge`, category `APACStream`. View them in Console, or set `OS_ACTIVITY_DT_MODE=enable` in the app's environment to mirror them to its standard error:

```text
[APACStream] seg1023 restarts conversion; run started at -1, converted -1
[APACStream] seg1023 after 1879 ms
[APACStream] seg1024 after 1253 ms
```

A track can also carry unsupported metadata partway through. The failed run returns an HTTP error for its segment, and `AVPlayer` reports a stall or item failure. Treat a failed item as a reason to fall back.

## Measured on Apple TV

Apple TV 4K (2nd generation), tvOS 27.2 beta, Jellyfin 12.2 over gigabit Ethernet, a 4K HDR10 HEVC remux with TrueHD Atmos 7.1, converted to the default 7.1.4:

| Measure | Result |
|---|---|
| `MatroskaFile.open` and `APACStream.start` | 1.8–2.4 s |
| Launch to playing | 4.3–6.6 s |
| Conversion | About 6× real time in steady playback; 0.7 s per 3.2-second segment, 4.5×, while video loads after a seek (9.1.6: 1 s, 3.2×); Debug and Release alike |
| Memory | No growth: available memory stayed within 2,139–2,174 MB over a 22-minute session, and 2,135–2,171 MB across 9.1.6 sessions of up to 16 minutes |
| Seeks | Recovered from every skip, scrub and jump in a scripted test; times above |
| Receiver | Dolby Atmos with `AtmosOutputActivator`; video and audio played together |

## Limits

- One audio track per stream; video on demand only.
- The stream needs the file's duration, which Matroska files declare. The audio playlist lasts that long, so a track that ends before the video ends in silence.
- The host's media server must accept range requests. Its audio-only remux endpoints are unsuitable, because they start early and reset timestamps; see [media servers](media-servers.md).
- APAC requires an appropriate Apple playback route. Software PCM output cannot carry it.
