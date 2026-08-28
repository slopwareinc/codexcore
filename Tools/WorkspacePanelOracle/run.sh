#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bundle_path="${CODEX_OFFICIAL_BUNDLE:-/Applications/ChatGPT.app}"
output_dir="${CODEX_WORKSPACE_ORACLE_OUTPUT:-${TMPDIR:-/tmp}/codexcore-workspace-panel-oracle}"
configuration="${CODEX_PERF_CONFIGURATION:-debug}"
iterations="${CODEX_PANEL_PERF_ITERATIONS:-30}"
captured_at="${CODEX_ORACLE_CAPTURED_AT:-}"
skip_performance=0

usage() {
    cat <<'EOF'
Usage: Tools/WorkspacePanelOracle/run.sh [options]

Read-only options:
  --bundle PATH       official .app bundle (default: /Applications/ChatGPT.app)
  --output DIR        directory for JSON artifacts
  --configuration CFG Swift test configuration: debug or release (default: debug)
  --iterations N      override performance sample scale (default: 30)
  --captured-at ISO   stable timestamp for inventory evidence
  --skip-performance  only inventory the official bundle
  -h, --help          show this help

The performance test writes signposted JSON through existing CodexCore public
interfaces. No production binary or official renderer code is modified.
EOF
}

while (($# > 0)); do
    case "$1" in
        --bundle)
            [[ $# -ge 2 ]] || { echo "--bundle requires a path" >&2; exit 2; }
            bundle_path="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { echo "--output requires a directory" >&2; exit 2; }
            output_dir="$2"
            shift 2
            ;;
        --configuration)
            [[ $# -ge 2 ]] || { echo "--configuration requires debug or release" >&2; exit 2; }
            configuration="$2"
            shift 2
            ;;
        --iterations)
            [[ $# -ge 2 ]] || { echo "--iterations requires a positive integer" >&2; exit 2; }
            iterations="$2"
            shift 2
            ;;
        --captured-at)
            [[ $# -ge 2 ]] || { echo "--captured-at requires a UTC timestamp" >&2; exit 2; }
            captured_at="$2"
            shift 2
            ;;
        --skip-performance)
            skip_performance=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$configuration" == "debug" || "$configuration" == "release" ]] || {
    echo "--configuration must be debug or release" >&2
    exit 2
}
[[ "$iterations" =~ ^[1-9][0-9]*$ ]] || {
    echo "--iterations must be a positive integer" >&2
    exit 2
}

mkdir -p "$output_dir"
source_commit="$(git -C "$root" rev-parse HEAD)"
inventory_args=(
    --bundle "$bundle_path"
    --source-commit "$source_commit"
    --output "$output_dir/official-workspace-panel-inventory.json"
)
if [[ -n "$captured_at" ]]; then
    inventory_args+=(--captured-at "$captured_at")
fi

python3 "$root/Tools/WorkspacePanelOracle/workspace_panel_oracle.py" "${inventory_args[@]}"

if ((skip_performance == 0)); then
    (
        cd "$root"
        CODEX_PERF_SOURCE_COMMIT="$source_commit" \
            CODEX_WORKSPACE_PANEL_PERF_OUTPUT="$output_dir/workspace-panel-performance-baseline.json" \
            CODEX_PANEL_PERF_ITERATIONS="$iterations" \
            swift test --configuration "$configuration" \
                --filter CodexWorkspacePanelPerformanceTests
    )
fi

echo "Workspace-panel oracle artifacts: $output_dir"
