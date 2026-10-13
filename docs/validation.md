# Validation

Validated on 2026-10-10 with Xcode 27.1, Swift 6.4, macOS 27.0.1 and Rust 1.99.0. Rust decoding tests ran on Linux with an Intel Core i9-13900K. Apple encoding and decoding ran on an Apple Silicon Mac. Device tests ran on an Apple TV 4K (2nd generation) with tvOS 27.2 beta (24K5103f), connected over HDMI to an Atmos receiver, with Jellyfin 12.2 on gigabit Ethernet.

## Results

### Decoding and rendering

| Check | Result |
|---|---|
| Atmos source panner | Every panner target routes to its own speaker, interior and ceiling positions match values worked by hand from TS 103 448, and point gains have unit power on at most eight speakers and are continuous over a room grid |
| Atmos panner against the specification | 2,880 point, size and divergence cases over both layouts match a literal transcription of TS 103 448 pseudocode 3 to 15 within 3.2 × 10⁻⁷ |
| Atmos rendering controls | Size, divergence, snap, zones, elevation disable, screen anchoring, default and custom trims, extended precision and optional dialogue normalisation pass; warp mode 1 leaves a side surround position unchanged; remaining unsupported controls produce explicit errors |
| DTS:X angular panning | Physical speaker angles, overhead symmetry, unit power and absent channels on their own ring pass |
| DTS:X alternate routing | All seven presentations in both layouts pass synthetic fold cleanup, role separation and physical-angle tests; object ramps and fallback errors pass |
| IMAX three-component metadata | Upstream payload parsed and C/L/R components routed correctly in both layouts, using synthetic PCM |
| Full TrueHD Atmos elementary stream | 58-second fixture passes chunking, finite PCM, height-energy and truncation checks |
| Full DTS:X Object Emulator elementary stream | 95-second fixture passes chunking, finite PCM, height-energy and truncation checks |
| Full alternate DTS:X elementary stream | 44.426667-second Trinnov Experience fixture: 4,165 D4 frames, 1,558 distinct object positions; chunking, finite PCM, height-energy and truncation checks pass |
| Decoder chunking | Bit-identical PCM and sample counts with 4096-byte and 317-byte chunks for all three full fixtures |
| Truncation | Removing the final compressed byte produces an error for all three fixtures |
| TrueHD mid-stream start | Starting at a later major sync without object metadata keeps every sample, preserves height audio and is independent of input chunking |
| DTS:X mid-stream start | Entering the standard (Object Emulator) and alternate (Experience) fixtures halfway keeps every frame's duration; a pending frame and the two warm-up frames play as silence, the next is within −30 dBFS of a continuous decode, and ten frames later within 1e-4 |
| Rendered peaks, earlier panner | In 7.1.4 and 9.1.6, no sample exceeded full scale in 38 minutes of a TrueHD Atmos film (peak −0.2 dBFS), the DTS:X fixture (−0.3 dBFS), the Helicopter fixture or seven excerpts of the film |

### Encoding and packaging

