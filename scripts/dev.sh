#!/bin/bash
# Full dev loop: fresh sidecar + tauri dev.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-sidecar.sh"
cd "$ROOT/app" && pnpm tauri dev
