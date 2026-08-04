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
frameworks_dir="${contents_dir}/Frameworks"
icon_source="${repo_root}/Sources/CodexCoreApp/Resources/AppIcon.svg"
iconset_dir="$(mktemp -d)/AppIcon.iconset"
entitlements_path="${repo_root}/CodexCore.entitlements"

cleanup() {
    rm -rf "${iconset_dir%/AppIcon.iconset}"
}
trap cleanup EXIT

swift build --package-path "${repo_root}" --configuration "${configuration}" --product codex-core-app
bin_dir="$(swift build --package-path "${repo_root}" --configuration "${configuration}" --show-bin-path)"

rm -rf "${app_dir}"
mkdir -p "${macos_dir}" "${resources_dir}" "${frameworks_dir}" "${iconset_dir}"
cp "${bin_dir}/codex-core-app" "${macos_dir}/CodexCore"
cp "${repo_root}/Sources/CodexCoreApp/Info.plist" "${contents_dir}/Info.plist"
cp "${icon_source}" "${resources_dir}/AppIcon.svg"

sparkle_framework="${bin_dir}/Sparkle.framework"
if [[ ! -d "${sparkle_framework}" ]]; then
    echo "error: SwiftPM did not place Sparkle.framework beside codex-core-app" >&2
    exit 1
fi
cp -R "${sparkle_framework}" "${frameworks_dir}/Sparkle.framework"

build_number="${CODEXCORE_BUILD_NUMBER:-$(git -C "${repo_root}" rev-list --count HEAD)}"
if [[ ! "${build_number}" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    echo "error: CODEXCORE_BUILD_NUMBER must contain one to three dot-separated integers" >&2
    exit 64
fi
git_commit="$(git -C "${repo_root}" rev-parse HEAD)"
update_feed_url="${CODEXCORE_UPDATE_FEED_URL:-https://updates.example.invalid/codexcore/appcast.xml}"
sparkle_public_key="${CODEXCORE_SPARKLE_PUBLIC_KEY:-REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY}"

plutil -replace CFBundleVersion -string "${build_number}" "${contents_dir}/Info.plist"
plutil -replace CodexCoreGitCommit -string "${git_commit}" "${contents_dir}/Info.plist"
plutil -replace SUFeedURL -string "${update_feed_url}" "${contents_dir}/Info.plist"
plutil -replace SUPublicEDKey -string "${sparkle_public_key}" "${contents_dir}/Info.plist"

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

timestamp_option="--timestamp"
if [[ "${signing_identity}" == "-" ]]; then
    timestamp_option="--timestamp=none"
fi

while IFS= read -r -d '' nested_executable; do
    if file -b "${nested_executable}" | grep -q 'Mach-O'; then
        codesign --force --options runtime "${timestamp_option}" --sign "${signing_identity}" "${nested_executable}"
    fi
done < <(find "${frameworks_dir}" -type f -perm -111 -print0)

while IFS= read -r -d '' nested_code; do
    codesign --force --options runtime "${timestamp_option}" --sign "${signing_identity}" "${nested_code}"
done < <(
    find -d "${frameworks_dir}" \
        \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) \
        -print0
)

codesign \
    --force \
    --options runtime \
    "${timestamp_option}" \
    --entitlements "${entitlements_path}" \
    --sign "${signing_identity}" \
    "${app_dir}"

while IFS= read -r -d '' nested_code; do
    codesign --verify --strict "${nested_code}"
done < <(
    find -d "${frameworks_dir}" \
        \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) \
        -print0
)
codesign --verify --strict "${app_dir}"

short_version="$(plutil -extract CFBundleShortVersionString raw "${contents_dir}/Info.plist")"
archive_path="${repo_root}/build/CodexCore-${short_version}-${build_number}.zip"

create_archive() {
    rm -f "${archive_path}"
    ditto -c -k --keepParent "${app_dir}" "${archive_path}"
}

create_archive

notary_profile="${CODEXCORE_NOTARY_KEYCHAIN_PROFILE:-}"
if [[ -n "${notary_profile}" ]]; then
    if [[ "${signing_identity}" != "Developer ID Application:"* ]]; then
        echo "error: notarization requires a Developer ID Application identity" >&2
        exit 64
    fi
    xcrun notarytool submit "${archive_path}" --keychain-profile "${notary_profile}" --wait
    xcrun stapler staple "${app_dir}"
    xcrun stapler validate "${app_dir}"
    create_archive
else
    echo "Skipping notarization: CODEXCORE_NOTARY_KEYCHAIN_PROFILE is not set"
fi

appcast_dir="${CODEXCORE_APPCAST_DIRECTORY:-}"
if [[ -n "${appcast_dir}" ]]; then
    generate_appcast="${CODEXCORE_GENERATE_APPCAST:-}"
    if [[ -z "${generate_appcast}" || ! -x "${generate_appcast}" ]]; then
        echo "error: CODEXCORE_GENERATE_APPCAST must name the executable Sparkle generate_appcast tool" >&2
        exit 64
    fi
    if [[ "${update_feed_url}" == *".invalid"* || "${sparkle_public_key}" == REPLACE_WITH_* ]]; then
        echo "error: appcast generation requires CODEXCORE_UPDATE_FEED_URL and CODEXCORE_SPARKLE_PUBLIC_KEY" >&2
        exit 64
    fi
    mkdir -p "${appcast_dir}"
    cp "${archive_path}" "${appcast_dir}/"
    "${generate_appcast}" "${appcast_dir}"
else
    echo "Skipping appcast generation: CODEXCORE_APPCAST_DIRECTORY is not set"
fi

echo "Packaged ${app_dir} (${configuration}, build ${build_number}, commit ${git_commit}, signed by ${signing_identity})"
echo "Archive: ${archive_path}"
