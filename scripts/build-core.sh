#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$TASK_ROOT/Rust/SpatialAudioCore/Cargo.toml"
ARTIFACTS="$TASK_ROOT/BinaryArtifacts"
HEADERS="$TASK_ROOT/Rust/SpatialAudioCore/include"
TARGETS=(aarch64-apple-darwin aarch64-apple-tvos aarch64-apple-tvos-sim)
if [[ "${1:-}" == "--mac-only" ]]; then TARGETS=(aarch64-apple-darwin); fi
rustup target add "${TARGETS[@]}"
for TARGET in "${TARGETS[@]}"; do
    cargo build --release --locked -j 1 --manifest-path "$MANIFEST" --target "$TARGET"
done
mkdir -p "$ARTIFACTS"
OUTPUT="$ARTIFACTS/SpatialAudioCore.xcframework"
# Replace only this script's generated framework.
if [[ -d "$OUTPUT" ]]; then rm -rf "$OUTPUT"; fi
ARGS=()
for TARGET in "${TARGETS[@]}"; do
    ARGS+=(-library "$TASK_ROOT/Rust/SpatialAudioCore/target/$TARGET/release/libspatial_audio_core.a" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUTPUT"
