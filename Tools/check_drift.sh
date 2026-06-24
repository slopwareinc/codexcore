#!/usr/bin/env bash
# Detects drift between the committed generated protocol files and the
# app-server schema of the selected codex binary. Selection order is
# $CODEX_BINARY, $CODEX_BIN, embedded /Applications/Codex.app, then PATH codex.
# Exits non-zero when the generated files are stale; run Tools/regenerate.sh to
# refresh them.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app_server_schema_common.sh"

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

if [ "$status" -eq 0 ]; then
    echo "Generated protocol files match $("$CODEX_BIN" --version)."
else
    echo
    echo "Run Tools/regenerate.sh to refresh the generated files."
fi
exit "$status"
