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

### Sources and streaming

| Check | Result |
|---|---|
| Matroska reader | Synthetic files cover track metadata, header stripping, all lacing modes, block groups, cues through the seek head and seeking to the last sync at or before the target |
| Real Matroska file | The Helicopter MKV's TrueHD track is byte-identical to the FFmpeg extraction; a 30-second seek starts at a sync within 0.1 s |
| Matroska over HTTP | From Jellyfin, 8-second conversions from 10:00 succeeded for one TrueHD Atmos and two DTS:X 4K remuxes; seeks reached a sync 21–64 ms before the target |
| `APACStream` segment grid | Every segment starts at N × 153,600 frames and lasts 153,600 frames, including after jumps forward and back; a restarted segment correlates above 0.99 with the continuous one after the priming |
| `APACStream` pacing | Conversion holds at the lookahead while no requests arrive, then serves later segments without restarting |
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
| `APACStream` with Jellyfin | A 4K HDR10 remux with TrueHD Atmos played from 7:00 with stream-copied HEVC video and Atmos on the receiver; ready 2.4–2.5 s after launch, converting at 2.6–2.7× real time |
| Sustained `APACStream` playback | After the pacing fix, 16 minutes without a stall; before it, playback stopped after 111 s when a dropped segment was requested |
| Activator lifecycle | The silent stream follows host play/pause, plays only for accepted items, follows a synchronizer, stops on detach and reports an unplayable stream (macOS) |

## Coverage

The suite includes 11 Rust unit tests, 3 Rust fixture tests and 28 Swift tests. Without fixture variables, 19 Swift tests run: configuration, playlists, the loopback server, synthetic Matroska files, the encoder round trip and the activator. Three tests need `SAB_TRUEHD_FIXTURE` or `SAB_DTSX_FIXTURE`, and six need `SAB_MKV_FIXTURE`. Rust Clippy and the Swift build pass with warnings treated as errors.

HLS codec strings are derived from the platform encoder's documented format mapping; this check does not independently parse the APAC profile from its opaque bitstream. The PCM chunk comparison checks that network and demuxer buffering do not change output. These checks do not establish equivalence to a licensed reference renderer.

## Not yet established

- Correct speaker placement beyond the channel check and informal listening, and the HDMI payload (MAT or otherwise).
- Lip sync with dialogue, measured rather than observed, and seek recovery times on Apple TV.
- Memory use over a full film, Wi-Fi playback, and other Apple TV models and receivers.
- Plex and Emby sources.

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

Run the Apple round-trip, streaming and renderer checks on macOS. Eight-second, complete-access-unit excerpts are sufficient for the elementary-stream tests and produce multiple HLS segments. The fixture suites serialize their encoder jobs.

```sh
SAB_TRUEHD_FIXTURE="/absolute/path/atmos-8s.thd" \
SAB_DTSX_FIXTURE="/absolute/path/dtsx-8s.dts" \
SAB_MKV_FIXTURE="/absolute/path/atmos-only.mkv" \
swift test -j 1 -Xswiftc -warnings-as-errors
```

On Apple TV, use the [StreamPlayer](../Examples/StreamPlayer/README.md) example against a media server and the [A/B player](../Examples/AtmosAB/README.md) for listening comparisons.
