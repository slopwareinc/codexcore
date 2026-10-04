#!/usr/bin/env bash
# Check generated bindings against the verified, exact pinned release.
set -euo pipefail
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="$("$TOOLS_DIR/install_runtime.sh")"
CODEX_BINARY="$binary" "$TOOLS_DIR/check_drift.sh"
