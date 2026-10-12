#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$TASK_ROOT/Rust/SpatialAudioCore/Cargo.toml"
ARTIFACTS="$TASK_ROOT/BinaryArtifacts"
# The headers sit in a folder named after the module: hosts copy every static XCFramework's headers
# into one include folder, where a top-level module.modulemap collides with other libraries' maps.
HEADERS="$TASK_ROOT/Rust/SpatialAudioCore/include"
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-tvos aarch64-apple-tvos-sim)
if [[ "${1:-}" == "--mac-only" ]]; then TARGETS=(aarch64-apple-darwin); fi
rustup target add "${TARGETS[@]}"
# Remap local paths and pin deployment targets so the libraries do not depend on where or by whom
# they are built. This replaces any RUSTFLAGS from the environment. The deployment targets match
# Package.swift, where Apple Silicon Macs start at 11 and Intel Macs at 10.15; the Swift API itself
# requires 26.
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
    MACOS="11.0"; [[ "$TARGET" == x86_64-apple-darwin ]] && MACOS="10.15"
    MACOSX_DEPLOYMENT_TARGET="$MACOS" cargo build --release --locked -j 1 --manifest-path "$MANIFEST" --target "$TARGET"
done
mkdir -p "$ARTIFACTS"
OUTPUT="$ARTIFACTS/SpatialAudioCore.xcframework"
# Replace only this script's generated framework and notices.
rm -rf "$OUTPUT" "$ARTIFACTS/licenses"
# One library per platform. Macs and the iOS simulator get universal ones, so hosts can build for
# Intel too; Rust has no stable x86_64 tvOS simulator target.
PLATFORMS=("aarch64-apple-darwin x86_64-apple-darwin" aarch64-apple-ios "aarch64-apple-ios-sim x86_64-apple-ios"
    aarch64-apple-tvos aarch64-apple-tvos-sim)
ARGS=()
for PLATFORM in "${PLATFORMS[@]}"; do
    BUILT=()
    for TARGET in $PLATFORM; do
        [[ " ${TARGETS[*]} " == *" $TARGET "* ]] && BUILT+=("$TASK_ROOT/Rust/SpatialAudioCore/target/$TARGET/release/libspatial_audio_core.a")
    done
    [[ ${#BUILT[@]} -eq 0 ]] && continue
    LIBRARY="${BUILT[0]}"
    if [[ ${#BUILT[@]} -gt 1 ]]; then
        LIBRARY="$TASK_ROOT/Rust/SpatialAudioCore/target/universal/${PLATFORM%% *}/libspatial_audio_core.a"
        mkdir -p "$(dirname "$LIBRARY")"
        lipo -create "${BUILT[@]}" -output "$LIBRARY"
    fi
    ARGS+=(-library "$LIBRARY" -headers "$HEADERS")
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
# Apps show this text in their acknowledgements; the SpatialAudioBridge target bundles it. Commit it
# when it changes, which happens with Cargo.lock, licenses/ or the toolchain.
cargo tree --locked --manifest-path "$MANIFEST" --edges normal,no-proc-macro --prefix none --format '{p}|{l}' \
    --target "${TARGETS[0]}" | python3 -I "$TASK_ROOT/scripts/make-notices.py" \
    "$TASK_ROOT/Sources/SpatialAudioBridge/Resources/ThirdPartyNotices.txt" "$TASK_ROOT/LICENSE" "$TASK_ROOT/licenses" \
    "$SYSROOT/share/doc/rust/COPYRIGHT-library.html" "$(rustc -vV | sed -n 's/^release: //p')"
