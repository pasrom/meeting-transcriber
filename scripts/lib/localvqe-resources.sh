#!/usr/bin/env bash
# Single source of truth for what a LocalVQE-enabled app bundle contains.
#
# Two scripts assemble a bundle — build_release.sh for distribution and
# run_app.sh for the dev app that e2e-app.sh then deploys — and both need the
# same two files in Contents/Resources. Spelled twice they drift, which the
# first version of this change proved by dropping the licence copy from the dev
# path on day one. The failure policy is NOT shared, because it legitimately
# differs: see the callers.
#
# Source this, don't execute it.

# Fetches the pinned model and installs it, with its licence, into the given
# Resources directory. Returns non-zero if ANY step fails, not just the fetch.
#
# Every step propagates its own failure explicitly rather than leaning on the
# caller's `set -e`, because one of the callers invokes this as
# `if ! install_localvqe_resources ...`, and POSIX errexit suppression applies
# recursively into a function called from a condition. Under `set -e` alone a
# failing `cp` would fall through to the next statement and the closing `echo`
# would hand back status 0: the build log would announce an installed model,
# the warning would never print, and the signed bundle would contain nothing.
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
    rm -f "$resources_dir"/localvqe-*.gguf || return 1
    cp "$model_path" "$resources_dir/$model_name" || return 1
    # Bundling the weights is redistribution, which is what makes the licence
    # copy mandatory rather than courteous (Apache-2.0 section 4a). The two are
    # installed together so no bundle can carry one without the other.
    cp "$lib_dir/../../licenses/LocalVQE-LICENSE.txt" "$resources_dir/LocalVQE-LICENSE.txt" || return 1

    echo "  LocalVQE model: $resources_dir/$model_name"
}
