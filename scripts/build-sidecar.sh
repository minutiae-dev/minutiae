#!/bin/bash
# Builds the Swift sidecar and installs it where Tauri's externalBin expects it,
# renamed with the target-triple suffix and ad-hoc codesigned with the
# audio-input entitlement (required for the TCC prompts to attribute correctly).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}" # "debug" (default) or "release"
DEST_DIR="$ROOT/app/src-tauri/binaries"
DEST="$DEST_DIR/minutiae-engine-aarch64-apple-darwin"

# Embed Info.plist (TCC usage strings) into the bare binary's __TEXT,__info_plist
# section — required for the mic/system-audio permission prompts to attribute.
INFO_PLIST="$ROOT/engine/Resources/Info.plist"

swift build --package-path "$ROOT/engine" -c "$CONFIG" --arch arm64 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO_PLIST"

mkdir -p "$DEST_DIR"
cp "$ROOT/engine/.build/arm64-apple-macosx/$CONFIG/minutiae-engine" "$DEST"

codesign --force --sign - --options runtime \
  --entitlements "$ROOT/engine/Resources/Entitlements.plist" \
  "$DEST"

# Sanity: the embedded Info.plist section must exist.
if ! otool -s __TEXT __info_plist "$DEST" | grep -q __info_plist; then
  echo "error: __TEXT,__info_plist section missing from $DEST" >&2
  exit 1
fi

echo "sidecar built: $DEST ($CONFIG)"
