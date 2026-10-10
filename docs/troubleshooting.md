# Troubleshooting

## The receiver does not show Atmos

- Attach `AtmosOutputActivator` and check `isActive` while APAC plays. If it is false, check `error`, and for `AVPlayer` check that the `playsAPAC` predicate returns true for the item.
- Check that the silent stream signals Atmos: `ffprobe` should report `profile=Dolby Digital Plus + Dolby Atmos`. See [Atmos output](atmos-output.md#make-a-silent-atmos-stream).
- In Apple TV settings, keep the audio format on Auto with Change Format off, and Dolby Atmos enabled.
- Do not rely on `AVAudioSession` channel counts or spatial audio flags to detect Atmos; they did not distinguish it on tvOS 27.2.

## `APACStream.start` or a session throws

`SpatialAudioError` explains the cause. Fall back to the host's usual audio path for any of these:

| Error | Meaning |
|---|---|
| `.decoding("… is not yet supported")`, naming object size, trims, bed downmix, divergence, ISF or multiple beds | The track uses metadata this renderer does not support. |
| `.decoding("This TrueHD stream has no Atmos presentation")` | Plain TrueHD without Atmos. |
| `.decoding("Atmos presentation has no object metadata within 0.5 s")` | The stream started without object metadata; possibly damaged or not a standard Atmos stream. |
| `.decoding("The initial Atmos renderer supports 48 kHz tracks")` | A 96 kHz or other non-48 kHz track. |
| `.decoding("This stream is not lossless DTS:X")` | DTS core, DTS-HD High Resolution or DTS-HD MA without DTS:X. |
| `.decoding("DTS:X … is experimental upstream and is not enabled")`, `"Unknown DTS:X presentation"` or `"…unknown bed fold…"` | An alternate or IMAX DTS:X presentation. |
| `.source("The file has no TrueHD or DTS track")` | No convertible track; check `file.audioTracks`. |
| `.source("The file does not declare its duration")` | `APACStream` needs the duration for its VOD playlist. |
| `.source("Could not load the video playlist")` | The video master URL failed or did not return a playlist; check its authorization. |
| `.source(…)` from `HTTPByteSource` | The server rejected the request or ignored the range. It must answer range requests with status 206. |

Jellyfin 12.2 returns 401 for the older `api_key` query parameter; use `ApiKey` or a header.

## AVPlayer error log entries

| Code | Meaning |
|---|---|
| −12318 "Segment exceeds specified bandwidth for variant" on video segments | The server's master understates its bitrate. Jellyfin declares 128 kbit/s for a 4K remux. Harmless on a fast network. |
| −12889 "No response for media file" on `seg<N>.m4s` | Conversion did not deliver the segment in time. Check `conversionSpeed`; below about 1.2, the device, the network or the server cannot keep up. |
| −12889 on video segments | The media server is slow to remux, often right after a seek. `AVPlayer` may pause or stop requesting media; see below. |
| −12880 "Can not proceed after removing variants" | `AVPlayer` gave up on every variant, usually after the first segment of a seek timed out. With a media server's transcoding variants offered, it may first have switched to one of them; offer only the stream-copy variant with `includesVideoVariant`. |
| HTTP 500 for `seg<N>.m4s` | Conversion failed, usually from unsupported metadata partway through the track. Decoding, encoding and configuration failures end the stream, so later requests fail too: fail the item and fall back to the host's audio path. After a network failure, the next request starts a new run. |
| HTTP 503 for `seg<N>.m4s` | A later request restarted conversion elsewhere, such as the next scrub position. Expected while scrubbing. |
| HTTP 410 | The stream was stopped; requests that arrive afterwards are refused. |

The stream's own log, subsystem `SpatialAudioBridge`, category `APACStream`, shows each request, restart and wait time. See [Monitor](avplayer.md#monitor).

## Playback stalls

Playback needs conversion faster than real time. Apple TV 4K (2nd generation) converts TrueHD Atmos to 9.1.6 at about 3.2×. Over Wi-Fi, the Matroska reader also transfers the video bytes, so the network must deliver the file faster than its bitrate. Choosing `.sevenOneFour` lowers the APAC bit rate and encoding work.

## Seeks take several seconds

After a seek, `AVPlayer` asks for audio from the start of the video segment before the target, and each segment that is not yet converted costs about 1 s on Apple TV 4K (2nd generation). Titles with long keyframe intervals, whose stream-copy video segments are long, therefore take longest: 6–14 s with 10.4-second segments. Skips within the last minute of played audio, or within the lookahead, resume in about 1 s. See [seeking](avplayer.md#seeking-and-synchronization).

## Playback stays waiting after rapid seeks

Three quick skips back made Jellyfin restart its remux twice within two seconds and abort a video segment mid-response (`The response has already started` in its log). `AVPlayer` then waited indefinitely without requesting anything more, while the stream kept answering, and seeking again did not help. Replace the item at the same position: [StreamPlayer](../Examples/StreamPlayer/README.md) does so after 20 s of waiting, though that recovery has not yet been observed on a device. A player's own stall handling can do the same.

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

## Media tests are skipped

The fixture tests need the fixture paths in environment variables; see [validation](validation.md#obtain-fixtures).
