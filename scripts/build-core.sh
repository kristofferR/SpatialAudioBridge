#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$TASK_ROOT/Rust/SpatialAudioCore/Cargo.toml"
ARTIFACTS="$TASK_ROOT/BinaryArtifacts"
HEADERS="$TASK_ROOT/Rust/SpatialAudioCore/include"
TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-tvos aarch64-apple-tvos-sim)
if [[ "${1:-}" == "--mac-only" ]]; then TARGETS=(aarch64-apple-darwin); fi
rustup target add "${TARGETS[@]}"
# Remap local paths and pin deployment targets so the libraries do not depend on where or by whom
# they are built. This replaces any RUSTFLAGS from the environment. The deployment targets match
# Package.swift, where Apple Silicon Macs start at 11; the Swift API itself requires 26.
SYSROOT="$(rustc --print sysroot)"
RUSTC_COMMIT="$(rustc -vV | sed -n 's/^commit-hash: //p')"
REMAPS=(
    "--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"
    "--remap-path-prefix=$SYSROOT/lib/rustlib/src/rust=/rustc/$RUSTC_COMMIT"
    "--remap-path-prefix=$TASK_ROOT=/spatial-audio-bridge"
)
CARGO_ENCODED_RUSTFLAGS="$(IFS=$'\x1f'; echo "${REMAPS[*]}")"
export CARGO_ENCODED_RUSTFLAGS MACOSX_DEPLOYMENT_TARGET=11.0 IPHONEOS_DEPLOYMENT_TARGET=13.0 TVOS_DEPLOYMENT_TARGET=13.0
for TARGET in "${TARGETS[@]}"; do
    cargo build --release --locked -j 1 --manifest-path "$MANIFEST" --target "$TARGET"
done
mkdir -p "$ARTIFACTS"
OUTPUT="$ARTIFACTS/SpatialAudioCore.xcframework"
# Replace only this script's generated framework and notices.
rm -rf "$OUTPUT" "$ARTIFACTS/licenses"
ARGS=()
for TARGET in "${TARGETS[@]}"; do
    ARGS+=(-library "$TASK_ROOT/Rust/SpatialAudioCore/target/$TARGET/release/libspatial_audio_core.a" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUTPUT"
# xcodebuild lists the libraries in a different order on each run.
python3 -I - "$OUTPUT/Info.plist" <<'EOF'
import plistlib, sys
with open(sys.argv[1], "rb") as file: info = plistlib.load(file)
info["AvailableLibraries"].sort(key=lambda library: library["LibraryIdentifier"])
with open(sys.argv[1], "wb") as file: plistlib.dump(info, file)
EOF
cp "$TASK_ROOT/THIRD-PARTY-NOTICES.md" "$TASK_ROOT/LICENSE" "$ARTIFACTS/"
cp -R "$TASK_ROOT/licenses" "$ARTIFACTS/"
# The libraries contain the Rust standard library; its notices come with the toolchain.
RUST_STD="$ARTIFACTS/licenses/rust-std-$(rustc -vV | sed -n 's/^release: //p')"
mkdir -p "$RUST_STD"
cp "$SYSROOT/share/doc/rust/COPYRIGHT-library.html" "$RUST_STD/"
