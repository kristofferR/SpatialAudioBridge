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
| TrueHD damaged access unit | Damage 50 access units before a major sync is concealed with silence up to it, keeping every sample, independent of input chunking; damage at that major sync as well fails |
| Peak limiter | Whole 7.1.4 renders of *Looper*, *F9*, *Alita: Battle Angel*, *Edge of Tomorrow* and *The Matrix Reloaded*, the films furthest above full scale, peak at −0.10 dBFS instead of +5.2 to +8.9 dBFS. 0.9–7.0% of each film changed, in 34 to 384 stretches of at most 9.7 s including recovery, with reductions up to 9.0 dB; every other sample is bit-identical. Synthetic tests cover the ceiling, chunk independence, frame count and the return to unchanged output |
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

### APAC peak measurements

On 2026-10-15, [Core run 38806510480](https://github.com/kristofferR/SpatialAudioBridge/actions/runs/38806510480) passed all 32 synthetic cases on macOS 26.6.2 (25G83): four signals, two layouts, file/live profiles and 0/+3 dB post-limiter gain. At 0 dB gain, the maximum over the two layouts was:

| Signal | Input sample peak | Limited sample peak | Limited reconstructed estimate | Decoded sample peak | Decoded reconstructed estimate |
|---|---:|---:|---:|---:|---:|
| 1 kHz tone | +6.021 | −0.100 | −0.100 | −0.099 | −0.099 |
| 8 kHz tone | +4.771 | −0.100 | +1.566 | −0.090 | +1.565 |
| Isolated transients | +12.041 | −0.100 | −0.100 | −0.100 | −0.100 |
| Multichannel tones | +5.105 | −0.100 | +0.959 | +0.455 | +0.954 |

All values are dB relative to full scale; reconstructed values are the four-times estimates described below. File and live profiles produced identical peak measurements for each matching case in this short run. The multichannel decoded sample peak was 0.555 dB above the encoder-input sample peak and exceeded full scale. The 8 kHz reconstruction peak already exceeded full scale before encoding and changed little after decoding, so it is not evidence of APAC adding that overshoot. Adding +3 dB after the limiter raised decoded peaks by approximately 3 dB, as expected.

The −0.1 dBFS limiter ceiling therefore applies to its output samples, not post-APAC samples or reconstructed peaks. Keep that ceiling unchanged for now: these short probes establish the limitation but do not establish a universally sufficient replacement margin. The direct encoder, broader signal/configuration coverage and receiver behavior remain unmeasured by this experiment.

#### Reproduction

The Core workflow generates two-second synthetic 1 kHz and 8 kHz tones, isolated transients and multichannel tones on Linux with `examples/peak_probes.rs`. It runs the production limiter source on each signal in 7.1.4 and 9.1.6, preserving the input and limited PCM as temporary little-endian Float32 artifacts. No private media is used or committed.

On the Apple runner, `PeakMeasurementTests` feeds that limited PCM into the transcoder's existing accumulator, encodes file and live fragmented output, and reads it back through `AVAssetReader`. It checks finite PCM, exact presented duration and the reported encoder-input peak. Cases use both 0 dB and +3 dB `gainDB`: that gain is applied **after** the limiter, so it can intentionally exceed the limiter ceiling. Bitrate and sync frequency stay at the layout's defaults; the JSON records those settings, queried priming and the runner's OS.

Each `SAB_PEAK_MEASUREMENT` JSON line reports sample peaks before limiting, after limiting, after gain and after decoding, plus reconstructed-peak estimates after limiting, gain and decoding. The `apac-peak-measurements` artifact retains the test log. These are measurements, not assertions that APAC preserves a ceiling. The reconstruction estimate evaluates four phases with a 33-tap Blackman-windowed sinc filter, calibrated with a known intersample-peak tone; it is not a certified true-peak meter or a bound over every continuous-time peak. Separate input and decoded estimates avoid attributing pre-existing intersample peaks to APAC.

To regenerate the inputs on Linux:

```sh
cargo run --release --locked --manifest-path "Rust/SpatialAudioCore/Cargo.toml" \
  --example peak_probes -- "/tmp/sab-peak-probes"
```

The Apple test enables the experiment only when `SAB_PEAK_PROBES_DIR` names that artifact directory. This measures the asset-writer file and fragment paths, not the direct sample-buffer encoder, receiver output or HDMI behavior. Aggregate limiter/recovery diagnostics remain separate work; this experiment does not change the limiter or public API.

A later [Apple run](https://github.com/kristofferR/SpatialAudioBridge/actions/runs/38808096964) returned 117,760 decoded frames instead of 96,000 for the live 9.1.6 multichannel case. The duration mismatch remains unexplained. The test retains a failing synthetic MP4 when `SAB_PEAK_FAILURES_DIR` is set and logs container timings and a second read; a successful second read does not erase the original failure. For a deliberate diagnostic run on an Apple build host, `SAB_PEAK_STRESS=1` repeats that case 32 times per gain. Required PR CI leaves this flag unset and runs the normal 32-case matrix, with the exact-duration assertion intact.

### APAC dynamic-range-control buffering

`DRCMeasurementTests` compares the current Capture/Movie DRC settings with disabled DRC using four seconds of synthetic multichannel tones, changing levels and transients. It keeps bitrate and sync frequency fixed, covers both layouts and live/offline content profiles, and exercises the direct packet encoder and fragmented asset-writer path. Playback defaults remain unchanged; the DRC switch is internal to the experiment.

Each `SAB_DRC_MEASUREMENT` JSON line records submitted frames at the first pre-flush output, output count before flushing, queried priming, decoded frame count, sample peak, RMS and OS/configuration. A null first-output value means no output was observed before flushing the four-second input, not infinite latency. Writer callback scheduling makes its submitted-frame observation an upper bound; it is not a precise count of frames consumed by the native codec. Offline content settings are tested with fragmented output so callbacks remain observable, not with a standalone file destination.

The direct decoder's raw frame count includes priming and trailing packet padding; its peak/RMS measurements use the source-length span after priming. The native file reader checks presented duration and contiguous timestamps for concatenated fragments. Core CI retains these lines in the package-test log within `apac-peak-measurements`. This experiment does not measure player seek recovery, receiver behavior or device latency, and its four-second input cannot determine longer lookahead exactly.

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

`examples/census.rs` reports which object metadata controls a TrueHD stream uses, or which DTS:X presentation, object positions and bed folds a DTS stream carries. For both, it reports where the renderer first rejects the stream and the rendered peaks before limiting in both layouts, using the Rust-only `Core::new_unlimited` measurement path. Playback remains limited by default. It accepts a TrueHD stream starting mid-access-unit, so FFmpeg can cut windows from a film:

```sh
# A 60-second window from 30:00; use -f dts for a DTS track.
ffmpeg -ss 1800 -t 60 -i "$URL" -map 0:a:0 -c copy -f truehd - |
  cargo run --release --example census --manifest-path "Rust/SpatialAudioCore/Cargo.toml" -- -
```

The four Dolby demo fixtures and both DTS:X fixtures pass without a rejection. On 2026-10-12 and 13 the census read every TrueHD and DTS track of the 895 such files in the movie and TV libraries, over the NAS share:

- **TrueHD Atmos**: every frame of all 265 tracks (160 films and 105 episodes of four series), 450 hours.
- **DTS:X**: every frame of all 29 films, 63 hours.
- **DTS-HD MA and High Resolution without a DTS:X label**: every frame of 172 tracks (144 films and 28 episodes), 326 hours. FFmpeg, and so Jellyfin, labels the alternate D4 fixture plain DTS-HD MA, so the label alone does not rule out DTS:X.
- **Other tracks**: every frame of the 19 TrueHD tracks without Atmos, and a 60-second window from the middle of each of 447 DTS core tracks, which cannot carry DTS:X.

| TrueHD Atmos | Result |
|---|---|
| Warp mode | One film. *Black Hawk Down* (2001) carries trim elements with `warp_mode` 1 in 21% of its metadata payloads, in whole scenes from 11:04, and renders in both layouts |
| Other trim metadata | None; *Black Hawk Down*'s trims are the defaults |
| Size, snap, zones, screen anchoring, distance, divergence, elevation disable, bed distribution or downmix, ISF, multiple beds | Not used in any frame |
| Rejected | None. Two films join clips partway through: the access unit before the join is cut short and the next ones lack the restart they follow, so they cannot be decoded, in *Toy Story* (1995) at 17:49 (51 access units) and *Star Wars: Episode I* (1999) at 54:25 (27). The decoder rejected both until it [concealed such joins](rendering.md#damaged-access-units); FFmpeg and truehdd decode through them |
| Bed | LFE only in every track, with 11 objects alongside in 196 tracks, 13 in 44 and 15 in 25 |
| Object blocks inside the room (at least 2.5% of the room size from every wall) | In 194 tracks |
| Dialogue level | −31 dB in 225 tracks; −23 to −30 dB in 40, most often −27 dB |
| Peaks above full scale, before the [limiter](rendering.md#levels) | 135 of 265 tracks in 7.1.4 and 124 in 9.1.6, most often in the centre, then front left and the front heights. The highest reached +8.9 dBFS (*Looper*); 39 tracks exceeded +3 dBFS and 6 exceeded +6 dBFS |

| DTS | Result |
|---|---|
| DTS:X presentation | Standard 7.1.4, four fixed heights and no objects, in every frame of 28 films. *Independence Day* (1996, extended cut) uses the IMAX Enhanced presentation, 7.1.4 with two objects, both at 12° elevation |
| Bed folds | Stated in every frame |
| Rejected | None of the DTS:X films |
| Peaks above full scale, before the limiter | Two films: *Independence Day* at +1.2 dBFS and one at 0.0 dBFS |
| DTS-HD without a DTS:X label | No DTS:X extension, standard or alternate, in any of the 172 tracks; the renderer rejects them, as intended |
| DTS core | No DTS-HD extension in any window but one episode of *The Expanse*, a lossless extension without DTS:X |

### Reference rendering

| Check | Result |
|---|---|
| Dolby rendering on macOS | Apple's E-AC-3 decoder, through `ExtAudioFile` and `AVAssetReader`, returned only the 5.1 core of a DD+ Atmos fixture into a 7.1.4 layout, with silent heights, so it gives no reference object rendering |
| Apple's live Atmos render | `AVPlayer` renders DD+ Atmos objects to 7.1.4 when its output device has that layout: BlackHole 16ch set to Apple's Atmos 7.1.4 layout, with an `MTAudioProcessingTap` recording the 12 channels. Against our 7.1.4 render of the TrueHD originals of three Dolby demos and four film excerpts, level-matched and compared in 200 ms windows: median direction error 0.1–2.1° (90th percentile at most 7.7°), ceiling energy share within 0.6 percentage points and mean elevation within ±0.4° on every clip, median per-channel share error at most 0.4 dB. The panner before the TS 103 448 one was 0.1–6.6° off and put up to 4.1 points too much in the ceiling. The reference passes through a lossy JOC encode; that error has not been separated out |
| Level against Apple's render | Apple's render of DD+ Atmos ignores dialogue normalisation. Without it, the default since 1.3.0, our 7.1.4 renders of the TrueHD originals of natures-fury (dialogue level −27 dB) and amaze (−31 dB) were 0.15 dB and 0.13 dB below Apple's render of the matched DD+ tracks; with it, natures-fury was 4.15 dB below |

## Coverage

The Core workflow runs Rust tests and Clippy on Linux before the Apple archive and package checks. Clippy treats warnings as errors. Public CI has no private media: Rust's compressed-fixture tests remain ignored, and fixture-dependent Swift tests are skipped. A successful workflow does not establish compressed-media or receiver behavior.

The separate [Rust fuzz harness](../Rust/SpatialAudioCore/fuzz/README.md) exercises compressed-input chunking, truncation, repeated input and C session terminal state with synthetic framing seeds on Linux. It uses AddressSanitizer, bounded runtime and memory, corpus caching and reproducible failure artifacts. A short clean run is not proof that malformed inputs cannot crash or grow buffers; the initial seeds do not establish valid spatial-decoding coverage. Swift parser fuzzing remains separate work.

### Mixed-language packaging check

The Apple build and release jobs run `scripts/test-mixed-host.sh` after creating the release ZIP, before uploading the artifact or publishing a release. It extracts the ZIP into a path with spaces and uses its macOS library and headers to build an Objective-C/C++ executable alongside an independent Rust static library. Both archive orders run with companion libraries built by Rust 1.86.0 and 1.99.0; the core is built by Rust 1.99.0.

The executable exercises SAB session creation, configuration, input/error handling and destruction before and after the companion library catches a deliberate Rust panic. It also checks Objective-C catch/finally and C++ catch/destructor behavior. Each language catches its own exception or panic before returning through the C ABI. The negative control links the original, unisolated Cargo archive with the Rust 1.86.0 companion and requires a duplicate `rust_eh_personality` diagnostic; an unrelated build failure does not pass the control.

This checks the native macOS architecture of the `macos-26` runner (Apple Silicon), with Xcode/Clang and OS versions recorded in the job log. The script also supports native Intel macOS with a 10.15 deployment target; Apple Silicon uses 11.0. A deployment target is not a runtime test on that older OS. The harness does not deliberately panic inside SAB, decode programme media, run iOS/tvOS slices, or establish receiver/HDMI behavior.

To reproduce on a macOS build host after building the archive, install the two Rust toolchains and run:

```sh
rustup toolchain install 1.86.0 1.99.0 --profile minimal
./scripts/test-mixed-host.sh
```

An optional argument selects another release ZIP. The matching unisolated Cargo archive must still be present under `Rust/SpatialAudioCore/target/<native-target>/release` for the negative control. No simulator, signing or private fixtures are needed.

### Package and renderer coverage

`PresentationTimingTests` feeds synthetic clicks into the transcoder's existing PCM accumulator, then reads MP4 and concatenated fragmented MP4 through `AVAssetReader`. It checks decoded timestamps and duration, click placement within 1 ms, fragment continuity and final-packet trimming at zero and nonzero source starts. The native reader presents both forms from movie time zero, including the concatenated fragments, so the tests separately inspect each fragment's stored `tfdt` to verify its original media timestamp. This reader behavior does not establish HLS playback timing. A fresh seek session includes a click in discarded pre-roll to detect leakage into the new timeline. Priming is queried; the click detector uses the main impulse peak and excludes a 50 ms ringing window from silence checks. These tests use the offline profile for files and the live profile for fragments, with 7.1.4 output and uneven PCM blocks.

This coverage starts after compressed decoding. It does not exercise Matroska seeking, `APACStream` playlist joins, sample-buffer renderer presentation, hardware playback or measured lip sync. Those require their separate checks; a fresh transcoder session alone does not validate a player's seek behavior.

The suite includes 33 Rust unit tests, 7 Rust fixture tests and 58 Swift tests. Without fixture variables, 45 Swift tests run: configuration, final-fragment trimming, silence padding to the playlist's end, playlists and variant filtering, subtitle routing and WebVTT time maps, the bundled notices, IEC 61937 unpacking of synthetic MAT and type IV bursts, the loopback server with pipelined requests, HTTP error handling, the stream's restart rule, cache window, helper runs, run endings and timestamp continuity, synthetic and malformed Matroska files, tracks that end before the video, the encoder round trip, renderer settings and failures, and the activator. Four tests need `SAB_TRUEHD_FIXTURE` or `SAB_DTSX_FIXTURE` (one of them also FFmpeg at `/opt/homebrew/bin/ffmpeg`), one needs `SAB_DTSX_ALTERNATE_FIXTURE`, and eight need `SAB_MKV_FIXTURE`. Rust Clippy and the Swift build pass with warnings treated as errors.

HLS codec strings are derived from the platform encoder's documented format mapping; this check does not independently parse the APAC profile from its opaque bitstream. The PCM chunk comparison checks that network and demuxer buffering do not change output. These checks do not establish equivalence to a licensed reference renderer. Full compressed alternate-profile media has been validated for D4 only. The other alternate profiles have synthetic routing checks; the IMAX component vector validates metadata parsing with synthetic PCM, not a complete IMAX track or APAC round trip. Full media and listening validation for those profiles remain outstanding.

## Not yet established

- Correct speaker placement beyond the channel check and informal listening, and the HDMI payload itself; tvOS reports MAT Atmos output.
- Lip sync with dialogue, measured rather than observed.
- Receiver output from `SpatialAudioRenderer` itself, beyond its rendering status; the earlier listening test fed the renderer from a file.
- Memory use over a full film, Wi-Fi playback, and other Apple TV models and receivers.
- Whether the peak limiter is audible. AtmosAB clips of the films' worst moments are prepared for a blind comparison against the unlimited render and DD+.
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

Fixture media remains local. Run ordinary Rust checks on Linux:

```sh
cargo test --release --locked --manifest-path "Rust/SpatialAudioCore/Cargo.toml"
cargo clippy --all-targets --locked --manifest-path "Rust/SpatialAudioCore/Cargo.toml" -- -D warnings
```

From the repository root, explicitly run all ignored Rust fixture tests on Linux:

```sh
SAB_TRUEHD_FIXTURE="/absolute/path/atmos.thd" \
SAB_DTSX_FIXTURE="/absolute/path/dtsx.dts" \
SAB_DTSX_ALTERNATE_FIXTURE="/absolute/path/dtsx-alternate.dts" \
./scripts/test-rust-fixtures.sh
```

The script rejects missing, unreadable or empty fixture files before invoking Cargo. It runs the `fixtures` test target with `--ignored`; ordinary `cargo test` does not run those tests, even when fixture variables are set.

The `render` example writes unlimited PCM and reports each rendered channel's peak and the samples above full scale, before limiting; write to `/dev/null` to measure a whole film:

```sh
cargo run --release --locked --manifest-path "Rust/SpatialAudioCore/Cargo.toml" --example render -- truehd film.thd /dev/null 7.1.4
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
