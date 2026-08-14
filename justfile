set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

root := justfile_directory()
build_jobs := env_var_or_default("CODEXCORE_BUILD_JOBS", "4")

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
    if pids=$(pgrep -x CodexCore 2>/dev/null); then
        echo "Stopping packaged CodexCore: ${pids//$'\n'/ }"
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
            if ! pgrep -x codex-core-app >/dev/null 2>&1 \
                && ! pgrep -x CodexCore >/dev/null 2>&1; then
                break
            fi
            sleep 0.05
        done
    fi

build:
    swift build --jobs "{{build_jobs}}" --target CodexCoreApp

test *ARGS:
    swift test --jobs "{{build_jobs}}" {{ARGS}}

# Render component scenes to build/gallery for visual review.
# Every theme family, both appearances. Liquid Glass renders as its opaque
# fallback: the window server composites real glass from behind the window, so
# it cannot be captured offscreen.
gallery *ARGS:
    swift run --jobs "{{build_jobs}}" codex-ui-gallery --out "{{root}}/build/gallery" {{ARGS}}

# Assemble a registered, ad-hoc signed macOS application bundle.
package:
    ./scripts/package-app.sh

package-release:
    ./scripts/package-app.sh --release

# Package and launch the real macOS application bundle.
run-app: kill package
    open "{{root}}/build/CodexCore.app"

# Kill any running instance, rebuild, and launch the CodexCore app.
run: kill build
    swift run --skip-build codex-core-app

# Alias for `run`.
rerun: run

# Kill and launch without rebuilding (when you only changed runtime data).
run-fast: kill
    swift run --skip-build codex-core-app

# Profile the running app's real transcript. Override with TRACE_DURATION=30s if needed.
trace:
    #!/usr/bin/env bash
    set -euo pipefail
    root="{{root}}"
    duration="${TRACE_DURATION:-15s}"
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
    available_kb="$(df -Pk "${profile_dir}" | awk 'NR == 2 { print $4 }')"
    required_kb="$((10 * 1024 * 1024))"
    if (( available_kb < required_kb )); then
        available_gb="$((available_kb / 1024 / 1024))"
        echo "Not enough free disk space to record safely (${available_gb} GiB available; 10 GiB required)." >&2
        exit 1
    fi

    cleanup_failed_trace() {
        status=$?
        if (( status != 0 )); then
            rm -rf "${trace_path}"
            echo "Recording failed; removed partial trace bundle: ${trace_path}" >&2
        fi
        exit "${status}"
    }
    trap cleanup_failed_trace EXIT

    echo "Recording CodexCore PID ${pid} for ${duration}."
    echo "Scroll the current transcript now; avoid switching tasks or resizing the window."
    xcrun xctrace record \
        --template "Animation Hitches" \
        --instrument "Time Profiler" \
        --attach "${pid}" \
        --time-limit "${duration}" \
        --output "${trace_path}"
    trap - EXIT
    echo "Saved trace: ${trace_path}"
