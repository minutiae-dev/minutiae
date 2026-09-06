#!/bin/bash
# Installs the MLX LLM sidecar (minutiae-llm) + its Metal shader bundles into a
# built Minutiae.app so the "Enhance notes" feature works in the packaged app.
#
# WHY THIS EXISTS (and isn't just externalBin):
#   The binary goes in Contents/MacOS (Tauri externalBin can't carry the
#   `.bundle` dirs anyway). The SwiftPM resource bundles (mlx-swift_Cmlx etc.,
#   which carry `default.metallib`) go in Contents/RESOURCES: once the executable
#   lives inside an .app, its `Bundle.main` is the .app, so SwiftPM's
#   `Bundle.module` lookup searches `Bundle.main.resourceURL`
#   (= Contents/Resources). Put them in Contents/MacOS instead and MLX can't find
#   the metallib — Metal init fails and the sidecar dies the moment enhancement
#   touches the GPU ("the language model stopped unexpectedly"). So: binary →
#   MacOS, bundles → Resources, after `tauri build`.
#
# Run this AFTER `tauri build` (and after build-llm-sidecar.sh has produced the
# sidecar in binaries/). Full release flow:
#   scripts/build-llm-sidecar.sh release   # build sidecar -> binaries/
#   pnpm tauri build                       # build the .app
#   scripts/install-llm-into-app.sh        # drop the sidecar into the .app
#
# Proper in-bundle packaging + Developer ID signing is the M5 milestone; this is
# the bridge until then.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STASH="$ROOT/app/src-tauri/binaries"
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

if [ ! -d "$APP" ]; then
  echo "error: app bundle not found: $APP" >&2
  echo "       build it first (pnpm tauri build), or pass the .app path as \$1." >&2
  exit 1
fi
BIN="$STASH/minutiae-llm"
if [ ! -x "$BIN" ]; then
  echo "error: $BIN missing — run scripts/build-llm-sidecar.sh [release] first." >&2
  exit 1
fi

MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
mkdir -p "$RES_DIR"
echo "installing minutiae-llm into $MACOS_DIR (bundles → Resources)"
cp -f "$BIN" "$MACOS_DIR/minutiae-llm"

# Clean up any bundles a previous (buggy) version dropped next to the binary.
for b in "$STASH"/*.bundle; do
  [ -e "$b" ] || continue
  rm -rf "$MACOS_DIR/$(basename "$b")"
done

found_bundle=0
for b in "$STASH"/*.bundle; do
  [ -e "$b" ] || continue
  rm -rf "$RES_DIR/$(basename "$b")"
  cp -R "$b" "$RES_DIR/"
  found_bundle=1
done
if [ "$found_bundle" -eq 0 ]; then
  echo "error: no *.bundle (metallib) found in $STASH" >&2
  exit 1
fi

# Re-seal the WHOLE bundle. Adding files after Tauri signed the .app invalidates
# its signature ("code has no resources…" / "damaged" when opened on another
# Mac). Sign the injected sidecar first, then deep-sign the app so the seal is
# internally consistent. NOTE: this is still ad-hoc (no Developer ID), so a Mac
# that didn't build it will quarantine + Gatekeeper-block the app. For sharing,
# the recipient must clear quarantine (`xattr -dr com.apple.quarantine <App>`);
# real distribution needs Developer ID signing + notarization (M5).
codesign --force --sign - "$MACOS_DIR/minutiae-llm" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Sanity: the metallib must be present in Resources (where Bundle.main finds it).
if ! ls "$RES_DIR"/*.bundle/Contents/Resources/default.metallib >/dev/null 2>&1; then
  echo "error: default.metallib missing under $RES_DIR" >&2
  exit 1
fi

if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo "signature seal: OK (ad-hoc)"
else
  echo "warning: signature seal still invalid" >&2
fi

echo "done: enhance should now work in $APP"
