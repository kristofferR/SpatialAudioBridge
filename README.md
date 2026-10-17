# SpatialAudioBridge

Play **TrueHD Atmos** and **DTS:X** on Apple TV with native spatial audio, including the height channels.

Apple TV cannot decode either format. Players usually decode them to multichannel PCM and lose the heights, or the server transcodes them. SpatialAudioBridge decodes the track, renders its objects and heights into 7.1.4 or 9.1.6 speaker feeds, and encodes those feeds as **Apple Positional Audio Codec (APAC)**, which Apple TV plays natively. With a silent Dolby Atmos stream alongside, which the library bundles, the receiver switches to Atmos.

```text
TrueHD Atmos / DTS:X ─▶ decode ─▶ render objects to 7.1.4 / 9.1.6 ─▶ APAC ─▶ AVPlayer or AVSampleBufferAudioRenderer
```

> [!NOTE]
> Tested end to end on an Apple TV 4K (2nd generation) with tvOS 27.2 beta, an Atmos receiver and Jellyfin. Atmos objects follow Dolby's published consumer renderer specification (ETSI TS 103 448). See [accuracy](#accuracy) and [validation](docs/validation.md) for what is and is not established.

## Choose an integration

| The player… | Use | Guide |
|---|---|---|
| plays video with `AVPlayer` | `APACStream` | [Play through AVPlayer](docs/avplayer.md) |
| renders with `AVSampleBufferRenderSynchronizer` | `SpatialAudioRenderer` | [Play through sample buffers](docs/sample-buffer-playback.md) |
| converts files or builds its own HLS | `SpatialAudioTranscoder`, `APACHLSOutput`, `APACTrackConverter` | [Convert and package](docs/conversion.md) |

Every playback path needs `AtmosOutputActivator` for Atmos output; see [Atmos output](docs/atmos-output.md). The [integration guide](docs/integration.md) covers choosing between paths and how existing players such as Swiftfin and Streamyfin fit.

## Quick start

For a player that uses `AVPlayer`, `APACStream` does everything between the media server and the player item:

```swift
import SpatialAudioBridge
import SpatialAudioPlayback

try AtmosOutputActivator.configureAudioSession()
let file = try await MatroskaFile.open(HTTPByteSource(url: directPlayURL))
let stream = try await APACStream.start(file: file, videoMaster: serverHLSURL, startTime: position)

let atmos = AtmosOutputActivator()
atmos.attach(to: player)
player.replaceCurrentItem(with: AVPlayerItem(url: stream.masterPlaylistURL!))
await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
player.play()
// Keep both for as long as playback lasts: releasing either stops it.
(self.stream, self.atmos) = (stream, atmos)
```

The stream reads the MKV's TrueHD or DTS track over HTTP range requests, converts it on demand, and serves it from the loopback interface as an HLS audio rendition beside the server's video. Seeking works anywhere: segments from every conversion run share one timeline with the video. If the track cannot be converted, `start` throws and the player falls back to its usual path.

## Current support

| Input / output | Status |
|---|---|
| TrueHD Atmos, 48 kHz, one bed | Supported, including starts at any major sync |
| Atmos object position, size, divergence, snap, zones, trim, gain, activity, timing and ramps | Supported; ETSI TS 103 448 source panner |
| TrueHD dialogue normalisation | Off by default, as in Apple TV's own Atmos playback; `normalizesDialogue` applies it as an AV receiver does |
| Atmos warp mode, a 5.1 downmix setting | Accepted; 7.1.4 and 9.1.6 positions unchanged |
| DTS:X standard four-height presentation, 48 kHz | Supported |
| DTS:X known alternate and IMAX object presentations, 48 kHz lossless | D0, D1, D3 and D4, three-component D0 and object-only routing; only D4 checked on full media |
| Matroska (MKV, MKA), local or over HTTP range requests | Supported, with cue-based seeking |
| APAC 7.1.4 and 9.1.6: MP4 files, HLS fragments, sample buffers | Supported; decoded by Apple's decoder in tests |
| `AVPlayer` playback with on-demand conversion and seeking | Verified on Apple TV with Jellyfin |
| `AVSampleBufferAudioRenderer` playback | Atmos and channel placement verified on Apple TV |
| Atmos ISF, multiple beds, bed distribution or downmix metadata | Rejected |
| Atmos objects outside the room, reserved warp modes | Rejected |
| Unknown DTS:X profiles, mismatched source roles, unresolved folds | Rejected |
| M2TS and MP4 containers | Use the host's demuxer with `SpatialAudioTranscoder` |

