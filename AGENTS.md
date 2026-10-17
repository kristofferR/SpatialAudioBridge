# SpatialAudioBridge

## Purpose and goals

Build a small, reusable library that lets Apple TV media players convert TrueHD Atmos and DTS:X audio tracks into Apple Positional Audio Codec (APAC) media for native Apple playback. Preserve spatial placement, including height audio, as accurately as the supported input metadata allows.

The first deliverable is the library: a simple Swift API for file conversion and incremental compressed input, with APAC MP4 and fragmented MP4 / HLS output, plus the playback pieces every host needs: Matroska reading, an on-demand HLS session for `AVPlayer`, a sample-buffer renderer and Atmos output activation. Once correctness, device playback and packaging are established, the intended integrations are the open-source Apple TV players in the [integration guide](docs/integration.md#fit-with-existing-players). Keep player adapters separate from the core library.

## Architecture and boundaries

- `Rust/SpatialAudioCore`: compressed decoding, metadata interpretation and rendering into 7.1.4 or 9.1.6 speaker feeds. Exposes a small C ABI.
- `Sources/SpatialAudioBridge`: Swift session management, Apple's APAC encoder, file output and timed fragment callbacks; Matroska reading from files or HTTP ranges; `APACStream` (VOD playlist on a fixed segment grid, on-demand conversion, loopback server, master rewrite); `SpatialAudioRenderer` (APAC into `AVSampleBufferAudioRenderer`); `IEC61937Unpacker` (TrueHD and DTS-HD from passthrough bursts, for mpv- and VLC-style hosts).
- `Sources/SpatialAudioPlayback`: playback-route helpers without the Rust core, including Atmos output activation for `AVPlayer` and render synchronizers.
- `Sources/APACConvert`: a command-line consumer of the public library API.
- `scripts/build-core.sh`: builds the Rust XCFramework for Apple Silicon and Intel Macs, Apple TV, iPhone and iPad devices and their simulators, without local paths, as dynamic frameworks that export only the C API (the `dca` DTS decoder is ported from FFmpeg, so the LGPL requires a replaceable core), and gathers the license notices, including the bundled `ThirdPartyNotices.txt` that `SpatialAudioBridgeNotices` serves.
- `scripts/release-core.sh`: packages that build as a reproducible, checksummed archive and tags a release commit whose `Package.swift` downloads it.
- `scripts/make-silent-atmos.swift`: writes the silent Dolby Digital Plus Atmos stream that `SpatialAudioPlayback` bundles, from the ETSI specifications alone.
- `Tests` and the Rust tests: focused checks for spatial rendering, stream handling, timing and native APAC round trips.
- `Examples`: Apple TV apps for listening comparisons (AtmosAB) and end-to-end media-server playback (StreamPlayer).

The pipeline is compressed audio → spatial speaker PCM → APAC. Rendering and encoding do not preserve the original compressed bitstream or object stream.

Most open-source Apple TV players do not expose compressed audio packets, so the library reads Matroska audio itself and serves APAC to `AVPlayer` or a sample-buffer renderer. Engines that demux on the device and serve `AVPlayer` loopback HLS can feed their packets to `SpatialAudioTranscoder` instead. The host keeps track selection, video, subtitles, UI, its fallback for unsupported tracks and its playback engine; other containers use the host's demuxer. Do not add a video playback engine. Native spatial output requires an appropriate Apple playback route; an existing software PCM sink is insufficient.

## Current baseline

- Experimental. The API requires tvOS 26+, iOS 26+ or macOS 26+; the package builds back to tvOS and iOS 13 and macOS 10.15 so hosts that support older systems can depend on it. Annotate new top-level declarations with `@available(macOS 26, iOS 26, tvOS 26, *)` (test functions rather than `@Suite` types), except `SpatialAudioBridgeNotices`, which apps need wherever the core ships. iOS links but is untested.
- 48 kHz TrueHD Atmos with one bed; objects follow the ETSI TS 103 448 source panner, including size, divergence, snap, zones, trim, gain, activity, timed updates and ramps. TrueHD dialogue normalisation is off by default, as in Apple TV's own Atmos playback, and `APACConfiguration.normalizesDialogue` applies it as an AV receiver does. Warp mode 1, a 5.1 downmix setting, leaves 7.1.4 and 9.1.6 positions unchanged.
- 48 kHz lossless DTS:X standard four-height and known alternate object presentations; resolved spatial folds are removed from the compatible bed before recombination. Alternate profiles are experimental, with physical-angle panning and frame-length object ramps.
- APAC 7.1.4 (default) and 9.1.6 output, including files, HLS fragments and sample buffers. Apple TV's Atmos output carries 12 channels, so it folds 9.1.6 to 7.1.4; a blind comparison found no consistent difference. Streaming paths use Apple's live encoder profile (about 1.6 s latency instead of about 20 s).
- On an Apple TV 4K (2nd generation) with tvOS 27.2 beta: `APACStream` played a Jellyfin 4K title with video and Atmos output, converting 7.1.4 at about 4.5× real time (9.1.6 at 3.2×) and recovering from every scripted seek (1–14 s); `AVSampleBufferAudioRenderer` with APAC gave Atmos and correct 7.1.4 placement. Atmos output required a silent E-AC-3 stream signalled as Atmos alongside, via `AtmosOutputActivator`; requesting MAT Atmos through private `AVAudioSession` API also switched output but sounded worse. The bundled stream signals Atmos only in its frame headers and `dec3` box: tvOS ignores Dolby Digital Plus object metadata unless Dolby's keyed EMDF protection is valid, and switches the output without it.
- Atmos ISF, multiple beds, bed distribution, bed downmix metadata, objects outside the room and reserved warp modes are rejected; none appeared in a full census of 265 library Atmos tracks. A damaged TrueHD access unit is concealed with silence up to the next major sync, as at a disc's clip join. Unknown DTS:X profiles, mismatched source roles and unresolved folds are rejected; 28 of 29 DTS:X films in the census used the standard presentation and one the IMAX presentation, every fold stated.
- A linked lookahead limiter holds rendered feeds at −0.1 dBFS; 135 of 265 library Atmos tracks exceeded full scale without it, by up to 8.9 dB. It changes nothing away from those peaks and keeps frame counts and timing.
- The [rendering model](docs/rendering.md) documents the Atmos panner, its 9.1.6 extension and the DTS:X approximation. None of it is a licensed reference renderer.

Real fixtures have passed decoding and Apple APAC round trips, and one Apple TV and receiver have confirmed Atmos activation and channel placement. A whole film has played on that Apple TV without a stall or memory growth, and filmed lip sync through `APACStream` was 18 ms behind native Dolby Digital Plus. This does not establish the HDMI payload (MAT or otherwise), Wi-Fi playback, lip sync through `SpatialAudioRenderer` or behavior on other devices and receivers. Keep those distinctions explicit in documentation and reports.

## Next priorities

1. Validate Wi-Fi playback on Apple TV; seek recovery is bound by single-threaded APAC encoding.
2. Validate other Apple TV models and receivers. Emby and Plex are out of scope; see [media servers](docs/media-servers.md#emby-and-plex).
3. Improve rendering accuracy and supported metadata through focused fixtures and documented behavior.
4. Build the player integrations in the [integration guide](docs/integration.md#fit-with-existing-players).

## Implementation guidance

- Keep the public API small and typed. Prefer fixing the existing pipeline over adding parallel abstractions.
- Reject unsupported or malformed inputs clearly so the host can choose its existing fallback. Document approximations rather than silently advertising full codec support.
- Preserve sample counts, channel order, metadata timing and codec trim information. Start a fresh session after a seek, timestamp discontinuity or format change.
- Query encoder priming instead of hardcoding a measured value. Coded fragment duration and presented source duration are different quantities.
- Keep cancellation, callback failures and encoder failures terminal for a session. Bound buffering and await backpressure.
- Pin decoder dependencies and preserve their license notices in binary distributions.
- Keep generated binaries and fixture media out of Git; the one exception is the bundled silent Atmos stream, which its script reproduces byte for byte. Never ship output from Dolby encoders or programme audio. Commit validated, scoped changes in logical commits.

## Development and validation

Run general Rust development and fixture processing on the Linux workstation. Build and test for Apple platforms on GitHub Actions: the Core workflow builds the release archive and runs the package tests on every pull request. Kris's Mac is not for builds; media fixture tests, which need the private fixtures, run on a Mac only when he asks.

```sh
cargo test --release --locked --manifest-path "Rust/SpatialAudioCore/Cargo.toml"
cargo clippy --all-targets --locked --manifest-path "Rust/SpatialAudioCore/Cargo.toml" -- -D warnings

# On macOS (GitHub Actions); rebuild the XCFramework after Rust changes.
./scripts/build-core.sh
swift build -j 1 -Xswiftc -warnings-as-errors
swift test -j 1 -Xswiftc -warnings-as-errors
```

Media tests require `SAB_TRUEHD_FIXTURE`, `SAB_DTSX_FIXTURE`, `SAB_DTSX_ALTERNATE_FIXTURE` and `SAB_MKV_FIXTURE`; otherwise they are skipped. Follow [docs/validation.md](docs/validation.md) for full fixture checks. Test actual spatial output, chunk independence, truncation handling, duration and priming when relevant. Height-channel energy alone does not prove correct spatial placement.

Keep [README.md](README.md), the guides in [docs](docs/) and [docs/validation.md](docs/validation.md) aligned with supported behavior and measured results. Do not repeat expensive validation unless a change or unresolved failure justifies it.

To release, run the Core workflow on `main` with the version (`gh workflow run core.yml -f version=VERSION`). It runs `./scripts/release-core.sh VERSION`, tests the package, pushes the tag and creates the GitHub release. The release commit stays off `main`: hosts get a downloaded core from release tags, while `main` keeps the local binary target so tests always link the Rust sources. Never move or replace a published tag or archive; its checksum is pinned by dependents.
