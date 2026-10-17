#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$TASK_ROOT/Rust/SpatialAudioCore/Cargo.toml"
ARTIFACTS="$TASK_ROOT/BinaryArtifacts"
HEADERS="$TASK_ROOT/Rust/SpatialAudioCore/include/SpatialAudioCore"
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
# The core is a dynamic framework so apps can meet the LGPL of the FFmpeg-derived DTS decoder in
# dca: a user can replace it with one built from this repository (see THIRD-PARTY-NOTICES.md). As
# its own image, it also keeps its Rust standard library and panic personality to itself.
NAME=SpatialAudioCore
for TARGET in "${TARGETS[@]}"; do
    MACOS="11.0"; [[ "$TARGET" == x86_64-apple-darwin ]] && MACOS="10.15"
    INSTALL_NAME="@rpath/$NAME.framework/$NAME"
    [[ "$TARGET" == *-darwin ]] && INSTALL_NAME="@rpath/$NAME.framework/Versions/A/$NAME"
    # Only the cdylib: next to the rlib the Rust tests use, Cargo skips the profile's LTO and
    # embeds bitcode instead. A cdylib exports only the C API.
    MACOSX_DEPLOYMENT_TARGET="$MACOS" cargo rustc --release --locked -j 1 --manifest-path "$MANIFEST" \
        --target "$TARGET" --lib --crate-type cdylib -- \
        -C link-arg=-Wl,-install_name,"$INSTALL_NAME" -C link-arg=-Wl,-application_extension
    strip -x "$TASK_ROOT/Rust/SpatialAudioCore/target/$TARGET/release/libspatial_audio_core.dylib"
done
# framework DIRECTORY LIBRARY PLATFORM MINIMUM: assembles a framework with the platform's layout.
framework() {
    local bundle="$1/$NAME.framework" contents="$1/$NAME.framework" plist
    mkdir -p "$bundle"
    if [[ "$3" == MacOSX ]]; then
        contents="$bundle/Versions/A"
        mkdir -p "$contents/Resources"
        ln -s A "$bundle/Versions/Current"
        for ENTRY in "$NAME" Headers Modules Resources; do ln -s "Versions/Current/$ENTRY" "$bundle/$ENTRY"; done
        plist="$contents/Resources/Info.plist"
    else
        plist="$bundle/Info.plist"
    fi
    mkdir -p "$contents/Headers" "$contents/Modules"
    cp "$2" "$contents/$NAME"
    cp "$HEADERS/$NAME.h" "$contents/Headers/"
    cp "$HEADERS/module.modulemap" "$contents/Modules/"
    python3 -I - "$plist" "$NAME" "$3" "$4" <<'EOF'
import plistlib, sys
path, name, platform, minimum = sys.argv[1:]
info = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": name,
    "CFBundleIdentifier": "com.kristofferr.SpatialAudioBridge.Core",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": name,
    "CFBundlePackageType": "FMWK",
    "CFBundleShortVersionString": "1.0",
    "CFBundleSupportedPlatforms": [platform],
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion" if platform == "MacOSX" else "MinimumOSVersion": minimum,
}
with open(path, "wb") as file: plistlib.dump(info, file)
EOF
}
mkdir -p "$ARTIFACTS"
OUTPUT="$ARTIFACTS/$NAME.xcframework"
# Replace only this script's generated framework and notices.
rm -rf "$OUTPUT" "$ARTIFACTS/licenses"
# One framework per platform. Macs and the iOS simulator get universal ones, so hosts can build for
# Intel too; Rust has no stable x86_64 tvOS simulator target.
PLATFORMS=("MacOSX 10.15 aarch64-apple-darwin x86_64-apple-darwin" "iPhoneOS 13.0 aarch64-apple-ios"
    "iPhoneSimulator 13.0 aarch64-apple-ios-sim x86_64-apple-ios" "AppleTVOS 13.0 aarch64-apple-tvos"
    "AppleTVSimulator 13.0 aarch64-apple-tvos-sim")
STAGE="$TASK_ROOT/Rust/SpatialAudioCore/target/frameworks"
rm -rf "$STAGE"
ARGS=()
for PLATFORM in "${PLATFORMS[@]}"; do
    read -r SDK MINIMUM PLATFORM_TARGETS <<< "$PLATFORM"
    BUILT=()
    for TARGET in $PLATFORM_TARGETS; do
        [[ " ${TARGETS[*]} " == *" $TARGET "* ]] && BUILT+=("$TASK_ROOT/Rust/SpatialAudioCore/target/$TARGET/release/libspatial_audio_core.dylib")
    done
    [[ ${#BUILT[@]} -eq 0 ]] && continue
    mkdir -p "$STAGE/$SDK"
    lipo -create "${BUILT[@]}" -output "$STAGE/$SDK/$NAME"
    framework "$STAGE/$SDK" "$STAGE/$SDK/$NAME" "$SDK" "$MINIMUM"
    ARGS+=(-framework "$STAGE/$SDK/$NAME.framework")
done
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUTPUT"
for LIBRARY in "$OUTPUT"/*/"$NAME.framework/$NAME"; do
    for ARCH in $(lipo -archs "$LIBRARY"); do
        GLOBALS="$(nm -gUj -arch "$ARCH" "$LIBRARY" | LC_ALL=C sort | paste -sd ' ' -)"
        [[ "$GLOBALS" =~ ^_sab_[a-z_]+(\ _sab_[a-z_]+)*$ ]] ||
            { echo "$LIBRARY ($ARCH) must export only the C API: $GLOBALS" >&2; exit 1; }
        [[ "$(otool -D -arch "$ARCH" "$LIBRARY" | tail -n 1)" == "@rpath/$NAME.framework/"* ]] ||
            { echo "$LIBRARY ($ARCH) has the wrong install name" >&2; exit 1; }
    done
done
# xcodebuild lists the libraries in a different order on each run.
python3 -I - "$OUTPUT/Info.plist" <<'EOF'
import plistlib, sys
with open(sys.argv[1], "rb") as file: info = plistlib.load(file)
info["AvailableLibraries"].sort(key=lambda library: library["LibraryIdentifier"])
with open(sys.argv[1], "wb") as file: plistlib.dump(info, file)
EOF
cp "$TASK_ROOT/THIRD-PARTY-NOTICES.md" "$TASK_ROOT/LICENSE" "$ARTIFACTS/"
cp -R "$TASK_ROOT/licenses" "$ARTIFACTS/"
# The frameworks contain the Rust standard library; its notices come with the toolchain.
RUST_STD="$ARTIFACTS/licenses/rust-std-$(rustc -vV | sed -n 's/^release: //p')"
mkdir -p "$RUST_STD"
cp "$SYSROOT/share/doc/rust/COPYRIGHT-library.html" "$RUST_STD/"
# Apps show this text in their acknowledgements; the SpatialAudioBridge target bundles it. Commit it
# when it changes, which happens with Cargo.lock, licenses/ or the toolchain.
cargo tree --locked --manifest-path "$MANIFEST" --edges normal,no-proc-macro --prefix none --format '{p}|{l}' \
    --target "${TARGETS[0]}" | python3 -I "$TASK_ROOT/scripts/make-notices.py" \
    "$TASK_ROOT/Sources/SpatialAudioBridge/Resources/ThirdPartyNotices.txt" "$TASK_ROOT/LICENSE" "$TASK_ROOT/licenses" \
    "$SYSROOT/share/doc/rust/COPYRIGHT-library.html" "$(rustc -vV | sed -n 's/^release: //p')"
