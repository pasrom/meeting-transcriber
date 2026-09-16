#!/usr/bin/env bash
# Shared signing helper: embed a provisioning profile and, only then, add the
# entitlements that profile authorises.
#
# Why this exists (issue #543): the browser-meeting consent prompt asks a
# question that expires. At the default interruption level macOS renders it as a
# banner, which any Focus mode suppresses outright, so the question is never seen
# and browser meetings silently never record. `.timeSensitive` is the only level
# that breaks through Focus, and it requires
# `com.apple.developer.usernotifications.time-sensitive`.
#
# That entitlement is RESTRICTED. Measured, not assumed: signing a bundle with it
# but no provisioning profile makes macOS refuse to launch the app outright
# ("Launchd job spawn failed", POSIX 163) — with a local Apple Development cert
# AND with Developer ID plus hardened runtime, i.e. exactly how a release is
# signed. Adding the key unconditionally would ship a brick.
#
# So the key is added ONLY when a profile that authorises it is present, and the
# no-profile path is byte-identical to the previous behaviour. Contributors and
# CI without profiles keep building working apps; the prompt just stays at the
# old interruption level for them.
#
# Profiles are Developer ID distribution profiles from the Apple Developer
# portal, one per bundle id. They are gitignored: they are account artifacts, and
# the same reasoning that keeps the signing certificate out of the repo applies.
# Point PROFILE_DIR somewhere else if you keep them elsewhere.

# Derived from this file's own location, so it does not depend on which caller
# happens to define TRANSCRIBER_ROOT.
_SIGNING_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="${PROFILE_DIR:-$_SIGNING_LIB_ROOT/signing}"

TIME_SENSITIVE_KEY="com.apple.developer.usernotifications.time-sensitive"

# The dev bundle every e2e lane deploys is the Homebrew variant, so
# resign_deployed_bundle resolves its base entitlements here rather than having
# four lanes each spell the same path — one more place for them to drift apart.
DEV_ENTITLEMENTS="${DEV_ENTITLEMENTS:-$_SIGNING_LIB_ROOT/app/MeetingTranscriber/Entitlements/Homebrew.entitlements}"

# profile_for <bundle-id> → path, or empty when none is available.
#
# "No profile" is a normal outcome, not a failure, so this must return 0 either
# way: an `&&`-terminated body would hand back the failed test's status, and a
# caller's `profile="$(profile_for "$id")"` under `set -e` would then abort the
# whole build with no output at all. Every machine without the account's
# profiles takes this path.
profile_for() {
    local bundle_id="$1"
    local candidate="$PROFILE_DIR/${bundle_id}.provisionprofile"
    if [ -f "$candidate" ]; then
        printf '%s' "$candidate"
    fi
}

# prepare_signing <app-bundle> <base-entitlements> <bundle-id> [fallback-identity]
#
# Embeds the matching profile when there is one, then sets two globals for the
# caller to sign with:
#   SIGNING_ENTITLEMENTS — the base file, or a derived copy carrying the
#                          time-sensitive key when a profile authorises it
#   SIGNING_IDENTITY     — the identity that profile covers, else the fallback
#
# Globals rather than stdout: this function MUTATES the bundle (it copies the
# profile in, or removes a stale one), and a `$( )` call site would hide that
# side effect inside a subshell — plus returning two values through stdout is
# what previously forced a second function and a second keychain query.
#
# shellcheck disable=SC2034  # SIGNING_ENTITLEMENTS/SIGNING_IDENTITY are read by callers
prepare_signing() {
    local bundle="$1" base_entitlements="$2" bundle_id="$3" fallback="${4:-}"
    local profile
    profile="$(profile_for "$bundle_id")"

    SIGNING_IDENTITY="$fallback"

    if [ -z "$profile" ]; then
        # Drop a profile left behind by an earlier build: the bundle is
        # reassembled in place, so a stale embedded.provisionprofile would make
        # this build look provisioned when it is not, and would make
        # verify_signing warn about a profile nobody asked for.
        rm -f "$bundle/Contents/embedded.provisionprofile"
        echo "  No provisioning profile for $bundle_id — signing without $TIME_SENSITIVE_KEY."
        echo "  (The consent prompt will not break through Focus in this build; see issue #543.)"
        SIGNING_ENTITLEMENTS="$base_entitlements"
        return 0
    fi

    cp "$profile" "$bundle/Contents/embedded.provisionprofile"
    echo "  Embedded provisioning profile for $bundle_id"

    # A profile authorises specific CERTIFICATES. Signing with one it does not
    # list makes macOS reject the launch outright once the entitlement is really
    # present ("Launchd job spawn failed" — measured). Developer ID distribution
    # profiles list the Developer ID Application certificate, so prefer that
    # over whatever `security find-identity` happens to return first.
    local devid
    devid="$(codesigning_identities | identity_fields | first_developer_id)"
    if [ -n "$devid" ]; then
        SIGNING_IDENTITY="$devid"
    else
        echo "  WARNING: a profile applies but no Developer ID Application certificate was found;"
        echo "  the signature will not be covered by it and the app may refuse to launch."
    fi

    # Derive the entitlements rather than keeping a second near-duplicate file,
    # so the base list stays the single source of truth. Written beside the
    # bundle instead of into TMPDIR: it is a build artifact, gets overwritten by
    # the next build, and goes away with the build directory rather than piling
    # up one file per build forever.
    local derived="${bundle%.app}-entitlements.plist"
    cp "$base_entitlements" "$derived"
    # plutil reads dots in a key as KEY PATH separators, so the literal key has
    # to arrive escaped or the insert silently fails and the build reports a key
    # it never added.
    plutil -insert "${TIME_SENSITIVE_KEY//./\\.}" -bool true "$derived" \
        || { echo "  ERROR: could not add $TIME_SENSITIVE_KEY to the entitlements" >&2; return 1; }
    echo "  Requesting $TIME_SENSITIVE_KEY"
    SIGNING_ENTITLEMENTS="$derived"
}

