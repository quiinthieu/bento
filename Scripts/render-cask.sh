#!/usr/bin/env bash
set -euo pipefail

# Renders Casks/agent-bento.rb.template with single-source product metadata and DMG SHA-256 (`PLAN.md` §11 T16).
#
# Usage:
#   Scripts/render-cask.sh --dmg <path/to/App.dmg> --url <download_url> [--output <path/to/agent-bento.rb>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_PATH="${ROOT_DIR}/Casks/agent-bento.rb.template"
XCCONFIG_FILE="${ROOT_DIR}/Config/Product.xcconfig"

DMG_PATH=""
DMG_URL=""
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)
            DMG_PATH="$2"
            shift 2
            ;;
        --url)
            DMG_URL="$2"
            shift 2
            ;;
        --output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --dmg <path> --url <download_url> [--output <path>]"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
    echo "ERROR: --dmg <file> is required and must exist." >&2
    exit 1
fi
if [[ -z "${DMG_URL}" ]]; then
    echo "ERROR: --url <download_url> is required." >&2
    exit 1
fi
if [[ ! -f "${TEMPLATE_PATH}" ]]; then
    echo "ERROR: Missing template at ${TEMPLATE_PATH}" >&2
    exit 1
fi

read_xcconfig_key() {
    local key="$1"
    awk -v k="${key}" '
        {
            sub(/\/\/.*$/, "", $0)
            if ($0 ~ "^[[:space:]]*" k "[[:space:]]*=") {
                sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", $0)
                sub(/[[:space:]]+$/, "", $0)
                print $0
                exit
            }
        }
    ' "${XCCONFIG_FILE}"
}

PRODUCT_NAME="$(read_xcconfig_key "BENTO_PRODUCT_NAME")"
BUNDLE_ID="$(read_xcconfig_key "BENTO_BUNDLE_ID")"
CLI_NAME="$(read_xcconfig_key "BENTO_CLI_NAME")"
SUPPORT_DIR_NAME="$(read_xcconfig_key "BENTO_SUPPORT_DIR_NAME")"
VERSION="$(read_xcconfig_key "BENTO_VERSION")"
SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"

escape_sed() {
    printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

RENDERED="$(sed \
    -e "s/{{VERSION}}/$(escape_sed "${VERSION}")/g" \
    -e "s/{{SHA256}}/$(escape_sed "${SHA256}")/g" \
    -e "s/{{DMG_URL}}/$(escape_sed "${DMG_URL}")/g" \
    -e "s/{{PRODUCT_NAME}}/$(escape_sed "${PRODUCT_NAME}")/g" \
    -e "s/{{BUNDLE_ID}}/$(escape_sed "${BUNDLE_ID}")/g" \
    -e "s/{{CLI_NAME}}/$(escape_sed "${CLI_NAME}")/g" \
    -e "s/{{SUPPORT_DIR_NAME}}/$(escape_sed "${SUPPORT_DIR_NAME}")/g" \
    "${TEMPLATE_PATH}")"

if [[ -n "${OUTPUT_PATH}" ]]; then
    mkdir -p "$(dirname "${OUTPUT_PATH}")"
    printf '%s\n' "${RENDERED}" > "${OUTPUT_PATH}"
    echo "Rendered Homebrew cask to ${OUTPUT_PATH} (sha256: ${SHA256})"
else
    printf '%s\n' "${RENDERED}"
fi
