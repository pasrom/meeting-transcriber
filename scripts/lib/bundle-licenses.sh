#!/usr/bin/env bash
# Installs the licence texts every shipped bundle has to carry: the app's own
# LICENSE plus the third-party texts.
#
# The app's own MIT notice goes to <resources-dir>/LICENSE, apart from the
# third-party directory because it is not a third-party component. The copyright
# holder needs no licence to ship their own build, but anyone who forks the repo
# and builds with these scripts redistributes this project's code, and MIT wants
# the notice in every copy. Without this the fork's bundle would carry every
# dependency's notice except the one for the code it is actually built from.
#
# The app statically links third-party source (WhisperKit, FluidAudio) and
# bundles third-party weights (LocalVQE), so the .app redistributes all of them.
# Apache-2.0 section 4a wants a copy of the License with any redistribution and
# 4d wants an existing NOTICE propagated; MIT wants its copyright and permission
# notice in all copies, and a binary is a copy. Nothing about that is visible at
# link time, which is exactly why it needs a build step rather than good
# intentions.
#
# The loop copies whatever `licenses/` holds instead of naming components, so a
# new dependency is attributed by dropping its licence file into that directory:
# no build script has to learn about it, and there is no per-component list that
# can silently fall behind the one in Package.swift.
#
# This is why the licence copy no longer rides along with the LocalVQE model
# install. Installing it here strengthens the property that helper's header
# claims: licences land unconditionally from a directory, not as a side effect of
# a model download that a caller is allowed to fail past.
#
# Source this, don't execute it.

# Copies the repo's LICENSE to <resources-dir>/LICENSE and every licence text in
# the repo's licenses/ directory into <resources-dir>/licenses/. Fatal on
# failure under `set -e`: a bundle that redistributes the code without the
# notices is not one to ship.
install_bundled_licenses() {
    local resources_dir="$1"
    local repo_root licenses_src dest
    local -a licence_files
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    licenses_src="$repo_root/licenses"
    dest="$resources_dir/licenses"

    # Collected rather than globbed straight into cp so an empty directory is a
    # hard stop. Unmatched, the glob would reach cp as a literal path and the
    # error would read like a missing file instead of "this bundle attributes
    # nothing".
    licence_files=("$licenses_src"/*.txt)
    if [ ! -e "${licence_files[0]}" ]; then
        echo "  ERROR: no licence texts in $licenses_src" >&2
        return 1
    fi

    # Anything outside the glob would be skipped in silence, and the directory
    # would still be non-empty so the check above would not catch it. Upstream
    # projects commonly ship LICENSE.md, so dropping one in unrenamed is the
    # natural mistake: it has to fail the build rather than bundle nothing.
    local candidate
    for candidate in "$licenses_src"/*; do
        case "$candidate" in
            *.txt) ;;
            *)
                echo "  ERROR: $candidate is not a .txt and would not be bundled" >&2
                return 1
                ;;
        esac
    done

    mkdir -p "$dest"
    cp "${licence_files[@]}" "$dest/"
    cp "$repo_root/LICENSE" "$resources_dir/LICENSE"

    echo "  App license: $resources_dir/LICENSE"
    echo "  Third-party licenses: $dest (${#licence_files[@]} files)"
}
