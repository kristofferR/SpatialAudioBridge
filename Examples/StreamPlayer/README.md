# StreamPlayer

A small tvOS and iOS 26+ player that plays a media server's MKV with its TrueHD Atmos or DTS:X track converted to APAC. It is the end-to-end test for the library's playback paths:

- **AVPlayer (default):** `APACStream` serves the audio beside the server's HLS video, played in `AVPlayerViewController`.
- **Renderer (`SAB_RENDERER=1`):** audio only, through `SpatialAudioRenderer` on an `AVSampleBufferRenderSynchronizer`.

Both modes attach `AtmosOutputActivator` and configure the audio session as in the [Atmos output guide](../../docs/atmos-output.md). On iPhone and iPad the same app tests spatial audio on headphones, such as AirPods: the log shows the audio route and whether it spatializes when playback starts and whenever the route changes, and `SAB_NO_ATMOS=1` leaves out the activator, which only HDMI receivers need.

## Build and install

Running the Core workflow by hand on a branch (`gh workflow run core.yml --ref BRANCH`) builds a
Release tvOS app against that checkout's core and uploads `StreamPlayer-unsigned-tvOS`. Download
it from the run for the exact revision being validated.
It contains no library media or server credentials. Signing and installation happen separately
on the paired device's host, using its existing development identity and provisioning profile;
CI does not receive signing credentials or install anything. An unsigned artifact is not proof
of device playback. This path keeps compilation off a resource-limited development Mac.

On the paired Mac, download and install that artifact without invoking Xcode's build system:

```sh
gh run download RUN_ID --repo kristofferR/SpatialAudioBridge \
  --name StreamPlayer-unsigned-tvOS --dir "/path/to/artifact"
security find-identity -v -p codesigning
xcrun devicectl list devices
xcrun devicectl device info details --device "DEVICE_IDENTIFIER" \
  --json-output "/tmp/stream-player-device.json"
APPLE_TV_UDID="$(plutil -extract result.properties.hardware.udid raw \
  "/tmp/stream-player-device.json" 2>/dev/null || \
  plutil -extract result.hardwareProperties.udid raw "/tmp/stream-player-device.json")"
./Examples/StreamPlayer/sign-and-install.sh \
  "/path/to/artifact/StreamPlayer-unsigned-tvOS.zip" \
  "/path/to/development.mobileprovision" "SIGNING_IDENTITY_SHA1" "$APPLE_TV_UDID"
```

Use the `Identifier` from `list devices` as `DEVICE_IDENTIFIER` to query the hardware UDID.
The displayed identifier may be a CoreDevice UUID; the helper needs the hardware UDID in the profile's
`ProvisionedDevices`. The extraction above supports both current and older device JSON layouts.

Use an existing, unexpired tvOS development profile that includes the Apple TV UDID and permits
`com.kristofferr.SpatialAudioBridge.StreamPlayer` (an exact app ID or a matching wildcard,
such as `PREFIX.*` or `PREFIX.com.kristofferr.*`).
The helper uses the profile's App ID prefix for application/keychain identifiers and keeps its
team identifier separate; older developer accounts may have different values.
The signing identity must have its private key in the local keychain and be included in the
profile. The helper checks the profile's platform, development flag, device and app ID, embeds it,
signs embedded code and the app with concrete development entitlements, verifies the signature,
and installs it. It does not create profiles, export keys, rebuild, publish or launch playback.

### Building locally on a suitable Mac

Use macOS with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), and build the Rust core first with `./scripts/build-core.sh` from the repository root:

```sh
cd Examples/StreamPlayer
SAB_DEVELOPMENT_TEAM="YOUR_TEAM_ID" ./build-and-install.sh "DEVICE_ID"
```

`xcrun devicectl list devices` shows the Apple TV's or iPhone's identifier. The script generates the project, builds with one job and installs the app.

## Run

The app reads its configuration from the launch environment. With `devicectl`, prefix each variable with `DEVICECTL_CHILD_`:

| Variable | Meaning |
|---|---|
| `SAB_SOURCE_URL` | The MKV, reachable with HTTP range requests, such as Jellyfin's static stream URL |
| `SAB_HTTP_HEADER` | Optional header for that URL, such as `Authorization: …` |
| `SAB_VIDEO_MASTER` | Optional HLS master supplying the video; audio-only without it |
| `SAB_VIDEO_VARIANT` | Optional text the chosen video variant's URL must contain; `AllowVideoStreamCopy=true` keeps Jellyfin from switching to a transcode |
| `SAB_START` | Optional start time in seconds |
| `SAB_RENDERER` | `1` to play the audio through `SpatialAudioRenderer` instead of AVPlayer |
| `SAB_SEEK_TEST` | `1` to run a scripted seek test: skips, scrubs and jumps as a remote issues them, each timed until playback resumes |
| `SAB_NO_ATMOS` | `1` to play without `AtmosOutputActivator`, to compare routes that don't need it, such as AirPods |
| `OS_ACTIVITY_DT_MODE` | `enable` to mirror the library's log, such as each segment request and restart, to the console |

