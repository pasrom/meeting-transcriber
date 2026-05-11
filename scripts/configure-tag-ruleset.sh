#!/usr/bin/env bash
# Apply (or update) the GitHub Tag Ruleset declared in
# `.github/tag-ruleset.json`. Idempotent: creates the ruleset if missing,
# updates it in place otherwise.
#
# Usage:
#   ./scripts/configure-tag-ruleset.sh            # apply the ruleset
#   ./scripts/configure-tag-ruleset.sh --dry-run  # show diff vs current
#   ./scripts/configure-tag-ruleset.sh --delete   # remove the ruleset
#
# Why this exists: tag rulesets reject `git push` of a matching tag when
# the named status checks aren't all green on the tagged SHA. Putting the
# config in repo so the rule is version-controlled and reproducible
# instead of living only in repo Settings → Rules.
#
# Requires: `gh` CLI authenticated as a repo admin.

set -euo pipefail
cd "$(dirname "$0")/.."

REPO=${REPO:-pasrom/meeting-transcriber}
CONFIG_FILE=.github/tag-ruleset.json

DRY_RUN=0
DELETE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --delete) DELETE=1 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found in PATH" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found in PATH" >&2
    exit 1
fi

RULESET_NAME=$(jq -r '.name' "$CONFIG_FILE")
EXISTING_ID=$(gh api "repos/$REPO/rulesets" |
    jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .id')

summarize() {
    jq '{
        name, target, enforcement,
        conditions: .conditions.ref_name,
        checks: [.rules[] | select(.type=="required_status_checks") |
                 .parameters.required_status_checks[].context]
    }' "$@"
}

if [[ "$DELETE" == "1" ]]; then
    if [[ -z "$EXISTING_ID" ]]; then
        echo "No ruleset named '$RULESET_NAME' found — nothing to delete."
        exit 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] Would DELETE ruleset $EXISTING_ID ($RULESET_NAME)"
        exit 0
    fi
    gh api -X DELETE "repos/$REPO/rulesets/$EXISTING_ID"
    echo "Deleted ruleset $EXISTING_ID ($RULESET_NAME)"
    exit 0
fi

if [[ -z "$EXISTING_ID" ]]; then
    ACTION="CREATE"
    METHOD=POST
    ENDPOINT="repos/$REPO/rulesets"
else
    ACTION="UPDATE"
    METHOD=PUT
    ENDPOINT="repos/$REPO/rulesets/$EXISTING_ID"
fi

if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] Would $ACTION ruleset '$RULESET_NAME' at $ENDPOINT"
    if [[ -n "$EXISTING_ID" ]]; then
        echo "[dry-run] Current state:"
        gh api "repos/$REPO/rulesets/$EXISTING_ID" | summarize
    fi
    echo "[dry-run] Desired state:"
    summarize "$CONFIG_FILE"
    exit 0
fi

RESULT=$(gh api -X "$METHOD" "$ENDPOINT" --input "$CONFIG_FILE")

echo "$RESULT" | jq -r '"\(.name) — id=\(.id), enforcement=\(.enforcement), target=\(.target)"'
echo "$ACTION ok"
