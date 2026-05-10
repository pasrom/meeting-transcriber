#!/usr/bin/env bash
# One-time setup for a self-hosted runner host that will run the
# live-recording E2E driver (scripts/e2e-app.sh).
#
# What this does:
#   1. Creates a self-signed code-signing cert in a dedicated dev keychain.
#      That keychain has an empty password and lives in the runner user's
#      Library — no sudo, no TouchID, no GUI prompts.
#   2. Builds the dev .app via run_app.sh --build-only.
#   3. Signs the .app with the new cert. The cert is NOT in the system
#      trust store (would need sudo + GUI auth, or an MDM-installed PPPC
#      profile — both blocked on macOS 26 without an actual MDM server).
#      That's fine for our purpose: TCC matches future builds via the
#      cert's leaf SHA-1, which stays constant across rebuilds even if
#      the chain is untrusted.
#   4. Deploys to ~/Applications/MeetingTranscriber-Dev.app (stable path).
#
# What you do once after this script:
#   - Launch the deployed .app (e.g. `open ~/Applications/MeetingTranscriber-Dev.app`).
#   - When macOS prompts for Microphone, click Allow.
#   - When the app first tries to detect a meeting via Screen Recording,
#     System Settings → Privacy & Security → Screen & System Audio
#     Recording → toggle on for MeetingTranscriber-Dev.app.
#   - From that point on, every rebuild keeps the same cert leaf SHA-1, so
#     TCC keeps the grants — scripts/e2e-app.sh runs end-to-end.
#
# Re-running is safe: the cert + dev keychain are recreated only if missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CERT_NAME="MeetingTranscriberDevSelfHosted"
CERT_ORG="meetingtranscriber-self-hosted"
# Dedicated keychain with empty password keeps everything non-interactive:
# - `-A` ACL imports don't need TouchID
# - `set-key-partition-list -k ""` succeeds without prompts
# Login keychain has neither property over SSH, hence the separation.
DEV_KEYCHAIN="$HOME/Library/Keychains/meetingtranscriber-dev.keychain-db"
DEV_KEYCHAIN_PASS=""
APP_BUNDLE_PATH="$HOME/Applications/MeetingTranscriber-Dev.app"
# /tmp because world-readable; the cert file may also be useful for a
# Keychain Access drag-import if the operator wants to manually mark the
# cert trusted (not required for signing, just nice-to-have).
ARTIFACTS_DIR="/tmp/meetingtranscriber-setup"
CERT_PATH="$ARTIFACTS_DIR/dev-cert.crt"

log()  { printf '[setup] %s\n' "$*"; }
fail() { printf '[setup] FAIL: %s\n' "$*" >&2; exit 1; }

# --- 1. cert ----------------------------------------------------------

# Three states: keychain+cert exist (skip), only keychain exists (re-export
# cert from it without nuking other identities the operator may have added),
# neither (full create). /tmp is volatile so the cert-only-missing case
# is common after a reboot.
if [ -f "$DEV_KEYCHAIN" ] \
    && security find-identity -p codesigning "$DEV_KEYCHAIN" 2>/dev/null \
        | grep -q "$CERT_NAME"; then
    if [ ! -f "$CERT_PATH" ]; then
        log "Re-exporting cert from dev keychain → $CERT_PATH"
        mkdir -p "$ARTIFACTS_DIR"
        chmod 0755 "$ARTIFACTS_DIR"
        security find-certificate -c "$CERT_NAME" -p "$DEV_KEYCHAIN" > "$CERT_PATH" \
            || fail "could not export cert from $DEV_KEYCHAIN"
        chmod 0644 "$CERT_PATH"
    else
        log "Code-signing cert '$CERT_NAME' already in dev keychain + $CERT_PATH present — skipping creation"
    fi
else
    log "Creating self-signed code-signing cert '$CERT_NAME'"
    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' EXIT

    # `keyUsage = digitalSignature` is required by Apple's code signing
    # policy (CSSMERR_TP_INVALID_CERTIFICATE without it). EKU `codeSigning`
    # alone is not sufficient on macOS 26 — find-identity reports "Invalid
    # Key Usage for policy" and codesign refuses with "no identity found".
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/CN=$CERT_NAME/O=$CERT_ORG" \
        -keyout "$TMPD/cert.key" -out "$TMPD/cert.crt" \
        -addext "keyUsage = critical, digitalSignature" \
        -addext "extendedKeyUsage = critical, codeSigning" \
        -addext "basicConstraints = critical, CA:false" >/dev/null 2>&1 \
        || fail "openssl req failed"

    # `-legacy` keeps PKCS#12 in the older format the macOS keychain
    # accepts; without it, import fails with `MAC verification failed`.
    openssl pkcs12 -export -legacy \
        -inkey "$TMPD/cert.key" -in "$TMPD/cert.crt" \
        -name "$CERT_NAME" -passout pass:dev -out "$TMPD/cert.p12" \
        || fail "openssl pkcs12 failed"

    if [ -f "$DEV_KEYCHAIN" ]; then
        log "Removing stale dev keychain"
        security delete-keychain "$DEV_KEYCHAIN" 2>/dev/null || true
    fi
    log "Creating dedicated keychain at $DEV_KEYCHAIN"
    security create-keychain -p "$DEV_KEYCHAIN_PASS" "$DEV_KEYCHAIN"
    # Disable auto-relock so codesign in long-running CI sessions never
    # hits a locked keychain.
    security set-keychain-settings "$DEV_KEYCHAIN"
    security unlock-keychain -p "$DEV_KEYCHAIN_PASS" "$DEV_KEYCHAIN"

    # Add to the user keychain search list so codesign and find-identity
    # actually look there. Preserves the existing list.
    EXISTING_LIST="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$DEV_KEYCHAIN" $EXISTING_LIST

    log "Importing cert into dev keychain"
    security import "$TMPD/cert.p12" \
        -k "$DEV_KEYCHAIN" -P dev -A -t agg \
        || fail "security import failed"

    log "Setting partition list (codesign + apple tools)"
    security set-key-partition-list \
        -S "apple-tool:,apple:,codesign:" \
        -s -k "$DEV_KEYCHAIN_PASS" "$DEV_KEYCHAIN" >/dev/null \
        || fail "set-key-partition-list failed"

    mkdir -p "$ARTIFACTS_DIR"
    chmod 0755 "$ARTIFACTS_DIR"
    cp "$TMPD/cert.crt" "$CERT_PATH"
    chmod 0644 "$CERT_PATH"
    log "Cert .crt persisted at $CERT_PATH"

    rm -rf "$TMPD"
    trap - EXIT
