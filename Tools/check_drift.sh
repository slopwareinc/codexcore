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

WORK_ROOT="$ROOT/.build/protocol-generation"
mkdir -p "$WORK_ROOT"
WORK_DIR="$(mktemp -d "$WORK_ROOT/drift.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
SCHEMA_DIR="$WORK_DIR/schema"
mkdir -p "$SCHEMA_DIR"

generate_app_server_schema "$SCHEMA_DIR" >/dev/null
generate_app_server_swift \
    "$SCHEMA_DIR" \
    "$WORK_DIR/AppServerProtocolMethods.swift" \
    "$WORK_DIR/AppServerSchemaTypes.swift" \
    "$WORK_DIR/CodexSessionCommands.swift"
generate_app_server_rust_schema \
    "$SCHEMA_DIR" \
    "$WORK_DIR/codex_app_server_protocol.v2.schemas.json"
generate_app_server_rust_server_request_schemas \
    "$SCHEMA_DIR" \
    "$WORK_DIR/server_requests"
generate_pinned_runtime_swift "$WORK_DIR/PinnedRuntimeVersion.swift"

status=0
for file in AppServerProtocolMethods.swift AppServerSchemaTypes.swift PinnedRuntimeVersion.swift; do
    if ! diff -u "$ROOT/Sources/CodexCore/Generated/$file" "$WORK_DIR/$file" > "$WORK_DIR/$file.diff"; then
        echo "DRIFT: Sources/CodexCore/Generated/$file is stale vs $("$CODEX_BIN" --version)."
        head -40 "$WORK_DIR/$file.diff"
        status=1
    fi
done

if ! diff -u \
    "$ROOT/rust/protocol/schema/codex_app_server_protocol.v2.schemas.json" \
    "$WORK_DIR/codex_app_server_protocol.v2.schemas.json" \
    > "$WORK_DIR/codex_app_server_protocol.v2.schemas.json.diff"
then
    echo "DRIFT: Rust v2 App Server schema is stale vs $($CODEX_BIN --version)."
    head -40 "$WORK_DIR/codex_app_server_protocol.v2.schemas.json.diff"
    status=1
fi

if ! diff -ru \
    "$ROOT/rust/protocol/schema/server_requests" \
    "$WORK_DIR/server_requests" \
    > "$WORK_DIR/server_requests.diff"
then
    echo "DRIFT: Rust server-request schemas are stale vs $($CODEX_BIN --version)."
    head -40 "$WORK_DIR/server_requests.diff"
    status=1
fi

if ! diff -u \
    "$ROOT/Sources/CodexCore/Client/CodexSessionCommands.swift" \
    "$WORK_DIR/CodexSessionCommands.swift" \
    > "$WORK_DIR/CodexSessionCommands.swift.diff"
then
    echo "DRIFT: Sources/CodexCore/Client/CodexSessionCommands.swift is stale vs $($CODEX_BIN --version)."
    head -40 "$WORK_DIR/CodexSessionCommands.swift.diff"
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "Generated protocol files match $("$CODEX_BIN" --version)."
else
    echo
    echo "Run Tools/regenerate.sh to refresh the generated files."
fi
exit "$status"
