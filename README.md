# SpatialAudioBridge

A Swift library that converts demuxed **TrueHD Atmos** and **DTS:X** audio into **Apple Positional Audio Codec (APAC)** media for native Apple playback.

Built on [truehdd](https://github.com/truehdd/truehdd) and [dca](https://github.com/harletty/harletty-bridge/tree/a717bae441b116485f0254603dc20a6ede65d8c6/dca), with Apple's platform APAC encoder.

```text
compressed track → Rust decoder → spatial speaker renderer → Float32 PCM
                  → Apple APAC encoder → MP4 or fragmented MP4 / HLS
```

This is an experimental first implementation. TrueHD objects are rendered into 7.1.4 or 9.1.6 speaker feeds. The established DTS:X height presentation is decoded and its height contribution is removed from the compatible bed before recombination. APAC then encodes those spatial feeds. This involves rendering and lossy encoding; it does not preserve the original object stream or bitstream.

## Decoder dependencies

The compressed-audio decoding and metadata parsing come from these upstream projects:

- **[truehdd](https://github.com/truehdd/truehdd)** (`truehd` crate): TrueHD framing, parsing and decoding, including Atmos presentation PCM and object metadata. This library uses the pinned [harletty fork](https://github.com/harletty/truehdd/tree/5c8b880405946e7ff1aee884cf9988415fe2c3a9).
- **[dca](https://github.com/harletty/harletty-bridge/tree/a717bae441b116485f0254603dc20a6ede65d8c6/dca)**: the standalone Rust DTS decoder in `harletty-bridge`. It supplies DTS-HD lossless decoding, the supported DTS:X height presentation, and the fold metadata/rendering used to remove height contributions from the compatible bed.
- **[oamd](https://github.com/truehdd/oamd)**: Atmos object-audio metadata parsing, included through `truehd`. Its parsed positions, gains and timing drive this library's object renderer.

SpatialAudioCore adds supported-metadata checks, channel routing and bed/height panning. The Swift layer provides the streaming API, Apple's APAC encoding and file/HLS output. Decoder revisions are pinned in [Cargo.toml](Rust/SpatialAudioCore/Cargo.toml), with resolved versions in [Cargo.lock](Rust/SpatialAudioCore/Cargo.lock). Dependency licenses and distribution requirements are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Build

Requires Apple Silicon, Xcode with SDK 26 or newer, and stable Rust. Encoding requires **tvOS 26+** or **macOS 26+**. The generated XCFramework includes Apple TV device, Apple TV simulator and Apple Silicon Mac slices.

```sh
./scripts/build-core.sh
swift build -j 1
swift test -j 1
```

Build artifacts are generated locally. Build the XCFramework before adding this checkout as a local Swift package dependency. A future release can replace the local binary target with a downloadable, checksummed XCFramework.

## Convert a track

```swift
import SpatialAudioBridge

let report = try await APACTrackConverter.convert(
    elementaryStream: inputURL,
    codec: .trueHDAtmos, // or .dtsX
    output: apacMP4URL
)
```

For a player's existing demuxer, stream compressed audio payloads directly:

```swift
let audio = try SpatialAudioTranscoder(
    codec: .dtsX,
    destination: .file(apacMP4URL),
    configuration: .init(layout: .sevenOneFour, startTime: firstAudioPTS)
)
for try await packet in demuxedAudioPackets {
    try await audio.append(packet.data)
}
let report = try await audio.finish()
```

Await each append. Supply only the selected track, starting at a major sync. DTS input must include both its core and DTS-HD extensions in 16-bit big-endian form. Container files such as MKV and M2TS need demuxing first. Start a new session after a seek, discontinuity or format change. Call `cancel()` when abandoning playback; task cancellation also stops conversion.

## Stream APAC over HLS

```swift
let config = APACConfiguration(layout: .nineOneSix, startTime: firstAudioPTS)
let hls = try APACHLSOutput(directory: newOutputDirectory, configuration: config)
let audio = try SpatialAudioTranscoder(codec: .trueHDAtmos,
                                     destination: hls.destination,
                                     configuration: config)
for try await packet in demuxedAudioPackets {
    try await audio.append(packet.data)
}
let report = try await audio.finish()
try hls.finish()
// Serve hls.playlistURL and its adjacent init.mp4 / .m4s files over HTTP.
// hls.encoderPrimingDuration exposes the encoder's leading-frame offset.
// hls.layout.apacCodecString supplies the audio CODECS entry for the master playlist.
```

Players can also consume `.segments(onSegment:)` directly. Segment reports include timestamps and durations. Callback errors propagate to conversion. The default segment interval is two APAC sync periods, approximately 3.2 seconds at 48 kHz.

The host player owns container parsing, networking, video remuxing, the HTTP server and A/V synchronization. Fragment timelines include encoder priming; query `encoderPrimingDuration` when aligning the native presentation and retain timing/trim metadata. Combine the audio rendition with compatible video in the host's HLS presentation. Playback through a player's software PCM output will not use native APAC spatial playback.

The [Apple TV A/B example](Examples/AtmosAB/README.md) includes the player/session setup that triggered Atmos for converted TrueHD → APAC on the tested route, using a separate near-silent JOC carrier. Sample media stays local; receiver Atmos activation does not prove correct speaker placement.

## Current support

| Input / output | Status |
|---|---|
| TrueHD Atmos, 48 kHz, one bed, point objects | Implemented; full 58-second fixture rendered |
| Object room position, extended precision, gain, activity, elevation enable, timing and ramps | Implemented; separate bed/height angular panning |
| DTS:X standard four-height presentation, 48 kHz | Implemented; full 95-second fixture rendered |
| DTS:X alternate/IMAX object profiles | Explicitly rejected |
| Atmos ISF, multiple beds and nonzero object sizes | Explicitly rejected |
| Atmos trims, bed distribution/downmix, divergence, snap, screen/distance/zone controls | Explicitly rejected |
| APAC 7.1.4 / 9.1.6, file / HLS fragments | Implemented; Apple encoder and decoder tested |
| Receiver/MAT output and sustained Apple TV performance | Requires device verification |

Use the host player's existing fallback when a track is unsupported. The [rendering model](docs/rendering.md) documents the coordinate mapping and supported metadata. This renderer is not a Dolby/DTS reference renderer. APAC's final HDMI output depends on the device, OS and audio route.

Validation, fixture acquisition and integration boundaries are described in [docs/validation.md](docs/validation.md) and [docs/integration.md](docs/integration.md). The source is Apache 2.0; dependency notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
