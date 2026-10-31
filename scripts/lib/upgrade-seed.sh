#!/usr/bin/env bash
# Helpers for the --upgrade lane of e2e-app.sh: lay out, in a throwaway home,
# the data an install of v0.8.1 leaves behind, and compare folders before and
# after the new build has run over it.
#
# Every on-disk shape written here is taken from the sources at tag v0.8.1, not
# from the current code, so the lane tests what an upgrading user actually has.
# What each one is derived from is written at the helper. Pure apart from the
# files they are pointed at; tested by scripts/tests/test_upgrade_seed_helpers.sh.
#
# Source this, don't execute it. Needs jq.

# The CoreML bundles and the files in each that a WhisperKit load requires.
# Mirrors WhisperKitLocalSnapshot.requiredBundles / requiredFiles, which is what
# WhisperKitModelMigration.isComplete checks before it moves a variant.
UPGRADE_REQUIRED_BUNDLES=(MelSpectrogram AudioEncoder TextDecoder)
UPGRADE_REQUIRED_FILES=(coremldata.bin model.mil weights/weight.bin)

# v0.8.1 called `WhisperKit.download(variant:)` without a download base, so the
# Hub client wrote under `<Documents>/huggingface/models/<repo>`, and the
# tokenizer under `models/openai/whisper-<size>` of the same base.
UPGRADE_WHISPERKIT_REPO="models/argmaxinc/whisperkit-coreml"
UPGRADE_TOKENIZER_ORG="models/openai"

# Seconds between the Unix epoch and 2001-01-01, the reference date Foundation's
# default JSONEncoder writes a `Date` as (v0.8.1 used the default strategy).
UPGRADE_FOUNDATION_EPOCH_OFFSET=978307200

# upgrade_variant_complete <variant folder> — every file a load requires is
# there. The same test the migration applies before it moves a variant.
upgrade_variant_complete() {
    local dir="$1" bundle file
    for bundle in "${UPGRADE_REQUIRED_BUNDLES[@]}"; do
        for file in "${UPGRADE_REQUIRED_FILES[@]}"; do
            [ -f "$dir/$bundle.mlmodelc/$file" ] || return 1
        done
    done
}

