#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
configuration="debug"

if [[ "${1:-}" == "--release" ]]; then
    configuration="release"
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--release]" >&2
    exit 64
fi

app_dir="${repo_root}/build/CodexCore.app"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
icon_source="${repo_root}/Sources/CodexCoreApp/Resources/AppIcon.svg"
iconset_dir="$(mktemp -d)/AppIcon.iconset"

cleanup() {
    rm -rf "${iconset_dir%/AppIcon.iconset}"
}
trap cleanup EXIT

swift build --package-path "${repo_root}" --configuration "${configuration}" --product codex-core-app
bin_dir="$(swift build --package-path "${repo_root}" --configuration "${configuration}" --show-bin-path)"

rm -rf "${app_dir}"
mkdir -p "${macos_dir}" "${resources_dir}" "${iconset_dir}"
cp "${bin_dir}/codex-core-app" "${macos_dir}/CodexCore"
cp "${repo_root}/Sources/CodexCoreApp/Info.plist" "${contents_dir}/Info.plist"
cp "${icon_source}" "${resources_dir}/AppIcon.svg"

master_png="${iconset_dir}/icon_512x512@2x.png"
sips --setProperty format png "${icon_source}" --out "${master_png}" >/dev/null
for size in 16 32 128 256 512; do
    sips --resampleHeightWidth "${size}" "${size}" "${master_png}" --out "${iconset_dir}/icon_${size}x${size}.png" >/dev/null
    double_size="$((size * 2))"
    sips --resampleHeightWidth "${double_size}" "${double_size}" "${master_png}" --out "${iconset_dir}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "${iconset_dir}" --output "${resources_dir}/AppIcon.icns"

plutil -lint "${contents_dir}/Info.plist" >/dev/null

signing_identity="${CODEXCORE_SIGNING_IDENTITY:-}"
if [[ -z "${signing_identity}" ]]; then
    signing_identity="$(
        security find-identity -v -p codesigning 2>/dev/null |
            awk -F '"' '
                /"Developer ID Application:/ {
                    print $2
                    found = 1
                    exit
                }
                /"Apple Development:/ && apple_development == "" {
                    apple_development = $2
                }
                END {
                    if (!found && apple_development != "") {
                        print apple_development
                    }
                }
            '
    )"
fi

if [[ -z "${signing_identity}" ]]; then
    signing_identity="-"
    echo "warning: no code-signing identity found; microphone permission may reset after rebuilds" >&2
fi

codesign --force --deep --sign "${signing_identity}" "${app_dir}"
codesign --verify --deep --strict "${app_dir}"

echo "Packaged ${app_dir} (${configuration}, signed by ${signing_identity})"
