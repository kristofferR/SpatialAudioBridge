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

The current encoder allocates its output scratch buffer and packet/dependency-description arrays
on each call that has enough input to encode (and on the final flush). This source observation
motivates checking reuse before adding a queue, but does not measure allocator cost. Retained
input storage already grows only when required. This experiment does not profile compressed
decoding, rendering, the asset writer, private media, player latency or cancellation/backpressure
under a new pipeline; no overlap or playback change is introduced.
