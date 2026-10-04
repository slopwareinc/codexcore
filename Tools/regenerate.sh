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
    "$SCHEMA_DIR/AppServerProtocolMethods.swift" \
    "$SCHEMA_DIR/AppServerSchemaTypes.swift" \
    "$SCHEMA_DIR/CodexSessionCommands.swift"

# Stage every output before touching committed files. A newly added method
# that the generator cannot map must leave the previous bindings and pin intact.
"$CODEX_BIN" --version > "$SCHEMA_DIR/UPSTREAM_VERSION"
python3 "$ROOT/Tools/generate_pinned_runtime_version.py" \
    --version-file "$SCHEMA_DIR/UPSTREAM_VERSION" \
    --out "$SCHEMA_DIR/PinnedRuntimeVersion.swift"
for file in AppServerProtocolMethods.swift AppServerSchemaTypes.swift PinnedRuntimeVersion.swift; do
    cp "$SCHEMA_DIR/$file" "$ROOT/Sources/CodexCore/Generated/$file"
done
cp "$SCHEMA_DIR/CodexSessionCommands.swift" "$ROOT/Sources/CodexCore/Client/CodexSessionCommands.swift"
cp "$SCHEMA_DIR/UPSTREAM_VERSION" "$ROOT/Tools/UPSTREAM_VERSION"

echo "Regenerated from $("$CODEX_BIN" --version)."