# verify_signing <app-bundle>
#
# Call AFTER codesign. Requesting the entitlement is not the same as getting it:
# when a profile is embedded, codesign validates entitlements against it and
# silently DROPS any the profile does not grant. Measured: with a profile that
# lacks the Time Sensitive Notifications capability, the key vanishes from the
# signature, the build reports success, and the consent prompt stays suppressed
# under Focus with nothing anywhere saying so.
#
# (Without any profile the same key instead makes the app refuse to launch, which
# is why prepare_signing only requests it when a profile is present.)
verify_signing() {
    local bundle="$1"
    [ -f "$bundle/Contents/embedded.provisionprofile" ] || return 0

    if bundle_has_time_sensitive "$bundle"; then
        echo "  Verified $TIME_SENSITIVE_KEY survived signing"
        return 0
    fi

    echo "  WARNING: the profile is embedded but codesign dropped $TIME_SENSITIVE_KEY."
    echo "  The profile does not grant it — enable the Time Sensitive Notifications"
    echo "  capability on this App ID and re-issue the profile. Until then the"
    echo "  consent prompt cannot break through Focus (issue #543)."
    return 0
}

# bundle_has_time_sensitive <app-bundle>
#
# True when the SIGNATURE actually carries the key. Separate from
# verify_signing so a caller that must fail on a missing key (an e2e lane
# asserting the prompt can break through Focus) shares this one definition of
# the check and of the key itself, instead of re-spelling both.
bundle_has_time_sensitive() {
    codesign -d --entitlements :- "$1" 2>/dev/null | grep -q "$TIME_SENSITIVE_KEY"
}

