# Media servers

`APACStream` needs two things from a media server: the original file over HTTP range requests, for the audio, and an HLS remux that `AVPlayer` can play, for the video. Jellyfin 12.2 provides both. Emby 4.10 and Plex 1.43 do not; see [Emby and Plex](#emby-and-plex).

## Jellyfin

### The file

The static stream returns the original MKV and honors range requests:

```text
http://jellyfin:8096/Videos/{itemId}/stream?static=true&MediaSourceId={mediaSourceId}&ApiKey={token}
```

Jellyfin 12.2 accepted an API key in the `ApiKey` query parameter and rejected the older `api_key` with 401. Clients that hold a session token can pass it the way they authenticate other stream requests: in the URL, or as a header through `HTTPByteSource(url:headers:)`.

```swift
let file = try await MatroskaFile.open(HTTPByteSource(url: staticStreamURL))
```

`file.audioTracks` lists the tracks in Matroska order. Jellyfin numbers its media streams separately, so match tracks by language, codec and title instead of by index.

### The video

Request an HLS remux that copies the video:

```text
http://jellyfin:8096/Videos/{itemId}/master.m3u8
    ?MediaSourceId={mediaSourceId}&DeviceId={deviceId}&PlaySessionId={newSessionId}
    &VideoCodec=hevc&AllowVideoStreamCopy=true&SegmentContainer=mp4&BreakOnNonKeyFrames=true
    &AudioCodec=aac&AudioStreamIndex={index}&TranscodingMaxAudioChannels=2&AudioBitrate=128000
    &AllowAudioStreamCopy=false&ApiKey={token}
```

- `AllowVideoStreamCopy=true` and `SegmentContainer=mp4` keep 4K HDR HEVC untouched in fragmented MP4, which `AVPlayer` requires for HEVC.
- The server's audio is discarded, so ask for small stereo AAC. `AudioStreamIndex` chooses the track Jellyfin transcodes; a lighter track than TrueHD, such as an AC-3 compatibility track, saves server CPU.
- Use a fresh `PlaySessionId` for each playback.

For HDR titles, Jellyfin's master always adds SDR and H.264 transcoding variants after the stream-copy one. When a stream-copy segment was slow, `AVPlayer` switched to the SDR variant and the server started a full 4K transcode, which slowed everything further. Offer only the stream-copy variant:

```swift
var options = APACStream.Options()
options.includesVideoVariant = { $0.query?.contains("AllowVideoStreamCopy=true") == true }
let stream = try await APACStream.start(file: file, videoMaster: masterURL, startTime: resumePosition,
                                        options: options)
```

With stream copy, Jellyfin cuts video segments at the title's keyframes. The tested 4K encode has a keyframe every 250 frames, so its segments last 10.4 s and weigh about 33 MB; the server's FFmpeg log showed `-codec:v:0 copy`, remuxing at 21× real time. After a seek, `AVPlayer` requests audio from the start of the video segment before the target, so long keyframe intervals mean more audio to convert before playback resumes; see [seeking](avplayer.md#seeking-and-synchronization).

Every variant declared `BANDWIDTH=128000` for a 42 Mbit/s remux, so `AVPlayer` logs error −12318, "Segment exceeds specified bandwidth for variant", for each video segment. Playback over gigabit Ethernet was unaffected. When Jellyfin did not start sending a video segment within about 3–5 s, typically right after rapid seeks, `AVPlayer` paused or stopped requesting media; see [troubleshooting](troubleshooting.md#playback-stays-waiting-after-rapid-seeks).

### Why not the audio-only endpoint

`/Audio/{id}/stream?audioCodec=copy&startTimeTicks=…` remuxes only the audio, but it starts at a cue up to several seconds before the requested time (measured 5.9 s early) and resets timestamps to zero. The host cannot align that with video, so read the original file instead.

## Reading over the network

`MatroskaFile` reads clusters in order and fetches 2 MiB windows, so video bytes are transferred along with the audio: about the file's bitrate, which a local network handles comfortably. Measured from Jellyfin 12.2 on gigabit Ethernet:

| Operation | Result |
|---|---|
| Open a 32.5 GB 4K remux | 2.4 MiB read in 0.5 s |
| Seek to 10:00 | Sync point 48 ms before the target, after 14 MiB and 0.5 s |
| Seek in a DTS:X title with sparse cues | 74 MiB and 2.3 s |
| Seeks across three 4K remuxes | Sync points 21–64 ms before the target |

Over Wi-Fi or a remote connection the transfer rate matters more: conversion stays ahead only while the network delivers the file faster than real time.

## Other servers

Any server works that offers:

1. the original file with HTTP range requests (status 206), and
2. an HLS multivariant playlist whose video `AVPlayer` can play, with segment timestamps that stay on the playlist's timeline when the server restarts its remux after a seek.

### Emby and Plex

Both servers are closed source and the targeted players use Jellyfin, so neither is supported. Tested with Emby 4.10.1 and Plex 1.43.4:

| | Emby | Plex |
|---|---|---|
| Original file | `/emby/Videos/{itemId}/stream.mkv?Static=true&MediaSourceId={mediaSourceId}&api_key={token}`; `X-Emby-Token` also works as a query parameter or header, Jellyfin's `ApiKey` returns 401 | `/library/parts/{partId}/{updatedAt}/file.mkv`, from the item's `Part` key; tested on an unclaimed server, without a token |
| Video playlist | `/emby/Videos/{itemId}/master.m3u8` with the Jellyfin parameters above copies HEVC into fMP4 segments on a fixed 6-second grid | `/video/:/transcode/universal/start.m3u8` copies HEVC only into MPEG-TS segments |
| With `APACStream` on macOS | Plays from the start; fails after Emby restarts its remux | No video |

Converting 10 seconds from 10:00 of a TrueHD Atmos and a DTS:X title over HTTP gave the same APAC from both servers, so a host that plays video itself can feed `SpatialAudioRenderer` from either; that path was not run against them.

**Emby** restarts FFmpeg when a request lies beyond its running remux, as for a resume position or a long seek. The restarted remux begins at the keyframe before the segment, and its fMP4 decode timestamps start at zero. `AVPlayer` places that segment at its playlist time and applies the same offset to the APAC rendition, whose timestamps are absolute: a start at 10:00 jumped to 19:58 and never played. With Emby's own audio, the picture instead trails the playlist clock by the distance to that keyframe, 2.8 s in the test. `BreakOnNonKeyFrames`, `CopyTimestamps` and `SegmentContainer=m4s` did not change the timestamps.

**Plex** rejects `start.m3u8` until the session has requested `/video/:/transcode/universal/decision` with the same parameters. Its built-in tvOS profile transcodes to 1080p H.264. The profile augmentation `X-Plex-Client-Profile-Extra=append-transcode-target-codec(type=videoProfile&context=streaming&protocol=hls&videoCodec=hevc)` makes it copy the HEVC video, but every HLS target in Plex's 79 built-in profiles uses MPEG-TS, and `AVPlayer` played only the audio of the HEVC stream. Plex ignores a container in a profile augmentation and always transcodes for DASH.
