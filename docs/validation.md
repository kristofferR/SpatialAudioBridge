# Validation

Validated on 2026-10-09 with Xcode 27.1, Swift 6.4, macOS 27.0.1 and Rust 1.99.0. Rust decoding tests ran on Linux with an Intel Core i9-13900K. Apple encoding and decoding ran on an Apple Silicon Mac.

## Results

| Check | Result |
|---|---|
| Angular panning | Canonical anchors, equal-power midpoints, room depth, bed/height separation, unit power over a room grid and continuity across angular boundaries pass |
| Atmos rendering controls | Elevation disable and extended precision pass; unsupported controls produce explicit errors |
| HLS codec metadata | Layouts expose `apac.31.03` / `apac.31.04` using Apple’s published platform profile/level mapping |
| Full TrueHD Atmos elementary stream | 58-second fixture passes chunking, finite PCM, height-energy and truncation checks |
| Full DTS:X Object Emulator elementary stream | 95-second fixture passes chunking, finite PCM, height-energy and truncation checks |
| Decoder chunking | Bit-identical PCM and sample counts with 4096-byte and 317-byte chunks for both full fixtures |
| Truncation | Removing the final compressed byte produces an error for both formats |
| TrueHD mid-stream start | Starting at a later major sync without object metadata keeps every sample, preserves height audio and is independent of input chunking |
| Eight-second Atmos / DTS:X → APAC → Apple PCM decoder | APAC codec and 16-channel 9.1.6 layout confirmed, duration checked, height energy retained |
| Eight-second Atmos → 7.1.4 fragmented MP4 | 12-channel layout confirmed; continuous timestamps and playlists checked at zero and nonzero start times |
| Fragmented encoder priming | Core Audio reports 2048 leading frames; native decoding trims to the original source sample count |
| Apple TV builds | ARM64 device and simulator Rust libraries generated; Swift sources typechecked against tvOS 26 with warnings treated as errors |
| Atmos output activator lifecycle | The silent stream follows host play/pause, plays only for accepted items, stops on detach and reports an unplayable stream instead of activity (macOS AVPlayer) |
| Native Apple TV Atmos activation | On tvOS 27.2 beta, Kris confirmed TrueHD → APAC plus a near-silent JOC Atmos stream and direct DDP both trigger Atmos and sound similar; encoder/media/renderer unchanged |
| A/B Auto playback | Eight matched 20-second excerpts completed in pair order on Apple TV; silent Atmos stream only during APAC, stop after the final pair, preparation/playback cancellation pass |

The suite includes eleven Rust unit tests, three full-fixture Rust tests, five Swift configuration/lifecycle tests, three Atmos output activator tests and three Swift media tests. Rust Clippy and Apple Swift checks pass with warnings treated as errors. HLS codec strings are derived from the platform encoder’s documented format mapping; this check does not independently parse the APAC profile from its opaque bitstream.

The PCM chunk comparison checks that network/demuxer buffering does not change output. These checks do not establish equivalence to a licensed reference renderer. The [A/B player](../Examples/AtmosAB/README.md) provides the measured `AtmosOutputActivator` and session setup for Atmos activation. Receiver indication and informal listening do not establish correct APAC speaker placement or MAT content. `AVAudioSession.outputNumberOfChannels` reported eight for both working formats, and rendering mode/spatial-audio flags were also unsuitable detectors on the tested beta. Sustained Apple TV performance, native HLS A/V sync and host seeks still require device/host-player tests.

The DTS:X container's first audio PTS is approximately 53 ms; its elementary stream begins at zero. A host must preserve that container offset when configuring the transcoder.

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

Fixture media remains local. Run full decoder checks on a development machine:

```sh
cd Rust/SpatialAudioCore
SAB_TRUEHD_FIXTURE="/absolute/path/atmos.thd" \
SAB_DTSX_FIXTURE="/absolute/path/dtsx.dts" \
cargo test --release --locked -- --include-ignored --test-threads=1
cargo clippy --all-targets --locked -- -D warnings
```

Run the Apple round-trip and HLS checks on macOS. Eight-second, complete-access-unit excerpts are sufficient for the integration tests and produce multiple HLS segments. The fixture suite serializes its encoder jobs.

```sh
SAB_TRUEHD_FIXTURE="/absolute/path/atmos-8s.thd" \
SAB_DTSX_FIXTURE="/absolute/path/dtsx-8s.dts" \
swift test -j 1 -Xswiftc -warnings-as-errors
```

Without fixture variables, the five configuration/lifecycle tests run and the three media tests are disabled explicitly.
