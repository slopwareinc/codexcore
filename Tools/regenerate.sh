#!/usr/bin/env bash
# Regenerates Sources/CodexCore/Generated/* from the codex binary's own
# app-server schema dump. The dump includes experimental APIs because this SDK
# negotiates the `experimentalApi` capability at initialize time.
#
# Usage: Tools/regenerate.sh
#   CODEX_BINARY=/path/to/codex Tools/regenerate.sh   # override binary
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_BIN="${CODEX_BINARY:-codex}"

SCHEMA_DIR="$(mktemp -d)"
trap 'rm -rf "$SCHEMA_DIR"' EXIT

"$CODEX_BIN" app-server generate-json-schema --out "$SCHEMA_DIR" --experimental

python3 "$ROOT/Tools/generate_app_server_methods.py" \
    --schema-dir "$SCHEMA_DIR" \
    --out "$ROOT/Sources/CodexCore/Generated/AppServerProtocolMethods.swift"

python3 "$ROOT/Tools/generate_app_server_schema_types.py" \
    --schema-dir "$SCHEMA_DIR" \
    --out "$ROOT/Sources/CodexCore/Generated/AppServerSchemaTypes.swift"

"$CODEX_BIN" --version > "$ROOT/Tools/UPSTREAM_VERSION"

echo "Regenerated from $("$CODEX_BIN" --version)."
