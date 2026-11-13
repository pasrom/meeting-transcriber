#!/bin/bash
# Regression test: assert-red-pixels.swift counts the mic-silent tint, not the
# menu bar behind it.
#
# The channel-health lane screenshots the whole menu bar strip and asks this
# checker whether the icon carries its red tint. The menu bar is translucent,
# so the strip also shows the wallpaper. A warm wallpaper region measured on
# the CI runner sat at about (150, 122, 112), and the checker's first criterion
# (red above 150 and 20 above green) counted some 1500 of those pixels against
# a threshold of 30: the check passed whatever the icon showed.
#
# The images are synthetic so the test needs no screen: a strip filled with a
# background colour, with a given number of pixels in a second colour on it.
# They are written without an alpha channel on purpose. Such a PNG loads with
# three samples in a four-byte pixel, which is the layout the checker's pixel
# stride has to get right; a screenshot carries alpha and never showed it.
#
# `A && ok || bad` is the assertion idiom of these tests; `ok` cannot fail.
# shellcheck disable=SC2015
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/scripts/assert-red-pixels.swift"

TMP="$(mktemp -d)"
# Set at the very end; see test_kill_and_verify_gone.sh for why an abort would
# otherwise read as a pass.
COMPLETED=0
cleanup() {
    local rc=$?
    rm -rf "$TMP"
    if [ "$COMPLETED" -ne 1 ]; then
        echo "FAIL: the test aborted before reaching its end" >&2
        exit 1
    fi
    exit "$rc"
}
trap cleanup EXIT
PASSED=0
ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }

cat > "$TMP/strips.swift" <<'SWIFT'
import AppKit

// strips.swift <dir> <name>:<bgR>,<bgG>,<bgB>:<count>:<r>,<g>,<b> ...
// One 400x30 strip per argument: the background colour, with <count> pixels
// in the second colour.
func rgb(_ s: Substring) -> [UInt8] { s.split(separator: ",").map { UInt8($0)! } }
let dir = CommandLine.arguments[1]
let width = 400, height = 30
for spec in CommandLine.arguments.dropFirst(2) {
    let parts = spec.split(separator: ":")
    let background = rgb(parts[1]), marked = Int(parts[2])!, mark = rgb(parts[3])
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24,
    )!
    let data = rep.bitmapData!
    for i in 0 ..< width * height {
        let colour = i < marked ? mark : background
        for c in 0 ..< 3 { data[i * 3 + c] = colour[c] }
    }
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(dir)/\(parts[0]).png"))
}
SWIFT

# Measured on the runner: the wallpaper behind the menu bar, the tint's core
# and its antialiased edge, which clears the checker's margins by the least.
WALLPAPER="155,125,112"
TINT_CORE="255,79,68"
TINT_EDGE="184,126,138"

swift "$TMP/strips.swift" "$TMP" \
    "wallpaper:$WALLPAPER:0:$TINT_CORE" \
    "edge:$WALLPAPER:60:$TINT_EDGE" \
    "few:$WALLPAPER:20:$TINT_CORE" \
    "warm_and_pink:175,135,120:100:230,120,200" \
    || bad strips_are_written "the generator failed"

# verdict <name>: runs the checker on that strip with the lane's threshold.
# Leaves its exit status in STATUS and its output in $TMP/out.
verdict() {
    STATUS=0
    swift "$CHECKER" "$TMP/$1.png" --min-count 30 > "$TMP/out" 2>&1 || STATUS=$?
}

# counted_and_refused: the checker read the image and found too little red.
# A status of 1 alone would also be what an unreadable image gives.
counted_and_refused() {
    [ "$STATUS" -eq 1 ] && grep -q '^Red pixels in 400x30 image: ' "$TMP/out"
}

verdict wallpaper
counted_and_refused && ok wallpaper_alone_is_not_a_tint \
    || bad wallpaper_alone_is_not_a_tint "status $STATUS: $(cat "$TMP/out")"

# The edge colour, not the core: it is the tint pixel closest to the margins,
# so a margin tightened past it fails here.
verdict edge
[ "$STATUS" -eq 0 ] && ok the_edge_of_a_tint_is_counted \
    || bad the_edge_of_a_tint_is_counted "status $STATUS: $(cat "$TMP/out")"

# Below the threshold: a few red pixels of some other menu bar item.
verdict few
counted_and_refused && ok a_few_red_pixels_are_not_a_tint \
    || bad a_few_red_pixels_are_not_a_tint "status $STATUS: $(cat "$TMP/out")"

# A warmer wallpaper than the measured one, red 40 above green, and pink, which
# only the blue margin keeps out.
verdict warm_and_pink
counted_and_refused && ok warmer_wallpaper_and_pink_are_not_a_tint \
    || bad warmer_wallpaper_and_pink_are_not_a_tint "status $STATUS: $(cat "$TMP/out")"

COMPLETED=1
echo "$PASSED passed"
