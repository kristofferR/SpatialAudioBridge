# Validation

Validated on 2026-10-09 with Xcode 27.1, Swift 6.4, macOS 27.0.1 and Rust 1.99.0. Rust decoding tests ran on Linux with an Intel Core i9-13900K. Apple encoding and decoding ran on an Apple Silicon Mac.

## Results

| Check | Result |
|---|---|
| Angular panning | Canonical anchors, equal-power midpoints, room depth, bed/height separation, unit power over a room grid and continuity across angular boundaries pass |
| DTS:X alternate routing | All seven presentations in both layouts pass synthetic fold cleanup, role separation and physical-angle tests; object ramps and fallback errors pass |
| IMAX three-component metadata | Upstream payload parsed and C/L/R components routed correctly in both layouts, using synthetic PCM |
| Atmos rendering controls | Elevation disable and extended precision pass; unsupported controls produce explicit errors |
| HLS codec metadata | Layouts expose `apac.31.03` / `apac.31.04` using Apple’s published platform profile/level mapping |
| Full TrueHD Atmos elementary stream | 58-second fixture passes chunking, finite PCM, height-energy and truncation checks |
| Full DTS:X Object Emulator elementary stream | 95-second fixture passes chunking, finite PCM, height-energy and truncation checks |
| Full alternate DTS:X elementary stream | 44.426667-second Trinnov Experience fixture: 4,165 D4 frames, 1,558 distinct object positions; chunking, finite PCM, height-energy and truncation checks pass |
| Decoder chunking | Bit-identical PCM and sample counts with 4096-byte and 317-byte chunks for all three full fixtures |
| Truncation | Removing the final compressed byte produces an error for all three fixtures |
| Eight-second Atmos / standard DTS:X / D4 DTS:X → APAC → Apple PCM decoder | APAC codec and 16-channel 9.1.6 layout confirmed, duration checked, height energy retained |
| Eight-second Atmos → 7.1.4 fragmented MP4 | 12-channel layout confirmed; continuous timestamps and playlists checked at zero and nonzero start times |
| Fragmented encoder priming | Core Audio reports 2048 leading frames; native decoding trims to the original source sample count |
| Apple TV builds | ARM64 device and simulator Rust libraries generated; Swift sources typechecked against tvOS 26 with warnings treated as errors |

The suite includes nineteen Rust unit tests, three full-fixture Rust tests, five Swift configuration/lifecycle tests and four Swift media tests. Rust Clippy and Apple Swift checks pass with warnings treated as errors. HLS codec strings are derived from the platform encoder’s documented format mapping; this check does not independently parse the APAC profile from its opaque bitstream.

The PCM chunk comparison checks that network/demuxer buffering does not change output. These checks do not establish equivalence to a licensed reference renderer. Full compressed alternate-profile media has been validated for D4 only. The other alternate profiles have synthetic routing checks; the IMAX component vector validates metadata parsing with synthetic PCM, not a complete IMAX track or APAC round trip. Full media and listening validation for those profiles remain outstanding. Actual receiver/MAT output, sustained Apple TV performance, native HLS A/V sync and seeks require device/host-player tests.

The DTS:X container's first audio PTS is approximately 53 ms; its elementary stream begins at zero. A host must preserve that container offset when configuring the transcoder.

## Obtain fixtures

The [Kodi sample list](https://kodi.wiki/view/Samples) provides the TrueHD Atmos Helicopter and DTS:X Object Emulator clips. The [public demo folder linked by a MediaInfo report](https://github.com/MediaArea/MediaInfoLib/issues/2429) contains the Trinnov Experience trailer labelled DTS-X Pro used for D4 validation. That label is a file title, not proof of a distinct codec or IMAX branding. Download fixtures separately, then use an existing FFmpeg installation to extract the selected compressed track:

```sh
ffmpeg -i "atmos-sample.mkv" -map 0:a:0 -c copy -f truehd "atmos.thd"
ffmpeg -i "dtsx-sample.mkv" -map 0:a:0 -c copy -f dts "dtsx.dts"
ffmpeg -i "experience-pro.mkv" -map 0:a:0 -c copy -f dts "dtsx-alternate.dts"
```

The validated elementary streams have SHA-256 values:

```text
Atmos: 79dd2aec46408f81f2a53da17dc5d43f24fe25bec9b61ee79b36c6e22cefcbf4
DTS:X: 718cb0dc98f67dcf6f04778fb64ff8862fc625bb782353a6ff9d828fb05fbd69
DTS:X D4: 5e8fc319289ab9ce5a44c7f161feb2fe497babf442185c8c965b34e1990a675c
```

Fixture media remains local. Run full decoder checks on a development machine:

```sh
cd Rust/SpatialAudioCore
SAB_TRUEHD_FIXTURE="/absolute/path/atmos.thd" \
SAB_DTSX_FIXTURE="/absolute/path/dtsx.dts" \
SAB_DTSX_ALTERNATE_FIXTURE="/absolute/path/dtsx-alternate.dts" \
cargo test --release --locked -- --include-ignored --test-threads=1
cargo clippy --all-targets --locked -- -D warnings
```

Run the Apple round-trip and HLS checks on macOS. Eight-second, complete-access-unit excerpts are sufficient for the integration tests and produce multiple HLS segments. The fixture suite serializes its encoder jobs.

```sh
SAB_TRUEHD_FIXTURE="/absolute/path/atmos-8s.thd" \
SAB_DTSX_FIXTURE="/absolute/path/dtsx-8s.dts" \
SAB_DTSX_ALTERNATE_FIXTURE="/absolute/path/dtsx-alternate-8s.dts" \
swift test -j 1 -Xswiftc -warnings-as-errors
```

Without fixture variables, the five configuration/lifecycle tests run and the four media tests are disabled explicitly.
