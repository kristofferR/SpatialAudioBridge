# StreamPlayer for Apple TV

A small tvOS 26+ player that plays a media server's MKV with its TrueHD Atmos or DTS:X track converted to APAC. It is the end-to-end test for the library's playback paths:

- **AVPlayer (default):** `APACStream` serves the audio beside the server's HLS video, played in `AVPlayerViewController`.
- **Renderer (`SAB_RENDERER=1`):** audio only, through `SpatialAudioRenderer` on an `AVSampleBufferRenderSynchronizer`.

Both modes attach `AtmosOutputActivator` and configure the audio session as in the [Atmos output guide](../../docs/atmos-output.md).

## Build and install

Use macOS with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), and build the Rust core first with `./scripts/build-core.sh` from the repository root. Supply a near-silent Dolby Atmos stream ([how to make one](../../docs/atmos-output.md#make-a-silent-atmos-stream)):

```sh
cd Examples/StreamPlayer
SAB_DEVELOPMENT_TEAM="YOUR_TEAM_ID" ./build-and-install.sh "DEVICE_ID" "/path/to/silent-atmos.mp4"
```

`xcrun devicectl list devices` shows the Apple TV's identifier. The script copies the stream into the ignored `Media` folder, generates the project, builds with one job and installs the app.

## Run

The app reads its configuration from the launch environment. With `devicectl`, prefix each variable with `DEVICECTL_CHILD_`:

| Variable | Meaning |
|---|---|
| `SAB_SOURCE_URL` | The MKV, reachable with HTTP range requests, such as Jellyfin's static stream URL |
| `SAB_HTTP_HEADER` | Optional header for that URL, such as `Authorization: …` |
| `SAB_VIDEO_MASTER` | Optional HLS master supplying the video; audio-only without it |
| `SAB_START` | Optional start time in seconds |
| `SAB_RENDERER` | `1` to play the audio through `SpatialAudioRenderer` instead of AVPlayer |

For Jellyfin, with an API key in `KEY` and the item and media source ID in `ID` (see [media servers](../../docs/media-servers.md)):

```sh
J="http://jellyfin:8096"
export DEVICECTL_CHILD_SAB_SOURCE_URL="$J/Videos/$ID/stream?static=true&MediaSourceId=$ID&ApiKey=$KEY"
export DEVICECTL_CHILD_SAB_VIDEO_MASTER="$J/Videos/$ID/master.m3u8?MediaSourceId=$ID&DeviceId=stream-player&PlaySessionId=$RANDOM&VideoCodec=hevc&AllowVideoStreamCopy=true&SegmentContainer=mp4&BreakOnNonKeyFrames=true&AudioCodec=aac&TranscodingMaxAudioChannels=2&AudioBitrate=128000&AllowAudioStreamCopy=false&ApiKey=$KEY"
export DEVICECTL_CHILD_SAB_START=420
xcrun devicectl device process launch --device "DEVICE_ID" --terminate-existing --console \
  com.kristofferr.SpatialAudioBridge.StreamPlayer
```

Keep the key out of shell history and logs. The app prints only file names from player errors, because server URLs carry credentials.

## Diagnostics

The console shows the startup time, then a line every five seconds:

```text
STREAM ready in 2.36 seconds: track 2 A_TRUEHD en
STREAM t=476.2 rate=1.0 item=1 silentAtmos=on conversion=2.63x available=1630 MB errors=-12318 69.mp4 Segment exceeds specified bandwidth for variant
STREAM playing → waiting after 82.31 s at t=1468.5
```

- `t`, `rate` and `item` are the player's time, rate and item status (1 is ready).
- `silentAtmos` is `AtmosOutputActivator.isActive`.
- `conversion` is `APACStream.conversionSpeed`. Below about 1.2, playback will stall.
- `available` is the memory the app may still allocate, from `os_proc_available_memory()`. A steady value means no growth.
- `errors` are the item's last two error log entries. Jellyfin's −12318 is harmless; see [troubleshooting](../../docs/troubleshooting.md).
- Each wait for media is logged with how long the previous state lasted, which measures seek recovery.

In renderer mode, lines report the synchronizer's time and rate and the renderer's status (1 is rendering).
