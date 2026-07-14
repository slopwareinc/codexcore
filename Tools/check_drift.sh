#!/usr/bin/env bash
# Detects drift between the committed generated protocol files and the pinned
# app-server schema. By default the exact Tools/UPSTREAM_VERSION release is
# downloaded and cached. CODEX_BINARY or CODEX_BIN can override the binary for
# local development. Exits non-zero when generated files are stale.
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${CODEX_BINARY:-}" ] && [ -z "${CODEX_BIN:-}" ]; then
    exec "$TOOLS_DIR/check_pinned_drift.sh"
fi

source "$TOOLS_DIR/app_server_schema_common.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
SCHEMA_DIR="$WORK_DIR/schema"
mkdir -p "$SCHEMA_DIR"

generate_app_server_schema "$SCHEMA_DIR" >/dev/null
generate_app_server_swift \
    "$SCHEMA_DIR" \
    "$WORK_DIR/AppServerProtocolMethods.swift" \
    "$WORK_DIR/AppServerSchemaTypes.swift"

status=0
for file in AppServerProtocolMethods.swift AppServerSchemaTypes.swift; do
    if ! diff -u "$ROOT/Sources/CodexCore/Generated/$file" "$WORK_DIR/$file" > "$WORK_DIR/$file.diff"; then
        echo "DRIFT: Sources/CodexCore/Generated/$file is stale vs $("$CODEX_BIN" --version)."
        head -40 "$WORK_DIR/$file.diff"
        status=1
    fi
done

if ! python3 "$TOOLS_DIR/check_handwritten_protocol_compatibility.py"; then
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "Generated protocol files match $("$CODEX_BIN" --version)."
else
    echo
    echo "Run Tools/regenerate.sh to refresh the generated files."
fi
exit "$status"
