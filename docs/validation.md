# Validation

Validated on 2026-10-09 with Xcode 27.1, Swift 6.4, macOS 27.0.1 and Rust 1.99.0. Rust decoding tests ran on Linux with an Intel Core i9-13900K. Apple encoding and decoding ran on an Apple Silicon Mac.

## Results

| Check | Result |
|---|---|
| Full TrueHD Atmos elementary stream | 2,784,640 frames at 48 kHz, 58.013333 s; all six height outputs have energy |
| Full DTS:X Object Emulator elementary stream | 4,557,824 frames at 48 kHz, 94.954667 s; all four fixed height outputs have energy |
| Decoder chunking | Bit-identical PCM and sample counts with 4096-byte and 317-byte chunks for both full fixtures |
| Truncation | Removing the final compressed byte produces an error for both formats |
| Full Atmos → APAC MP4 | 16 channels, 9.1.6, 58.013333 s; 75-packet sync cadence confirmed by `afinfo` |
| Eight-second Atmos / DTS:X → APAC → Apple PCM decoder | APAC codec confirmed, duration checked, height energy retained |
| Eight-second Atmos → 7.1.4 fragmented MP4 | Initialization and timed media fragments produced; continuous timestamps and playlist files checked |
| Fragmented encoder priming | Core Audio reports 2048 leading frames; native decoding trims to the original source sample count |
| Apple TV builds | ARM64 device and simulator Rust libraries generated; Swift sources typechecked against tvOS 26 with warnings treated as errors |

The PCM chunk comparison checks that network/demuxer buffering does not change output. These checks do not establish equivalence to a licensed reference renderer. Actual receiver/MAT output, sustained Apple TV performance, native HLS A/V sync and seeks require device/host-player tests.

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

Without fixture variables, the four configuration/lifecycle tests run and the three media tests are disabled explicitly.
