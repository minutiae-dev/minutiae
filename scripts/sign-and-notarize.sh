#!/bin/bash
# Developer-ID sign + notarize + staple a built Minutiae.app so it opens on any
# Mac with no Gatekeeper warnings.
#
# WHY this is separate from `tauri build`: the LLM sidecar is injected into the
# .app AFTER Tauri builds/signs it, which invalidates Tauri's signature. So we
# inject first, then sign the whole bundle here, then notarize. (Tauri's built-in
# signing/notarization can't see the injected sidecar.)
#
# Run order for a release:
#   scripts/build-llm-sidecar.sh release     # once (and after llm-engine changes)
#   pnpm tauri build                         # builds engine sidecar + app (ad-hoc)
#   scripts/sign-and-notarize.sh             # inject sidecar, sign, notarize, staple
#
# Required env:
#   APPLE_SIGNING_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#                            (see: security find-identity -v -p codesigning)
# Notarization credentials — choose ONE method:
#   A) Apple ID:   APPLE_ID, APPLE_PASSWORD (app-specific password), APPLE_TEAM_ID
#   B) API key:    APPLE_API_KEY (Key ID), APPLE_API_ISSUER, APPLE_API_KEY_PATH (.p8)
# Optional:
#   SKIP_NOTARIZE=1          sign only (e.g. to iterate on signing/entitlements)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app/src-tauri"

# Cargo's target directory is not always app/src-tauri/target: a global
# `target-dir` in ~/.cargo/config.toml (or CARGO_TARGET_DIR) redirects it, and
# the bundle lands there instead. Ask cargo rather than assuming, or the release
# scripts silently operate on a stale bundle -- or none at all.
cargo_target_dir() {
  local md
  if md=$(cargo metadata --no-deps --format-version 1 \
            --manifest-path "$SRC/Cargo.toml" 2>/dev/null); then
    printf '%s' "$md" | /usr/bin/python3 -c \
      'import sys,json; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null && return
  fi
  printf '%s' "$SRC/target"
}

APP="${1:-$(cargo_target_dir)/release/bundle/macos/Minutiae.app}"
ENT_APP="$SRC/Entitlements.plist"
ENT_LLM="$SRC/Entitlements.llm.plist"

# Credentials live in a gitignored .notarize.env at the repo root. Source it so
# the documented one-liner works; already-exported vars win, so CI can override.
if [ -z "${APPLE_SIGNING_IDENTITY:-}" ] && [ -f "$ROOT/.notarize.env" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/.notarize.env"
  echo "loaded credentials from .notarize.env"
fi

: "${APPLE_SIGNING_IDENTITY:?set APPLE_SIGNING_IDENTITY, or put it in .notarize.env at the repo root (e.g. \"Developer ID Application: Your Name (TEAMID)\")}"
[ -d "$APP" ] || { echo "error: app not found: $APP (run pnpm tauri build first)" >&2; exit 1; }

# 1) Put the LLM sidecar + metallib in place (this also ad-hoc signs; we override
#    that below with the Developer ID identity).
"$ROOT/scripts/install-llm-into-app.sh" "$APP"

# 2) Sign nested binaries FIRST, each with its own entitlements + hardened runtime,
#    then the app bundle LAST (signs the main binary and seals Resources).
sign() { codesign --force --timestamp --options runtime --sign "$APPLE_SIGNING_IDENTITY" "$@"; }
echo "signing with: $APPLE_SIGNING_IDENTITY"
sign --entitlements "$ENT_LLM" "$APP/Contents/MacOS/minutiae-llm"
sign --entitlements "$ENT_APP" "$APP/Contents/MacOS/minutiae-engine"
sign --entitlements "$ENT_APP" "$APP"

# 3) Verify the signature seal + each binary's hardened runtime.
codesign --verify --deep --strict --verbose=2 "$APP"
echo "authority: $(codesign -dvv "$APP" 2>&1 | grep -m1 'Authority')"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "signed (notarization skipped). spctl:"; spctl -a -vv "$APP" || true
  exit 0
fi

# 4) Notarize: zip the bundle, submit, wait for Apple's verdict.
WORK="$(mktemp -d)"; ZIP="$WORK/Minutiae.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "submitting to Apple notary service (this can take a few minutes)…"
if [ -n "${APPLE_API_KEY:-}" ]; then
  xcrun notarytool submit "$ZIP" \
    --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER" --wait
else
  : "${APPLE_ID:?set APPLE_ID}"
  : "${APPLE_PASSWORD:?set APPLE_PASSWORD (an app-specific password from appleid.apple.com)}"
  : "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
  xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
fi

# 5) Staple the ticket into the .app so it validates offline, then verify.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"

# 6) Produce the distributable (the stapled ticket travels inside the .app).
OUT="$HOME/Desktop/Minutiae-signed.zip"
rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"
echo "done: notarized + stapled. Share: $OUT"
