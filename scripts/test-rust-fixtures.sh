#!/usr/bin/env bash
set -euo pipefail

# Validate every input before Cargo builds or runs the private-media tests.
for variable in SAB_TRUEHD_FIXTURE SAB_DTSX_FIXTURE SAB_DTSX_ALTERNATE_FIXTURE; do
    path="${!variable:-}"
    if [[ -z "$path" || ! -f "$path" || ! -r "$path" || ! -s "$path" ]]; then
        echo "$variable must name a readable, nonempty elementary-stream file" >&2
        exit 1
    fi
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec cargo test --release --locked --manifest-path "$root/Rust/SpatialAudioCore/Cargo.toml" \
    --test fixtures -- --ignored --test-threads=1