| Check | Result |
|---|---|
| HLS codec metadata | Layouts expose `apac.31.03` / `apac.31.04` using Apple's published platform profile/level mapping |
| Eight-second Atmos / standard DTS:X / D4 DTS:X → APAC → Apple PCM decoder | APAC codec and 16-channel 9.1.6 layout confirmed, duration checked, height energy retained |
| Atmos → 7.1.4 fragmented MP4, eight-second and full 58-second streams | 12-channel layout confirmed; continuous timestamps and playlists checked at zero and nonzero start times |
| Fragmented encoder priming | Core Audio reports 2048 leading frames; native decoding trims them. `AVAssetWriter` ignored a `TrimDurationAtEnd` attachment in fragments, but Apple's decoder honored a shortened final sample: with it, the full 58-second stream decodes to exactly its source length at zero and nonzero start times, instead of rounding up to a whole 1024-frame packet |
| Live encoding | Segments trail their input by less than 2 s over 30 s of TrueHD Atmos; the offline profile's first fragment needs 23.3 s of input |
| `AudioConverter` encoder | Sixteen distinct tones survive a 9.1.6 APAC round trip, each correlating above 0.98 with its own channel and below 0.1 with its neighbour |
| Encoder quality tiers | On 20 s of a film, all 16 channels active: high 47.0 dB and medium 48.4 dB signal-to-error, low 43.0 dB; on the height-only fixture, high and medium 60.9–61.0 dB, low 18.8 dB. Medium encoded 1.25–1.5× as fast as high on a synthetic 16-channel signal and 1.06–1.17× on Atmos content (lowest process CPU of repeated runs on a busy Mac), low 3×. `AVAssetWriter` ignored the setting; its packets were bit-identical to `AudioConverter` at medium, Core Audio's default, with the live and offline profiles |
| Samples above full scale | 9.1.6 tones at +4, +6 and +12 dBFS kept their level within 0.1 dB through the APAC encoder and Apple's float decoder |
| Encoder input batching | Passing PCM to `AudioConverter` once a packet's worth is pending, instead of once per 40-frame TrueHD access unit, cut encoding CPU by about 20% with identical packets |
| Conversion profile | In a macOS profile, Apple's APAC encoder was about 85% of conversion work. After moving PCM scaling to Accelerate, Debug and Release builds convert at the same speed |
| Conversion speed by layout | On an Apple Silicon Mac, one conversion at a time, 21 minutes of TrueHD Atmos in eight files converted at 12.0× real time to 7.1.4 and 7.8× to 9.1.6 |
| Release archive | Built from a worktree and from a fresh clone at a path with spaces on one Mac, the archives were byte-identical and their libraries recorded no local paths. A package using the archive as its binary target linked and called the core; SwiftPM kept the license notices beside the XCFramework. Once 1.0.0 was public, a scratch package resolved it from GitHub, verified the downloaded archive's checksum, built, and converted an eight-second TrueHD Atmos clip to 7.1.4 APAC with the release's `apac-convert`. The 1.1.0 archive, with iOS slices added, was again byte-identical across two builds; a package declaring macOS 10.15, iOS 13 and tvOS 13 resolved it from GitHub and linked the core behind `#available` into a dynamic library for macOS, tvOS and iOS devices and arm64 simulators. 1.1.0 failed beside LibDovi 2.1.0, another static XCFramework with a top-level module map ("Multiple commands produce module.modulemap"); with 1.1.1's nested headers, a package depending on both resolved from GitHub and built for macOS, tvOS and the tvOS simulator. 1.2.0 resolved from GitHub the same way, and its tvOS build bundled `ThirdPartyNotices.txt` in the package's resource bundle. The 1.3.0 to 1.6.1 archives were each byte-identical across two builds and resolved from GitHub into the same low-minimum package, which built for macOS and tvOS, and from 1.5.0, with its x86_64 slices, also as a universal arm64 and x86_64 macOS build. 1.5.1 and 1.6.0 changed only Swift code, so their archives match 1.5.0's. From 1.6.2, GitHub Actions builds the archive with Xcode 26.6: Cargo builds only the staticlib, so the profile's LTO applies, and each library is prelinked into one object. Two runs from different commits with the same core sources built byte-identical 4.8 MB archives, down from 1.6.1's 56 MB, and every slice exported only the five `sab_*` functions and a weak `rust_eh_personality`, with its target's platform and minimum OS. On a Mac with Xcode 27.1, the fixture tests passed against the prelinked macOS library, and a test app with its own Objective-C and C++ exceptions linked it beside a Rust 1.86 static library and caught a panic thrown in that library; the plain Cargo library failed there with a duplicate `rust_eh_personality`. Four personality routines in one binary (Objective-C, C++, C and Rust) failed to link with or without DWARF unwind information in the core, and `-Wl,-no_compact_unwind` produced binaries that crashed on the first exception, even without the core |

### Sources and streaming