# upgrade_path_inside <path> <dir> — `path` lies strictly below `dir`, and
# neither carries a `..` segment that could climb back out of it.
upgrade_path_inside() {
    local path="$1" dir="${2%/}"
    [ -n "$dir" ] || return 1
    case "/$path/" in */../*) return 1 ;; esac
    case "/$dir/" in */../*) return 1 ;; esac
    case "$path" in "$dir"/?*) return 0 ;; *) return 1 ;; esac
}

# _upgrade_clone <from> <to> — an APFS clone where the volume offers one, a copy
# otherwise. A clone shares the source's blocks until either side changes, so
# the seed costs no space and leaves the source untouched.
_upgrade_clone() {
    cp -cR "$1" "$2" 2>/dev/null || { rm -rf "${2:?}"; cp -R "$1" "$2"; }
}

# upgrade_seed_whisperkit <source base> <dest base> <variant> <tokenizer>
#
# Lay out `variant` and its tokenizer under `dest base` (a `.../huggingface`
# folder) the way v0.8.1's downloads left them, from a complete copy under
# `source base` in the same layout. Writes:
#   <dest>/models/argmaxinc/whisperkit-coreml/<variant>
#   <dest>/models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/<variant>
#   <dest>/models/openai/<tokenizer>
# The download metadata is cloned when the source has it. The app's own cache
# can lack it (an earlier build fetched the model without leaving it there),
# and then a stand-in in the Hub client's format (commit, etag, timestamp, one
# per line) is written, since what the lane checks is that the migration
# carries the folder along, not what it says.
# Returns 1, with the reason on stderr, when the source is not complete.
upgrade_seed_whisperkit() {
    local src="$1" dst="$2" variant="$3" tokenizer="$4"
    local src_repo="$src/$UPGRADE_WHISPERKIT_REPO" dst_repo="$dst/$UPGRADE_WHISPERKIT_REPO"
    local src_meta="$src_repo/.cache/huggingface/download/$variant"
    local dst_meta="$dst_repo/.cache/huggingface/download/$variant"
    if ! upgrade_variant_complete "$src_repo/$variant"; then
        echo "no complete $variant under $src_repo" >&2
        return 1
    fi
    if [ ! -f "$src/$UPGRADE_TOKENIZER_ORG/$tokenizer/tokenizer.json" ]; then
        echo "no $tokenizer tokenizer under $src/$UPGRADE_TOKENIZER_ORG" >&2
        return 1
    fi
    mkdir -p "$dst_repo" "$dst/$UPGRADE_TOKENIZER_ORG" "$(dirname "$dst_meta")"
    _upgrade_clone "$src_repo/$variant" "$dst_repo/$variant"
    _upgrade_clone "$src/$UPGRADE_TOKENIZER_ORG/$tokenizer" "$dst/$UPGRADE_TOKENIZER_ORG/$tokenizer"
    if [ -d "$src_meta" ]; then
        _upgrade_clone "$src_meta" "$dst_meta"
    else
        mkdir -p "$dst_meta"
        printf '%s\n%s\n%s\n' 0123456789abcdef0123456789abcdef01234567 \
            '"e2e-upgrade-seed"' 1700000000.0 >"$dst_meta/config.json.metadata"
    fi
}

# upgrade_file_url <absolute path> — the string Foundation's JSONEncoder writes
# for a file URL: `file://` and the path with each segment percent-encoded, so
# `Application Support` becomes `Application%20Support`.
upgrade_file_url() {
    jq -rn --arg p "$1" '"file://" + ($p | split("/") | map(@uri) | join("/"))'
}

# upgrade_foundation_date <unix seconds> — the number Foundation's default
# JSONEncoder writes for that moment.
upgrade_foundation_date() {
    echo $(( $1 - UPGRADE_FOUNDATION_EPOCH_OFFSET ))
}

# upgrade_v081_pipeline_job <id> <title> <state> <mix path> <unix enqueued>
#
# One job of `ipc/pipeline_queue.json` as v0.8.1 wrote it: `PipelineSnapshot.save`
# encoded `[PipelineJob]` with a default JSONEncoder, and that struct's
# synthesized Codable left out nil optionals. A recording of the app's own,
# single-source, with the three output options a v0.8.1 enqueue stamped. None of
# the fields added since (relocated paths, sidecar folders, track viability,
# naming start, AI-title choice) are present, which is the point.
upgrade_v081_pipeline_job() {
    local id="$1" title="$2" state="$3" mix="$4" enqueued="$5"
    jq -nc \
        --arg id "$id" --arg title "$title" --arg state "$state" \
        --arg mix "$(upgrade_file_url "$mix")" \
        --argjson enqueued "$(upgrade_foundation_date "$enqueued")" \
        --argjson started "$(upgrade_foundation_date $(( enqueued - 60 )))" \
        '{id: $id, meetingTitle: $title, appName: "MeetingSimulator", mixPath: $mix,
          micDelay: 0, participants: [], enqueuedAt: $enqueued,
          meetingStartTime: $started, state: $state, warnings: [],
          includeFullTranscriptInProtocol: true, saveRawTranscriptSeparately: false,
          autoSkipNaming: false}'
}

# upgrade_v081_terminal_record <id> <title> <transcript path>
#
# One record of `ipc/terminal_jobs.json` as v0.8.1 wrote it: `[JobStatusDTO]`
# from a default JSONEncoder, paths as plain strings, nil optionals left out. It
# carries an echo verdict in v0.8.1's shape, without the `cancellationSeconds`
# added since, because that object has a hand-written decoder whose leniency is
# exactly what an old record depends on.
upgrade_v081_terminal_record() {
    local id="$1" title="$2" transcript="$3"
    jq -nc --arg id "$id" --arg title "$title" --arg transcript "$transcript" \
        '{jobID: $id, state: "done", meetingTitle: $title, transcriptPath: $transcript,
          warnings: [],
          echo: {detected: false, affectedWindowShare: 0, windowsScored: 12,
                 windowsAffected: 0, suppressedSegments: 0}}'
}

# upgrade_tree_digest <dir> — the SHA-256 of every file below `dir` with its
# relative path, sorted, or `absent`: equal for two copies with the same
# contents, whatever their inodes.
upgrade_tree_digest() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo absent
        return 0
    fi
    (cd "$dir" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256)
}

# upgrade_tree_fingerprint <dir> — one line per entry below `dir` (inode,
# modification time, size, type, relative path), sorted, or `absent`. Two equal
# fingerprints mean nothing was added, removed, replaced or rewritten in place:
# a move keeps the inode, a rewrite changes the time, a new entry adds a line
# and changes its folder's time.
upgrade_tree_fingerprint() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo absent
        return 0
    fi
    # An entry that vanishes between find and stat, or a folder that cannot be
    # listed, drops out of the listing rather than aborting a `set -e` caller
    # without a word; the comparison then reports the difference.
    (cd "$dir" && find . -print0 2>/dev/null | sort -z | xargs -0 stat -f '%i %m %z %HT %N' 2>/dev/null) || true
}
