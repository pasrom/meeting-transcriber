#!/usr/bin/env bash
# Generate the REAL-AUDIO quality fixture: an excerpt of a genuine recorded
# multi-party meeting, plus the ground-truth sidecar the WER/DER suite expects.
#
# Why this exists alongside generate_quality_fixtures.sh: that script renders
# `say` voices concatenated with fixed silence. Synthetic audio has no room
# reverb, no overlapping speech, no disfluencies, no level variation and no
# breath noise, so it systematically flatters both the ASR engines and the
# diarizer. This fixture supplies what the synthetic ones cannot: four real
# speakers in a real room, roughly a third of the speech overlapping.
#
# Source: AMI Meeting Corpus (University of Edinburgh), CC BY 4.0. Both the
# signals and the manual annotations are redistributable with attribution; see
# app/MeetingTranscriber/Tests/Fixtures/quality/ATTRIBUTION.md.
#
# The window is snapped to instants where all four speakers are silent, so no
# utterance is cut mid-word and the reference transcript is complete. Which
# window, and why that one, is documented in scripts/lib/ami_fixture_truth.py
# next to the constants that define it.
#
# Output: app/MeetingTranscriber/Tests/Fixtures/quality/
#   four_speakers_en_ami.wav        16 kHz mono 16-bit
#   four_speakers_en_ami_truth.json same shape as the synthetic fixtures
#
# Requires: curl, unzip, sox, python3, shasum.
# Downloads ~56 MB on first run and caches them; set AMI_CACHE_DIR to relocate.

set -euo pipefail

for tool in curl unzip sox python3 shasum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required"; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_DIR/app/MeetingTranscriber/Tests/Fixtures/quality"
CACHE_DIR="${AMI_CACHE_DIR:-${TMPDIR:-/tmp}/ami-fixture-cache}"

MEETING="ES2004a"
FIXTURE="four_speakers_en_ami"

# Makes the reproducibility claim in ATTRIBUTION.md checkable instead of merely
# asserted. The audio URL carries no version in its path, and a sox upgrade
# could change the resample, so without this a regeneration could silently
# produce different audio under a fixture name whose baselines still say the
# old thing. Update deliberately, in the same change that re-blesses.
EXPECTED_WAV_SHA256="50501ed96f0b837480ece0621a8ce40345c05a8ccbe8e8c20d72717530295ae6"

AUDIO_URL="https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/${MEETING}/audio/${MEETING}.Mix-Headset.wav"
ANNO_URL="https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"

mkdir -p "$CACHE_DIR" "$OUT_DIR"

AUDIO_SRC="$CACHE_DIR/${MEETING}.Mix-Headset.wav"
ANNO_ZIP="$CACHE_DIR/ami_public_manual_1.6.2.zip"
ANNO_DIR="$CACHE_DIR/anno"

fetch() {
    curl -fsSL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
}

if [ ! -f "$AUDIO_SRC" ]; then
    echo "Downloading $MEETING audio (~33 MB)..."
    fetch "$AUDIO_URL" "$AUDIO_SRC"
fi

if [ ! -d "$ANNO_DIR" ]; then
    [ -f "$ANNO_ZIP" ] || { echo "Downloading AMI manual annotations (~22 MB)..."; fetch "$ANNO_URL" "$ANNO_ZIP"; }
    echo "Extracting annotations..."
    mkdir -p "$ANNO_DIR"
    unzip -o -q "$ANNO_ZIP" -d "$ANNO_DIR"
fi

# Resolve the snapped window and write the truth sidecar. Prints "start
# duration" so the sox trim below uses exactly the numbers the JSON was built
# from; the window itself is defined by constants inside the Python.
WINDOW="$(python3 "$SCRIPT_DIR/lib/ami_fixture_truth.py" \
    --annotations "$ANNO_DIR" \
    --meeting "$MEETING" \
    --fixture "$FIXTURE" \
    --out "$OUT_DIR/${FIXTURE}_truth.json")"

read -r WIN_START WIN_DURATION <<<"$WINDOW"

echo "Cutting ${WIN_DURATION}s from ${WIN_START}s..."
sox "$AUDIO_SRC" -r 16000 -c 1 -b 16 "$OUT_DIR/${FIXTURE}.wav" \
    trim "$WIN_START" "$WIN_DURATION"

ACTUAL_SHA="$(shasum -a 256 "$OUT_DIR/${FIXTURE}.wav" | cut -d' ' -f1)"
if [ "$ACTUAL_SHA" != "$EXPECTED_WAV_SHA256" ]; then
    echo "ERROR: produced audio does not match the committed fixture." >&2
    echo "  expected $EXPECTED_WAV_SHA256" >&2
    echo "  actual   $ACTUAL_SHA" >&2
    echo "The upstream recording, sox, or the window constants changed. If that" >&2
    echo "is intended, update EXPECTED_WAV_SHA256 and re-bless the baselines." >&2
    exit 1
fi

echo "Wrote:"
echo "  $OUT_DIR/${FIXTURE}.wav (${WIN_DURATION}s, sha256 verified)"
echo "  $OUT_DIR/${FIXTURE}_truth.json"
echo
echo "If the fixture changed, baselines are stale. Re-measure with"
echo "  RUN_QUALITY_TESTS=1 swift test --filter Quality"
echo "and re-bless via scripts/bless_quality_baseline.sh."