Rejected tracks fail with a clear error so the player can fall back. The [rendering model](docs/rendering.md) documents how objects are placed.

Conversions report TrueHD concealed frames, events and longest spans through
[`report.recovery`](docs/conversion.md#report-concealed-input).

## Accuracy

The output is rendered speaker audio encoded as APAC; the original bitstream and its objects are not passed through.

| Area | Accuracy |
|---|---|
| Atmos placement against Apple's Atmos render | Seven demo and film clips at 7.1.4, rendered by SpatialAudioBridge from TrueHD and by Apple's decoder from a Dolby Digital Plus Atmos version of the same audio: median direction error 0.1–2.1°, ceiling share within 0.6 percentage points, median per-channel level error at most 0.4 dB |
| Atmos panner against the specification | 2,880 point, size and divergence cases match a literal transcription of the TS 103 448 pseudocode within 3.2 × 10⁻⁷ |
| Standard DTS:X | No panning: the bed and four height channels play on their own speakers once the heights folded into the bed are removed with the stream's own coefficients. 28 of the 29 DTS:X films in the [library census](docs/validation.md#library-census) use this presentation; the other is IMAX Enhanced |
| APAC encoding | 48.4 dB signal-to-error on a 9.1.6 film excerpt with all 16 channels active; distinct tones in all 16 channels stay in their own channel |

Apple's render passed through a lossy Dolby Digital Plus encode, so part of the remaining error on busier clips is probably codec error. Objects in the alternate DTS:X presentations use a [documented approximation](docs/rendering.md#presentations-and-polar-objects) that no DTS reference render has checked.

## Measured on Apple TV

Apple TV 4K (2nd generation), tvOS 27.2 beta, Jellyfin 12.2 over gigabit Ethernet, 4K HDR10 remux with TrueHD Atmos converted to the default 7.1.4:

| Measure | Result |
|---|---|
| Open the file and convert the first segment | 1.8–2.4 s |
| Conversion speed | About 6× real time in steady playback; 4.5×, or 0.7 s per 3.2-second segment, while video loads after a seek (9.1.6: 1 s) |
| Receiver | Dolby Atmos with `AtmosOutputActivator`; without it, no Atmos |
| Steady playback | A whole film, 1 h 59 min, without a stall; the app's physical footprint stayed between 34 and 64 MB |
| Seeks | Every skip, scrub and jump recovered: 1–1.5 s within converted audio, 5.5–12.5 s elsewhere on a title with 10.4-second keyframe intervals |
| Lip sync | Filmed against video flashes, audio arrived 18 ms later than with the same clip's Dolby Digital Plus Atmos track played natively |

## Documentation

- [Integration guide](docs/integration.md): choosing a path, host responsibilities, fit with existing players
- [Play through AVPlayer](docs/avplayer.md): `APACStream`, seeking, options and limits
- [Play through sample buffers](docs/sample-buffer-playback.md): `SpatialAudioRenderer` with a render synchronizer
- [Convert and package](docs/conversion.md): transcoder, HLS output, configuration, priming and the CLI
- [Media servers](docs/media-servers.md): Jellyfin URLs and network costs
- [Atmos output](docs/atmos-output.md): the bundled silent Atmos stream, how it is made and what was tested
- [Architecture](docs/architecture.md): pipeline, timing grid, live encoding and bounds
- [Rendering model](docs/rendering.md): coordinate mapping and supported metadata
- [Troubleshooting](docs/troubleshooting.md): errors and their causes
- [Validation](docs/validation.md): test coverage, device results and fixtures

Symbol documentation is available in Xcode through DocC.

## Examples

- [StreamPlayer](Examples/StreamPlayer/README.md): a tvOS player for a media server's MKV, through `APACStream` or `SpatialAudioRenderer`.
- [Atmos A/B](Examples/AtmosAB/README.md): compares converted APAC with Dolby Digital Plus Atmos on Apple TV.

## Install

Add the package from a release, in Xcode or in `Package.swift`:

```swift
.package(url: "https://github.com/kristofferR/SpatialAudioBridge", from: "2.0.0")
```

Release tags download the Rust core as a checksummed XCFramework for Macs, Apple TV, iPhone and iPad, and their simulators (universal for Macs and the iOS simulator), so the host needs no Rust toolchain. It is a dynamic framework that exports only the core's C functions, which SwiftPM and Xcode embed in the app, so it links beside other Rust libraries, such as LibDovi. Apps show `SpatialAudioBridgeNotices.text` in their acknowledgements: it covers this library, the Rust components in its core and the Rust standard library.

The API requires **tvOS 26+**, **iOS 26+** or **macOS 26+**. The package itself builds back to tvOS and iOS 13 and macOS 10.15, so apps that support older systems can depend on it and check `#available` before using it. iPhone and iPad builds link but are untested. The package offers three products:

| Product | Contents |
|---|---|
| `SpatialAudioBridge` | Decoding, rendering, encoding, Matroska reading, `APACStream`, `SpatialAudioRenderer`, `IEC61937Unpacker` |
| `SpatialAudioPlayback` | `AtmosOutputActivator`, without the Rust core |
| `apac-convert` | Command-line converter |

## Build from source

The `main` branch and local checkouts build the Rust core themselves. Requires Apple Silicon, Xcode with SDK 26 or newer, and stable Rust.

```sh
./scripts/build-core.sh   # Rust core as an XCFramework: Mac, Apple TV, iPhone and iPad, and simulators
swift build -j 1
swift test -j 1
```

`./scripts/release-core.sh` builds the release archive and prints its checksum. Each release's notes name the commit and toolchain to rebuild it with and compare.

CI checks the packaged macOS framework in a mixed Rust, Objective-C and C++ host before artifact upload or release publication, including caught exceptions. See [packaging coverage](docs/validation.md#mixed-language-packaging-check) for the toolchains and limits.

## Decoder dependencies

- **[truehdd](https://github.com/truehdd/truehdd)** (`truehd` crate): TrueHD framing, parsing and decoding, including Atmos presentation PCM and object metadata. This library uses the pinned [harletty fork](https://github.com/harletty/truehdd/tree/5c8b880405946e7ff1aee884cf9988415fe2c3a9).
- **[dca](https://github.com/harletty/harletty-bridge/tree/a717bae441b116485f0254603dc20a6ede65d8c6/dca)**: the Rust DTS decoder in `harletty-bridge`, supplying DTS-HD lossless decoding, DTS:X presentation classification and object positions, and the fold metadata used to remove spatial contributions from the compatible bed.
- **[oamd](https://github.com/truehdd/oamd)**: Atmos object-audio metadata parsing, through `truehd`.

SpatialAudioCore adds metadata checks, channel routing and bed/height panning. Revisions are pinned in [Cargo.toml](Rust/SpatialAudioCore/Cargo.toml) and [Cargo.lock](Rust/SpatialAudioCore/Cargo.lock).

## Acknowledgements

Thanks to [Native Player](https://apps.apple.com/app/native-player/id6760623926) for the idea. It showed that TrueHD Atmos converted to APAC could play on Apple TV with its height channels intact, and that started this library.

## License

Apache 2.0. The one exception is the core's DTS decoder, the `dca` crate, which is ported from FFmpeg and usable under the LGPL, version 3 or later; the core is a dynamic framework so apps can meet that license and keep their own. Dependency licenses and distribution requirements are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md); apps can show `SpatialAudioBridgeNotices.text`.
