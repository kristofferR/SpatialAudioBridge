# SpatialAudioBridge

## Purpose and goals

Build a small, reusable library that lets Apple TV media players convert TrueHD Atmos and DTS:X audio tracks into Apple Positional Audio Codec (APAC) media for native Apple playback. Preserve spatial placement, including height audio, as accurately as the supported input metadata allows.

The first deliverable is the library: a simple Swift API for file conversion and incremental compressed input, with APAC MP4 and fragmented MP4 / HLS output. Once correctness, device playback and packaging are established, the intended integrations are Swiftfin and Streamyfin. Keep player adapters separate from the core library.

## Architecture and boundaries

- `Rust/SpatialAudioCore`: compressed decoding, metadata interpretation and rendering into 7.1.4 or 9.1.6 speaker feeds. Exposes a small C ABI.
- `Sources/SpatialAudioBridge`: Swift session management, PCM sample buffers, Apple's APAC encoder, file output and timed fragment callbacks.
- `Sources/APACConvert`: a command-line consumer of the public library API.
- `scripts/build-core.sh`: builds the Rust XCFramework for Apple Silicon Mac, Apple TV device and Apple TV simulator.
- `Tests` and the Rust tests: focused checks for spatial rendering, stream handling, timing and native APAC round trips.

The pipeline is compressed audio → spatial speaker PCM → APAC. Rendering and encoding do not preserve the original compressed bitstream or object stream.

The host player owns demuxing, track selection, networking, video, HTTP serving, seeks and A/V synchronization. Accept the selected continuous elementary stream rather than adding a container parser or playback engine. Native spatial output requires an appropriate Apple playback route; an existing software PCM sink is insufficient.

## Current baseline

- Experimental, with tvOS 26+ and macOS 26+ encoding requirements.
- 48 kHz TrueHD Atmos with one bed and point objects; position, gain, activity, timed updates and ramps are implemented.
- 48 kHz DTS:X standard four-height presentation; known height folds are removed from the compatible bed before recombination.
- APAC 7.1.4 and 9.1.6 output, including files and HLS fragments.
- Atmos ISF, multiple beds, nonzero object sizes and alternate/IMAX DTS:X profiles are rejected.
- Custom Atmos trims and screen/distance/zone rendering are not implemented. The renderer is an approximation, not a licensed reference renderer.

Real fixtures have passed decoding and Apple APAC round trips. This does not establish correct receiver/MAT output, sustained Apple TV performance or host-player A/V synchronization. Keep those distinctions explicit in documentation and reports.

## Next priorities

1. Verify native Apple TV playback, spatial channel placement and receiver output on actual hardware.
2. Measure sustained decoding/encoding speed and memory use on Apple TV, including cancellation and backpressure.
3. Validate host HLS timing, encoder priming, seeks and discontinuities with video.
4. Improve rendering accuracy and supported metadata through focused fixtures and documented behavior.
5. Package a reproducible XCFramework and straightforward Swift dependency, then build the player integrations.

## Implementation guidance

- Keep the public API small and typed. Prefer fixing the existing pipeline over adding parallel abstractions.
- Reject unsupported or malformed inputs clearly so the host can choose its existing fallback. Document approximations rather than silently advertising full codec support.
- Preserve sample counts, channel order, metadata timing and codec trim information. Start a fresh session after a seek, timestamp discontinuity or format change.
- Query encoder priming instead of hardcoding a measured value. Coded fragment duration and presented source duration are different quantities.
- Keep cancellation, callback failures and encoder failures terminal for a session. Bound buffering and await backpressure.
- Pin decoder dependencies and preserve their license notices in binary distributions.
- Keep generated binaries and fixture media out of Git. Commit validated, scoped changes in logical commits.

## Development and validation

Run general Rust development and fixture processing on the Linux workstation. Use macOS for Apple SDK work and native encoding/decoding, with one build job on the resource-limited Mac.

```sh
cargo test --release --locked --manifest-path "Rust/SpatialAudioCore/Cargo.toml"
cargo clippy --all-targets --locked --manifest-path "Rust/SpatialAudioCore/Cargo.toml" -- -D warnings

# On macOS; rebuild the XCFramework after Rust changes.
./scripts/build-core.sh
swift build -j 1 -Xswiftc -warnings-as-errors
swift test -j 1 -Xswiftc -warnings-as-errors
```

Media tests require `SAB_TRUEHD_FIXTURE` and `SAB_DTSX_FIXTURE`; otherwise they are skipped. Follow [docs/validation.md](docs/validation.md) for full fixture checks. Test actual spatial output, chunk independence, truncation handling, duration and priming when relevant. Height-channel energy alone does not prove correct spatial placement.

Keep [README.md](README.md), [docs/integration.md](docs/integration.md) and [docs/validation.md](docs/validation.md) aligned with supported behavior and measured results. Do not repeat expensive validation unless a change or unresolved failure justifies it.
