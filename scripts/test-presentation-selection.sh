#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/Rust/SpatialAudioCore/Cargo.toml"
# Cargo resolves the pinned checkout; no media is copied into the repository or CI artifacts.
dependency="$(cargo metadata --locked --format-version 1 --manifest-path "$manifest" \
    | jq -er '.packages[] | select(.name == "truehd") | .manifest_path')"
export SAB_TRUEHD_PUBLIC_FIXTURES_DIR="$(dirname "$dependency")/tests/assets"
exec cargo test --release --locked --manifest-path "$manifest" --lib \
    presentation_selection_tests -- --ignored --test-threads=1