For Jellyfin, with an API key in `KEY` and the item and media source ID in `ID` (see [media servers](../../docs/media-servers.md)):

```sh
J="http://jellyfin:8096"
export DEVICECTL_CHILD_SAB_SOURCE_URL="$J/Videos/$ID/stream?static=true&MediaSourceId=$ID&ApiKey=$KEY"
export DEVICECTL_CHILD_SAB_VIDEO_MASTER="$J/Videos/$ID/master.m3u8?MediaSourceId=$ID&DeviceId=stream-player&PlaySessionId=$RANDOM&VideoCodec=hevc&AllowVideoStreamCopy=true&SegmentContainer=mp4&BreakOnNonKeyFrames=true&AudioCodec=aac&TranscodingMaxAudioChannels=2&AudioBitrate=128000&AllowAudioStreamCopy=false&ApiKey=$KEY"
export DEVICECTL_CHILD_SAB_VIDEO_VARIANT="AllowVideoStreamCopy=true"
export DEVICECTL_CHILD_SAB_START=420
xcrun devicectl device process launch --device "DEVICE_ID" --terminate-existing --console \
  com.kristofferr.SpatialAudioBridge.StreamPlayer
```

Keep the key out of shell history and logs. The app prints only file names from player errors, because server URLs carry credentials.

## Diagnostics

The console shows the startup time, each change of the player's state, and a status line every five seconds. From a run with `OS_ACTIVITY_DT_MODE=enable`:

```text
[APACStream] seg1023 restarts conversion; run started at -1, converted -1
[APACStream] seg1023 after 1879 ms
STREAM ready in 2.1953005 seconds: track 2 A_TRUEHD en
[APACStream] seg1024 after 1253 ms
STREAM waiting → playing after 4.04 s at t=3274.0
STREAM t=3275.0 rate=1.0 item=1 silentAtmos=on conversion=2.27x footprint=212 MB available=2165 MB errors=-12318 541.mp4 Segment exceeds specified bandwidth for variant
```

- `t`, `rate` and `item` are the player's time, rate and item status (1 is ready).
- `silentAtmos` is `AtmosOutputActivator.isActive`.
- `conversion` is `APACStream.conversionSpeed`. Below about 1.2, playback will stall.
- `footprint` is the process's physical footprint, the figure the system's memory limit applies to; `available` is what the app may still allocate, from `os_proc_available_memory()`. A steady footprint means no growth.
- `errors` are the item's last two error log entries. Jellyfin's −12318 is harmless; see [troubleshooting](../../docs/troubleshooting.md).
- Each state change is logged with how long the previous state lasted, which measures seek recovery.

About ten seconds after startup the app logs `durations:` for the source file, the audio and video playlists and the player item, and `ended at` when the item plays to its end, so an early or late ending can be traced to one of them.

In renderer mode, lines report the synchronizer's time and rate and the renderer's status (1 is rendering).

The app also shows a recovery a host may want. After rapid seeks, `AVPlayer` sometimes waited indefinitely, after Jellyfin aborted a video segment mid-response or after `AVPlayer` dropped a connection. If the player waits for more than 20 s, the app replaces the item at the pending seek target, or at the current position when none is pending, and logs `recovering a stalled item`. It learns the remote's seek targets from `AVPlayerViewControllerDelegate`. The wedge appeared in four of eight scripted runs. On the device, the app recovered one at the pending target, playing 0.25 s after replacing the item.

`AVPlayer` gives up differently when the server is unreachable: it waits, then pauses, or fails the item. The app treats a failed item, or a pause that directly follows a wait while requests are failing, as stopped playback; a viewer's pause during a wait stays. It logs `playback stopped`, reloads the item where it stopped after 5 s, then 10, 20 and 40 s between attempts, and logs `resumed` once it plays again. If `APACStream.failure` reports that conversion itself failed, it logs `stream failed` with that error and stops instead, since a reload cannot recover it.

An Apple TV that goes to sleep suspends the app mid-run, which looks like a hang: the log simply stops. Wake it before testing; `devicectl` then reports "System is asleep" on launch.
