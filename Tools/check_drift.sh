#!/usr/bin/env bash
# Detects drift between the committed generated protocol files and the
# app-server schema of the codex binary on PATH (or $CODEX_BINARY).
# Exits non-zero when the generated files are stale; run Tools/regenerate.sh
# to refresh them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_BIN="${CODEX_BINARY:-codex}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
SCHEMA_DIR="$WORK_DIR/schema"
mkdir -p "$SCHEMA_DIR"

"$CODEX_BIN" app-server generate-json-schema --out "$SCHEMA_DIR" --experimental >/dev/null

python3 "$ROOT/Tools/generate_app_server_methods.py" \
    --schema-dir "$SCHEMA_DIR" \
    --out "$WORK_DIR/AppServerProtocolMethods.swift"

python3 "$ROOT/Tools/generate_app_server_schema_types.py" \
    --schema-dir "$SCHEMA_DIR" \
    --out "$WORK_DIR/AppServerSchemaTypes.swift"

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
