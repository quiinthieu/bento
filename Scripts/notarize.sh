#!/usr/bin/env bash
set -euo pipefail

# Submits a Developer ID signed DMG to Apple's Notary Service, staples the notarization ticket,
# and validates both `xcrun stapler validate` and Gatekeeper `spctl -a -vv` (`PLAN.md` §8, §11 T16).
#
# Supported authentication modes (checked in order):
#   1. Keychain profile:
#        NOTARYTOOL_PROFILE="bento-notary"
#   2. App Store Connect API Key (recommended for GitHub Actions):
#        APPLE_API_KEY_PATH="/path/to/AuthKey_XXXX.p8"
#        APPLE_API_KEY_ID="XXXXXXXXXX"
#        APPLE_API_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#   3. Apple ID + App-Specific Password:
#        APPLE_ID="you@example.com"
#        APPLE_TEAM_ID="XXXXXXXXXX"
#        APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
#
# Usage:
#   Scripts/notarize.sh [--dry-run] <path/to/App.dmg>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
XCCONFIG_FILE="${ROOT_DIR}/Config/Product.xcconfig"

DRY_RUN=0
DMG_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] <path/to/App.dmg>"
            exit 0
            ;;
        *)
            DMG_PATH="$1"
            shift
            ;;
    esac
done

if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
    echo "ERROR: Provide an existing .dmg file to notarize." >&2
    exit 1
fi

PRODUCT_NAME="$(awk '
    {
        sub(/\/\/.*$/, "", $0)
        if ($0 ~ "^[[:space:]]*BENTO_PRODUCT_NAME[[:space:]]*=") {
            sub("^[[:space:]]*BENTO_PRODUCT_NAME[[:space:]]*=[[:space:]]*", "", $0)
            sub(/[[:space:]]+$/, "", $0)
            print $0
            exit
        }
    }
' "${XCCONFIG_FILE}")"

AUTH_ARGS=()
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    AUTH_ARGS=(--keychain-profile "${NOTARYTOOL_PROFILE}")
elif [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]; then
    AUTH_ARGS=(--key "${APPLE_API_KEY_PATH}" --key-id "${APPLE_API_KEY_ID}" --issuer "${APPLE_API_ISSUER_ID}")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    AUTH_ARGS=(--apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}" --password "${APPLE_APP_SPECIFIC_PASSWORD}")
else
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "DRY-RUN: No notarytool credentials set in environment; verified DMG exists at ${DMG_PATH}."
        exit 0
    fi
    cat >&2 <<EOF
ERROR: Missing Apple notarization credentials. Configure one of:
  1. NOTARYTOOL_PROFILE (saved via 'xcrun notarytool store-credentials')
  2. APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER_ID
  3. APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD
EOF
    exit 1
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN: Would run xcrun notarytool submit '${DMG_PATH}' --wait, stapler staple, stapler validate, and spctl -a -vv."
    exit 0
fi

# Confirm the DMG carries a Developer ID signature rather than ad-hoc ("-").
DMG_SIG_INFO="$(/usr/bin/codesign -dv --verbose=4 "${DMG_PATH}" 2>&1 || true)"
if [[ "${DMG_SIG_INFO}" != *"Authority=Developer ID Application"* ]]; then
    echo "ERROR: ${DMG_PATH} is not signed with a 'Developer ID Application' certificate." >&2
    echo "${DMG_SIG_INFO}" >&2
    exit 1
fi

echo "==> Submitting ${DMG_PATH} to Apple Notary Service..."
/usr/bin/xcrun notarytool submit "${DMG_PATH}" "${AUTH_ARGS[@]}" --wait

echo "==> Stapling notarization ticket to ${DMG_PATH}..."
/usr/bin/xcrun stapler staple "${DMG_PATH}"

echo "==> Validating stapled DMG ticket..."
/usr/bin/xcrun stapler validate "${DMG_PATH}"
/usr/sbin/spctl -a -vv -t open --context context:primary-signature "${DMG_PATH}"

MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bento-notarize-verify.XXXXXX")"
cleanup_mount() {
    /usr/bin/hdiutil detach "${MOUNT_DIR}" -quiet >/dev/null 2>&1 || true
    rm -rf "${MOUNT_DIR}"
}
trap cleanup_mount EXIT

echo "==> Mounting ${DMG_PATH} read-only to verify Gatekeeper assessment on ${PRODUCT_NAME}.app..."
/usr/bin/hdiutil attach "${DMG_PATH}" -nobrowse -readonly -mountpoint "${MOUNT_DIR}" -quiet
/usr/sbin/spctl -a -vv --type execute "${MOUNT_DIR}/${PRODUCT_NAME}.app"

echo "==> Notarization, stapling, stapler validation, and spctl assessment succeeded for ${DMG_PATH}."
