#!/bin/bash
set -euo pipefail
# Usage: ./scripts/release-core.sh [VERSION]
# Builds the release archive of the Rust core and prints its checksum. With a version, also tags a
# release commit whose Package.swift downloads the archive from that version's GitHub release.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="https://github.com/kristofferR/SpatialAudioBridge"
ARTIFACTS="$TASK_ROOT/BinaryArtifacts"
ARCHIVE="$ARTIFACTS/SpatialAudioCore.xcframework.zip"
VERSION="${1:-}"
fail() { echo "$1" >&2; exit 1; }
cd "$TASK_ROOT"
if [[ -n "$VERSION" ]]; then
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Use a MAJOR.MINOR.PATCH version."
    [[ -z "$(git status --porcelain)" ]] || fail "Commit or remove local changes first."
    # Release tags are off main, so fetching main alone does not bring them.
    git fetch -q --tags origin main
    ! git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null || fail "Tag $VERSION already exists."
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "Check out the latest origin/main first."
fi

"$TASK_ROOT/scripts/build-core.sh"
[[ -z "$VERSION" || -z "$(git status --porcelain)" ]] || fail "The build changed tracked files, such as the notices; commit them first."

# Fixed timestamps, permissions and entry order make the archive reproducible.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ENTRIES=(SpatialAudioCore.xcframework LICENSE THIRD-PARTY-NOTICES.md licenses)
for ENTRY in "${ENTRIES[@]}"; do cp -R "$ARTIFACTS/$ENTRY" "$STAGE/"; done
find "$STAGE" -name .DS_Store -delete
chmod -R u=rwX,go=rX "$STAGE"
TZ=UTC find "$STAGE" -exec touch -h -t 198001010000 {} +
rm -f "$ARCHIVE"
(cd "$STAGE" && find "${ENTRIES[@]}" | LC_ALL=C sort | TZ=UTC zip -X -q -@ "$ARCHIVE")
CHECKSUM="$(swift package compute-checksum "$ARCHIVE")"
echo "$ARCHIVE"
echo "Checksum: $CHECKSUM"
echo "Built with $(rustc -V) and $(xcodebuild -version | paste -sd ' ' -)"
[[ -n "$VERSION" ]] || exit 0

# The release commit stays off main, which keeps building the core from source.
LOCAL='path: "BinaryArtifacts/SpatialAudioCore.xcframework"'
REMOTE="url: \"$REPOSITORY/releases/download/$VERSION/SpatialAudioCore.xcframework.zip\", checksum: \"$CHECKSUM\""
grep -qF "$LOCAL" Package.swift || fail "Package.swift has no local SpatialAudioCore target to replace."
SOURCE="$(git rev-parse HEAD)"
BRANCH="$(git symbolic-ref -q --short HEAD || echo "$SOURCE")"
git checkout -q --detach
trap 'git checkout -q -f "$BRANCH"; rm -rf "$STAGE"' EXIT
sed -i '' "s|$LOCAL|$REMOTE|" Package.swift
swift package dump-package | grep -qF "\"$CHECKSUM\"" || fail "The release manifest does not load."
git commit -q -m "chore(release): $VERSION" Package.swift
git tag -a "$VERSION" -m "SpatialAudioBridge $VERSION"
cat > "$ARTIFACTS/release-notes.md" <<EOF
Prebuilt Rust core for Apple Silicon Macs, Apple TV, iPhone and iPad, and their simulators, with the license notices of its dependencies. \`Package.swift\` at this tag downloads it.

- Checksum: \`$CHECKSUM\`
- Built from $SOURCE with $(rustc -V) and $(xcodebuild -version | paste -sd ' ' -)

To reproduce the archive, check out that commit, install the same toolchain and run \`./scripts/release-core.sh\`.
EOF
echo "Tagged $VERSION. Publish it with:"
echo "  git push origin $VERSION"
echo "  gh release create $VERSION \"$ARCHIVE\" --verify-tag --title $VERSION --notes-file \"$ARTIFACTS/release-notes.md\""
