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
# prelink TARGET: turns the target's library into one object whose only globals are the C API and a
# weak rust_eh_personality. Otherwise its copy of the Rust standard library collides with another
# Rust static library's in the same app, such as a prebuilt libdovi. The personality stays global
# because a private copy would be one more personality routine, and an image can have three (Rust,
# Objective-C and C++); weak, it merges with the other library's copy. Every C entry point catches
# panics, so only the routine is shared.
prelink() {
    local release="$TASK_ROOT/Rust/SpatialAudioCore/target/$1/release"
    local work="$release/prelink"
    [[ -z "$(ar -t "$release/libspatial_audio_core.a" | sort | uniq -d)" ]] ||
        { echo "Duplicate member names in the $1 library" >&2; exit 1; }
    rm -rf "$work"
    mkdir -p "$work/members"
    (cd "$work/members" && ar -x "$release/libspatial_audio_core.a" && rm -f __.SYMDEF*)
    printf '%s\n' '_sab_*' _rust_eh_personality > "$work/exports"
    local members=("$work"/members/*) version
    # The platform and minimum OS the crate was compiled for; ld -r would otherwise record an older
    # default. Precompiled compiler_builtins objects can carry only an older LC_VERSION_MIN_*.
    read -r -a version < <(otool -l "${members[@]}" | awk '$1 == "platform" {p = $2} $1 == "minos" {m = $2}
        $1 == "sdk" && p != "" {print p, m, ($2 == "n/a" ? "0.0" : $2); exit}')
    [[ ${#version[@]} -eq 3 ]] || { echo "No LC_BUILD_VERSION in the $1 library" >&2; exit 1; }
    ld -r -platform_version "${version[@]}" -exported_symbols_list "$work/exports" -o "$work/core.o" "${members[@]}"
    strip -S "$work/core.o"
    # Neither ld nor strip can mark a definition weak: set N_WEAK_DEF in the symbol table.
    python3 -I - "$work/core.o" _rust_eh_personality <<'EOF'
import struct, sys
path, name = sys.argv[1], sys.argv[2].encode()
data = bytearray(open(path, "rb").read())
assert struct.unpack_from("<I", data)[0] == 0xFEEDFACF, f"{path} is not a 64-bit Mach-O object"
offset, found = 32, 0
for _ in range(struct.unpack_from("<I", data, 16)[0]):
    command, size = struct.unpack_from("<II", data, offset)
    if command == 0x2:  # LC_SYMTAB
        symbols, count, strings = struct.unpack_from("<III", data, offset + 8)
        for entry in range(symbols, symbols + 16 * count, 16):
            index, kind, _, flags = struct.unpack_from("<IBBH", data, entry)
            start = strings + index
            # An external symbol defined in a section: N_SECT | N_EXT.
            if kind == 0x0F and data[start:data.index(0, start)] == name:
                struct.pack_into("<H", data, entry + 6, flags | 0x80)  # N_WEAK_DEF
                found += 1
    offset += size
assert found == 1, f"{path} defines {name.decode()} {found} times"
open(path, "wb").write(data)
EOF
    libtool -static -D -o "$work/libspatial_audio_core.a" "$work/core.o"
}
for TARGET in "${TARGETS[@]}"; do
    MACOS="11.0"; [[ "$TARGET" == x86_64-apple-darwin ]] && MACOS="10.15"
    # Only the staticlib: next to the rlib the Rust tests use, Cargo skips the profile's LTO and
    # embeds bitcode instead.
    MACOSX_DEPLOYMENT_TARGET="$MACOS" cargo rustc --release --locked -j 1 --manifest-path "$MANIFEST" \
        --target "$TARGET" --lib --crate-type staticlib
    prelink "$TARGET"
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
        [[ " ${TARGETS[*]} " == *" $TARGET "* ]] && BUILT+=("$TASK_ROOT/Rust/SpatialAudioCore/target/$TARGET/release/prelink/libspatial_audio_core.a")
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
for LIBRARY in "$OUTPUT"/*/libspatial_audio_core.a; do
    for ARCH in $(lipo -archs "$LIBRARY"); do
        GLOBALS="$(nm -gUm -arch "$ARCH" "$LIBRARY" | sed -n -e 's/\[no dead strip\] //' -e 's/.*) //p' | LC_ALL=C sort | paste -sd ' ' -)"
        [[ "$GLOBALS" =~ ^(external\ _sab_[a-z_]+\ )+weak\ external\ _rust_eh_personality$ ]] ||
            { echo "$LIBRARY ($ARCH) must export only the C API and a weak personality: $GLOBALS" >&2; exit 1; }
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
