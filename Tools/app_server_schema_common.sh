#!/usr/bin/env bash

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
CODEX_BIN="${CODEX_BINARY:-codex}"

generate_app_server_schema() {
    local schema_dir="$1"
    "$CODEX_BIN" app-server generate-json-schema --out "$schema_dir" --experimental
}

generate_app_server_swift() {
    local schema_dir="$1"
    local methods_out="$2"
    local schema_types_out="$3"

    python3 "$ROOT/Tools/generate_app_server_methods.py" \
        --schema-dir "$schema_dir" \
        --out "$methods_out"

    python3 "$ROOT/Tools/generate_app_server_schema_types.py" \
        --schema-dir "$schema_dir" \
        --out "$schema_types_out"
}
