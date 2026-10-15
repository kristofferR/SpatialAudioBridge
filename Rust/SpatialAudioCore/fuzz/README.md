# Rust stream and session fuzzing

Run on Linux, using synthetic framing inputs only:

```sh
rustup toolchain install nightly-2026-10-01 --profile minimal --component rust-src,clippy
cargo +nightly-2026-10-01 install cargo-fuzz --version 0.13.2 --locked
./scripts/fuzz-core.sh 60
```

Run the script from the repository root. It builds an AddressSanitizer-instrumented `stream_session` target, then gives libFuzzer 60 seconds, a 10-second per-input timeout, a 1 GiB RSS limit and a 128 KiB input limit. The script accepts 1–600 seconds and puts an additional wall-clock bound around execution and failure minimization. Limits detect excessive resource use in the exercised cases; they do not prove a global memory or runtime bound.

Each input has four control bytes followed by compressed bytes:

- Byte 0 selects TrueHD/DTS, 7.1.4/9.1.6, consumer cancellation and dialogue normalization.
- Byte 1 selects 1, 17, 317, 4096 or 65,536-byte chunks.
- Byte 2 removes that many bytes from the payload's end, down to an empty payload.
- Byte 3 selects 1, 2, 8 or 33 repetitions, allowing cumulative input to exceed the core's buffering limits with small corpus files.

The target feeds the Rust core directly to expose panics and check owned PCM shape, channel count, sample rate and finiteness. It then feeds the same stream through the actual C symbols and checks that failures, consumer cancellation and a successful end-of-stream remain terminal. A later append or flush must not resume callbacks or change the stored error. Any panic reported as an ordinary C error also fails the target. Calls use live owned handles and valid input pointers; invalid pointer misuse is outside the API contract.

The seed corpus consists of empty streams and truncated synthetic TrueHD/DTS headers. It exercises malformed framing and session failure paths. PCM, successful completion and consumer-cancellation checks are conditional on reaching supported decoded output; these seeds do not establish coverage of valid Atmos/DTS:X rendering. Private programme media must never be put in this corpus or uploaded as a CI artifact. Swift's IEC 61937 and Matroska parsers are not covered by this target.

The `Rust fuzz` workflow runs on relevant pull requests and main changes, or by manual dispatch. It retains the evolving corpus in an Actions cache and uploads the corpus and failure artifacts for 14 days. A failed run stays failed even if the bounded minimizer fails or times out; the original input is retained alongside any minimized result. `REPRODUCE.txt` and `run.log` in the artifact record how to replay the failure. From `Rust/SpatialAudioCore`:

```sh
cargo +nightly-2026-10-01 fuzz run stream_session "fuzz/artifacts/stream_session/FAILURE_FILE" -- -timeout=10 -rss_limit_mb=1024
```

The fuzz workspace has its own dependency lockfile and does not add libFuzzer to the shipped core or change the release build. The ordinary Rust tests and Clippy remain separate checks.
