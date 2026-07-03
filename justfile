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
