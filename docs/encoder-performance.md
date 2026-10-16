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

The existing encoder allocates its output scratch buffer and packet/dependency-description arrays
on each call that has enough input to encode (and on the final flush). The evaluated reuse candidate
retained one output buffer, sized for 16 maximum-size packets, and both 16-entry arrays for the
encoder's lifetime. Returned packets still copied their bytes into owned `Data`. The candidate
was removed after the comparison below showed no benefit; production behavior remains unchanged.
Retained input storage already grows only when required.
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

## Reuse comparison and decision

[Core run 38829321256, attempt 2](https://github.com/kristofferR/SpatialAudioBridge/actions/runs/38829321256/attempts/2)
measured the reuse candidate at `f7565465`, on the same macOS version and configuration. Each entry
is the median of five passes after warm-up:

| Channels | Input chunk (frames) | Baseline wall (s) | Reuse wall (s) | Baseline CPU (s) | Reuse CPU (s) |
| --- | --- | --- | --- | --- | --- |
| 12 | 317 | 0.2220 | 0.2433 | 0.2221 | 0.2431 |
| 12 | 1024 | 0.2255 | 0.2942 | 0.2256 | 0.2946 |
| 16 | 317 | 0.3006 | 0.4167 | 0.3004 | 0.4062 |
| 16 | 1024 | 0.2958 | 0.3820 | 0.2959 | 0.3685 |

All 24 candidate passes matched the baseline packet digest for their layout, with the same packet
counts, encoded bytes, priming and first-output submission counts. Cumulative process peak RSS
reached 57.1 MB in the 12-channel cases and 74.3 MB in the 16-channel cases, with no demonstrated
memory reduction. These separate hosted runs are not a controlled same-machine A/B experiment;
load and hardware may differ, and the package/test harness uses its default debug build. The
higher times do not establish a production regression caused by reuse. They also provide no
evidence that this candidate helps.

Keep the existing encoder, remove the unproven reuse candidate, and retain the opt-in measurement
harness. Do not add overlap based on these results. A later optimization proposal needs production
configuration measurements and allocation/stage evidence before adopting more complexity.

The first attempt failed a default-DRC fragmented-writer duration check before profiling ran. Its
saved container has duplicated final packet timestamps/payloads and fragment sequence order
1, 2, 4, 3. Attempt 2 passed 69 package tests and the isolated profile, but that does not fix the
unresolved writer/delegate issue tracked in [#56](https://github.com/kristofferR/SpatialAudioBridge/issues/56).
