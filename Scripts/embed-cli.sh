#!/usr/bin/env bash
set -euo pipefail

# Embeds the companion CLI executable inside `<App.app>/Contents/Helpers/<BENTO_CLI_NAME>` (`PLAN.md` §11 T16).
# Works both as an Xcode postBuildScript phase and standalone (`--app <path/to/App.app>`).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SRCROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

APP_BUNDLE=""
CLI_BINARY="${BENTO_PREBUILT_CLI_PATH:-}"
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP_BUNDLE="$2"
            shift 2
            ;;
        --cli-binary)
            CLI_BINARY="$2"
            shift 2
            ;;
        --sign-identity)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

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
    ' "${ROOT_DIR}/Config/Product.xcconfig"
}

CLI_NAME="${BENTO_CLI_NAME:-$(read_xcconfig_key "BENTO_CLI_NAME")}"
ENTITLEMENTS_PATH="${ROOT_DIR}/Config/Bento.entitlements"

if [[ -z "${APP_BUNDLE}" ]]; then
    if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${WRAPPER_NAME:-}" ]]; then
        APP_BUNDLE="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
    elif [[ -n "${TARGET_BUILD_DIR:-}" && -n "${CONTENTS_FOLDER_PATH:-}" ]]; then
        APP_BUNDLE="$(dirname "${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}")"
    else
        echo "ERROR: Provide --app <App.app> or invoke from Xcode build phase." >&2
        exit 1
    fi
fi

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "ERROR: App bundle directory not found at '${APP_BUNDLE}'" >&2
    exit 1
fi

HELPERS_DIR="${APP_BUNDLE}/Contents/Helpers"
mkdir -p "${HELPERS_DIR}"
DEST_BINARY="${HELPERS_DIR}/${CLI_NAME}"

if [[ -z "${CLI_BINARY}" || ! -x "${CLI_BINARY}" ]]; then
    CONFIG_LOWER="$(echo "${CONFIGURATION:-Release}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${CONFIG_LOWER}" != "debug" ]]; then
        SPM_CONFIG="release"
    else
        SPM_CONFIG="debug"
    fi

    ARCH_ARGS=()
    if [[ -n "${ARCHS:-}" ]]; then
        read -r -a ARCH_LIST <<< "${ARCHS}"
        if [[ "${#ARCH_LIST[@]}" -gt 1 ]]; then
            for arch in "${ARCH_LIST[@]}"; do
                ARCH_ARGS+=("--arch" "${arch}")
            done
        elif [[ "${#ARCH_LIST[@]}" -eq 1 && "${ARCH_LIST[0]}" != "$(uname -m)" ]]; then
            ARCH_ARGS+=("--arch" "${ARCH_LIST[0]}")
        fi
    fi

    if [[ "${SPM_CONFIG}" == "debug" && "${#ARCH_ARGS[@]}" -eq 0 && -x "${ROOT_DIR}/.build/debug/${CLI_NAME}" ]]; then
        CLI_BINARY="${ROOT_DIR}/.build/debug/${CLI_NAME}"
    else
        echo "Building ${CLI_NAME} (${SPM_CONFIG}) via SwiftPM for embedding..."
        SPM_COMPAT_ARGS=("-Xswiftc" "-runtime-compatibility-version" "-Xswiftc" "none")
        (
            cd "${ROOT_DIR}"
            swift build -c "${SPM_CONFIG}" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} "${SPM_COMPAT_ARGS[@]}" --product "${CLI_NAME}"
        )
        BIN_DIR="$(cd "${ROOT_DIR}" && swift build -c "${SPM_CONFIG}" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} "${SPM_COMPAT_ARGS[@]}" --show-bin-path)"
        CLI_BINARY="${BIN_DIR}/${CLI_NAME}"
    fi
fi

if [[ ! -x "${CLI_BINARY}" ]]; then
    echo "ERROR: Built CLI binary not found or not executable at '${CLI_BINARY}'" >&2
    exit 1
fi

cp -f "${CLI_BINARY}" "${DEST_BINARY}"
chmod 755 "${DEST_BINARY}"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
    EFFECTIVE_IDENTITY="${SIGN_IDENTITY:--}"
    CODESIGN_ARGS=(--force --options runtime)
    if [[ -f "${ENTITLEMENTS_PATH}" ]]; then
        CODESIGN_ARGS+=(--entitlements "${ENTITLEMENTS_PATH}")
    fi
    if [[ "${EFFECTIVE_IDENTITY}" != "-" ]]; then
        CODESIGN_ARGS+=(--timestamp)
    fi
    /usr/bin/codesign "${CODESIGN_ARGS[@]}" --sign "${EFFECTIVE_IDENTITY}" "${DEST_BINARY}"
fi

echo "Embedded ${CLI_NAME} at ${DEST_BINARY}"
