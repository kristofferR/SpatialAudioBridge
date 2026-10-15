#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FUZZ="$TASK_ROOT/Rust/SpatialAudioCore/fuzz"
DURATION="${1:-60}"
[[ "$DURATION" =~ ^[1-9][0-9]*$ && "$DURATION" -le 600 ]] ||
    { echo "Use a fuzzing duration between 1 and 600 seconds." >&2; exit 1; }
[[ "$(uname -s)" == Linux ]] || { echo "Run Rust fuzzing on Linux." >&2; exit 1; }
export RUSTUP_TOOLCHAIN=nightly-2026-10-01
cd "$TASK_ROOT/Rust/SpatialAudioCore"
CORPUS="$FUZZ/corpus/stream_session"
ARTIFACTS="$FUZZ/artifacts/stream_session"
mkdir -p "$CORPUS" "$ARTIFACTS"

# Synthetic framing seeds only. The four control bytes select codec/layout, chunk size,
# truncation and repetition; no encoded programme audio is used or downloaded.
printf '\000\002\000\000' > "$CORPUS/empty-truehd"
printf '\001\002\000\000' > "$CORPUS/empty-dts"
printf '\000\002\000\000\000\020\000\000\370\162\157\272\000\000\000\000' > "$CORPUS/truehd-sync"
printf '\001\002\000\000\177\376\200\001\374\074\077\377\265\340\000\000\000\000\000\000\000\000\144\130\040\045' > "$CORPUS/dts-sync"

cargo fetch --locked --manifest-path "$FUZZ/Cargo.toml"
export CARGO_NET_OFFLINE=true
cargo fuzz build stream_session
git diff --exit-code -- "$FUZZ/Cargo.lock"

set +e
timeout --kill-after=5s "$((DURATION + 60))s" cargo fuzz run stream_session "$CORPUS" -- \
    -max_total_time="$DURATION" -timeout=10 -rss_limit_mb=1024 -max_len=131072 \
    -dict="$FUZZ/stream.dict" -artifact_prefix="$ARTIFACTS/" \
    2>&1 | tee "$ARTIFACTS/run.log"
STATUS=${PIPESTATUS[0]}
set -e
if [[ "$STATUS" -ne 0 ]]; then
    # Preserve the original failure even when minimization times out or cannot reproduce it.
    shopt -s nullglob
    for FAILURE in "$ARTIFACTS"/crash-* "$ARTIFACTS"/timeout-* "$ARTIFACTS"/oom-*; do
        timeout --kill-after=5s 45s cargo fuzz tmin stream_session "$FAILURE" -- \
            -max_total_time=30 -timeout=10 -rss_limit_mb=1024 \
            > "$ARTIFACTS/minimize.log" 2>&1 || true
        break
    done
fi
cat > "$ARTIFACTS/REPRODUCE.txt" <<'EOF'
From Rust/SpatialAudioCore, with nightly-2026-10-01 and cargo-fuzz 0.13.2 installed:
  cargo +nightly-2026-10-01 fuzz run stream_session fuzz/artifacts/stream_session/FAILURE_FILE -- -timeout=10 -rss_limit_mb=1024

Original failures and any minimized result are included. A failed run remains failed even
if bounded minimization cannot reproduce it. run.log records libFuzzer's failure and seed.
EOF
exit "$STATUS"
