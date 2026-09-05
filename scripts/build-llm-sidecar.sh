#!/bin/bash
# Builds the MLX LLM sidecar (minutiae-llm) and installs it where the Tauri dev
# build can spawn it.
#
# Unlike the audio engine (pure SwiftPM via build-sidecar.sh), the LLM sidecar
# MUST be built with xcodebuild: SwiftPM alone cannot compile MLX's Metal
# shaders into `default.metallib` (see llm-engine/README.md). Requires
# Xcode 16.4+ (Swift 6.1.2) for the qwen3_5 architecture.
#
# MLX locates `default.metallib` inside `mlx-swift_Cmlx.bundle` *relative to the
# binary*, so the bundle must be colocated with the sidecar wherever it runs.
# The Rust `shell().sidecar("minutiae-llm")` call resolves the binary next to
# the app executable (target/<profile>/), so we drop the binary + bundles there.
#
# NOTE: this is intentionally NOT part of `pnpm dev`'s beforeDevCommand — the
# MLX build is slow (minutes) and heavy (GBs). Run it once (and after pulling
# llm-engine changes). Release bundling into the .app (+ signing, tauri#11992)
# is deferred to the packaging milestone (M5).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-debug}"          # "debug" (default) or "release"
PACKAGE="$ROOT/llm-engine"
DD="$PACKAGE/.xcode-dd"

# Map our profile to an Xcode configuration. Release is recommended (much faster
# inference); debug exists for parity with the engine's dev loop.
if [ "$PROFILE" = "release" ]; then
  XCCONFIG="Release"
else
  XCCONFIG="Debug"
fi

echo "building minutiae-llm ($XCCONFIG) — this is slow on a clean build…"
# xcodebuild discovers the SwiftPM package from the working directory.
( cd "$PACKAGE" && xcodebuild build \
    -scheme minutiae-llm \
    -destination 'platform=macOS' \
    -derivedDataPath "$DD" \
    -configuration "$XCCONFIG" \
    -skipMacroValidation )

PRODUCTS="$DD/Build/Products/$XCCONFIG"
BIN="$PRODUCTS/minutiae-llm"
if [ ! -x "$BIN" ]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

# Destinations:
#   1. the Tauri target dir, so `pnpm dev` can spawn it (binary + metallib bundle)
#   2. binaries/ as a stash for the M5 externalBin packaging path
TARGET_DIR="$ROOT/app/src-tauri/target/$PROFILE"
STASH_DIR="$ROOT/app/src-tauri/binaries"

install_into() {
  local dest="$1"
  mkdir -p "$dest"
  cp -f "$BIN" "$dest/minutiae-llm"
  # Colocate every resource bundle (carries default.metallib) next to it.
  local found_bundle=0
  for b in "$PRODUCTS"/*.bundle; do
    [ -e "$b" ] || continue
    rm -rf "$dest/$(basename "$b")"
    cp -R "$b" "$dest/"
    found_bundle=1
  done
  if [ "$found_bundle" -eq 0 ]; then
    echo "error: no *.bundle (metallib) found in $PRODUCTS" >&2
    exit 1
  fi
}

install_into "$TARGET_DIR"
install_into "$STASH_DIR"

# Sanity: the metallib must be present beside the installed binary.
if ! ls "$TARGET_DIR"/*.bundle/Contents/Resources/default.metallib >/dev/null 2>&1; then
  echo "error: default.metallib missing beside $TARGET_DIR/minutiae-llm" >&2
  exit 1
fi

echo "llm sidecar installed:"
echo "  $TARGET_DIR/minutiae-llm  (+ metallib bundle, used by pnpm dev)"
echo "  $STASH_DIR/minutiae-llm   (stash for M5 packaging)"
