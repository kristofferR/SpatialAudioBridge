# SpatialAudioBridge

Play **TrueHD Atmos** and **DTS:X** on Apple TV with native spatial audio, including the height channels.

Apple TV cannot decode either format. Players usually decode them to multichannel PCM and lose the heights, or the server transcodes them. SpatialAudioBridge decodes the track, renders its objects and heights into 7.1.4 or 9.1.6 speaker feeds, and encodes those feeds as **Apple Positional Audio Codec (APAC)**, which Apple TV plays natively. With a near-silent Dolby Atmos stream alongside, the receiver switches to Atmos.

```text
TrueHD Atmos / DTS:X ─▶ decode ─▶ render objects to 7.1.4 / 9.1.6 ─▶ APAC ─▶ AVPlayer or AVSampleBufferAudioRenderer
```

> [!NOTE]
> Experimental. Tested end to end on an Apple TV 4K (2nd generation) with tvOS 27.2 beta, an Atmos receiver and Jellyfin. The renderer approximates object placement; it is not a Dolby or DTS reference renderer. See [validation](docs/validation.md) for what is and is not established.

## Quick start

For a player that uses `AVPlayer`, `APACStream` does everything between the media server and the player item:

```swift
import SpatialAudioBridge
import SpatialAudioPlayback

try AtmosOutputActivator.configureAudioSession()
let file = try await MatroskaFile.open(HTTPByteSource(url: directPlayURL))
let stream = try await APACStream.start(file: file, videoMaster: serverHLSURL, startTime: position)

let atmos = AtmosOutputActivator(silentAtmosStream: silentAtmosURL)
atmos.attach(to: player)
player.replaceCurrentItem(with: AVPlayerItem(url: stream.masterPlaylistURL!))
player.play()
```

The stream reads the MKV's TrueHD or DTS track over HTTP range requests, converts it on demand, and serves it from the loopback interface as an HLS audio rendition beside the server's video. Seeking works anywhere: segments from every conversion run share one timeline with the video. If the track cannot be converted, `start` throws and the player falls back to its usual path.

## Choose an integration

| The player… | Use | Guide |
|---|---|---|
| plays video with `AVPlayer` | `APACStream` | [Play through AVPlayer](docs/avplayer.md) |
| renders with `AVSampleBufferRenderSynchronizer` | `SpatialAudioRenderer` | [Play through sample buffers](docs/sample-buffer-playback.md) |
| converts files or builds its own HLS | `SpatialAudioTranscoder`, `APACHLSOutput`, `APACTrackConverter` | [Convert and package](docs/conversion.md) |

Every playback path needs `AtmosOutputActivator` for Atmos output; see [Atmos output](docs/atmos-output.md). The [integration guide](docs/integration.md) covers choosing between paths and how existing players such as Swiftfin and Streamyfin fit.

## Current support

| Input / output | Status |
|---|---|
| TrueHD Atmos, 48 kHz, one bed, point objects | Supported, including starts at any major sync |
| Object position, extended precision, gain, activity, elevation enable, timing and ramps | Supported; separate bed and height angular panning |
| DTS:X standard four-height presentation, 48 kHz | Supported |
| Matroska (MKV, MKA), local or over HTTP range requests | Supported, with cue-based seeking |
| APAC 7.1.4 and 9.1.6: MP4 files, HLS fragments, sample buffers | Supported; decoded by Apple's decoder in tests |
| `AVPlayer` playback with on-demand conversion and seeking | Verified on Apple TV with Jellyfin |
| `AVSampleBufferAudioRenderer` playback | Atmos and channel placement verified on Apple TV |
| Atmos ISF, multiple beds, nonzero object sizes | Rejected |
| Atmos trims, bed distribution/downmix, divergence, snap, screen/distance/zone controls | Rejected |
| DTS:X alternate and IMAX presentations | Rejected |
| M2TS and MP4 containers | Use the host's demuxer with `SpatialAudioTranscoder` |

