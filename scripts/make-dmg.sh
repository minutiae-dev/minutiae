#!/bin/bash
# Build a signed + notarized + stapled .dmg installer around the already
# signed/notarized Minutiae.app (run scripts/sign-and-notarize.sh first).
#
# Tauri's own .dmg is NOT used: it's built before the LLM sidecar is injected,
# so it lacks the sidecar. This packages the real, notarized .app.
#
# Required env (same as sign-and-notarize.sh):
#   APPLE_SIGNING_IDENTITY, and notarization creds (APPLE_ID + APPLE_PASSWORD +
#   APPLE_TEAM_ID, or APPLE_API_KEY + APPLE_API_ISSUER + APPLE_API_KEY_PATH).
# Optional: SKIP_NOTARIZE=1 to sign the dmg only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app/src-tauri"
APP="${1:-$SRC/target/release/bundle/macos/Minutiae.app}"
VOL="Minutiae"
OUT="$HOME/Desktop/Minutiae.dmg"

# Same gitignored credentials file as sign-and-notarize.sh; already-exported
# vars win so CI can override.
if [ -z "${APPLE_SIGNING_IDENTITY:-}" ] && [ -f "$ROOT/.notarize.env" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/.notarize.env"
  echo "loaded credentials from .notarize.env"
fi

: "${APPLE_SIGNING_IDENTITY:?set APPLE_SIGNING_IDENTITY, or put it in .notarize.env at the repo root}"
[ -d "$APP" ] || { echo "error: app not found: $APP (sign it first)" >&2; exit 1; }

# Warn if the .app isn't notarized/stapled yet — the dmg should wrap a good app.
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "warning: $APP has no stapled notarization ticket — run scripts/sign-and-notarize.sh first." >&2
fi

# Stage: the .app plus a drag-to-Applications shortcut.
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

echo "building dmg…"
rm -f "$OUT"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null

# Sign the dmg itself (hardened runtime flags don't apply to a dmg).
codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$OUT"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "dmg signed (notarization skipped): $OUT"
  exit 0
fi

echo "notarizing dmg (a few minutes)…"
if [ -n "${APPLE_API_KEY:-}" ]; then
  xcrun notarytool submit "$OUT" \
    --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER" --wait
else
  : "${APPLE_ID:?set APPLE_ID}"
  : "${APPLE_PASSWORD:?set APPLE_PASSWORD}"
  : "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
  xcrun notarytool submit "$OUT" \
    --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
fi

xcrun stapler staple "$OUT"
xcrun stapler validate "$OUT"
spctl -a -t open --context context:primary-signature -vv "$OUT" || true
echo "done: notarized dmg → $OUT"
