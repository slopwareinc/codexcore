#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <duration> (for example: 15s, 2m, or 30)" >&2
    exit 64
fi

duration_input="$1"
duration_seconds=""
if [[ "${duration_input}" =~ ^([0-9]+)$ ]]; then
    duration_seconds="${BASH_REMATCH[1]}"
elif [[ "${duration_input}" =~ ^([0-9]+)s$ ]]; then
    duration_seconds="${BASH_REMATCH[1]}"
elif [[ "${duration_input}" =~ ^([0-9]+)m$ ]]; then
    duration_seconds="$((BASH_REMATCH[1] * 60))"
elif [[ "${duration_input}" =~ ^([0-9]+)h$ ]]; then
    duration_seconds="$((BASH_REMATCH[1] * 3600))"
else
    echo "duration must be an integer number of seconds, or end in s, m, or h" >&2
    exit 64
fi

if (( duration_seconds < 1 )); then
    echo "duration must be at least one second" >&2
    exit 64
fi

sample_interval_ms="${CODEXCORE_SAMPLE_INTERVAL_MS:-10}"
if [[ ! "${sample_interval_ms}" =~ ^[1-9][0-9]*$ ]]; then
    echo "CODEXCORE_SAMPLE_INTERVAL_MS must be a positive integer" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
app_executable="${repo_root}/build/CodexCore.app/Contents/MacOS/CodexCore"
sample_dir="${repo_root}/build/samples"
sample_path="${sample_dir}/codexcore-$(date +%Y%m%d-%H%M%S).sample.txt"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

just --justfile "${repo_root}/justfile" run-app

pid=""
for _ in {1..80}; do
    pid="$(ps -axo pid=,command= | awk -v target="${app_executable}" '$2 == target && first == "" { first = $1 } END { if (first != "") print first }')"
    [[ -n "${pid}" ]] && break
    sleep 0.25
done

if [[ -z "${pid}" ]]; then
    echo "Timed out waiting for ${app_executable}" >&2
    exit 1
fi

mkdir -p "${sample_dir}"
echo "Sampling CodexCore pid ${pid} for ${duration_input} (interval ${sample_interval_ms}ms)."
echo "Output: ${sample_path}"
interrupted=0
trap 'interrupted=1' INT
set +e
/usr/bin/sample "${pid}" "${duration_seconds}" "${sample_interval_ms}" -file "${sample_path}"
sample_exit=$?
set -e
trap - INT
if (( interrupted == 1 || sample_exit == 130 || sample_exit == 141 )); then
    if [[ -s "${sample_path}" ]]; then
        echo "Sample interrupted after writing: ${sample_path}"
        exit 0
    fi
fi
if (( sample_exit != 0 )); then
    echo "sample failed with exit code ${sample_exit}" >&2
    exit "${sample_exit}"
fi
echo "Sample complete: ${sample_path}"
