#!/usr/bin/env bash
# One-shot SaaS release: build the MLX LLM sidecar, build the .app with the
# `saas` feature, then inject the sidecar + Developer-ID sign + notarize +
# staple, and finally build the notarized DMG. Output lands on your Desktop.
#
# Chain (each step reuses the existing scripts):
#   1. build-llm-sidecar.sh release   -> binaries/minutiae-llm (+ metallib)
#   2. pnpm build:saas                -> Minutiae.app (VITE_SAAS=1, --features saas)
#   3. sign-and-notarize.sh           -> injects sidecar, signs, notarizes, staples
#   4. make-dmg.sh                    -> ~/Desktop/Minutiae.dmg
#
# Apple credentials are sourced from .notarize.env if present. Required:
#   APPLE_SIGNING_IDENTITY + notarization creds (APPLE_ID/APPLE_PASSWORD/
#   APPLE_TEAM_ID, or APPLE_API_KEY/APPLE_API_ISSUER/APPLE_API_KEY_PATH).
# Env:
#   SKIP_NOTARIZE=1   sign only — faster, NOT distributable (passed through)
#   REBUILD_LLM=1     force-rebuild the slow MLX sidecar even if already present
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# cargo isn't always on a non-interactive PATH (known gotcha).
export PATH="$HOME/.cargo/bin:$PATH"

# Apple signing/notarization credentials.
if [ -f "$ROOT/.notarize.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT/.notarize.env"
fi
# Fail fast before the slow build if signing isn't configured.
: "${APPLE_SIGNING_IDENTITY:?set APPLE_SIGNING_IDENTITY (e.g. in .notarize.env) before releasing}"

LLM_BIN="$ROOT/app/src-tauri/binaries/minutiae-llm"

echo "==> [1/4] MLX LLM sidecar"
if [ "${REBUILD_LLM:-0}" = "1" ] || [ ! -x "$LLM_BIN" ]; then
  scripts/build-llm-sidecar.sh release
else
  echo "    already present — skipping (REBUILD_LLM=1 to force a rebuild)"
fi

echo "==> [2/4] build Minutiae.app (saas feature + VITE_SAAS)"
pnpm build:saas

echo "==> [3/4] inject sidecar, Developer-ID sign, notarize, staple"
scripts/sign-and-notarize.sh

echo "==> [4/4] build notarized DMG"
scripts/make-dmg.sh

echo "✅ SaaS release complete → ~/Desktop/Minutiae.dmg"
