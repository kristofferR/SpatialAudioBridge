# Player integration

Keep the player’s existing demuxer. Route the selected TrueHD Atmos or DTS:X payload to `SpatialAudioTranscoder` instead of the conventional audio decoder. The transcoder creates APAC files or fMP4 fragments; `APACHLSOutput` persists fragments into an audio EVENT playlist.

For streaming video, the host must expose the audio playlist over its local HTTP service and attach it as an alternative audio rendition to the video HLS master playlist. The video rendition must use codecs and containers accepted by AVPlayer. Align audio and video using the first audio PTS in `APACConfiguration.startTime`; sample counts determine all subsequent audio timestamps.

Use `hls.layout.apacCodecString` (or `configuration.layout.apacCodecString` for direct segment callbacks) in the variant’s `CODECS` list alongside the video codec. This includes the mandatory APAC profile and level: `apac.31.03` for 7.1.4 and `apac.31.04` for 9.1.6. Set the audio rendition’s `CHANNELS` to `"12"` or `"16"` using `layout.channelCount`; do not label this channel-based APAC output as JOC. The host still supplies rendition grouping, language, URIs and measured bandwidth.

A container timestamp gap or a seek needs a new conversion session. Begin at a decodable major sync, discard preroll in the host when necessary, and start a new HLS initialization segment with a discontinuity. TrueHD may begin at any major sync: audio decoded before the first object metadata is kept and rendered at the first known object positions. The library accepts continuous elementary-stream bytes and cannot infer missing packets, container trim metadata or timestamp jumps from those bytes.

The Swift actor rejects overlapping append/finish operations. Backpressure suspends the caller while Apple's writer catches up. PCM is batched into 1024-frame buffers and compressed input is decoded in 4096-byte chunks. A callback failure, malformed/truncated stream or encoder failure ends the session; create a fresh session to recover. Apply `gainDB` explicitly if additional headroom is needed. `peakPCM` reports the largest pre-encoding sample, without automatic clipping or normalization.

For a player using VLC, mpv or another PCM pipeline, integration includes choosing a native AVPlayer route for this audio/video presentation. A library that produces APAC cannot make a PCM-only audio sink emit spatial HDMI audio by itself. React Native applications can wrap the Swift actor in their native playback module; the public boundary consists of data, URLs, configuration and segment callbacks.

The package currently requires tvOS 26. A production integration retaining older OS support will need an availability-gated packaging arrangement and the player's existing audio fallback.

## Atmos output

APAC alone did not switch the tested Apple TV's HDMI output to Atmos. Use `AtmosOutputActivator` from the `SpatialAudioPlayback` product, which does not link the Rust core. Create it with a near-silent E-AC-3 + JOC stream and attach it to the host's `AVPlayer`. It plays that stream in a separate, unmuted player while the host plays, or is waiting to play, an item accepted by the `playsAPAC` predicate. It pauses with the host and re-evaluates on item and audio selection changes. For an HLS item that also offers other audio, return true only when the APAC rendition is selected. Call `detach()` when leaving playback.

`AtmosOutputActivator.configureAudioSession()` applies the tested session: playback category, movie playback mode and multichannel content. The A/B example also activates an `MPNowPlayingSession` for the main player. Native Player 1.1.2 uses the same silent Atmos technique with only a playback/movie session, so the multichannel and Now Playing steps may be unnecessary; the example's launch arguments isolate them.

This is a measured workaround on tvOS 27.2 beta, not an Apple guarantee or proof of correct height/speaker placement. Receiver Atmos activation was confirmed by listening and receiver indication; session channel count, rendering mode and spatial-audio flags were unsuitable detectors on that system. Validate the setup on each target route and OS. The library does not distribute a silent Atmos stream; the host supplies one.

## Encoder priming

`APACConfiguration.encoderPrimingDuration()` queries the installed Core Audio encoder. `APACHLSOutput.encoderPrimingDuration` exposes the same value before writing. On the tested system it is 2048 samples, or 42.667 ms at 48 kHz. MP4 file writing trims this priming from the presented duration. Fragmented output retains it in the coded timeline, so its segment durations total the source duration plus this offset.

Preserve the fragment timestamps and codec/trim metadata when constructing the native presentation. A nonzero start time gives the encoder room to represent priming before the requested source PTS; timestamps are clamped at zero for a zero start. Apple's decoder trims the priming: concatenated fMP4 decoded to exactly the original sample count in the fixture test. Segment duration sums describe the coded timeline, while the conversion report counts source PCM samples. Device playback and seek synchronization still need verification in each host player.

## Encoder configuration

Defaults are 9.1.6, 48 kHz, 256 kbit/s per channel capped at 4.096 Mbit/s, Movie dynamic-range configuration and an APAC sync packet every 75 codec packets. The encoder uses the SDK's `AppleAV_Spatial_Offline` content source. On macOS 27.0.1, the generic `AV_Spatial_Offline` setting failed `canApply`, while the Apple spatial setting succeeded for both output layouts. Treat this as measured platform behavior and recheck on target devices and OS versions.

Apple requires profile and level in the codec string in its [HLS authoring specification](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html). The strings above follow the platform encoder’s published channel-count mapping. Apple describes APAC and sync-packet requirements in its [APAC technical note](https://developer.apple.com/av-foundation/Apple-Positional-Audio-Codec.pdf). The renderer uses the published metadata timing relationship from [ETSI TS 103 448](https://www.etsi.org/deliver/etsi_ts/103400_103499/103448/01.01.01_60/ts_103448v010101p.pdf), with update offsets in units of 32 samples and gain ramps lasting the signalled duration plus one sample.