# bundle_signing_cert_sha1 <app-bundle>
#
# SHA-1 of the leaf certificate the bundle is signed with, empty when it is
# unsigned or ad-hoc signed. The hash and not the certificate's name, because
# the hash is what TCC keys a grant on and two certificates share a name across
# a renewal — a name comparison would call those two the same certificate.
bundle_signing_cert_sha1() {
    local bundle="$1" dir hash=""
    # Absolute, because the subshell below changes directory: a relative path
    # would resolve against the temp dir, yield no certificate, and read as
    # "unsigned" — which sends the caller down the destructive branch.
    case "$bundle" in /*) ;; *) bundle="$PWD/$bundle" ;; esac
    dir="$(mktemp -d)"
    # --extract-certificates writes codesign0, codesign1, … into the CURRENT
    # directory, hence the subshell cd. codesign0 is the leaf.
    ( cd "$dir" && codesign -d --extract-certificates "$bundle" >/dev/null 2>&1 ) || true
    if [ -f "$dir/codesign0" ]; then
        # `|| true`: an unsigned or odd bundle is a normal answer (empty), not a
        # failure. Under the callers' `pipefail` a non-zero pipeline here would
        # become the function's status and abort their `hash="$(…)"` assignment
        # with no output at all — the same trap documented at profile_for.
        hash="$(openssl x509 -inform DER -in "$dir/codesign0" -noout -fingerprint -sha1 2>/dev/null \
            | sed 's/^.*=//' | tr -d ':' | tr '[:lower:]' '[:upper:]' || true)"
    fi
    rm -rf "$dir"
    printf '%s' "$hash"
}

# choose_signing_identity <app-bundle>
#
# Which certificate to sign a dev bundle with so TCC keeps the grants it has
# already made against that bundle. Sets three globals:
#   CHOSEN_IDENTITY          SHA-1 of the certificate to sign with; empty when
#                            the keychain holds no codesigning identity. What
#                            that means for the bundle is each caller's call
#   CHOSEN_IDENTITY_REASON   the rule that chose it, one phrase for the log
#   CHOSEN_IDENTITY_LISTING  its `security find-identity` line(s), leading
#                            whitespace removed, so the log can name the
#                            certificate instead of only hashing it
#
# Globals rather than stdout, as with prepare_signing: three values, and one
# keychain query behind all of them.
#
# Call it BEFORE the bundle is touched. The certificate of the previous build
# lives in the main executable's embedded signature, and copying a freshly
# linked binary over that executable leaves an ad-hoc signature with no
# certificate in it. Measured: the intact bundle yields the hash, the same
# bundle after the copy yields nothing. Called after the copy this function is
# not wrong, only blind: it can never take rule 1 and falls through to rules 2
# and 3, which costs the renewal case described at rule 1 and, on a keychain
# without a Developer ID, moves a bundle whose certificate was fine to
# whatever happens to be listed first.
#
# TCC binds a grant to the signing certificate's leaf SHA-1, so the choice made
# here decides whether the dev app keeps its microphone and screen-recording
# grants or silently loses all of them: the rebuilt app then records nothing,
# with no error anywhere and no prompt, because from TCC's point of view it is
# a different application. `head -1` over the keychain made that depend on
# listing order, and the order changed under us the day an Apple Development
# certificate was added. Hence, in order:
#
#   1. Keep the certificate the bundle already carries, while it is still in
#      the keychain AND it is either a Developer ID one or there is no
#      Developer ID to move to. Two valid Developer ID Application
#      certificates (the overlap around a renewal) would otherwise put us back
#      to "whichever is listed first", and switching between them voids the
#      grants just as thoroughly as switching issuer would. The second half of
#      the condition matters: a bundle signed with Apple Development before
#      this rule existed would be pinned to the wrong certificate forever by
#      "keep what is there" alone, with the only escape being to delete the
#      bundle by hand. With it, such a bundle moves to Developer ID by itself.
#   2. Otherwise the Developer ID Application certificate, the one the grants
#      on a maintainer's machine were made against.
#   3. Otherwise the first identity listed, with a note that grants made
#      against a different certificate will not apply. A self-hosted runner
#      holding only its self-signed certificate lands here; its lanes re-sign
#      the deployed copy with dev_signing_identity anyway, so this choice
#      decides nothing there.
#
# The identities are read through codesigning_identities, identity_fields and
# first_developer_id below, so this and prepare_signing answer "which one is
# the Developer ID" the same way.
#
# shellcheck disable=SC2034  # CHOSEN_IDENTITY* are read by callers
choose_signing_identity() {
    local bundle="$1" previous listing fields devid carried
    CHOSEN_IDENTITY=""
    CHOSEN_IDENTITY_REASON=""
    CHOSEN_IDENTITY_LISTING=""

    previous="$(bundle_signing_cert_sha1 "$bundle")"
    listing="$(codesigning_identities)"
    fields="$(printf '%s\n' "$listing" | identity_fields)"
    devid="$(printf '%s\n' "$fields" | first_developer_id)"
    # The carried certificate's record: empty when the bundle is unsigned or
    # the certificate has left the keychain, and either way there is nothing
    # to keep.
    carried="$(printf '%s\n' "$fields" | awk -v h="$previous" 'h != "" && $1 == h')"

    if [ -n "$carried" ]; then
        if [ -z "$devid" ] || [ -n "$(printf '%s\n' "$carried" | first_developer_id)" ]; then
            CHOSEN_IDENTITY="$previous"
            CHOSEN_IDENTITY_REASON="kept the certificate this bundle already carried"
        fi
    fi
    if [ -z "$CHOSEN_IDENTITY" ] && [ -n "$devid" ]; then
        CHOSEN_IDENTITY="$devid"
        CHOSEN_IDENTITY_REASON="chose the Developer ID Application certificate"
    fi
    if [ -z "$CHOSEN_IDENTITY" ]; then
        CHOSEN_IDENTITY="$(printf '%s\n' "$fields" | awk 'NF { print $1; exit }')"
        if [ -n "$CHOSEN_IDENTITY" ]; then
            CHOSEN_IDENTITY_REASON="no Developer ID Application certificate exists, took the first identity"
            echo "  NOTE: TCC grants made against a different certificate will not apply to this build."
        fi
    fi
    if [ -n "$CHOSEN_IDENTITY" ]; then
        CHOSEN_IDENTITY_LISTING="$(printf '%s\n' "$listing" | awk -v h="$CHOSEN_IDENTITY" 'toupper($2) == h')"
    fi
    return 0
}

# codesigning_identities → what `security find-identity -v -p codesigning`
# lists, one record per line, leading whitespace removed.
#
# Only records of the form `N) <sha1> "<name>"` count. An empty keychain
# answers `0 valid identities found`, and `head -1 | awk '{print $2}'` over
# that used to hand the word `valid` to codesign as the identity. The name is
# required along with the hash, not merely described: the rules classify an
# identity by its name and the log prints it, so a record without one could
# only ever reach the last-resort rule with nothing to say for itself. The
# real tool never prints such a record, so the check costs nothing there and
# keeps the shape stated here true in one place.
#
# `length` rather than a `{40}` interval because the system awk does not
# promise the latter. `|| true`: a keychain that cannot be read is a normal
# answer (empty), not a failure, the trap documented at profile_for.
codesigning_identities() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk '$1 ~ /^[0-9]+\)$/ && length($2) == 40 && $2 ~ /^[0-9A-Fa-f]+$/ &&
               $3 ~ /^"/ && $NF ~ /"$/ { sub(/^[ \t]+/, ""); print }' \
        || true
}

# identity_fields: those records on stdin → `<SHA1> <name>` per line, the hash
# upper-cased, the name without its quotes (everything between the first and
# the last, so a name with spaces, parentheses or a quote inside survives).
# The hash is then a whole field and the name starts at a fixed column, so a
# rule compares the one exactly and anchors on the other, instead of grepping
# the line, where a name that merely CONTAINS a phrase, or a hash that happens
# to occur inside a name, would match as well.
identity_fields() {
    awk 'NF { name = $0; sub(/^[^"]*"/, "", name); sub(/"[^"]*$/, "", name)
              print toupper($2) " " name }'
}

# first_developer_id: identity_fields records on stdin → SHA-1 of the first
# whose name IS a Developer ID Application certificate's, i.e. begins with
# `Developer ID Application: `, the form Apple issues (`Developer ID
# Application: <holder> (<team>)`). Anchored on purpose, where identity_sha1
# below is deliberately a substring: that one resolves a name the way codesign
# does, this one decides which certificate the grants belong to, and a
# self-signed certificate is named by whoever makes it (see
# setup-self-hosted-runner.sh), so `Archive of Developer ID Application: ...`
# listed first must not win. Column 42: forty hex digits and one space.
first_developer_id() {
    awk 'substr($0, 42) ~ /^Developer ID Application: / { print $1; exit }'
}

# identity_sha1 <identity> [keychain]
#
# The same hash for an identity held as either a 40-hex SHA-1 (what the lanes
# compute from the runner's self-signed certificate) or a name (what the
# DEVELOPER_ID secret carries). Empty when a name resolves to nothing, or to more
# than one certificate.
#
# The name is matched as a SUBSTRING, because that is how codesign resolves
# `--sign <name>`: per its man page it takes the certificate whose subject common
# name *contains* the string. Anchoring on the fully quoted name that
# `find-identity` prints would reject identities codesign accepts — and since an
# unresolved identity can never match the bundle, the caller would then always
# take the destructive branch.
# identity_matches <name> [keychain] — the SHA-1 of every codesigning identity
# whose line contains this name, one per line, deduplicated.
#
# Split out of identity_sha1 because the COUNT is load-bearing to a second
# caller and that function deliberately throws it away: it answers empty both
# for a name nothing matches and for one that several do, which are opposite
# situations with opposite remedies. A caller that has to tell them apart asks
# here instead of running a second, separately maintained query.
#
# `|| true` because a keychain that cannot be read is a normal answer (empty),
# not a failure. Without it, `pipefail` would make this the function's status
# and abort the caller's `x="$(…)"` assignment with no output at all, the trap
# documented at profile_for.
identity_matches() {
    local identity="$1" keychain="${2:-}" args=(-v -p codesigning)
    [ -n "$keychain" ] && args+=("$keychain")
    security find-identity "${args[@]}" 2>/dev/null \
        | awk -v name="$identity" 'index($0, name) { print toupper($2) }' \
        | sort -u || true
}

identity_sha1() {
    local identity="$1" keychain="${2:-}"
    if [[ $identity =~ ^[0-9A-Fa-f]{40}$ ]]; then
        printf '%s' "$identity" | tr '[:lower:]' '[:upper:]'
        return 0
    fi
    local matches count
    matches="$(identity_matches "$identity" "$keychain")"
    count="$(printf '%s' "$matches" | grep -c . || true)"
    # Ambiguous is not a match. Guessing between two certificates that both
    # contain the name could skip a re-sign the bundle needed; re-signing when it
    # was unnecessary only costs a signature.
    [ "$count" = 1 ] && printf '%s' "$matches"
    return 0
}

# The self-hosted runner's own signing identity, installed by
# scripts/setup-self-hosted-runner.sh. Overridable so a test can point at a
# fixture keychain.
DEV_KEYCHAIN="${DEV_KEYCHAIN:-$HOME/Library/Keychains/meetingtranscriber-dev.keychain-db}"
DEV_CERT_NAME="${DEV_CERT_NAME:-MeetingTranscriberDevSelfHosted}"

# dev_signing_identity → SHA-1 of that certificate, empty when it is not there.
#
# Resolved from the KEYCHAIN, which is where the setup script installs it and
# where codesign reads it from when signing. The lanes used to hash the export
# copy the setup script also leaves in /tmp/meetingtranscriber-setup — and macOS
# discards /tmp across a reboot, after which a lane aborted with "run
# scripts/setup-self-hosted-runner.sh first" although the keychain and the
# identity were both intact. Nothing depends on that copy any more; it is an
# artifact to look at.
#
# The unlock here is for the LOOKUP, not for a signature: `security
# find-identity` needs the keychain readable, and the empty password is a
# property of how the setup script creates THIS keychain. `resign_deployed_bundle`
# unlocks again for the same reason a second time, and that is not redundant:
# callers now resolve the identity before their build, so minutes of building sit
# between this unlock and the codesign that needs the private key.
# The lookup itself is identity_sha1's, so there is one definition of how a name
# becomes a hash — including its refusal to guess between two certificates whose
# names both contain the string, which here means an identity left behind under a
# renamed variant.
dev_signing_identity() {
    [ -f "$DEV_KEYCHAIN" ] || return 0
    security unlock-keychain -p "" "$DEV_KEYCHAIN" 2>/dev/null || true
    identity_sha1 "$DEV_CERT_NAME" "$DEV_KEYCHAIN"
}

# deployed_leaf_record <bundle> — where the leaf a driver signed with is
# recorded. Beside the bundle, never inside it: anything written into the
# bundle after signing invalidates the signature it is meant to describe.
# Derived from the bundle path so the two cannot drift apart.
deployed_leaf_record() {
    local bundle="${1%/}"
    printf '%s/.%s.signing-leaf' "$(dirname "$bundle")" "$(basename "$bundle")"
}

# record_deployed_signing_leaf <bundle> — remember which certificate the bundle
# at the shared deploy path was last signed with.
#
# A `--no-build` lane inherits whatever an earlier driver left there, and the
# TCC grants it depends on are keyed on that certificate. The step this lane
# runs in carries no DEVELOPER_ID, so it cannot recompute the expectation for
# itself: asking "what would this host sign with" would answer with the dev
# keychain's self-signed certificate and refuse every run. Recording it at the
# one place that knows is the only honest source.
#
# THE EMPTY LEAF IS RECORDED, NOT ERASED. A deploy that left the bundle ad-hoc
# is a fact the next lane has to refuse on. An earlier draft deleted the record
# in that case, reasoning that an empty file reads the same as no file; that is
# true and is exactly why deleting was wrong. Both forms report "nothing
# recorded", which PASSES, so the deletion turned the one state that refuses
# into the one that does not. The file's existence now says a deploy recorded
# something, and its content is the leaf.
record_deployed_signing_leaf() {
    local bundle="$1" leaf record tmp
    leaf="$(bundle_signing_cert_sha1 "$bundle")"
    record="$(deployed_leaf_record "$bundle")"
    tmp="$record.$$.tmp"
    # Written to a temp file and renamed, so a reader never sees the truncated
    # window between opening the record and filling it. A zero-byte record now
    # means "the deploy signed ad-hoc" and refuses, so a torn write would be a
    # false refusal rather than a false pass.
    #
    # `2>/dev/null` comes FIRST: redirections are applied left to right, so a
    # trailing one does not cover the failure of opening the file before it.
    # Measured: with the order reversed, an unwritable deploy path prints a raw
    # "Permission denied" into the driver's log right under the re-sign line.
    #
    # Best effort on purpose: failing the re-sign over a record would cost the
    # lane its whole run. What a failed write costs depends on what was already
    # there. With no record yet the next lane simply cannot look, and says so.
    # With an older record still in place it compares against a deploy that has
    # since been superseded, which reads as "something replaced the bundle" and
    # refuses. That is the safe direction, and it is why the write is a rename
    # rather than an in-place truncation.
    if printf '%s' "$leaf" 2>/dev/null > "$tmp"; then
        mv -f "$tmp" "$record" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
}

# deployed_leaf_verdict <actual> <recorded> <have_record> — the pure decision,
# so the lanes agree on what counts as a problem and it can be exercised
# without a bundle.
#
# `have_record` is a separate input from `recorded` on purpose, and folding the
# two together is the defect this signature exists to prevent: "no record at
# all" must not refuse, because the record appears only after the first deploy
# that follows this change, while "recorded as carrying no certificate" must.
deployed_leaf_verdict() {
    local actual="$1" recorded="$2" have_record="$3"
    if [ "$have_record" != yes ]; then printf 'unrecorded'; return 0; fi
    if [ -z "$recorded" ]; then printf 'deployed-adhoc'; return 0; fi
    if [ -z "$actual" ]; then printf 'adhoc'; return 0; fi
    if [ "$actual" = "$recorded" ]; then printf 'match'; else printf 'mismatch'; fi
}

# assert_deployed_signing_leaf <bundle> — refuse when the bundle is demonstrably
# not the one that was signed. Returns 1 only on a verdict that says so.
#
# What a passing verdict does NOT promise: it speaks about the certificate, not
# about which build carries it. A driver that deploys a differently compiled
# bundle and signs it with the same certificate reads as a match, which is
# correct for the TCC question and says nothing about the code under test.
assert_deployed_signing_leaf() {
    local bundle="$1" record actual recorded="" have=no verdict
    # No deployment at all is a different question, and the drivers already ask
    # it right after this: each checks its binaries exist and names the missing
    # one. Answering it here too would replace that clear message with a
    # confusing one about certificates.
    if [ ! -d "$bundle" ]; then
        echo "No bundle at $bundle; leaving the missing-binary check to say so." >&2
        return 0
    fi
    record="$(deployed_leaf_record "$bundle")"
    if [ -f "$record" ]; then
        have=yes
        recorded="$(cat "$record" 2>/dev/null || true)"
    fi
    actual="$(bundle_signing_cert_sha1 "$bundle")"
    verdict="$(deployed_leaf_verdict "$actual" "$recorded" "$have")"
    case "$verdict" in
        match)
            # Said out loud on purpose. A silent pass is indistinguishable in
            # the log from a check that was never reached, and a gate whose
            # success looks exactly like its absence is the failure mode this
            # whole mechanism exists to remove.
            echo "$bundle carries the certificate the last deploy recorded ($actual)." >&2
            return 0 ;;
        unrecorded)
            echo "No signing record beside $bundle; cannot tell which certificate it carries." >&2
            if [ "${GITHUB_ACTIONS:-}" = true ]; then
                # The exemption exists so a rollout is not an outage, and that
                # reason does not apply here: in CI the deploy that signs runs
                # earlier in the same job, so by the time this lane runs a
                # record exists unless the deployment came from somewhere else.
                # Left unconditional, the exemption would be a permanent silent
                # pass the first time anything deploys by another route, and
                # its own message would read like a benign rollout note.
                echo "  The deploy that signs runs earlier in this same job, so a missing" >&2
                echo "  record means this deployment did not come from it. Refusing rather" >&2
                echo "  than reporting on a bundle of unknown provenance." >&2
                return 1
            fi
            echo "  Locally this is the normal state until the next build and deploy." >&2
            return 0 ;;
        deployed-adhoc)
            echo "The last deploy signed $bundle with no certificate at all." >&2
            echo "  The TCC grants are keyed on a certificate, so capture would be denied" >&2
            echo "  and this lane would read that denial as its own result." >&2
            return 1 ;;
        adhoc)
            echo "$bundle carries no certificate (ad-hoc signed or replaced)." >&2
            echo "  The TCC grants are keyed on a certificate, so capture would be denied" >&2
            echo "  and this lane would read that denial as its own result." >&2
            return 1 ;;
        *)
            echo "$bundle is signed by $actual, but the last deploy signed it with $recorded." >&2
            echo "  Something replaced or re-signed the bundle since, or the last re-sign" >&2
            echo "  failed after codesign had already run. Either way the TCC grants do not" >&2
            echo "  follow, so capture would be denied and read as this lane's result." >&2
            return 1 ;;
    esac
}

# require_signing_identity — establish how this host will re-sign the deployed
# bundle, or refuse. Sets SIGN_IDENTITY and SIGN_KEYCHAIN for a later
# `resign_deployed_bundle`; prints the diagnosis and returns 1 when neither
# route is available.
#
# Call it BEFORE the build. The deploy that follows replaces the bundle at the
# shared path whose TCC grants are keyed on the certificate leaf, and every
# `--no-build` sibling lane reuses that same bundle. A lane that discovers it
# cannot sign only afterwards has already swapped a working, granted deployment
# for an unsigned one, which leaves the host worse off than no check at all.
#
# Both routes are resolved, not merely named. The workflow exports DEVELOPER_ID
# on every lane but imports the certificate only when the keychain secret is
# present, so a set name is no evidence that anything can sign.
# shellcheck disable=SC2034  # SIGN_IDENTITY/SIGN_KEYCHAIN are read by the e2e drivers
require_signing_identity() {
    local candidate="" keychain=""

    if [ -n "${DEVELOPER_ID:-}" ]; then
        keychain="${E2E_SIGNING_KEYCHAIN:-}"
        if [ -n "$(identity_sha1 "$DEVELOPER_ID" "$keychain")" ]; then
            SIGN_IDENTITY="$DEVELOPER_ID"
            SIGN_KEYCHAIN="$keychain"
            return 0
        fi
        # `identity_sha1` answers empty for TWO opposite situations, and they
        # must not share an outcome.
        local matched
        matched="$(printf '%s' "$(identity_matches "$DEVELOPER_ID" "$keychain")" | grep -c . || true)"

        if [ "$matched" -gt 1 ]; then
            # Several certificates carry this name, which is the normal state
            # during a renewal overlap. Falling back here would sign with the
            # dev cert on a lane whose whole point is the Developer-ID grant,
            # and it would do so on a host that HAS the certificate, which is
            # the one case where continuing is indefensible. Refuse instead.
            echo "DEVELOPER_ID names '$DEVELOPER_ID', which matches $matched certificates" >&2
            echo "  ${keychain:+in $keychain }and so cannot be resolved to one." >&2
            echo "  This is what a renewal overlap looks like. Falling back to the dev cert" >&2
            echo "  would silently drop the Developer-ID TCC grant this lane depends on, so" >&2
            echo "  the run stops here instead." >&2
            echo "  Fix: remove the superseded certificate, or point DEVELOPER_ID at the" >&2
            echo "  SHA-1 of the one you want." >&2
            return 1
        fi

        # Nothing matched: fall through rather than refuse. The name and the
        # certificate are two separate secrets. The workflow exports
        # DEVELOPER_ID on every lane and imports the certificate only when its
        # own secret is present, and it documents the self-signed cert as the
        # fallback for exactly that case. Said out loud, because a run signed by
        # the dev cert is one the manual Developer-ID grant does not cover.
        echo "DEVELOPER_ID names '$DEVELOPER_ID', which matches no identity" >&2
        echo "  ${keychain:+in $keychain}; falling back to the dev keychain." >&2
        echo "  A run signed by the dev cert is NOT covered by the Developer-ID grant." >&2
    fi

    candidate="$(dev_signing_identity)"
    if [ -n "$candidate" ]; then
        SIGN_IDENTITY="$candidate"
        SIGN_KEYCHAIN="$DEV_KEYCHAIN"
        return 0
    fi

    # Nothing is assigned on this path on purpose: a caller that forgets the
    # `|| exit 1` then trips `set -u` at the first use instead of quietly
    # signing with values this function already rejected.
    #
    # Two different failures, and only one is fixed by re-running the setup
    # script: an identity left behind under a renamed variant makes
    # `identity_sha1` refuse to guess, and creating another one does not help.
    if [ -f "$DEV_KEYCHAIN" ]; then
        echo "$DEV_KEYCHAIN holds no unambiguous '$DEV_CERT_NAME' identity." >&2
        echo "  If two certificates there carry that name, remove the stale one;" >&2
        echo "  re-running scripts/setup-self-hosted-runner.sh will not resolve it." >&2
    else
        echo "No usable Developer ID and no $DEV_KEYCHAIN." >&2
        echo "  Set DEVELOPER_ID in the environment, or run" >&2
        echo "  scripts/setup-self-hosted-runner.sh to create the dev identity." >&2
    fi
    return 1
}

# resign_deployed_bundle <app-bundle> <identity> [keychain]
#
# Re-sign a bundle that was built and deployed elsewhere, with a stable identity
# so TCC keeps its grants across rebuilds, WITHOUT discarding what the build
# signed into it (issue #609). Two measured facts make that more than a codesign
# call:
#
#   - `codesign --force --sign X "$bundle"` with no `--entitlements` writes a
#     signature carrying NO entitlements at all. That is how the e2e lanes used
#     to drop the microphone entitlement and — where a profile had authorised it
#     — the time-sensitive one, one step after the build verified it survived.
#   - The key cannot simply be re-requested here, because a profile authorises
#     specific CERTIFICATES and macOS refuses to launch a bundle whose restricted
#     entitlement no embedded profile covers (see this file's header).
#
# So a bundle whose VALID signature is already by the requested certificate is
# left alone — re-signing it could only subtract — and otherwise the bundle is
# re-signed with the base entitlements, dropping a profile the new signature
# cannot honour. That last part matters: a profile left embedded next to a missing
# key is what makes e2e-browser.sh's pairing check fail while pointing at
# prepare_signing, which did its job correctly.
#
# Validity is part of the question, not a detail. The certificate is read from
# the executable's own signature and says who signed it, not that the bundle
# still matches what was signed: anything changed under the seal afterwards, a
# resource or the plist, leaves the certificate readable and the signature
# invalid, and keeping it would launch a bundle macOS refuses to run.
# (test_rpc.sh's copy of a fresh binary into the signed bundle is NOT that
# case: the copy replaces the very executable the certificate is read from,
# so bundle_signing_cert_sha1 answers nothing and the hash comparison alone
# sends it to the re-sign. Measured: after the copy `codesign -d` reports an
# ad-hoc signature and extracts no certificate, and `--verify` fails with
# "code has no resources but signature indicates they must be present".)
#
# The keychain is a parameter rather than pass-through codesign flags, so no
# caller has to expand a possibly-empty array under `set -u`.
resign_deployed_bundle() {
    local bundle="$1" identity="$2" keychain="${3:-}"

    # The dev keychain's unlock belongs here rather than only where the identity
    # was resolved: a lane that resolves before its build (which is where the
    # decision has to be taken, so a refusal cannot strand the deployment) puts
    # minutes between the two, and this is the step that needs the private key.
    # Scoped to that one keychain because the empty password is a property of
    # how setup-self-hosted-runner.sh creates it, not of keychains in general.
    if [ -n "$keychain" ] && [ "$keychain" = "${DEV_KEYCHAIN:-}" ]; then
        security unlock-keychain -p "" "$keychain" 2>/dev/null || true
    fi

    local want have=""
    want="$(identity_sha1 "$identity" "$keychain")"
    # Only worth asking the bundle when the identity resolved: one that did not
    # can never claim a match.
    if [ -n "$want" ]; then
        have="$(bundle_signing_cert_sha1 "$bundle")"
    fi

    if [ "$want" = "$have" ] && [ -n "$have" ] && codesign --verify "$bundle" 2>/dev/null; then
        echo "  Already signed by the requested certificate — keeping that signature;"
        echo "  re-signing would only drop the entitlements it carries."
    else
        # Checked before the bundle is touched, so a bad path cannot leave a
        # half-changed bundle behind. Without it the path surfaces as codesign's
        # "cannot read entitlement data", which reads like a malformed plist.
        [ -f "$DEV_ENTITLEMENTS" ] \
            || { echo "  ERROR: entitlements not found: $DEV_ENTITLEMENTS" >&2; return 1; }

        # The profile is SET ASIDE rather than deleted, and put back if signing
        # fails. It is sealed in _CodeSignature/CodeResources, so a bundle missing
        # it fails `codesign --verify` even though nothing else changed: deleting
        # first would turn a failed re-sign — a locked keychain, an identity the
        # parallel runner's search-list churn hid — into an unlaunchable bundle at
        # the shared, TCC-granted deploy path. The bare re-sign this replaced was
        # at least all-or-nothing.
        local profile="$bundle/Contents/embedded.provisionprofile" stash=""
        if [ -f "$profile" ]; then
            stash="$(mktemp -d)/embedded.provisionprofile"
            mv "$profile" "$stash" \
                || { echo "  ERROR: could not set the embedded profile aside" >&2; return 1; }
            echo "  Setting the embedded provisioning profile aside: '$identity' is not"
            echo "  the certificate it authorises, so $TIME_SENSITIVE_KEY cannot come along."
            echo "  (Point DEVELOPER_ID at the profile's certificate to keep the built signature.)"
            echo "  WARNING: with no profile embedded, e2e-browser.sh can only SKIP its"
            echo "  check that the consent prompt breaks through Focus (issue #543)."
        fi

        local args=(--force --sign "$identity" --entitlements "$DEV_ENTITLEMENTS")
        [ -n "$keychain" ] && args+=(--keychain "$keychain")
        if ! codesign "${args[@]}" "$bundle" >/dev/null; then
            [ -n "$stash" ] && mv "$stash" "$profile"
            return 1
        fi

        # verify_signing speaks only about the profile pairing, and on this path
        # there is no profile left to pair with — so check the thing this function
        # exists for. A signature with no entitlements at all is issue #609 itself.
        codesign -d --entitlements :- "$bundle" 2>/dev/null | grep -q '<key>' \
            || { echo "  ERROR: the new signature carries no entitlements (issue #609)" >&2; return 1; }
    fi
    # Recorded here rather than in each driver: this is the only place that knows
    # the bundle at the shared deploy path is now on a known certificate, and
    # every driver that deploys comes through it, including the branch above
    # that keeps an existing signature. A `--no-build` lane inherits the bundle
    # and can then tell "the deployment I was given" from "something else has
    # been put there since".
    #
    # The status check is a contract, not a live gate: every exit in
    # verify_signing today is `return 0`, so it never actually withholds the
    # record. It is written this way so a future verify_signing that can fail
    # does not silently start recording bundles it rejected. The failures that
    # CAN happen here all return earlier, before anything is recorded.
    local status=0
    verify_signing "$bundle" || status=$?
    if [ "$status" -eq 0 ]; then
        record_deployed_signing_leaf "$bundle"
    fi
    return "$status"
}
