#!/bin/bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${1:-${SAB_AB_MEDIA_DIR:-}}"
if [[ -z "$SOURCE_DIR" ]]; then
  echo 'Usage: ./prepare-media.sh /path/to/prepared/media' >&2
  exit 1
fi
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

for sample in helicopter amaze natures-fury channel-check-7.1.4; do
  for version in APAC DDP; do
    if [[ ! -s "$SOURCE_DIR/$sample.$version.mp4" ]]; then
      echo "Missing media: $SOURCE_DIR/$sample.$version.mp4" >&2
      exit 1
    fi
  done
done
if [[ ! -s "$SOURCE_DIR/silent-atmos.mp4" ]]; then
  echo "Missing near-silent JOC Atmos stream: $SOURCE_DIR/silent-atmos.mp4" >&2
  exit 1
fi

mkdir -p "$APP_DIR/Media"
if [[ "$SOURCE_DIR" != "$APP_DIR/Media" ]]; then
  # Baseline APAC, 9.1.6 APAC and PCM files are optional; each is offered when every sample has one.
  # With a baseline for every sample, Auto runs a blind A/B/C test.
  shopt -s nullglob
  rm -f "$APP_DIR/Media"/*.APAC-baseline.mp4 "$APP_DIR/Media"/*.APAC-9.1.6.mp4 "$APP_DIR/Media"/*.PCM.mp4 "$APP_DIR/Media"/*.PCM.mov
  for media in "$SOURCE_DIR"/*.APAC.mp4 "$SOURCE_DIR"/*.APAC-baseline.mp4 "$SOURCE_DIR"/*.APAC-9.1.6.mp4 "$SOURCE_DIR"/*.PCM.mov "$SOURCE_DIR"/*.DDP.mp4 "$SOURCE_DIR/silent-atmos.mp4"; do
    cp -c "$media" "$APP_DIR/Media/"
  done
  if [[ -f "$SOURCE_DIR/extra-samples.json" ]]; then
    cp "$SOURCE_DIR/extra-samples.json" "$APP_DIR/Media/"
  elif [[ -f "$APP_DIR/Media/extra-samples.json" ]]; then
    # Do not retain an old list when replacing the prepared media set.
    rm "$APP_DIR/Media/extra-samples.json"
  fi
fi
