set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

root := justfile_directory()

default:
    @just run

# Stop any running CodexCore app instance (swift run or direct binary).
kill:
    #!/usr/bin/env bash
    set -euo pipefail
    root="{{root}}"
    killed=0
    if pids=$(pgrep -x codex-core-app 2>/dev/null); then
        echo "Stopping codex-core-app: ${pids//$'\n'/ }"
        kill ${pids} 2>/dev/null || true
        killed=1
    fi
    if pids=$(pgrep -f "${root}/.build/.*/codex-core-app" 2>/dev/null); then
        echo "Stopping built binary: ${pids//$'\n'/ }"
        kill ${pids} 2>/dev/null || true
        killed=1
    fi
    if [[ "${killed}" -eq 0 ]]; then
        echo "No CodexCore app instance running."
    else
        for _ in {1..20}; do
            pgrep -x codex-core-app >/dev/null 2>&1 || break
            sleep 0.05
        done
    fi

build:
    swift build --target CodexCoreApp

# Kill any running instance, rebuild, and launch the CodexCore app.
run: kill build
    swift run codex-core-app

# Alias for `run`.
rerun: run

# Kill and launch without rebuilding (when you only changed runtime data).
run-fast: kill
    swift run codex-core-app

# Profile the running app's real transcript. Override with TRACE_DURATION=60s if needed.
trace:
    #!/usr/bin/env bash
    set -euo pipefail
    root="{{root}}"
    duration="${TRACE_DURATION:-45s}"
    profile_dir="${HOME}/.codexcore/profiles"
    trace_path="${profile_dir}/scroll-$(date +%Y%m%d-%H%M%S).trace"

    pid="$(pgrep -x codex-core-app 2>/dev/null | tail -n 1 || true)"
    if [[ -z "${pid}" ]]; then
        pid="$(pgrep -f "${root}/.build/.*/codex-core-app" 2>/dev/null | tail -n 1 || true)"
    fi
    if [[ -z "${pid}" ]]; then
        echo "No running CodexCore app found. Run 'just run' first." >&2
        exit 1
    fi

    mkdir -p "${profile_dir}"
    echo "Recording CodexCore PID ${pid} for ${duration}."
    echo "Scroll the current transcript now; avoid switching tasks or resizing the window."
    xcrun xctrace record \
        --template "Animation Hitches" \
        --instrument "Time Profiler" \
        --attach "${pid}" \
        --time-limit "${duration}" \
        --output "${trace_path}"
    echo "Saved trace: ${trace_path}"
