#!/bin/bash
# Builds the Swift sidecar and installs it where Tauri's externalBin expects it,
# renamed with the target-triple suffix and ad-hoc codesigned with the
# audio-input entitlement (required for the TCC prompts to attribute correctly).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}" # "debug" (default) or "release"
DEST_DIR="$ROOT/app/src-tauri/binaries"
DEST="$DEST_DIR/minutiae-engine-aarch64-apple-darwin"

swift build --package-path "$ROOT/engine" -c "$CONFIG" --arch arm64

mkdir -p "$DEST_DIR"
cp "$ROOT/engine/.build/arm64-apple-macosx/$CONFIG/minutiae-engine" "$DEST"

codesign --force --sign - --options runtime \
  --entitlements "$ROOT/engine/Resources/Entitlements.plist" \
  "$DEST"

echo "sidecar built: $DEST ($CONFIG)"
