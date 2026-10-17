#!/usr/bin/env bash
set -euo pipefail

# Renders the excerpts listed in Rust/SpatialAudioCore/tests/baselines/excerpts.tsv through SAB's
# C interface, in both layouts, and compares each with its reviewed baseline there. For a
# difference it reports, per speaker feed, the old and new peak and RMS and the seconds that moved,
# and fails. Review that report and justify an intentional rendering change before rerunning with
# --update, which writes the new baselines. Media and decoded audio stay in a temporary directory.
#
#   scripts/compare-baselines.sh [--update] [excerpt name ...]
#
# SAB_MEDIA_ROOT (default /mnt/media/arr) holds `media:` sources; SAB_FIXTURE_DIR the public
# fixtures named by `fixture:` sources (see docs/validation.md#obtain-fixtures).

update=false
if [[ "${1:-}" == --update ]]; then
    update=true
    shift
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baselines="$root/Rust/SpatialAudioCore/tests/baselines"
media="${SAB_MEDIA_ROOT:-/mnt/media/arr}"
fixtures="${SAB_FIXTURE_DIR:-$root/.dependencies/fixtures}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cargo build --quiet --release --locked --manifest-path "$root/Rust/SpatialAudioCore/Cargo.toml" --example baseline
baseline="$root/Rust/SpatialAudioCore/target/release/examples/baseline"
cut_with="$("${FFMPEG:-ffmpeg}" -version | head -n 1)"

failed=0
matched=0
while IFS=$'\t' read -r name codec source index start duration; do
    [[ "$name" == name || "$name" == \#* || -z "$name" ]] && continue
    if [[ $# -gt 0 && " $* " != *" $name "* ]]; then continue; fi
    matched=$((matched + 1))
    format=$([[ "$codec" == truehd ]] && echo truehd || echo dts)
    case "$source" in
        fixture:*) input="$fixtures/${source#fixture:}" ;;
        media:*)
            # A title names the single Matroska file in its library folder.
            films=("$media/movies/${source#media:} "*/*.mkv)
            [[ ${#films[@]} -eq 1 && -f "${films[0]}" ]] ||
                { echo "$name: expected one film for ${source#media:} in $media/movies" >&2; exit 2; }
            input="$work/$name.$format"
            "$root/scripts/compare-excerpt.sh" "${films[0]}" "$index" "$start" "$duration" "$format" "$input"
            ;;
        *) echo "$name: unknown source $source" >&2; exit 2 ;;
    esac
    sha="$(sha256sum "$input" | cut -d ' ' -f 1)"
    for layout in 7.1.4 9.1.6; do
        new="$work/$name-$layout.txt" old="$baselines/$name-$layout.txt"
        {
            echo "# Reviewed expected output of SAB's C interface. Regenerate with scripts/compare-baselines.sh."
            echo "# Excerpt cut with $cut_with."
            printf 'source %s stream %s start %s duration %s\n' "$source" "$index" "$start" "$duration"
            echo "input-sha256 $sha"
            "$baseline" "$codec" "$layout" "$input"
        } > "$new"
        echo "== $name $layout"
        if [[ ! -f "$old" ]]; then
            echo "NEW: no baseline yet"
            failed=1
        elif [[ "$(awk '$1 == "input-sha256" { print $2 }' "$old")" != "$sha" ]]; then
            echo "INPUT CHANGED: the excerpt differs from the baseline's, so its output is not comparable"
            failed=1
        elif ! "$baseline" --diff "$old" "$new"; then
            failed=1
        fi
        if $update; then
            cp "$new" "$old"
        fi
    done
done < "$baselines/excerpts.tsv"

[[ $matched -gt 0 ]] || { echo "no excerpt matched: $*" >&2; exit 2; }
if $update; then
    echo "Baselines written; commit them with the justification for any difference above."
elif [[ $failed -ne 0 ]]; then
    exit 1
fi
