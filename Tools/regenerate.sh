#!/usr/bin/env bash
# Regenerates Sources/CodexCore/Generated/* from the codex binary's own
# app-server schema dump. The dump includes experimental APIs because this SDK
# negotiates the `experimentalApi` capability at initialize time.
#
# Usage: Tools/regenerate.sh
#   CODEX_BINARY=/path/to/codex Tools/regenerate.sh   # override binary
#   CODEX_BIN=/path/to/codex Tools/regenerate.sh      # alternate override
# Without an override, prefers the embedded Codex.app binary when installed,
# then falls back to codex on PATH.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app_server_schema_common.sh"

WORK_ROOT="$ROOT/.build/protocol-generation"
mkdir -p "$WORK_ROOT"
SCHEMA_DIR="$(mktemp -d "$WORK_ROOT/schema.XXXXXX")"
trap 'rm -rf "$SCHEMA_DIR"' EXIT

generate_app_server_schema "$SCHEMA_DIR"
generate_app_server_swift \
    "$SCHEMA_DIR" \
    "$ROOT/Sources/CodexCore/Generated/AppServerProtocolMethods.swift" \
    "$ROOT/Sources/CodexCore/Generated/AppServerSchemaTypes.swift" \
    "$ROOT/Sources/CodexCore/Client/CodexSessionCommands.swift"

"$CODEX_BIN" --version > "$ROOT/Tools/UPSTREAM_VERSION"
generate_pinned_runtime_swift \
    "$ROOT/Sources/CodexCore/Generated/PinnedRuntimeVersion.swift"

echo "Regenerated from $("$CODEX_BIN" --version)."
