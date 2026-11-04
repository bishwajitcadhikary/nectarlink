#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a NectarLink.app bundle and a disk image for macOS:
#   dist/Nectarlink-<version>-macos-<arch>.dmg
#
# The app is self-contained: macdeployqt copies the Qt frameworks, plugins and
# QML modules beside the binary, and the translations are compiled in.
#
# Environment:
#   VERSION                  the version, from Cargo.toml by default
#   ARCH                     arm64, x86_64, or universal (this Mac's by default)
#   SKIP_BUILD=1             use an existing target/ build
#   QMAKE or QT_ROOT_DIR     where Qt 6 is (found on PATH or in Homebrew, ~/Qt)
#   NECTARLINK_CODESIGN_IDENTITY
#                            a Developer ID identity; without it the app is
#                            signed ad hoc (users then allow it once in
#                            System Settings, or it isn't notarized)
#   NECTARLINK_NOTARY_PROFILE
#                            a notarytool keychain profile. Alternatively set
#                            NECTARLINK_NOTARY_APPLE_ID, _TEAM_ID and
#                            _APP_PASSWORD. Without either, the disk image is
#                            built but not notarized.
#
# Options:
#   --check                  build and verify the bundle and disk image, then
#                            stop (what CI runs)
#
# Needs macOS 14 or newer with Xcode Command Line Tools, Rust with the
# aarch64-apple-darwin and x86_64-apple-darwin targets for a universal build,
# and Qt 6.12 (aqtinstall, Homebrew, or the Qt online installer).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DESKTOP_DIR="${REPO_ROOT}/desktop/app"
MINIMUM_MACOS="${MINIMUM_MACOS:-14.0}"

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
elif [[ -n "${1:-}" ]]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "this script builds the macOS app, on macOS"

# ---- Version, from the workspace manifest ----
VERSION="${VERSION:-$(awk -F'"' '/^version = "/ { print $2; exit }' "${REPO_ROOT}/Cargo.toml")}"
[[ -n "${VERSION}" ]] || fail "can't read the version from Cargo.toml"
SHORT_VERSION="${VERSION%%-*}"
[[ "${SHORT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected version ${VERSION}"

# CFBundleVersion is a build number: the release sorts after its nightlies,
# as Windows' fourth file-version number does. One integer keeps it valid.
if [[ "${VERSION}" =~ -nightly\.([0-9]+)$ ]]; then
    BUILD_NUMBER="${BASH_REMATCH[1]}"
else
    BUILD_NUMBER=999
fi
[[ "${BUILD_NUMBER}" -ge 0 && "${BUILD_NUMBER}" -le 999 ]] || fail "nightly number in ${VERSION} must be 0 to 999"
IFS=. read -r MAJOR MINOR PATCH <<<"${SHORT_VERSION}"
BUNDLE_VERSION=$((MAJOR * 1000000 + MINOR * 10000 + PATCH * 100 + BUILD_NUMBER))

# ---- Architecture ----
ARCH="${ARCH:-$(uname -m)}"
case "${ARCH}" in
    arm64|aarch64) ARCH="arm64"; TARGETS=("aarch64-apple-darwin") ;;
    x86_64|amd64) ARCH="x86_64"; TARGETS=("x86_64-apple-darwin") ;;
    universal) TARGETS=("aarch64-apple-darwin" "x86_64-apple-darwin") ;;
    *) fail "ARCH must be arm64, x86_64 or universal, not ${ARCH}" ;;
esac

