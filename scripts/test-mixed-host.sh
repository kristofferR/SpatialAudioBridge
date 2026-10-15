#!/bin/bash
set -euo pipefail
# Run on a macOS CI host after release-core.sh, against the ZIP that will be distributed.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${1:-$TASK_ROOT/BinaryArtifacts/SpatialAudioCore.xcframework.zip}"
FIXTURES="$TASK_ROOT/Tests/MixedHost"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sab mixed-host.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "$1" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "Mixed-host checks require macOS."
case "$(uname -m)" in
    arm64) TARGET=aarch64-apple-darwin; MINIMUM=11.0 ;;
    x86_64) TARGET=x86_64-apple-darwin; MINIMUM=10.15 ;;
    *) fail "Unsupported macOS host architecture." ;;
esac
RAW="$TASK_ROOT/Rust/SpatialAudioCore/target/$TARGET/release/libspatial_audio_core.a"
[[ -f "$ARCHIVE" && -f "$RAW" ]] || fail "Build the release archive first."
ditto -x -k "$ARCHIVE" "$WORK/unpacked"
SLICE="$WORK/unpacked/SpatialAudioCore.xcframework/macos-arm64_x86_64"
CORE="$SLICE/libspatial_audio_core.a"
[[ -f "$CORE" ]] || fail "The archive has no universal macOS library."

echo "Mixed-host checks: $TARGET; deployment target $MINIMUM"
xcodebuild -version
xcrun clang --version
sw_vers
export MACOSX_DEPLOYMENT_TARGET="$MINIMUM"
xcrun clang -std=c11 -O1 -Wall -Wextra -Werror -fobjc-exceptions \
    -mmacosx-version-min="$MINIMUM" -I "$SLICE/Headers" \
    -c "$FIXTURES/main.m" -o "$WORK/main.o"
xcrun clang++ -std=c++17 -O1 -Wall -Wextra -Werror -fexceptions \
    -mmacosx-version-min="$MINIMUM" -c "$FIXTURES/exceptions.cpp" -o "$WORK/exceptions.o"

link_host() {
    local output="$1"
    shift
    xcrun clang++ -mmacosx-version-min="$MINIMUM" "$WORK/main.o" "$WORK/exceptions.o" \
        "$@" -framework Foundation -o "$output"
}

# An older independent Rust runtime exercises coexistence with prebuilt host dependencies.
# The current toolchain also covers two libraries built with the same compiler as the core.
for TOOLCHAIN in 1.86.0 1.99.0; do
    rustup run "$TOOLCHAIN" rustc --version
    OTHER="$WORK/libother-$TOOLCHAIN.a"
    rustup run "$TOOLCHAIN" rustc --edition 2021 --crate-name mixed_host_other \
        --crate-type staticlib --target "$TARGET" -C panic=unwind -C opt-level=1 \
        -C codegen-units=1 "$FIXTURES/other.rs" -o "$OTHER"
    for ORDER in core-first other-first; do
        if [[ "$ORDER" == core-first ]]; then LIBRARIES=("$CORE" "$OTHER")
        else LIBRARIES=("$OTHER" "$CORE"); fi
        echo "Packaged core with Rust $TOOLCHAIN, $ORDER"
        link_host "$WORK/host" "${LIBRARIES[@]}"
        "$WORK/host"
    done
    if [[ "$TOOLCHAIN" == 1.86.0 ]]; then
        # The original, unisolated Cargo archive must reproduce the personality collision.
        # An arbitrary linker failure is not evidence that this control worked.
        if link_host "$WORK/control" "$RAW" "$OTHER" > "$WORK/control.log" 2>&1; then
            fail "Negative control unexpectedly linked the unisolated core."
        fi
        cat "$WORK/control.log"
        grep -Eq "duplicate symbol ['\"]?_rust_eh_personality" "$WORK/control.log" ||
            fail "Negative control failed for a reason other than the Rust personality collision."
        echo "Negative control detected the unisolated Rust personality collision."
    fi
done
echo "Mixed-host checks passed (native macOS only; no media or device playback)."
