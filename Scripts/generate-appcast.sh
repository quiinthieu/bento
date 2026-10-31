#!/usr/bin/env bash
set -euo pipefail

# Generates a Sparkle 2 EdDSA appcast.xml for a release DMG (`PLAN.md` §11 T16).
#
# Supports signing automatically via Sparkle's `sign_update` binary (using SPARKLE_EDDSA_PRIVATE_KEY
# or the macOS Keychain), accepting a precomputed `--ed-signature`, or emitting an unsigned local
# preview feed unless `--require-signature` is passed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
XCCONFIG_FILE="${ROOT_DIR}/Config/Product.xcconfig"

DMG_PATH=""
DOWNLOAD_URL=""
OUTPUT_PATH="${ROOT_DIR}/dist/appcast.xml"
ED_SIGNATURE=""
RELEASE_NOTES_URL="https://github.com/quiinthieu/bento/releases"
MIN_SYSTEM_VERSION="15.0"
REQUIRE_SIGNATURE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)
            DMG_PATH="$2"
            shift 2
            ;;
        --download-url)
            DOWNLOAD_URL="$2"
            shift 2
            ;;
        --output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --ed-signature)
            ED_SIGNATURE="$2"
            shift 2
            ;;
        --release-notes-url)
            RELEASE_NOTES_URL="$2"
            shift 2
            ;;
        --require-signature)
            REQUIRE_SIGNATURE=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 --dmg <file> --download-url <url> [--ed-signature <sig>] [--output <appcast.xml>] [--require-signature]"
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
if [[ -z "${DOWNLOAD_URL}" ]]; then
    echo "ERROR: --download-url <url> is required." >&2
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
VERSION="$(read_xcconfig_key "BENTO_VERSION")"
BUILD_NUMBER="$(read_xcconfig_key "BENTO_BUILD_NUMBER")"
FILE_LENGTH="$(stat -f%z "${DMG_PATH}")"
PUB_DATE="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"

# Attempt EdDSA signing with Sparkle's sign_update if signature was not supplied explicitly.
if [[ -z "${ED_SIGNATURE}" ]]; then
    SIGN_UPDATE_BIN="${SPARKLE_SIGN_UPDATE_BIN:-}"
    if [[ -z "${SIGN_UPDATE_BIN}" ]] && command -v sign_update >/dev/null 2>&1; then
        SIGN_UPDATE_BIN="$(command -v sign_update)"
    fi
    if [[ -n "${SIGN_UPDATE_BIN}" && -x "${SIGN_UPDATE_BIN}" ]]; then
        if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
            RAW_SIG="$(printf '%s' "${SPARKLE_EDDSA_PRIVATE_KEY}" | "${SIGN_UPDATE_BIN}" --ed-key-file - -p "${DMG_PATH}")"
            ED_SIGNATURE="$(printf '%s' "${RAW_SIG}" | tr -d '\r\n')"
        fi
    fi
fi

if [[ "${REQUIRE_SIGNATURE}" -eq 1 && -z "${ED_SIGNATURE}" ]]; then
    echo "ERROR: Sparkle EdDSA signature is required (--require-signature), but neither --ed-signature nor SPARKLE_EDDSA_PRIVATE_KEY + sign_update was provided." >&2
    exit 1
fi

SIG_ATTR=""
if [[ -n "${ED_SIGNATURE}" ]]; then
    SIG_ATTR=" sparkle:edSignature=\"${ED_SIGNATURE}\""
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")"

cat > "${OUTPUT_PATH}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${PRODUCT_NAME} Changelog</title>
    <link>https://github.com/quiinthieu/bento</link>
    <description>Most recent updates to ${PRODUCT_NAME}.</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${RELEASE_NOTES_URL}</sparkle:releaseNotesLink>
      <enclosure url="${DOWNLOAD_URL}" sparkle:version="${BUILD_NUMBER}" sparkle:shortVersionString="${VERSION}" length="${FILE_LENGTH}" type="application/octet-stream"${SIG_ATTR}/>
    </item>
  </channel>
</rss>
EOF

echo "Generated Sparkle appcast at ${OUTPUT_PATH}"
