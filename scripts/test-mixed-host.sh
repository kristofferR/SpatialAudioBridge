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
[[ -f "$ARCHIVE" ]] || fail "Build the release archive first."
ditto -x -k "$ARCHIVE" "$WORK/unpacked"
SLICE="$WORK/unpacked/SpatialAudioCore.xcframework/macos-arm64_x86_64"
[[ -L "$SLICE/SpatialAudioCore.framework/SpatialAudioCore" ]] || fail "The archive has no versioned macOS framework."

echo "Mixed-host checks: $TARGET; deployment target $MINIMUM"
xcodebuild -version
xcrun clang --version
sw_vers
export MACOSX_DEPLOYMENT_TARGET="$MINIMUM"
xcrun clang -std=c11 -O1 -Wall -Wextra -Werror -fobjc-exceptions \
    -mmacosx-version-min="$MINIMUM" -F "$SLICE" \
    -c "$FIXTURES/main.m" -o "$WORK/main.o"
xcrun clang++ -std=c++17 -O1 -Wall -Wextra -Werror -fexceptions \
    -mmacosx-version-min="$MINIMUM" -c "$FIXTURES/exceptions.cpp" -o "$WORK/exceptions.o"

link_host() {
    local output="$1"
    shift
    xcrun clang++ -mmacosx-version-min="$MINIMUM" "$WORK/main.o" "$WORK/exceptions.o" \
        "$@" -F "$SLICE" -framework SpatialAudioCore -Wl,-rpath,"$SLICE" -framework Foundation -o "$output"
}

# Other Rust static libraries, from an older toolchain and from the core's, bring their own runtime.
for TOOLCHAIN in 1.86.0 1.99.0; do
    rustup run "$TOOLCHAIN" rustc --version
    OTHER="$WORK/libother-$TOOLCHAIN.a"
    rustup run "$TOOLCHAIN" rustc --edition 2021 --crate-name mixed_host_other \
        --crate-type staticlib --target "$TARGET" -C panic=unwind -C opt-level=1 \
        -C codegen-units=1 "$FIXTURES/other.rs" -o "$OTHER"
    echo "Packaged core with Rust $TOOLCHAIN"
    link_host "$WORK/host" "$OTHER"
    "$WORK/host"
done
echo "Mixed-host checks passed (native macOS only; no media or device playback)."
