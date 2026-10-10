# Validation

Validated on 2026-10-10 with Xcode 27.1, Swift 6.4, macOS 27.0.1 and Rust 1.99.0. Rust decoding tests ran on Linux with an Intel Core i9-13900K. Apple encoding and decoding ran on an Apple Silicon Mac. Device tests ran on an Apple TV 4K (2nd generation) with tvOS 27.2 beta (24K5103f), connected over HDMI to an Atmos receiver, with Jellyfin 12.2 on gigabit Ethernet.

## Results

### Decoding and rendering

| Check | Result |
|---|---|
| Angular panning | Canonical anchors, equal-power midpoints, room depth, bed/height separation, unit power over a room grid and continuity across angular boundaries pass |
| Atmos rendering controls | Elevation disable and extended precision pass; unsupported controls produce explicit errors |
| Full TrueHD Atmos elementary stream | 58-second fixture passes chunking, finite PCM, height-energy and truncation checks |
| Full DTS:X Object Emulator elementary stream | 95-second fixture passes chunking, finite PCM, height-energy and truncation checks |
| Decoder chunking | Bit-identical PCM and sample counts with 4096-byte and 317-byte chunks for both full fixtures |
| Truncation | Removing the final compressed byte produces an error for both formats |
| TrueHD mid-stream start | Starting at a later major sync without object metadata keeps every sample, preserves height audio and is independent of input chunking |

### Encoding and packaging

| Check | Result |
|---|---|
| HLS codec metadata | Layouts expose `apac.31.03` / `apac.31.04` using Apple's published platform profile/level mapping |
| Eight-second Atmos / DTS:X → APAC → Apple PCM decoder | APAC codec and 16-channel 9.1.6 layout confirmed, duration checked, height energy retained |
| Atmos → 7.1.4 fragmented MP4, eight-second and full 58-second streams | 12-channel layout confirmed; continuous timestamps and playlists checked at zero and nonzero start times |
| Fragmented encoder priming | Core Audio reports 2048 leading frames; native decoding trims them, and the full 58-second stream decodes to its source length rounded up to a whole 1024-frame packet |
| Live encoding | Segments trail their input by less than 2 s over 30 s of TrueHD Atmos; the offline profile's first fragment needs 23.3 s of input |
| `AudioConverter` encoder | Sixteen distinct tones survive a 9.1.6 APAC round trip, each correlating above 0.98 with its own channel and below 0.1 with its neighbour |
| Encoder quality tiers | On 20 s of a film, all 16 channels active: high 47.0 dB and medium 48.4 dB signal-to-error, low 43.0 dB; on the height-only fixture, high and medium 60.9–61.0 dB, low 18.8 dB. Medium encoded 1.25–1.5× as fast as high, low 3×. `AVAssetWriter` ignored the setting |
| Conversion profile | In a macOS profile, Apple's APAC encoder was about 85% of conversion work. After moving PCM scaling to Accelerate, Debug and Release builds convert at the same speed |

### Sources and streaming

| Check | Result |
|---|---|
| Matroska reader | Synthetic files cover track metadata, header stripping, all lacing modes, block groups, cues and metadata found through the seek head, seeking to the last sync at or before the target, seeking into a laced block and rejecting malformed lacing |
| Real Matroska file | The Helicopter MKV's TrueHD track is byte-identical to the FFmpeg extraction; a 30-second seek starts at a sync within 0.1 s |
| Matroska over HTTP | From Jellyfin, 8-second conversions from 10:00 succeeded for one TrueHD Atmos and two DTS:X 4K remuxes; seeks reached a sync 21–64 ms before the target |
| `APACStream` segment grid | Every segment starts at N × 153,600 frames and lasts 153,600 frames, including after jumps forward and back; a restarted segment correlates above 0.99 with the continuous one after the priming |
| `APACStream` pacing | Conversion holds at the lookahead while no requests arrive, then serves later segments without restarting; a request served from the cache does not hold back one waiting further ahead |
| `APACStream` with `AVPlayer` | macOS `AVPlayer` plays the audio playlist and continues after an exact seek to 0:40 |
| Playlist rewriting and loopback server | Video masters keep absolute URIs, subtitles and I-frame and image playlists; the server answers GET, HEAD, byte ranges and unknown paths |
| `SpatialAudioRenderer` | From a 20-second seek into the MKV fixture, macOS renders APAC and the synchronizer advances |

### Playback on Apple TV

| Check | Result |
|---|---|
| Atmos activation with `AVPlayer` | APAC plus `AtmosOutputActivator` and direct Dolby Digital Plus both trigger Atmos and sound similar; APAC alone does not |
| Atmos activation with `AVSampleBufferAudioRenderer` | Atmos only with the activator; a 7.1.4 channel check played every speaker in its place, including the heights |
| A/B Auto playback | Eight matched 20-second excerpts completed in pair order; silent Atmos stream only during APAC, stop after the final pair, preparation/playback cancellation pass |
| Activator and Dolby Digital Plus | Direct Dolby Digital Plus no longer stutters once the activator unloads its stream for non-APAC items |
| `APACStream` with Jellyfin | A 4K HDR10 title with TrueHD Atmos played with stream-copied HEVC video and Atmos on the receiver; stream ready 2.0–2.5 s and playing 4–5 s after launch; about 1 s of conversion per 3.2-second segment, in Debug and Release builds alike |
| Sustained `APACStream` playback | After the pacing fix, no stalls in 37 minutes of steady playback; before it, playback stopped after 111 s when a dropped segment was requested. Available memory stayed within 2,135–2,171 MB across sessions of up to 16 minutes |
| Seeks with `AVPlayer` | Before the restart rule changed, a long scrub failed the item (`-12880`) and skips back waited up to 30 s. Afterwards, a scripted test of eight skips, scrubs and jumps recovered every time; times below |
| `SpatialAudioRenderer` on device | Renderer mode read the title from Jellyfin, started the synchronizer 1.47 s after launch and reported `.rendering` with the silent Atmos stream playing |
| Activator lifecycle | The silent stream follows host play/pause, plays only for accepted items, follows a synchronizer, stops on detach and reports an unplayable stream (macOS) |

