# SpatialAudioBridge

## Purpose and goals

Build a small, reusable library that lets Apple TV media players convert TrueHD Atmos and DTS:X audio tracks into Apple Positional Audio Codec (APAC) media for native Apple playback. Preserve spatial placement, including height audio, as accurately as the supported input metadata allows.

The first deliverable is the library: a simple Swift API for file conversion and incremental compressed input, with APAC MP4 and fragmented MP4 / HLS output, plus the playback pieces every host needs: Matroska reading, an on-demand HLS session for `AVPlayer`, a sample-buffer renderer and Atmos output activation. Once correctness, device playback and packaging are established, the intended integrations are Swiftfin and Streamyfin. Keep player adapters separate from the core library.

## Architecture and boundaries

- `Rust/SpatialAudioCore`: compressed decoding, metadata interpretation and rendering into 7.1.4 or 9.1.6 speaker feeds. Exposes a small C ABI.
- `Sources/SpatialAudioBridge`: Swift session management, Apple's APAC encoder, file output and timed fragment callbacks; Matroska reading from files or HTTP ranges; `APACStream` (VOD playlist on a fixed segment grid, on-demand conversion, loopback server, master rewrite); `SpatialAudioRenderer` (APAC into `AVSampleBufferAudioRenderer`).
- `Sources/SpatialAudioPlayback`: playback-route helpers without the Rust core, including Atmos output activation for `AVPlayer` and render synchronizers.
- `Sources/APACConvert`: a command-line consumer of the public library API.
- `scripts/build-core.sh`: builds the Rust XCFramework for Apple Silicon Mac, Apple TV device and Apple TV simulator.
- `Tests` and the Rust tests: focused checks for spatial rendering, stream handling, timing and native APAC round trips.
- `Examples`: Apple TV apps for listening comparisons (AtmosAB) and end-to-end media-server playback (StreamPlayer).

The pipeline is compressed audio → spatial speaker PCM → APAC. Rendering and encoding do not preserve the original compressed bitstream or object stream.

None of the surveyed open-source Apple TV players expose compressed audio packets, so the library reads Matroska audio itself and serves APAC to `AVPlayer` or a sample-buffer renderer. The host keeps track selection, video, subtitles, UI, its fallback for unsupported tracks and its playback engine; other containers use the host's demuxer. Do not add a video playback engine. Native spatial output requires an appropriate Apple playback route; an existing software PCM sink is insufficient.

## Current baseline

- Experimental, with tvOS 26+ and macOS 26+ encoding requirements.
- 48 kHz TrueHD Atmos with one bed; objects follow the ETSI TS 103 448 source panner, including size, divergence, snap, zones, trim, gain, activity, timed updates and ramps, and TrueHD dialogue normalisation is applied.
- 48 kHz lossless DTS:X standard four-height and known alternate object presentations; resolved spatial folds are removed from the compatible bed before recombination. Alternate profiles are experimental, with physical-angle panning and frame-length object ramps.
- APAC 7.1.4 and 9.1.6 output, including files, HLS fragments and sample buffers. Streaming paths use Apple's live encoder profile (about 1.6 s latency instead of about 20 s).
- On an Apple TV 4K (2nd generation) with tvOS 27.2 beta: `APACStream` played a Jellyfin 4K title with video and Atmos output, converting at about 3.2× real time and recovering from every scripted seek (1–14 s); `AVSampleBufferAudioRenderer` with APAC gave Atmos and correct 7.1.4 placement. Atmos output required a near-silent E-AC-3 + JOC stream alongside, via `AtmosOutputActivator`.
- Atmos ISF, multiple beds, bed distribution, bed downmix metadata, objects outside the room and warped positions are rejected; a census of 179 library titles found only warped positions, in one title. Unknown DTS:X profiles, mismatched source roles and unresolved folds are rejected; all eight DTS:X titles in the census used the standard presentation with every fold stated.
- The [rendering model](docs/rendering.md) documents the Atmos panner, its 9.1.6 extension and the DTS:X approximation. None of it is a licensed reference renderer.

Real fixtures have passed decoding and Apple APAC round trips, and one Apple TV and receiver have confirmed Atmos activation and channel placement. This does not establish the HDMI payload (MAT or otherwise), measured lip sync, full-film memory use or behavior on other devices and receivers. Keep those distinctions explicit in documentation and reports.

## Next priorities

1. Measure lip sync and memory over a full film on Apple TV, including Wi-Fi playback; seek recovery is bound by single-threaded APAC encoding.
2. Validate other Apple TV models, receivers and media servers (Plex, Emby).
3. Improve rendering accuracy and supported metadata through focused fixtures and documented behavior.
4. Package a reproducible XCFramework and straightforward Swift dependency, then build the player integrations, starting with Swiftfin's native player.

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

Media tests require `SAB_TRUEHD_FIXTURE`, `SAB_DTSX_FIXTURE`, `SAB_DTSX_ALTERNATE_FIXTURE` and `SAB_MKV_FIXTURE`; otherwise they are skipped. Follow [docs/validation.md](docs/validation.md) for full fixture checks. Test actual spatial output, chunk independence, truncation handling, duration and priming when relevant. Height-channel energy alone does not prove correct spatial placement.

Keep [README.md](README.md), the guides in [docs](docs/) and [docs/validation.md](docs/validation.md) aligned with supported behavior and measured results. Do not repeat expensive validation unless a change or unresolved failure justifies it.