fi

# Read the SHA-1 fingerprint straight from the .crt — works whether or
# not the cert is trusted. (`find-identity -v` would only see trusted
# identities; we don't trust this cert, so `-v` would always be empty.)
CERT_HASH="$(openssl x509 -in "$CERT_PATH" -noout -fingerprint -sha1 \
    | sed 's/^.*=//' | tr -d ':')"
[ -n "$CERT_HASH" ] || fail "could not extract cert SHA-1 from $CERT_PATH"
log "Cert SHA-1: $CERT_HASH"

# --- 2. detect trust state -----------------------------------------------

# `find-identity -v` only lists identities that codesign can actually use
# (= cert chain validates). For a self-signed cert, that means the user
# trusted it. macOS 26 forbids `add-trusted-cert -d` without an MDM
# server, but the per-user variant works — it just needs an interactive
# auth dialog the operator runs once from a GUI Terminal.
CERT_TRUSTED=false
if security find-identity -v -p codesigning "$DEV_KEYCHAIN" 2>/dev/null \
        | grep -q "$CERT_NAME"; then
    CERT_TRUSTED=true
fi

if [ "$CERT_TRUSTED" = false ]; then
    cat <<MSG

[setup] Phase 1 complete. ⏸  Cert generated but not yet trusted.

Run this one command in a GUI Terminal as user '$USER' (it pops a
TouchID / password prompt, can't be answered over SSH):

  security add-trusted-cert \\
      -r trustRoot -p codeSign \\
      -k "\$HOME/Library/Keychains/login.keychain-db" \\
      "$CERT_PATH"

Then re-run this script:

  bash $0

It will detect the trust and proceed with build + sign + deploy.

MSG
    exit 0
fi

# --- 3. build + sign + deploy --------------------------------------------

log "Building dev .app"
"$SCRIPT_DIR/run_app.sh" --build-only

mkdir -p "$(dirname "$APP_BUNDLE_PATH")"
SRC="$ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app"
log "Deploying to $APP_BUNDLE_PATH"
if [ -d "$APP_BUNDLE_PATH" ]; then
    rsync -a --delete "$SRC/" "$APP_BUNDLE_PATH/"
else
    cp -R "$SRC" "$APP_BUNDLE_PATH"
fi

# Unlock the dev keychain — codesign needs access to the private key,
# and `errSecInternalComponent` is what you get when the keychain is
# locked. Empty password (set in phase 1) makes this safe to call on
# every run.
security unlock-keychain -p "$DEV_KEYCHAIN_PASS" "$DEV_KEYCHAIN" \
    || fail "could not unlock dev keychain"

# Sign explicitly with our cert — run_app.sh's signing step uses
# `find-identity -v` and so won't pick up our untrusted cert. Doing it
# here keeps run_app.sh untouched for other callers.
log "Signing with $CERT_NAME"
codesign --force --sign "$CERT_HASH" \
    --keychain "$DEV_KEYCHAIN" \
    "$APP_BUNDLE_PATH" >/dev/null \
    || fail "codesign failed"

log "Signed: $(codesign -dv "$APP_BUNDLE_PATH" 2>&1 | grep -E 'Identifier|Authority' | head -2 | tr '\n' ' ')"

cat <<MSG

[setup] DONE. ✓
        Cert SHA-1: $CERT_HASH
        Dev bundle: $APP_BUNDLE_PATH

Next (one-time, in the GUI session as user '$USER'):
  1. Launch the dev app:

       open $APP_BUNDLE_PATH

  2. macOS will prompt for Microphone the first time the app tries to
     record. Click Allow.

  3. macOS may also prompt for Screen Recording (used for meeting
     detection via window titles). Allow it. Or pre-grant via System
     Settings → Privacy & Security → Screen & System Audio Recording →
     "+" → $APP_BUNDLE_PATH.

  4. Verify in System Settings → Privacy & Security:
       - Microphone               → MeetingTranscriber-Dev.app on
       - Screen & System Audio Recording → MeetingTranscriber-Dev.app on

After that, scripts/e2e-app.sh rebuilds + redeploys, the cert leaf SHA-1
stays $CERT_HASH across rebuilds, and TCC keeps the grants automatically.
MSG