# ---- Qt ----
find_qmake() {
    if [[ -n "${QMAKE:-}" ]]; then
        if [[ -x "${QMAKE}" ]]; then
            printf '%s\n' "${QMAKE}"
            return 0
        fi
        # A bare name ("qmake") or a path on PATH.
        if command -v "${QMAKE}" >/dev/null 2>&1; then
            command -v "${QMAKE}"
            return 0
        fi
    fi
    if [[ -n "${QT_ROOT_DIR:-}" && -x "${QT_ROOT_DIR}/bin/qmake" ]]; then
        printf '%s\n' "${QT_ROOT_DIR}/bin/qmake"
        return 0
    fi
    local candidate
    for candidate in \
        /opt/homebrew/opt/qt/bin/qmake \
        /opt/homebrew/opt/qt@6/bin/qmake \
        /usr/local/opt/qt/bin/qmake \
        /usr/local/opt/qt@6/bin/qmake; do
        [[ -x "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
    done
    # aqtinstall and the Qt online installer: ~/Qt/<version>/macos/bin/qmake.
    # The newest install wins; a specific one can be chosen with QMAKE.
    local installs=("${HOME}"/Qt/*/macos/bin/qmake)
    if [[ -e "${installs[0]}" ]]; then
        candidate="$(ls -1t "${installs[@]}" | head -n 1)"
        printf '%s\n' "${candidate}"
        return 0
    fi
    installs=("${HOME}"/Qt/*/clang_64/bin/qmake)
    if [[ -e "${installs[0]}" ]]; then
        candidate="$(ls -1t "${installs[@]}" | head -n 1)"
        printf '%s\n' "${candidate}"
        return 0
    fi
    command -v qmake6 || command -v qmake
}
QMAKE="$(find_qmake || true)"
[[ -n "${QMAKE}" ]] || fail "Qt 6 not found: set QMAKE or QT_ROOT_DIR"
export QMAKE
QT_BIN="$(dirname "${QMAKE}")"
export PATH="${QT_BIN}:${PATH}"
MACDEPLOYQT="${QT_BIN}/macdeployqt"
LRELEASE="${QT_BIN}/lrelease"
[[ -x "${MACDEPLOYQT}" ]] || fail "macdeployqt not found in ${QT_BIN}"
[[ -x "${LRELEASE}" || -z "$(compgen -G "${DESKTOP_DIR}/i18n/nectarlink_*.ts" || true)" ]] \
    || fail "lrelease not found in ${QT_BIN}: install Qt's qttools archive (aqt: --archives qttools)"

QT_VERSION="$("${QMAKE}" -query QT_VERSION 2>/dev/null || true)"
echo "Qt ${QT_VERSION:-unknown} at ${QT_BIN}"

# ---- Build ----
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-${MINIMUM_MACOS}}"
HOST_ARCH="$(uname -m)"
[[ "${HOST_ARCH}" == "aarch64" ]] && HOST_ARCH="arm64"
[[ "${HOST_ARCH}" == "amd64" ]] && HOST_ARCH="x86_64"
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    step "Build (${ARCH})"
    if [[ "${ARCH}" == "universal" ]]; then
        for target in "${TARGETS[@]}"; do
            rustup target list --installed | grep -qx "${target}" \
                || fail "${target} isn't installed: rustup target add ${TARGETS[*]}"
            (cd "${REPO_ROOT}" && cargo build --locked --release -p nectarlink-desktop --target "${target}")
        done
    elif [[ "${ARCH}" == "${HOST_ARCH}" ]]; then
        (cd "${REPO_ROOT}" && cargo build --locked --release -p nectarlink-desktop)
    else
        rustup target list --installed | grep -qx "${TARGETS[0]}" \
            || fail "${TARGETS[0]} isn't installed: rustup target add ${TARGETS[0]}"
        (cd "${REPO_ROOT}" && cargo build --locked --release -p nectarlink-desktop --target "${TARGETS[0]}")
    fi
fi

STAGE_DIR="$(mktemp -d -t nectarlink-macos-XXXXXX)"
MOUNT_DIR=""
cleanup() {
    if [[ -n "${MOUNT_DIR}" && -d "${MOUNT_DIR}" ]]; then
        hdiutil detach "${MOUNT_DIR}" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

APP="${STAGE_DIR}/NectarLink.app"
CONTENTS="${APP}/Contents"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

BINARY="${CONTENTS}/MacOS/nectarlink-desktop"
if [[ "${ARCH}" == "universal" ]]; then
    BINARIES=()
    for target in "${TARGETS[@]}"; do
        path="${REPO_ROOT}/target/${target}/release/nectarlink-desktop"
        [[ -f "${path}" ]] || fail "no release build at ${path}"
        BINARIES+=("${path}")
    done
    lipo -create "${BINARIES[@]}" -output "${BINARY}"
else
    path=""
    for candidate in \
        "${REPO_ROOT}/target/${TARGETS[0]}/release/nectarlink-desktop" \
        "${REPO_ROOT}/target/release/nectarlink-desktop"; do
        if [[ -f "${candidate}" ]]; then
            path="${candidate}"
            break
        fi
    done
    [[ -n "${path}" ]] || fail "no release build for ${ARCH} in target/"
    # A plain `cargo build` on this Mac makes the host's architecture: make
    # sure it's the one the disk image is named after.
    archs="$(lipo -archs "${path}")"
    [[ "${archs}" == *"${ARCH}"* ]] || fail "${path} is ${archs}, not ${ARCH}"
    install -m 0755 "${path}" "${BINARY}"
fi
chmod 0755 "${BINARY}"
lipo -archs "${BINARY}"

# ---- Icon ----
ICON_SOURCE="${REPO_ROOT}/assets/brand/icon-1024.png"
[[ -f "${ICON_SOURCE}" ]] || ICON_SOURCE="${REPO_ROOT}/assets/brand/icon-512.png"
[[ -f "${ICON_SOURCE}" ]] || fail "no app icon in assets/brand"
ICONSET="${STAGE_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET}"
for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    size="${spec%% *}"
    name="${spec#* }"
    sips -z "${size}" "${size}" "${ICON_SOURCE}" --out "${ICONSET}/${name}" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${CONTENTS}/Resources/AppIcon.icns"

# ---- Info.plist and PkgInfo ----
sed \
    -e "s/@SHORT_VERSION@/${SHORT_VERSION}/g" \
    -e "s/@BUNDLE_VERSION@/${BUNDLE_VERSION}/g" \
    -e "s/@MINIMUM_MACOS@/${MINIMUM_MACOS}/g" \
    "${SCRIPT_DIR}/Info.plist.in" >"${CONTENTS}/Info.plist"
plutil -lint "${CONTENTS}/Info.plist" >/dev/null
printf 'APPL????' >"${CONTENTS}/PkgInfo"

# ---- Translations ----
# build.rs compiles the .qm files beside the Cargo output, but the staged
# bundle only copies the executable. Recompile them into the bundle, where the
# app looks for them beside the executable (src/i18n.rs). They are written
# after macdeployqt so it doesn't try to run otool on them.
compile_translations() {
    for ts in "${DESKTOP_DIR}"/i18n/nectarlink_*.ts; do
        [[ -e "${ts}" ]] || continue
        stem="$(basename "${ts}" .ts)"
        "${LRELEASE}" -silent "${ts}" -qm "${CONTENTS}/MacOS/${stem}.qm"
    done
}

# ---- Qt, plugins and QML modules ----
step "Bundle Qt"
# -appstore-compliant leaves out the SQL plugins that use private API; any
# remaining drivers are removed after deployment (see below).
"${MACDEPLOYQT}" "${APP}" \
    -qmldir="${DESKTOP_DIR}/qml" \
    -appstore-compliant \
    -always-overwrite \
    -verbose=1

compile_translations

# NectarLink doesn't use QtSql. macdeployqt still copies its drivers, and the
# Mimer driver links an optional system library that isn't present.
rm -rf "${CONTENTS}/PlugIns/sqldrivers"

# ---- Notices ----
mkdir -p "${CONTENTS}/Resources/licenses"
install -m 0644 "${REPO_ROOT}/LICENSE" "${CONTENTS}/Resources/licenses/LICENSE.txt"
cp -R "${REPO_ROOT}/LICENSES/." "${CONTENTS}/Resources/licenses/"
(cd "${REPO_ROOT}" && cargo xtask notices "${CONTENTS}/Resources/THIRD-PARTY-NOTICES.txt" \
    --target "${TARGETS[0]}") || fail "couldn't write the third-party notices"

# ---- Sign ----
SIGN_IDENTITY="${NECTARLINK_CODESIGN_IDENTITY:-}"
SIGNED=0
NOTARIZED=0
if [[ -n "${SIGN_IDENTITY}" ]]; then
    step "Sign"
    security find-identity -v -p codesigning | grep -Fq "${SIGN_IDENTITY}" \
        || fail "no code-signing identity matching ${SIGN_IDENTITY} in the keychain"
    # Deep signing is what macdeployqt's copied frameworks and plugins need:
    # every nested binary is signed before the bundle's own seal.
    codesign --force --deep --options runtime --timestamp \
        --entitlements "${SCRIPT_DIR}/entitlements.plist" \
        --sign "${SIGN_IDENTITY}" "${APP}"
    SIGNED=1
else
    step "Sign (ad hoc)"
    # Gatekeeper still asks, but the app and its frameworks are internally
    # consistent, so macOS can run it once the user allows it.
    codesign --force --deep --sign - "${APP}"
fi
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign --display --verbose=2 "${APP}" 2>&1 | sed -n '1,4p'

# ---- Notarize ----
if [[ "${SIGNED}" == "1" ]]; then
    NOTARY_PROFILE="${NECTARLINK_NOTARY_PROFILE:-}"
    if [[ -n "${NOTARY_PROFILE}" || -n "${NECTARLINK_NOTARY_APPLE_ID:-}" ]]; then
        step "Notarize"
        notary_zip="${STAGE_DIR}/NectarLink-notarize.zip"
        ditto -c -k --keepParent "${APP}" "${notary_zip}"
        if [[ -n "${NOTARY_PROFILE}" ]]; then
            xcrun notarytool submit "${notary_zip}" --keychain-profile "${NOTARY_PROFILE}" --wait
        else
            xcrun notarytool submit "${notary_zip}" \
                --apple-id "${NECTARLINK_NOTARY_APPLE_ID}" \
                --team-id "${NECTARLINK_NOTARY_TEAM_ID}" \
                --password "${NECTARLINK_NOTARY_APP_PASSWORD}" \
                --wait
        fi
        xcrun stapler staple "${APP}"
        xcrun stapler validate "${APP}"
        NOTARIZED=1
    else
        echo "warning: signed but not notarized; first launch asks for permission"
    fi
fi

if [[ "${SIGNED}" == "1" && "${NOTARIZED}" == "1" ]]; then
    spctl --assess --type execute --verbose "${APP}"
fi

# ---- Disk image ----
step "Disk image"
DMG_ROOT="${STAGE_DIR}/dmg"
mkdir -p "${DMG_ROOT}"
# ditto preserves the bundle's extended attributes, including a stapled ticket.
ditto "${APP}" "${DMG_ROOT}/NectarLink.app"
ln -s /Applications "${DMG_ROOT}/Applications"

OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/dist}"
mkdir -p "${OUTPUT_DIR}"
DMG="${OUTPUT_DIR}/Nectarlink-${VERSION}-macos-${ARCH}.dmg"
rm -f "${DMG}"
hdiutil create -volname "NectarLink" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${DMG}" >/dev/null
hdiutil verify "${DMG}" >/dev/null
if [[ "${SIGNED}" == "1" ]]; then
    codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG}"
