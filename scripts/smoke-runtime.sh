#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$("$root/Tools/install_runtime.sh")"
CODEXCORE_RUNTIME_SMOKE=1 CODEX_BINARY="$binary" \
    swift test --package-path "$root" --filter PinnedRuntimeSmokeTests
