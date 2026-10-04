#!/usr/bin/env bash
# Install the exact pinned runtime into the workspace, without replacing PATH
# binaries or sharing authentication. stdout contains only the resolved path.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(sed -E 's/^codex-cli[[:space:]]+//' "$ROOT/Tools/UPSTREAM_VERSION" | tr -d '[:space:]')"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "Invalid pinned runtime version: $version" >&2
    exit 2
fi
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) target="aarch64-apple-darwin" ;;
    Darwin-x86_64) target="x86_64-apple-darwin" ;;
    *) echo "Unsupported runtime host: $(uname -s) $(uname -m)" >&2; exit 2 ;;
esac
cache="${CODEXCORE_TOOL_CACHE:-$ROOT/.build/codexcore-tools}"
mkdir -p "$cache"
cache="$(cd "$cache" && pwd)"
binary="$cache/codex-$version-$target"
if [ ! -x "$binary" ]; then
    work="$(mktemp -d "$cache/install.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    asset="codex-$target.tar.gz"
    echo "Downloading codex-cli $version for $target..." >&2
    curl --fail --location --silent --show-error --retry 3 \
        "https://api.github.com/repos/openai/codex/releases/tags/rust-v$version" \
        --output "$work/release.json"
    digest="$(python3 - "$work/release.json" "$asset" <<'PY'
import json, re, sys
assets = json.load(open(sys.argv[1]))['assets']
asset = next(a for a in assets if a['name'] == sys.argv[2])
digest = asset.get('digest', '')
if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
    raise SystemExit('Release asset has no SHA-256 digest; refusing unverified installation')
print(digest.removeprefix('sha256:'))
PY
    )"
    curl --fail --location --silent --show-error --retry 3 \
        "https://github.com/openai/codex/releases/download/rust-v$version/$asset" \
        --output "$work/runtime.tar.gz"
    printf '%s  %s\n' "$digest" "$work/runtime.tar.gz" | shasum -a 256 -c - >&2
    tar -xzf "$work/runtime.tar.gz" -C "$work"
    candidate="$work/codex-$target"
    if [ "$("$candidate" --version)" != "codex-cli $version" ]; then
        echo "Downloaded runtime version does not match pin" >&2
        exit 1
    fi
    install -m 0755 "$candidate" "$work/verified-codex"
    mv "$work/verified-codex" "$binary"
fi
if [ "$("$binary" --version)" != "codex-cli $version" ]; then
    echo "Cached runtime version does not match pin: $binary" >&2
    exit 1
fi
printf '%s\n' "$binary"
