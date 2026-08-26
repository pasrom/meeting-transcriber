#!/usr/bin/env bash
# Fetch the LocalVQE AEC model into a shared cache and print its path.
#
# Usage:
#   MODEL=$(./scripts/fetch-localvqe-model.sh)
#
# All progress goes to stderr; stdout carries exactly one line, the path to a
# verified model file, so the script composes into a command substitution.
#
# Pinning is by content, not by name. A HuggingFace branch moves and a file at
# a path can be replaced, so the revision pin says which bytes to ask for and
# the SHA-256 says what must have come back. A mismatch is an error, never a
# silent re-download: at that point either the pin is stale or the transfer is
# not what it claims, and both want a person.
#
# Bumping the model needs a new xcframework FIRST, not just a new URL here.
# LocalVQE checks the GGUF against a SHA-256 allowlist compiled into the
# library, so a model the linked binary does not know is rejected at load
# however correctly it is pinned here. Package.swift is the other half.
#
# Then, in one commit: change REVISION, FILE and SHA256 in
# the same commit, update the LocalVQE entry in THIRD-PARTY-NOTICES.md (which
# records the exact revision and filename as provenance, so it goes stale
# here), and re-run the measurements the choice rests on. Regenerate the
# checksum with:
#
#   shasum -a 256 <downloaded-file>

set -euo pipefail

# LocalVQE v1.4-AEC, 203K parameters, F32. Echo cancellation only (no noise
# suppression or dereverberation), which is what this app wants: the room tone
# of the local speaker should survive untouched.
REPO="LocalAI-io/LocalVQE"
REVISION="29ca38495cba9d6393a92a4dd890f28dd81f758d"
FILE="localvqe-v1.4-aec-200K-f32.gguf"
SHA256="b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"

URL="https://huggingface.co/${REPO}/resolve/${REVISION}/${FILE}"

# Shared across worktrees and preserved across `rm -rf .build`, because a
# release build should not re-download 2.9 MB for every checkout on the
# machine. Safe to delete: the next build refetches. Named for LocalVQE and not
# for models in general, because it moves nothing else: WhisperKit and
# FluidAudio cache under their own SDK directories, and those are the ~1 GB.
CACHE_DIR="${MEETINGTRANSCRIBER_LOCALVQE_CACHE:-$HOME/Library/Caches/MeetingTranscriber/models}"
CACHED="$CACHE_DIR/$FILE"

verify() {
    [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$SHA256" ]
}

if verify "$CACHED"; then
    echo "fetch-localvqe-model: cached $CACHED" >&2
    echo "$CACHED"
    exit 0
fi

if [ -f "$CACHED" ]; then
    echo "fetch-localvqe-model: cached copy fails the checksum, refetching" >&2
fi

mkdir -p "$CACHE_DIR"
TMP="$(mktemp "$CACHE_DIR/.$FILE.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

echo "fetch-localvqe-model: downloading $FILE from $REPO@${REVISION:0:12}" >&2
# Timeouts are not optional here: a network that blackholes rather than
# refuses would otherwise hang a build indefinitely with no output, and
# --retry would multiply the stall. 2.9 MB over any usable link fits in 60 s.
curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 -o "$TMP" "$URL"

if ! verify "$TMP"; then
    echo "fetch-localvqe-model: CHECKSUM MISMATCH for $URL" >&2
    echo "  expected $SHA256" >&2
    echo "  actual   $(shasum -a 256 "$TMP" | cut -d' ' -f1)" >&2
    exit 1
fi

# Atomic within the cache directory, so a concurrent build either sees the old
# file or the complete new one, never a partial write.
mv "$TMP" "$CACHED"
trap - EXIT
chmod 644 "$CACHED"

echo "fetch-localvqe-model: verified $CACHED" >&2
echo "$CACHED"