fi

# ---- Check what actually ships ----
step "Check the disk image"
MOUNT_DIR="${STAGE_DIR}/mount"
mkdir -p "${MOUNT_DIR}"
hdiutil attach -nobrowse -readonly -mountpoint "${MOUNT_DIR}" "${DMG}" >/dev/null
MOUNTED_APP="${MOUNT_DIR}/NectarLink.app"
[[ -d "${MOUNTED_APP}" ]] || fail "no NectarLink.app in ${DMG}"
[[ "$(plutil -extract CFBundleIdentifier raw "${MOUNTED_APP}/Contents/Info.plist")" == "org.nectarlink.desktop" ]] \
    || fail "wrong bundle identifier"
version_output="$("${MOUNTED_APP}/Contents/MacOS/nectarlink-desktop" --version)"
echo "${version_output}"
[[ "${version_output}" == *"${VERSION}"* ]] || fail "the app reports ${version_output}, expected ${VERSION}"
if [[ "${ARCH}" == "universal" ]]; then
    archs="$(lipo -archs "${MOUNTED_APP}/Contents/MacOS/nectarlink-desktop")"
    [[ "${archs}" == *arm64* && "${archs}" == *x86_64* ]] || fail "universal app is ${archs}"
fi
hdiutil detach "${MOUNT_DIR}" -quiet >/dev/null
MOUNT_DIR=""

echo
echo "Disk image: ${DMG} ($(du -h "${DMG}" | cut -f1 | tr -d ' '))"
if [[ "${CHECK_ONLY}" == "1" ]]; then
    echo "Checked ${APP##*/} and ${DMG##*/}."
fi