Rejected tracks fail with a clear error so the player can fall back. The [rendering model](docs/rendering.md) documents how objects are placed.

## Measured on Apple TV

Apple TV 4K (2nd generation), tvOS 27.2 beta, Jellyfin 12.2 over gigabit Ethernet, 4K HDR10 remux with TrueHD Atmos converted to 9.1.6:

| Measure | Result |
|---|---|
| Open the file and convert the first segment | 2.4–2.5 s |
| Conversion speed | 2.6–2.7× real time |
| Receiver | Dolby Atmos with `AtmosOutputActivator`; without it, no Atmos |
| Sustained playback | 16 minutes without a stall |

## Documentation

- [Integration guide](docs/integration.md): choosing a path, host responsibilities, fit with existing players
- [Play through AVPlayer](docs/avplayer.md): `APACStream`, seeking, options and limits
- [Play through sample buffers](docs/sample-buffer-playback.md): `SpatialAudioRenderer` with a render synchronizer
- [Convert and package](docs/conversion.md): transcoder, HLS output, configuration, priming and the CLI
- [Media servers](docs/media-servers.md): Jellyfin URLs and network costs
- [Atmos output](docs/atmos-output.md): the silent Atmos stream and how to make one
- [Architecture](docs/architecture.md): pipeline, timing grid, live encoding and bounds
- [Rendering model](docs/rendering.md): coordinate mapping and supported metadata
- [Troubleshooting](docs/troubleshooting.md): errors and their causes
- [Validation](docs/validation.md): test coverage, device results and fixtures

Symbol documentation is available in Xcode through DocC.

## Examples

- [StreamPlayer](Examples/StreamPlayer/README.md): a tvOS player for a media server's MKV, through `APACStream` or `SpatialAudioRenderer`.
- [Atmos A/B](Examples/AtmosAB/README.md): compares converted APAC with Dolby Digital Plus Atmos on Apple TV.

## Build

Requires Apple Silicon, Xcode with SDK 26 or newer, and stable Rust. Encoding requires **tvOS 26+** or **macOS 26+**.

```sh
./scripts/build-core.sh   # Rust core as an XCFramework: Mac, Apple TV and Apple TV simulator
swift build -j 1
swift test -j 1
```

Build the XCFramework before adding this checkout as a local Swift package. The package offers three products:

| Product | Contents |
|---|---|
| `SpatialAudioBridge` | Decoding, rendering, encoding, Matroska reading, `APACStream`, `SpatialAudioRenderer` |
| `SpatialAudioPlayback` | `AtmosOutputActivator`, without the Rust core |
| `apac-convert` | Command-line converter |

A future release can replace the local binary target with a downloadable, checksummed XCFramework.

## Decoder dependencies

- **[truehdd](https://github.com/truehdd/truehdd)** (`truehd` crate): TrueHD framing, parsing and decoding, including Atmos presentation PCM and object metadata. This library uses the pinned [harletty fork](https://github.com/harletty/truehdd/tree/5c8b880405946e7ff1aee884cf9988415fe2c3a9).
- **[dca](https://github.com/harletty/harletty-bridge/tree/a717bae441b116485f0254603dc20a6ede65d8c6/dca)**: the Rust DTS decoder in `harletty-bridge`, supplying DTS-HD lossless decoding, the DTS:X height presentation and the fold metadata used to remove height contributions from the compatible bed.
- **[oamd](https://github.com/truehdd/oamd)**: Atmos object-audio metadata parsing, through `truehd`.

SpatialAudioCore adds metadata checks, channel routing and bed/height panning. Revisions are pinned in [Cargo.toml](Rust/SpatialAudioCore/Cargo.toml) and [Cargo.lock](Rust/SpatialAudioCore/Cargo.lock).

## License

Apache 2.0. Dependency licenses and distribution requirements are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
