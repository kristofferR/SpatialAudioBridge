# Direct APAC encoder measurements

`EncoderPerformanceTests` profiles the existing live direct encoder with four seconds of synthetic
speaker tones at 48 kHz, for both layouts and input chunks of 317 or 1024 frames. It runs only when
`SAB_ENCODER_PROFILE=1`. Core PR CI runs it in a separate test invocation after the package checks,
so other test suites do not compete inside the same process. Cloud hosts may still vary in load.

Each case has one warm-up and five measured passes. `SAB_ENCODER_PROFILE` JSON lines contain wall
time, process CPU time, input-frame throughput, first-output submission count, queried priming,
packet count, encoded bytes and a SHA-256 digest covering packet lengths, dependency flags and data.
Repeated passes must have the same packet digest. Hashing and input generation are outside the
timed region; encoder creation, feeding, output collection and final flush are inside it. Encoder
destruction is outside. Process peak RSS is a cumulative high-water mark, including the test
harness, input and retained output; it is not the encoder's live allocation size or allocation count.

The log is retained as `encoder-profile.log` in the `apac-peak-measurements` artifact. Compare
distributions across matching OS, layout, bitrate, sync frequency and input chunks. Do not add
timing thresholds to correctness CI or infer a real-media/device speedup from this probe.

The baseline encoder allocated its output scratch buffer and packet/dependency-description arrays
on each call that had enough input to encode (and on the final flush). The reuse candidate retains
one output buffer, sized for 16 maximum-size packets, and both 16-entry arrays for the encoder's
lifetime. Returned packets still copy their bytes into owned `Data`; the next encode call cannot
overwrite earlier output. Retained input storage already grows only when required.
This experiment does not profile compressed
decoding, rendering, the asset writer, private media, player latency or cancellation/backpressure
under a new pipeline; no overlap or playback change is introduced.

## Baseline

[Core run 38828022358](https://github.com/kristofferR/SpatialAudioBridge/actions/runs/38828022358)
at `3bef1d9b` used macOS 26.6.2 (25G83). Medians exclude the warm-up pass:

| Channels | Input chunk (frames) | Wall time (s) | CPU time (s) | First output after submitted frames |
| --- | --- | --- | --- | --- |
| 12 | 317 | 0.2220 | 0.2221 | 74,812 |
| 12 | 1024 | 0.2255 | 0.2256 | 73,728 |
| 16 | 317 | 0.3006 | 0.3004 | 74,812 |
| 16 | 1024 | 0.2958 | 0.2959 | 73,728 |

All passes emitted 190 packets with 2,048 queried priming frames. Both chunk sizes and all passes
had the same digest within each layout: `d026c96fe4a1534ce0264de37d59ae9e7c076a22b04fe33803e81a659231de4d`
for 12 channels (887,444 encoded bytes), and
`8255c546bc6dedff836e891e53e65dc4402b51752f79e8b0fd5f892ba1459979` for 16 channels
(1,518,057 encoded bytes). The process high-water mark grew to 57.0 MB during the 12-channel
cases and 74.3 MB during the 16-channel cases. These are cumulative process measurements, not
per-session memory or evidence of a leak.

The reuse candidate still needs its matching cloud measurements. The baseline alone does not
establish a performance benefit or justify adding decode/encode concurrency.
