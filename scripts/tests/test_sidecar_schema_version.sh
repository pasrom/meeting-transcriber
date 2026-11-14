#!/bin/bash
# Keeps the sidecar version the e2e-app.sh lanes pin level with the one the
# app writes.
#
# `assert_sidecar_common` in scripts/e2e-app.sh refuses a `_meta.json` whose
# `version` is not the one it names. The lanes that call it run on main and
# on labelled pull requests only, so a change that raised
# `RecordingSidecar.currentVersion` passed every required check and turned
# the record-only and microphone-only lanes red after the merge. This test
# runs with the other script tests on every pull request and fails as soon
# as the two numbers differ.
#
# No EXIT trap here on purpose: without one, an abort of this file exits 1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIDECAR_SOURCE="$ROOT/app/MeetingTranscriber/Sources/RecordingSidecar.swift"
DRIVER="$ROOT/scripts/e2e-app.sh"
PASSED=0

ok()  { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
bad() { echo "$1 ... FAIL: $2"; exit 1; }

# Exactly one number each. Nothing found, or two matches on two lines, means
# a pattern no longer finds what it was written for, which must not read as
# two equal empty strings.
app_version="$(sed -n 's/^ *static let currentVersion = \([0-9][0-9]*\)$/\1/p' "$SIDECAR_SOURCE")"
[[ "$app_version" =~ ^[0-9]+$ ]] \
    && ok app_declares_one_version || bad app_declares_one_version "found: '$app_version' in $SIDECAR_SOURCE"

driver_version="$(sed -n 's/^ *if \.version != \([0-9][0-9]*\) then .*$/\1/p' "$DRIVER")"
[[ "$driver_version" =~ ^[0-9]+$ ]] \
    && ok driver_pins_one_version || bad driver_pins_one_version "found: '$driver_version' in $DRIVER"

[ "$app_version" = "$driver_version" ] \
    && ok driver_pins_the_version_the_app_writes \
    || bad driver_pins_the_version_the_app_writes "app writes $app_version, e2e-app.sh expects $driver_version"

echo "$PASSED checks passed"
