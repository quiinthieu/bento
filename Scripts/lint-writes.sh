#!/usr/bin/env bash
set -euo pipefail

# Enforces PLAN.md §0 Rule 3:
# Only Sources/BentoFixes and Sources/BentoStore may write, symlink, remove, or trash files.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SOURCES_DIR="${ROOT_DIR}/Sources"

if [[ ! -d "${SOURCES_DIR}" ]]; then
    echo "ERROR: Sources directory not found at ${SOURCES_DIR}" >&2
    exit 1
fi

FORBIDDEN_REGEX='(\.write[[:space:]]*\([[:space:]]*to(File)?[[:space:]]*:|\b(Data|String|NSData|NSString)\.write\b|\bFileHandle[[:space:]]*\([[:space:]]*for(Writing|Updating)|\b(createFile|createDirectory|createSymbolicLink|trashItem|removeItem|moveItem|copyItem|replaceItem|replaceItemAt|linkItem|setAttributes)[[:space:]]*\(|\bOutputStream[[:space:]]*\([[:space:]]*(toFileAtPath|url)[[:space:]]*:)'

violations=0

scan_file() {
    local file="$1"
    # Strip trailing // single-line comments before matching to avoid doc-comment false positives.
    local matches
    matches="$(awk '{
        line = $0
        sub(/\/\/.*$/, "", line)
        printf "%d:%s\n", NR, line
    }' "${file}" | grep -E "${FORBIDDEN_REGEX}" || true)"

    if [[ -n "${matches}" ]]; then
        while IFS= read -r match; do
            echo "ERROR: Forbidden write API in ${file}:${match}" >&2
            violations=$((violations + 1))
        done <<< "${matches}"
    fi
}

while IFS= read -r -d '' swift_file; do
    case "${swift_file}" in
        "${SOURCES_DIR}/BentoFixes/"*|"${SOURCES_DIR}/BentoStore/"*)
            continue
            ;;
    esac
    scan_file "${swift_file}"
done < <(find "${SOURCES_DIR}" -type f -name '*.swift' -print0)

if [[ -d "${ROOT_DIR}/XcodeApp" ]]; then
    while IFS= read -r -d '' swift_file; do
        scan_file "${swift_file}"
    done < <(find "${ROOT_DIR}/XcodeApp" -type f -name '*.swift' -print0)
fi

if [[ "${violations}" -gt 0 ]]; then
    echo "FAILED: Found ${violations} forbidden write API call(s) outside BentoFixes/BentoStore." >&2
    exit 1
fi

echo "OK: No forbidden write APIs found outside BentoFixes/BentoStore."
