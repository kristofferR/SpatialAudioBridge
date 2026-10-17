# Troubleshooting

## The receiver does not show Atmos

- Attach `AtmosOutputActivator` and check `isActive` while APAC plays. If it is false, check `error`, and for `AVPlayer` check that the `playsAPAC` predicate returns true for the item.
- With your own stream in `init(silentAtmosStream:)`, check that it signals Atmos: `ffprobe` should report `profile=Dolby Digital Plus + Dolby Atmos`. See [Atmos output](atmos-output.md#the-bundled-stream).
- Check that the receiver shows Atmos for Atmos content in other Apple TV apps. The Apple TV sends the same Dolby MAT output for both.
- In Apple TV settings, keep the audio format on Auto with Change Format off, and Dolby Atmos enabled.
- Do not rely on `AVAudioSession` channel counts, spatial audio flags or the private hardware format to detect Atmos; on tvOS 27.2 none of them tracked the receiver's indicator.

## `APACStream.start` or a session throws

`SpatialAudioError` explains the cause. Fall back to the host's usual audio path for any of these:

| Error | Meaning |
|---|---|
| `.decoding("… is not yet supported")`, naming objects outside the room, bed distribution, bed downmix, ISF or multiple beds, or `.decoding("Reserved Atmos zone constraint")` or `"Reserved Atmos warp mode"` | The track uses metadata this renderer does not support. |
| `.decoding("This TrueHD stream has no Atmos presentation")` | Plain TrueHD without Atmos. |
| `.decoding("Atmos presentation has no object metadata within 0.5 s")` | The stream started without object metadata; possibly damaged or not a standard Atmos stream. |
| `.decoding("The initial Atmos renderer supports 48 kHz tracks")` | A 96 kHz or other non-48 kHz track. |
| `.decoding("This stream is not lossless DTS:X")` | DTS core, DTS-HD High Resolution or DTS-HD MA without DTS:X. |
| `.decoding("Unknown DTS:X presentation")`, `"…source role does not match its presentation"` or `"…unknown bed fold…"` | A DTS:X presentation this renderer does not recognize, or metadata that does not match it. |
| `.source("The file has no TrueHD or DTS track")` | No convertible track; check `file.audioTracks`. |
| `.source("The file does not declare its duration")` | `APACStream` needs the duration for its VOD playlist. |
| `.source("Could not load the video playlist")` | The video master URL failed or did not return a playlist; check its authorization. |
| `.source(…)` from `HTTPByteSource` | The server rejected the request or ignored the range. Server errors (5xx), timeouts and lost connections arrive as `URLError` instead. It must answer range requests with status 206. |

To skip a track the next time it plays, remember only `.decoding` errors: they describe the track, so every later attempt fails the same way. `.source`, `.encoding`, `.coreMedia` and `URLError` failures can come from the network, a timestamp jump or the encoder, so fall back for that playback only.

Jellyfin 12.2 returns 401 for the older `api_key` query parameter; use `ApiKey` or a header.

## AVPlayer error log entries

| Code | Meaning |
|---|---|
| −12318 "Segment exceeds specified bandwidth for variant" on video segments | The server's master understates its bitrate. Jellyfin declares 128 kbit/s for a 4K remux. Harmless on a fast network. |
| −12889 "No response for media file" on `seg<N>.m4s` | Conversion did not deliver the segment in time. Check `conversionSpeed`; below about 1.2, the device, the network or the server cannot keep up. |
| −12889 on video segments | The media server is slow to remux, often right after a seek. `AVPlayer` may pause or stop requesting media; see below. |
| −12880 "Can not proceed after removing variants" | `AVPlayer` gave up on every variant, usually after the first segment of a seek timed out. With a media server's transcoding variants offered, it may first have switched to one of them; offer only the stream-copy variant with `includesVideoVariant`. |
| HTTP 500 for `seg<N>.m4s` | Conversion failed, usually from unsupported metadata, malformed Matroska data or a jump in the track's timestamps partway through. Such failures end the stream, so later requests fail too: fail the item and fall back to the host's audio path. After a lost connection or a server error, the next request starts a new run. |
| HTTP 503 for `seg<N>.m4s` | A later request restarted conversion elsewhere, such as the next scrub position. Expected while scrubbing. |
| HTTP 410 | The stream was stopped; requests that arrive afterwards are refused. |

The stream's own log, subsystem `SpatialAudioBridge`, category `APACStream`, shows each request, restart and wait time. See [Monitor](avplayer.md#monitor).

## Playback stalls

Playback needs conversion faster than real time. Apple TV 4K (2nd generation) converts TrueHD Atmos to the default 7.1.4 at about 6× real time in steady playback and 4.5× while video loads after a seek, and to 9.1.6 at about 3.2× after a seek. Over Wi-Fi, the Matroska reader also transfers the video bytes, so the network must deliver the file faster than its bitrate.

## Seeks take several seconds

After a seek, `AVPlayer` asks for audio from the start of the video segment before the target, and each segment that is not yet converted costs about 0.7 s on Apple TV 4K (2nd generation) at 7.1.4, 1 s at 9.1.6. Titles with long keyframe intervals, whose stream-copy video segments are long, therefore take longest: 5.5–12.5 s with 10.4-second segments. Skips within the last minute of played audio, or within the lookahead, resume in 1–1.5 s. See [seeking](avplayer.md#seeking-and-synchronization).

## Playback stays waiting after rapid seeks

Three quick skips back sometimes left `AVPlayer` waiting indefinitely without requesting anything more, while the stream kept answering, and seeking again did not help. In one run Jellyfin had aborted a video segment mid-response (`The response has already started` in its log); in another, `AVPlayer` reset the connection while an audio segment was being sent.

Recover in the host: when the player has waited 20 s, replace the item and seek it to the pending seek target, or to the current position when no seek is pending. On the tested title, legitimate waits after a seek lasted up to 15 s, so 20 s does not cut a slow seek short. On tvOS, `AVPlayerViewControllerDelegate`'s `playerViewController(_:timeToSeekAfterUserNavigatedFrom:to:)` reports the remote's seek targets. [StreamPlayer](../Examples/StreamPlayer/README.md) does this. On an Apple TV it recovered a wedge at the pending target, playing 0.25 s after replacing the item. An earlier version, which reloaded at the stuck position, also recovered one but lost the pending target. A player's own stall handling can do the same.

## Other audio stutters

With the activator loaded, direct Dolby Digital Plus playback stuttered. The activator unloads its stream for items the predicate rejects; make sure it returns false for them.

## Audio is out of sync

- With `APACStream`, audio and video share the media timeline after every seek. Check the receiver's and TV's audio delay settings first.
- With a custom HLS presentation, set `startTime` to the first audio presentation time and keep the fragment timestamps. A zero `startTime` makes audio one priming duration (42.7 ms) late; see [encoder priming](conversion.md#encoder-priming).
- With `SpatialAudioRenderer`, call `begin(at:)` with the time the synchronizer starts from.

## The first fragment takes 20 seconds

`SpatialAudioTranscoder` uses Apple's offline profile by default, which analyzes about 20 s ahead. Set `liveEncoding = true` for playback; see [live and offline encoding](architecture.md#live-and-offline-encoding).

## Seeking reads a lot of data

The Matroska reader seeks to the cue two seconds before the target, then reads forward. Files with sparse cues need more: one DTS:X remux read 74 MiB for a seek. Remuxing the file with a cue at every video keyframe fixes it.

## The loopback playlist does not load

Allow local networking in App Transport Security (`NSAllowsLocalNetworking`), and media loads over plain HTTP if the server uses it (`NSAllowsArbitraryLoadsForMedia`).

## The build fails after upgrading

`… has been modified since the module file … was built`, followed by missing `sab_…` functions, means Xcode or SwiftPM reused the previous release's precompiled `SpatialAudioCore` module. Delete the `SpatialAudioCore-*.pcm` files in the build's module caches (in DerivedData, `SwiftExplicitPrecompiledModules` and `ModuleCache.noindex`; for SwiftPM, under `.build`), or clean the build.

## Media tests are skipped

The fixture tests need the fixture paths in environment variables; see [validation](validation.md#obtain-fixtures).