Scripted seeks on the Release build, from 55:06 into the Jellyfin title, whose stream-copy video segments last 10.4 s. Each seek was issued as a remote does, without waiting for the previous one, and timed until playback moved past the target:

| Seek | Resumed after |
|---|---|
| Skip forward 10 s, within converted audio | 1.1 s |
| Skip back 10 s, before the first converted segment | 6.8 s |
| Three skips back 10 s, 0.3 s apart | 6.2 s |
| Scrub forward 2 min, twelve steps 0.17 s apart | 13.6 s |
| Scrub back 1 min, six steps | 12.2 s |
| Jump forward 10 min | 13.7 s |
| Jump back 5 min | 13.3 s |
| Two 1-minute jumps forward, 0.5 s apart | 11.9 s |

In two other runs, the three quick skips back made Jellyfin abort a video segment mid-response, after which `AVPlayer` waited without requesting anything more; see [troubleshooting](troubleshooting.md#playback-stays-waiting-after-rapid-seeks).

## Coverage

The suite includes 11 Rust unit tests, 3 Rust fixture tests and 37 Swift tests. Without fixture variables, 27 Swift tests run: configuration, playlists and variant filtering, the loopback server, the stream's restart rule, cache window and run endings, synthetic and malformed Matroska files, the encoder round trip, renderer settings and failures, and the activator. Three tests need `SAB_TRUEHD_FIXTURE` or `SAB_DTSX_FIXTURE`, and seven need `SAB_MKV_FIXTURE`. Rust Clippy and the Swift build pass with warnings treated as errors.

HLS codec strings are derived from the platform encoder's documented format mapping; this check does not independently parse the APAC profile from its opaque bitstream. The PCM chunk comparison checks that network and demuxer buffering do not change output. These checks do not establish equivalence to a licensed reference renderer.

## Not yet established

- Correct speaker placement beyond the channel check and informal listening, and the HDMI payload (MAT or otherwise).
- Lip sync with dialogue, measured rather than observed.
- Receiver output from `SpatialAudioRenderer` itself, beyond its rendering status; the earlier listening test fed the renderer from a file.
- Memory use over a full film, Wi-Fi playback, titles with short keyframe intervals, and other Apple TV models and receivers.
- Plex and Emby sources.
- Rendered peaks: a film's front height channel reached +4 dBFS before encoding; objects summing into one speaker can exceed full scale.

`AVAudioSession.outputNumberOfChannels` reported eight for both working formats, and the session's rendering mode and spatial audio flags were also unsuitable Atmos detectors on the tested beta.

The DTS:X fixture container's first audio PTS is approximately 53 ms; its elementary stream begins at zero. A host must preserve that container offset when configuring the transcoder.

## Obtain fixtures

The [Kodi sample list](https://kodi.wiki/view/Samples) provides the TrueHD Atmos Helicopter and DTS:X Object Emulator clips. Download fixtures separately, then use an existing FFmpeg installation to extract the selected compressed track:

```sh
ffmpeg -i "atmos-sample.mkv" -map 0:a:0 -c copy -f truehd "atmos.thd"
ffmpeg -i "dtsx-sample.mkv" -map 0:a:0 -c copy -f dts "dtsx.dts"
```

The validated elementary streams have SHA-256 values:

```text
Atmos: 79dd2aec46408f81f2a53da17dc5d43f24fe25bec9b61ee79b36c6e22cefcbf4
DTS:X: 718cb0dc98f67dcf6f04778fb64ff8862fc625bb782353a6ff9d828fb05fbd69
```

For the Matroska and streaming tests, keep the Helicopter MKV's TrueHD track in a Matroska file:

```sh
ffmpeg -i "atmos-sample.mkv" -map 0:a:0 -c copy "atmos-only.mkv"
```

Fixture media remains local. Run full decoder checks on a development machine:

```sh
cd Rust/SpatialAudioCore
SAB_TRUEHD_FIXTURE="/absolute/path/atmos.thd" \
SAB_DTSX_FIXTURE="/absolute/path/dtsx.dts" \
cargo test --release --locked -- --include-ignored --test-threads=1
cargo clippy --all-targets --locked -- -D warnings
```

Run the Apple round-trip, streaming and renderer checks on macOS. Use the full Atmos elementary stream with the MKV made from it, because one test compares the MKV's track with it byte for byte. For DTS:X, an eight-second, complete-access-unit excerpt is sufficient. The fixture suites serialize their encoder jobs.

```sh
SAB_TRUEHD_FIXTURE="/absolute/path/atmos.thd" \
SAB_DTSX_FIXTURE="/absolute/path/dtsx-8s.dts" \
SAB_MKV_FIXTURE="/absolute/path/atmos-only.mkv" \
swift test -j 1 -Xswiftc -warnings-as-errors
```

On Apple TV, use the [StreamPlayer](../Examples/StreamPlayer/README.md) example against a media server and the [A/B player](../Examples/AtmosAB/README.md) for listening comparisons.
