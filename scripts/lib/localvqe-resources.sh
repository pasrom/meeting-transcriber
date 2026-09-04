#!/usr/bin/env bash
# Single source of truth for what a LocalVQE-enabled app bundle contains.
#
# Two scripts assemble a bundle — build_release.sh for distribution and
# run_app.sh for the dev app that e2e-app.sh then deploys — and both need the
# same model in Contents/Resources. Spelled twice they drift, which the first
# version of this change proved by dropping the licence copy from the dev path
# on day one. The failure policy is NOT shared, because it legitimately differs:
# see the callers.
#
# Source this, don't execute it.

# How a model file is recognised inside a bundle. The Swift resolver matches on
# the same prefix and extension (LocalVQEModel.resourcePrefix), and everything
# else discovers the concrete name rather than restating it, so a model bump
# stays one edit in fetch-localvqe-model.sh. Exported as a variable because the
# cleanup below and the e2e lane that checks a deployed bundle both need it, and
# two hand-typed globs are two things to keep in step.
LOCALVQE_RESOURCE_GLOB="localvqe-*.gguf"

# Fetches the pinned model and installs it into the given Resources directory.
# Returns non-zero if ANY step fails, not just the fetch.
#
# Every step propagates its own failure explicitly rather than leaning on the
# caller's `set -e`, because one of the callers invokes this as
# `if ! install_localvqe_resources ...`, and POSIX errexit suppression applies
# recursively into a function called from a condition. Under `set -e` alone a
# failing `cp` would fall through to the next statement and the closing `echo`
# would hand back status 0: the build log would announce an installed model,
# the warning would never print, and the signed bundle would contain nothing.
#
# The LocalVQE licence copy lives in lib/bundle-licenses.sh now, and the
# guarantee it used to give here got stronger in the move: the licence no
# longer arrives as a side effect of a model download that run_app.sh is
# allowed to fail past, but unconditionally, from a directory, before this
# function is ever reached. A bundle carrying the weights without the licence
# was previously prevented by the two copies sitting next to each other; it is
# now impossible by ordering.
install_localvqe_resources() {
    local resources_dir="$1"
    local lib_dir model_path model_name
    # Guarded because the rm below is a glob: an empty argument would aim it at
    # the filesystem root instead of a bundle.
    [ -n "$resources_dir" ] || { echo "  ERROR: no Resources directory given" >&2; return 1; }
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1

    model_path="$("$lib_dir/../fetch-localvqe-model.sh")" || return 1
    model_name="${model_path##*/}"

    mkdir -p "$resources_dir" || return 1
    # A model from an earlier pin would otherwise sit alongside the new one, and
    # the resolver picks deterministically by filename, so the SUPERSEDED model
    # would win from then on with nothing reporting it. build_release.sh
    # rebuilds its bundle from scratch and run_app.sh does not, so the cleanup
    # belongs here where both callers inherit it.
    # Unquoted on purpose: the point is that the shell expands the pattern.
    # Quoting it, which is what a passing lint cleanup would do, makes this
    # match nothing, leaves the superseded model in place, and the resolver's
    # deterministic pick then returns the OLD one for good.
    # shellcheck disable=SC2086
    rm -f "$resources_dir"/$LOCALVQE_RESOURCE_GLOB || return 1
    cp "$model_path" "$resources_dir/$model_name" || return 1

    echo "  LocalVQE model: $resources_dir/$model_name"
}