| Check | Result |
|---|---|
| Matroska reader | Synthetic files cover track metadata, header stripping, all lacing modes, block groups, cues and metadata found through the seek head, seeking to the last sync at or before the target, seeking into a laced block and rejecting malformed lacing |
| Real Matroska file | The Helicopter MKV's TrueHD track is byte-identical to the FFmpeg extraction; a 30-second seek starts at a sync within 0.1 s |
| Matroska over HTTP | From Jellyfin, 8-second conversions from 10:00 succeeded for one TrueHD Atmos and two DTS:X 4K remuxes; seeks reached a sync 21–64 ms before the target |
| Emby and Plex | From Emby 4.10.1 and Plex 1.43.4, 10-second conversions from 10:00 gave the same APAC for one TrueHD Atmos and one DTS:X 4K remux. On macOS, `APACStream` with Emby's HEVC video played from the start but not after Emby restarted its remux; Plex's HEVC playlist played without video. See [media servers](media-servers.md#emby-and-plex) |
| `APACStream` segment grid | Every segment starts at N × 153,600 frames and lasts 153,600 frames, including after jumps forward and back; a restarted segment correlates above 0.99 with the continuous one after the priming |
| `APACStream` pacing | Conversion holds at the lookahead while no requests arrive, then serves later segments without restarting; a request served from the cache does not hold back one waiting further ahead |
| `APACStream` helper run | Played on from the first run's segment, the helper's first segment matches continuous conversion across the join, correlating above 0.99 over the 2048 frames a restart's priming would replace. Replaying `AVPlayer`'s 11 sequential requests after a jump on a busy Apple Silicon Mac: typically 1.4–1.7 s with the helper, 2.1–2.9 s without. On Apple TV, see the seek results below |
| `APACStream` with `AVPlayer` | macOS `AVPlayer` plays the audio playlist and continues after an exact seek to 0:40 |
| Playlist rewriting and loopback server | Video masters keep absolute URIs and I-frame and image playlists; subtitle renditions are served through the stream, with Jellyfin's WebVTT `X-TIMESTAMP-MAP` moved to MPEG-TS 0, other maps kept and IMSC1 and byte-range segments left on the server; the server answers GET, HEAD, byte ranges and unknown paths. On Jellyfin 12.2 ("2012", stream-copy 4K fMP4, three WebVTT renditions) on macOS 27, `AVPlayerItemLegibleOutput` delivered every checked cue between 113 s and 137 s at its WebVTT time, 0.000 s apart, where before each arrived 10 s late |
| IEC 61937 passthrough bursts | FFmpeg's spdif muxer, which mpv's passthrough uses, wrapped the helicopter TrueHD fixture in MAT frames and the DTS:X emulator in type IV bursts at 768 kHz; `IEC61937Unpacker`, fed in uneven chunks, returned byte-identical elementary streams. On the Apple TV, an mpv output in Streamyfin played "2012" through the unpacker and `SpatialAudioRenderer`; across seven seeks and a track switch, `skippedDuration` stayed between 24 and 97 ms with no growing offset. A DTS-HD MA title without DTS:X fell back to PCM as the [mpv guide](sample-buffer-playback.md#mpv) describes. In Plezy's mpv the receiver showed Atmos for a TrueHD Atmos and a DTS:X title, and both fallbacks reached PCM: reselecting the track in about 40 ms, and refusing the reopened format in about 0.6 s |
| `SpatialAudioRenderer` | From a 20-second seek into the MKV fixture, macOS renders APAC and the synchronizer advances |

### Playback on Apple TV

| Check | Result |
|---|---|
| Atmos activation with `AVPlayer` | APAC plus `AtmosOutputActivator` and direct Dolby Digital Plus both trigger Atmos and sound similar; APAC alone does not |
| Atmos activation with `AVSampleBufferAudioRenderer` | Atmos only with the activator; a 7.1.4 channel check played every speaker in its place, including the heights |
| A/B Auto playback | Eight matched 20-second excerpts completed in pair order; silent Atmos stream only during APAC, stop after the final pair, preparation/playback cancellation pass |
| Blind renderer comparison | Four Dolby demos and four film scenes chosen for objects inside the room, level-matched: the DD+ Atmos reference, then the TS 103 448 panner and the previous one as X and Y in random order. They sounded different, but neither was consistently closer to the reference; the TS 103 448 panner was kept |
| Activator and Dolby Digital Plus | Direct Dolby Digital Plus no longer stutters once the activator unloads its stream for non-APAC items |
| Bundled silent stream | With the generated stream, APAC switched the soundbar to Atmos and sounded the same as with a near-silent cut from a Dolby encode, for Helicopter, Amaze and Nature's Fury. An ffmpeg-encoded silent stream with only the `dec3` Atmos bytes added did too. On the Mac, ffprobe reports Dolby Digital Plus + Dolby Atmos, CoreMedia offers the same `'ec+3'` layouts as real streams and Apple's decoder outputs digital silence |
| EMDF protection | Blind, on Helicopter DD+ Atmos: the untouched track played its heights; with only the 40 EMDF protection bits flipped, or with the EMDF syncword broken, the heights were gone. tvOS validates the keyed protection, so generated streams carry no object metadata |
| Atmos output format | With the activator playing, the session's private current hardware format read `'mat+'` (MAT) and the output unit reported 12 channels (`DiscreteInOrder`); idle, `'lpcm'` and 2 channels. `outputNumberOfChannels` reported 8 meanwhile |
| 9.1.6 output | With the activator, a Samsung HW-Q990C soundbar played a 9.1.6 sweep's wides and top middles from neighbouring speakers, the top middles from both front and rear heights: tvOS folds 9.1.6 into its 12-channel output |
| Blind layout comparison | Our 7.1.4 and 9.1.6 renders of a synthetic object circling the room at ear level and overhead and of seven Dolby demo and film excerpts, as X and Y in random order without a reference: 7.1.4 was preferred five times and 9.1.6 three, while the second-played version won seven of eight. No consistent difference; 7.1.4 became the default |
| MAT Atmos without the activator | Requesting `'mat+'` through the private `-[AVAudioSession setPreferredAudioFormat:error:]` switched the output to MAT Atmos with 12 channels, and the soundbar showed Atmos. In an A/B of the same height channels, the heights sounded lower, vaguer and quieter than with the activator. `setPreferredOutputNumberOfChannels(_:)` with 12 or 16 left 8-channel LPCM |
| MAT output without Atmos | AetherEngine 7.34.0's own APAC output, with no activator, read `'mat+'` on every sample of a TrueHD Atmos title while the soundbar, watched in person, showed no Atmos. `'mat+'` therefore shows MAT output, not the receiver's Atmos indication. With `AtmosOutputActivator` attached to the same player, the soundbar showed Atmos, also after a 60-second skip. `outputNumberOfChannels` read 2 without the activator and 32 with it, where earlier sessions read 8 and a later one 2 with Atmos showing, so it is no detector either |
| `APACStream` with Jellyfin | A 4K HDR10 title with TrueHD Atmos played with stream-copied HEVC video and Atmos on the receiver; at 9.1.6, stream ready 2.0–2.5 s and playing 4–5 s after launch, about 1 s of conversion per 3.2-second segment, in Debug and Release builds alike. At 7.1.4, in three Debug launches: ready 1.8–2.4 s, playing 4.3–6.6 s after launch, `conversionSpeed` about 6.3× in steady playback and segments a median 0.7 s apart while video loads after a seek |
| Sustained `APACStream` playback | At 9.1.6, after the pacing fix, no stalls in 37 minutes of steady playback; before it, playback stopped after 111 s when a dropped segment was requested. Available memory stayed within 2,135–2,171 MB across sessions of up to 16 minutes. At 7.1.4, no stalls or segment errors in 15 minutes of steady playback, then remote pauses and skips; available memory stayed within 2,139–2,174 MB over the 22-minute session |
| Seeks with `AVPlayer` | Before the restart rule changed, a long scrub failed the item (`-12880`) and skips back waited up to 30 s. Afterwards, a scripted test of eight skips, scrubs and jumps recovered every time; times below |
| `SpatialAudioRenderer` on device | Renderer mode read the title from Jellyfin, started the synchronizer 1.47 s after launch and reported `.rendering` with the silent Atmos stream playing |
| Activator lifecycle | The silent stream follows host play/pause, plays only for accepted items, follows a synchronizer, stops on detach and reports an unplayable stream (macOS) |

Scripted seeks from 55:06 into the Jellyfin title, whose stream-copy video segments last 10.4 s. Each seek was issued as a remote does, without waiting for the previous one, and timed until playback moved past the target:

| Seek | 9.1.6, Release | 9.1.6, with the helper run | 7.1.4, two runs |
|---|---|---|---|
| Skip forward 10 s, within converted audio | 1.1 s | 1.5 s | 1.1 s, 1.5 s |
| Skip back 10 s, before the first converted segment | 6.8 s | 6.0 s | 6.4 s, 6.8 s |
| Three skips back 10 s, 0.3 s apart | 6.2 s | 6.7 s | 21.5 s (wedge, recovered by the watchdog), 7.5 s |
| Scrub forward 2 min, twelve steps 0.17 s apart | 13.6 s | 11.4 s | 9.3 s, 10.0 s |
| Scrub back 1 min, six steps | 12.2 s | 9.3 s | 9.8 s, 8.0 s |
| Jump forward 10 min | 13.7 s | 9.0 s | 7.3 s, 5.5 s |
| Jump back 5 min | 13.3 s | 9.8 s | 12.5 s, 7.4 s |
| Two 1-minute jumps forward, 0.5 s apart | 11.9 s | 10.0 s | 8.7 s, 6.4 s |

In four of eight runs, the three quick skips back left `AVPlayer` waiting without requesting anything more, after Jellyfin aborted a video segment mid-response or `AVPlayer` reset an audio connection. StreamPlayer's 20-second watchdog recovered both wedges that occurred while it was in place, by replacing the item, the second at the pending seek target; see [troubleshooting](troubleshooting.md#playback-stays-waiting-after-rapid-seeks). In the two runs on the final code, every other seek resumed in 0.7–14.7 s, within about a second of the times above. The helper column is one run of a Debug build; Debug converts as fast as Release. The 7.1.4 runs used a Debug build of the current code: segments converted in a median 0.7 s (0.68–0.80 s for 80% of them), and first segments after restarts in 1.2–2.6 s, with one at 3.1 s and one at 4.9 s after the 5-minute jump back, which `AVPlayer` logged as a −12889 timeout without failing the seek. A run that started the helper together with the first run resumed long jumps as fast, but delayed first segments after restarts to up to 4.2 s, past the 3 s `AVPlayer` allows a seek; starting the helper after the first segment kept them at 1.6–3.1 s, as without it (1.8–3.7 s).

On a 97.5 Mbit/s 4K remux with keyframes at most 0.9 s apart, the same scripted test from 20:00 resumed scrubs and jumps in 5.1–8.2 s and three skips back in 6.8 s; skips within converted audio took 0.7–0.9 s. Its first segments after restarts took 3.0–3.5 s and `AVPlayer` logged three −12889 timeouts without failing a seek: the reader transfers the video too, about 85 MB for the 7 s of file a restart's first segment needs.

### Library census

`examples/census.rs` reports which object metadata controls a TrueHD stream uses, or which DTS:X presentation, object positions and bed folds a DTS stream carries. For both, it reports where the renderer first rejects the stream and the rendered peaks in both layouts. It accepts a TrueHD stream starting mid-access-unit, so FFmpeg can cut windows from a film:

```sh
# A 60-second window from 30:00; use -f dts for a DTS track.
ffmpeg -ss 1800 -t 60 -i "$URL" -map 0:a:0 -c copy -f truehd - |
  cargo run --release --example census --manifest-path "Rust/SpatialAudioCore/Cargo.toml" -- -
```

The four Dolby demo fixtures and both DTS:X fixtures pass without a rejection. On 2026-10-10 the census ran over HTTP on every TrueHD Atmos and DTS-HD title in the Jellyfin library:

- **TrueHD Atmos**: five 60-second windows, at 10%, 30%, 50%, 70% and 90%, from each of 179 titles (74 films and 105 episodes of four series), 15.8 hours in all, and ten of the films in full, 24.8 hours.
- **DTS:X**: all eight titles in full, 17.2 hours.
- **DTS-HD MA without a DTS:X label**: one to three windows from each of 112 titles. FFmpeg, and so Jellyfin, labels the alternate D4 fixture plain DTS-HD MA, so the label alone does not rule out DTS:X.

| TrueHD Atmos | Result |
|---|---|
| Warp mode | One title. *Black Hawk Down* (2001) carries trim elements with `warp_mode` 1 in 21% of its metadata payloads, in whole scenes from 11:04; three of its five windows had none. The renderer rejected it until warp mode was accepted; a 10-minute excerpt with its first two warped scenes now renders in both layouts |
| Rejected | None with the current renderer |
| Other trim metadata | None; *Black Hawk Down*'s trims are the defaults |
| Size, snap, zones, screen anchoring, distance, divergence, elevation disable, bed distribution or downmix, ISF, multiple beds | Not used in any window or full film |
| Bed | LFE only in every title, with 11 objects alongside in 143 titles, 13 in 14 and 15 in 22 |
| Object blocks inside the room (at least 2.5% of the room size from every wall) | In 239 of 895 windows, from 81 titles, up to 42% of active blocks; in 7 of the 10 full films, up to 17% |
| Dialogue level | −31 dB in 166 titles; −23 to −29 dB in 13, most often −27 dB |
| Peaks above full scale in 7.1.4 | 28 of 895 windows from 22 titles, highest +6.2 dBFS, most often in the front heights and centre. In full, *Alita: Battle Angel* reached +7.6 dBFS and *Sinners* +1.5 dBFS, though none of the *Sinners* windows exceeded full scale. The *Black Hawk Down* excerpt reached +2.4 dBFS once warp mode was accepted |

| DTS | Result |
|---|---|
| DTS:X presentation | Standard 7.1.4, four fixed heights and no objects, in every frame of all eight films. Every film used its heights; the loudest height channel peaked between −16 and 0 dBFS |
| Bed folds | Stated in every frame |
| Rejected | None of the DTS:X films |
| Peaks above full scale | None; highest 0.0 dBFS |
| DTS-HD MA without a DTS:X label | No DTS:X extension, standard or alternate, in any of the 112 titles; the renderer rejects them, as intended |

### Reference rendering

| Check | Result |
|---|---|
| Dolby rendering on macOS | Apple's E-AC-3 decoder, through `ExtAudioFile` and `AVAssetReader`, returned only the 5.1 core of a DD+ Atmos fixture into a 7.1.4 layout, with silent heights, so it gives no reference object rendering |
| Apple's live Atmos render | `AVPlayer` renders DD+ Atmos objects to 7.1.4 when its output device has that layout: BlackHole 16ch set to Apple's Atmos 7.1.4 layout, with an `MTAudioProcessingTap` recording the 12 channels. Against our 7.1.4 render of the TrueHD originals of three Dolby demos and four film excerpts, level-matched and compared in 200 ms windows: median direction error 0.1–2.1° (90th percentile at most 7.7°), ceiling energy share within 0.6 percentage points and mean elevation within ±0.4° on every clip, median per-channel share error at most 0.4 dB. The panner before the TS 103 448 one was 0.1–6.6° off and put up to 4.1 points too much in the ceiling. The reference passes through a lossy JOC encode; that error has not been separated out |
| Level against Apple's render | Apple's render of DD+ Atmos ignores dialogue normalisation. Without it, the default since 1.3.0, our 7.1.4 renders of the TrueHD originals of natures-fury (dialogue level −27 dB) and amaze (−31 dB) were 0.15 dB and 0.13 dB below Apple's render of the matched DD+ tracks; with it, natures-fury was 4.15 dB below |

## Coverage

The suite includes 30 Rust unit tests, 6 Rust fixture tests and 58 Swift tests. Without fixture variables, 45 Swift tests run: configuration, final-fragment trimming, silence padding to the playlist's end, playlists and variant filtering, subtitle routing and WebVTT time maps, the bundled notices, IEC 61937 unpacking of synthetic MAT and type IV bursts, the loopback server with pipelined requests, HTTP error handling, the stream's restart rule, cache window, helper runs, run endings and timestamp continuity, synthetic and malformed Matroska files, tracks that end before the video, the encoder round trip, renderer settings and failures, and the activator. Four tests need `SAB_TRUEHD_FIXTURE` or `SAB_DTSX_FIXTURE` (one of them also FFmpeg at `/opt/homebrew/bin/ffmpeg`), one needs `SAB_DTSX_ALTERNATE_FIXTURE`, and eight need `SAB_MKV_FIXTURE`. Rust Clippy and the Swift build pass with warnings treated as errors.

HLS codec strings are derived from the platform encoder's documented format mapping; this check does not independently parse the APAC profile from its opaque bitstream. The PCM chunk comparison checks that network and demuxer buffering do not change output. These checks do not establish equivalence to a licensed reference renderer. Full compressed alternate-profile media has been validated for D4 only. The other alternate profiles have synthetic routing checks; the IMAX component vector validates metadata parsing with synthetic PCM, not a complete IMAX track or APAC round trip. Full media and listening validation for those profiles remain outstanding.

## Not yet established

- Correct speaker placement beyond the channel check and informal listening, and the HDMI payload itself; tvOS reports MAT Atmos output.
- Lip sync with dialogue, measured rather than observed.
- Receiver output from `SpatialAudioRenderer` itself, beyond its rendering status; the earlier listening test fed the renderer from a file.
- Memory use over a full film, Wi-Fi playback, and other Apple TV models and receivers.
- Whether the playback output clips rendered peaks above full scale. APAC preserves them, and the [census](#library-census) found them in at least 24 of 179 Atmos titles. See [levels](rendering.md#levels).
- A release archive rebuilt on another Mac.
- Placement against Dolby's own renderer: the panner matches [Apple's Atmos render](#reference-rendering) closely, but no Dolby reference renderer output of the same content has been compared.

`AVAudioSession.outputNumberOfChannels` reported eight for both working formats (2 and 32 in later sessions, with Atmos showing), and the session's rendering mode and spatial audio flags were also unsuitable Atmos detectors on the tested beta. The private current hardware format, which the AtmosAB output probe reads, distinguishes MAT from PCM output but not the receiver's Atmos indication.

The DTS:X fixture container's first audio PTS is approximately 53 ms; its elementary stream begins at zero. A host must preserve that container offset when configuring the transcoder.

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

For the Matroska and streaming tests, keep the Helicopter MKV's TrueHD track in a Matroska file:

```sh
ffmpeg -i "atmos-sample.mkv" -map 0:a:0 -c copy "atmos-only.mkv"
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

The `render` example reports each rendered channel's peak and the samples above full scale; write to `/dev/null` to measure a whole film:

```sh
cargo run --release --locked --example render -- truehd film.thd /dev/null 7.1.4
```

Run the Apple round-trip, streaming and renderer checks on macOS. Use the full Atmos elementary stream with the MKV made from it, because one test compares the MKV's track with it byte for byte. For both DTS:X fixtures, eight-second, complete-access-unit excerpts are sufficient. The fixture suites serialize their encoder jobs.

```sh
SAB_TRUEHD_FIXTURE="/absolute/path/atmos.thd" \
SAB_DTSX_FIXTURE="/absolute/path/dtsx-8s.dts" \
SAB_DTSX_ALTERNATE_FIXTURE="/absolute/path/dtsx-alternate-8s.dts" \
SAB_MKV_FIXTURE="/absolute/path/atmos-only.mkv" \
swift test -j 1 -Xswiftc -warnings-as-errors
```

On Apple TV, use the [StreamPlayer](../Examples/StreamPlayer/README.md) example against a media server and the [A/B player](../Examples/AtmosAB/README.md) for listening comparisons.
