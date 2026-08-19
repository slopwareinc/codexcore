#!/usr/bin/env bash

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
DEFAULT_CODEX_APP_BINARY="/Applications/Codex.app/Contents/Resources/codex"

if [ -n "${CODEX_BINARY:-}" ]; then
    CODEX_BIN="$CODEX_BINARY"
elif [ -n "${CODEX_BIN:-}" ]; then
    CODEX_BIN="$CODEX_BIN"
elif [ -x "$DEFAULT_CODEX_APP_BINARY" ]; then
    CODEX_BIN="$DEFAULT_CODEX_APP_BINARY"
else
    CODEX_BIN="codex"
fi

generate_app_server_schema() {
    local schema_dir="$1"
    "$CODEX_BIN" app-server generate-json-schema --out "$schema_dir" --experimental
}

generate_app_server_swift() {
    local schema_dir="$1"
    local methods_out="$2"
    local schema_types_out="$3"
    local requests_out="$4"

    python3 "$ROOT/Tools/generate_app_server_methods.py" \
        --schema-dir "$schema_dir" \
        --out "$methods_out"

    python3 "$ROOT/Tools/generate_app_server_schema_types.py" \
        --schema-dir "$schema_dir" \
        --out "$schema_types_out"

    python3 "$ROOT/Tools/generate_app_server_requests.py" \
        --schema-dir "$schema_dir" \
        --out "$requests_out"
}

generate_app_server_rust_schema() {
    local schema_dir="$1"
    local out="$2"
    install -m 0644 \
        "$schema_dir/codex_app_server_protocol.v2.schemas.json" \
        "$out"
}

generate_pinned_runtime_swift() {
    local out="$1"
    python3 "$ROOT/Tools/generate_pinned_runtime_version.py" \
        --version-file "$ROOT/Tools/UPSTREAM_VERSION" \
        --out "$out"
}
