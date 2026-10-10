# Media servers

`APACStream` needs two things from a media server: the original file over HTTP range requests, for the audio, and an HLS remux that `AVPlayer` can play, for the video. Jellyfin 12.2 provides both. Plex and Emby have equivalent endpoints but are untested.

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

```swift
let stream = try await APACStream.start(file: file, videoMaster: masterURL, startTime: resumePosition)
```

Jellyfin's master lists the stream-copy variant first, followed by SDR and H.264 transcoding variants. In testing, `AVPlayer` played the stream-copy variant: the server's FFmpeg log showed `-codec:v:0 copy`, remuxing in 6-second segments at 21× real time. Every variant declared `BANDWIDTH=128000` for a 42 Mbit/s remux, so `AVPlayer` logs error −12318, "Segment exceeds specified bandwidth for variant", for each video segment. Playback over gigabit Ethernet was unaffected.

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
2. an HLS multivariant playlist whose video `AVPlayer` can play.

Plex's direct-play part URLs and Emby's static stream URLs should satisfy the first, and their HLS endpoints the second. Neither is tested yet.
