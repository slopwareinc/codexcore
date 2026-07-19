#!/usr/bin/env bash
# Downloads the exact Codex release recorded in Tools/UPSTREAM_VERSION and
# checks the committed generated protocol against that immutable binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINNED_VERSION="$(sed -E 's/^codex-cli[[:space:]]+//' "$ROOT/Tools/UPSTREAM_VERSION" | tr -d '[:space:]')"

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) target="aarch64-apple-darwin" ;;
    Darwin-x86_64) target="x86_64-apple-darwin" ;;
    *)
        echo "Unsupported host for pinned drift check: $(uname -s) $(uname -m)" >&2
        exit 2
        ;;
esac

CACHE_DIR="${CODEXCORE_TOOL_CACHE:-$ROOT/.build/codexcore-tools}"
BINARY="$CACHE_DIR/codex-$PINNED_VERSION-$target"

if [ ! -x "$BINARY" ]; then
    download_root="$ROOT/.build/protocol-generation"
    mkdir -p "$download_root"
    archive="$(mktemp "$download_root/codex-${PINNED_VERSION}.XXXXXX")"
    extract_dir="$(mktemp -d "$download_root/codex-${PINNED_VERSION}.XXXXXX")"
    trap 'rm -f "$archive"; rm -rf "$extract_dir"' EXIT
    url="https://github.com/openai/codex/releases/download/rust-v${PINNED_VERSION}/codex-${target}.tar.gz"
    echo "Downloading codex-cli $PINNED_VERSION for $target..."
    curl --fail --location --silent --show-error "$url" --output "$archive"
    tar -xzf "$archive" -C "$extract_dir"
    mkdir -p "$CACHE_DIR"
    install -m 0755 "$extract_dir/codex-$target" "$BINARY"
fi

actual_version="$($BINARY --version)"
if [ "$actual_version" != "codex-cli $PINNED_VERSION" ]; then
    echo "Pinned binary version mismatch: expected codex-cli $PINNED_VERSION, got $actual_version" >&2
    exit 1
fi

CODEX_BINARY="$BINARY" "$ROOT/Tools/check_drift.sh"
