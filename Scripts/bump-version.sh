#!/usr/bin/env bash
set -euo pipefail

# Single-source version & build-number synchronizer/verifier (`PLAN.md` §11 T16).
# Keeps Config/Product.xcconfig and Sources/BentoCore/Product.swift identical.
#
# Usage:
#   Scripts/bump-version.sh --verify [--root <dir>]
#   Scripts/bump-version.sh --print [--root <dir>]
#   Scripts/bump-version.sh [--root <dir>] <new_version> [new_build_number]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE="bump"
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            ROOT_DIR="$2"
            shift 2
            ;;
        --verify)
            MODE="verify"
            shift
            ;;
        --print)
            MODE="print"
            shift
            ;;
        -h|--help)
            echo "Usage:"
            echo "  $0 --verify [--root <dir>]"
            echo "  $0 --print [--root <dir>]"
            echo "  $0 [--root <dir>] <new_version> [new_build_number]"
            exit 0
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

XCCONFIG_FILE="${ROOT_DIR}/Config/Product.xcconfig"
PRODUCT_SWIFT_FILE="${ROOT_DIR}/Sources/BentoCore/Product.swift"

if [[ ! -f "${XCCONFIG_FILE}" ]]; then
    echo "ERROR: Missing ${XCCONFIG_FILE}" >&2
    exit 1
fi
if [[ ! -f "${PRODUCT_SWIFT_FILE}" ]]; then
    echo "ERROR: Missing ${PRODUCT_SWIFT_FILE}" >&2
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

read_swift_constant() {
    local name="$1"
    sed -nE "s/^[[:space:]]*public[[:space:]]+static[[:space:]]+let[[:space:]]+${name}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*$/\1/p" "${PRODUCT_SWIFT_FILE}" | head -n 1
}

validate_formats() {
    local ver="$1"
    local build="$2"
    if [[ ! "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
        echo "ERROR: Invalid semantic version '${ver}' (expected MAJOR.MINOR.PATCH[-prerelease])." >&2
        exit 1
    fi
    if [[ ! "${build}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Invalid build number '${build}' (expected positive integer)." >&2
        exit 1
    fi
}

verify_sync() {
    local xc_ver xc_build sw_ver sw_build
    xc_ver="$(read_xcconfig_key "BENTO_VERSION")"
    xc_build="$(read_xcconfig_key "BENTO_BUILD_NUMBER")"
    sw_ver="$(read_swift_constant "version")"
    sw_build="$(read_swift_constant "buildNumber")"

    if [[ -z "${xc_ver}" || -z "${xc_build}" ]]; then
        echo "ERROR: Missing BENTO_VERSION or BENTO_BUILD_NUMBER in ${XCCONFIG_FILE}." >&2
        exit 1
    fi
    if [[ -z "${sw_ver}" || -z "${sw_build}" ]]; then
        echo "ERROR: Missing Product.version or Product.buildNumber in ${PRODUCT_SWIFT_FILE}." >&2
        exit 1
    fi

    validate_formats "${xc_ver}" "${xc_build}"

    local failed=0
    if [[ "${xc_ver}" != "${sw_ver}" ]]; then
        echo "ERROR: Version mismatch: Product.xcconfig BENTO_VERSION='${xc_ver}' vs Product.swift version='${sw_ver}'" >&2
        failed=1
    fi
    if [[ "${xc_build}" != "${sw_build}" ]]; then
        echo "ERROR: Build number mismatch: Product.xcconfig BENTO_BUILD_NUMBER='${xc_build}' vs Product.swift buildNumber='${sw_build}'" >&2
        failed=1
    fi
    if [[ "${failed}" -ne 0 ]]; then
        exit 1
    fi
}

if [[ "${MODE}" == "verify" ]]; then
    verify_sync
    echo "OK: Version ($(read_xcconfig_key "BENTO_VERSION")) and build ($(read_xcconfig_key "BENTO_BUILD_NUMBER")) are synchronized."
    exit 0
fi

if [[ "${MODE}" == "print" ]]; then
    verify_sync
    echo "version=$(read_xcconfig_key "BENTO_VERSION")"
    echo "build=$(read_xcconfig_key "BENTO_BUILD_NUMBER")"
    exit 0
fi

if [[ "${#POSITIONAL[@]}" -lt 1 || "${#POSITIONAL[@]}" -gt 2 ]]; then
    echo "ERROR: Provide <new_version> [new_build_number], or pass --verify / --print." >&2
    exit 1
fi

NEW_VERSION="${POSITIONAL[0]}"
CURRENT_BUILD="$(read_xcconfig_key "BENTO_BUILD_NUMBER")"
if [[ "${#POSITIONAL[@]}" -eq 2 ]]; then
    NEW_BUILD="${POSITIONAL[1]}"
else
    if [[ "${CURRENT_BUILD}" =~ ^[0-9]+$ ]]; then
        NEW_BUILD="$((CURRENT_BUILD + 1))"
    else
        NEW_BUILD="1"
    fi
fi

validate_formats "${NEW_VERSION}" "${NEW_BUILD}"

TMP_XC="$(mktemp "${XCCONFIG_FILE}.tmp.XXXXXX")"
TMP_SW="$(mktemp "${PRODUCT_SWIFT_FILE}.tmp.XXXXXX")"
trap 'rm -f "${TMP_XC}" "${TMP_SW}"' EXIT

awk -v ver="${NEW_VERSION}" -v build="${NEW_BUILD}" '
    /^[[:space:]]*BENTO_VERSION[[:space:]]*=/ {
        print "BENTO_VERSION = " ver
        next
    }
    /^[[:space:]]*BENTO_BUILD_NUMBER[[:space:]]*=/ {
        print "BENTO_BUILD_NUMBER = " build
        next
    }
    { print }
' "${XCCONFIG_FILE}" > "${TMP_XC}"

awk -v ver="${NEW_VERSION}" -v build="${NEW_BUILD}" '
    /public static let version = "/ {
        sub(/"[^"]+"/, "\"" ver "\"")
        print
        next
    }
    /public static let buildNumber = "/ {
        sub(/"[^"]+"/, "\"" build "\"")
        print
        next
    }
    { print }
' "${PRODUCT_SWIFT_FILE}" > "${TMP_SW}"

mv "${TMP_XC}" "${XCCONFIG_FILE}"
mv "${TMP_SW}" "${PRODUCT_SWIFT_FILE}"

verify_sync
echo "Updated version to ${NEW_VERSION} (build ${NEW_BUILD})."
