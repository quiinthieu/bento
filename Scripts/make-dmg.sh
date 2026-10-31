#!/usr/bin/env bash
set -euo pipefail

# Builds a universal (arm64 + x86_64) macOS `.app` bundle with the companion CLI embedded at
# `<Product.name>.app/Contents/Helpers/<Product.cliName>`, signs with Hardened Runtime
# (Developer ID Application when configured, or ad-hoc "-" locally/CI), and packages a
# compressed UDZO DMG (`PLAN.md` §8, §11 T16).
#
# Usage:
#   Scripts/make-dmg.sh [--output-dir <dir>] [--sign-identity <id>] [--use-swiftpm] [--native-arch-only] [--prefer-hdiutil]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
XCCONFIG_FILE="${ROOT_DIR}/Config/Product.xcconfig"
SIGNING_XCCONFIG_FILE="${ROOT_DIR}/Config/Signing.xcconfig"
ENTITLEMENTS_FILE="${ROOT_DIR}/Config/Bento.entitlements"

OUTPUT_DIR="${ROOT_DIR}/dist"
SIGN_IDENTITY_OVERRIDE=""
FORCE_SWIFTPM=0
NATIVE_ARCH_ONLY=0
PREFER_HDIUTIL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --sign-identity)
            SIGN_IDENTITY_OVERRIDE="$2"
            shift 2
            ;;
        --use-swiftpm)
            FORCE_SWIFTPM=1
            shift
            ;;
        --native-arch-only)
            NATIVE_ARCH_ONLY=1
            shift
            ;;
        --prefer-hdiutil)
            PREFER_HDIUTIL=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--output-dir <dir>] [--sign-identity <id>] [--use-swiftpm] [--native-arch-only] [--prefer-hdiutil]"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

"${SCRIPT_DIR}/bump-version.sh" --verify --root "${ROOT_DIR}"

read_xcconfig_key_from_file() {
    local file="$1"
    local key="$2"
    if [[ ! -f "${file}" ]]; then
        return 0
    fi
    awk -v k="${key}" '
        {
            sub(/\/\/.*$/, "", $0)
            if ($0 ~ "^[[:space:]]*" k "[[:space:]]*=") {
                sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", $0)
                sub(/[[:space:]]+$/, "", $0)
                val = $0
            }
        }
        END {
            if (length(val) > 0) print val
        }
    ' "${file}"
}

read_config_key() {
    local key="$1"
    local override_val=""
    if [[ -f "${SIGNING_XCCONFIG_FILE}" ]]; then
        override_val="$(read_xcconfig_key_from_file "${SIGNING_XCCONFIG_FILE}" "${key}")"
    fi
    if [[ -n "${override_val}" ]]; then
        printf '%s' "${override_val}"
    else
        read_xcconfig_key_from_file "${XCCONFIG_FILE}" "${key}"
    fi
}

PRODUCT_NAME="$(read_config_key "BENTO_PRODUCT_NAME")"
BUNDLE_ID="$(read_config_key "BENTO_BUNDLE_ID")"
CLI_NAME="$(read_config_key "BENTO_CLI_NAME")"
VERSION="$(read_config_key "BENTO_VERSION")"
BUILD_NUMBER="$(read_config_key "BENTO_BUILD_NUMBER")"
MIN_MACOS="$(read_config_key "MACOSX_DEPLOYMENT_TARGET")"
ENABLE_SPARKLE="$(read_config_key "BENTO_ENABLE_SPARKLE")"
RAW_FEED_URL="$(read_config_key "SPARKLE_FEED_URL")"
FEED_URL="${RAW_FEED_URL//\$(BENTO_SLASH)//}"
PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$(read_config_key "SPARKLE_PUBLIC_ED_KEY")}"

if [[ -n "${SIGN_IDENTITY_OVERRIDE}" ]]; then
    SIGN_IDENTITY="${SIGN_IDENTITY_OVERRIDE}"
elif [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="${CODESIGN_IDENTITY}"
else
    SIGN_IDENTITY="$(read_config_key "CODE_SIGN_IDENTITY")"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

if [[ "${NATIVE_ARCH_ONLY}" -eq 1 ]]; then
    HOST_ARCH="$(uname -m)"
    SPM_ARCH_ARGS=("--arch" "${HOST_ARCH}")
    XCODE_ARCHS="${HOST_ARCH}"
    EXPECTED_ARCHS=("${HOST_ARCH}")
else
    SPM_ARCH_ARGS=("--arch" "arm64" "--arch" "x86_64")
    XCODE_ARCHS="arm64 x86_64"
    EXPECTED_ARCHS=("arm64" "x86_64")
fi

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bento-make-dmg.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Target macOS 15+ includes the Swift 6 runtime in the OS; disabling Swift 5.x
# back-deployment compatibility libraries avoids linking arm64-only libswiftCompatibility56.a
# on macOS 26+/27+ SDKs when universal (arm64 + x86_64) builds compile third-party packages.
SPM_COMPAT_ARGS=("-Xswiftc" "-runtime-compatibility-version" "-Xswiftc" "none")

echo "==> Building ${CLI_NAME} (${XCODE_ARCHS}) via SwiftPM..."
(
    cd "${ROOT_DIR}"
    swift build -c release "${SPM_ARCH_ARGS[@]}" "${SPM_COMPAT_ARGS[@]}" --product "${CLI_NAME}"
)
SPM_BIN_DIR="$(cd "${ROOT_DIR}" && swift build -c release "${SPM_ARCH_ARGS[@]}" "${SPM_COMPAT_ARGS[@]}" --show-bin-path)"
BUILT_CLI="${SPM_BIN_DIR}/${CLI_NAME}"

USE_XCODE=0
if [[ "${FORCE_SWIFTPM}" -eq 0 ]] && command -v xcodegen >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
    USE_XCODE=1
fi

FINAL_APP="${OUTPUT_DIR}/${PRODUCT_NAME}.app"
rm -rf "${FINAL_APP}"

if [[ "${USE_XCODE}" -eq 1 ]]; then
    echo "==> Building ${PRODUCT_NAME}.app (${XCODE_ARCHS}) via XcodeGen + xcodebuild..."
    DERIVED_DATA="${WORK_DIR}/DerivedData"
    (
        cd "${ROOT_DIR}"
        xcodegen generate
        BENTO_PREBUILT_CLI_PATH="${BUILT_CLI}" \
        xcodebuild \
            -project Bento.xcodeproj \
            -scheme BentoMacApp \
            -configuration Release \
            -derivedDataPath "${DERIVED_DATA}" \
            ARCHS="${XCODE_ARCHS}" \
            ONLY_ACTIVE_ARCH=NO \
            CODE_SIGNING_ALLOWED=NO \
            build
    )
    XCODE_APP="${DERIVED_DATA}/Build/Products/Release/${PRODUCT_NAME}.app"
    if [[ ! -d "${XCODE_APP}" ]]; then
        echo "ERROR: Expected built app at ${XCODE_APP}" >&2
        exit 1
    fi
    ditto "${XCODE_APP}" "${FINAL_APP}"
    # Ensure the universal CLI binary is embedded in Contents/Helpers.
    CODE_SIGNING_ALLOWED=NO "${SCRIPT_DIR}/embed-cli.sh" \
        --app "${FINAL_APP}" \
        --cli-binary "${BUILT_CLI}"
else
    echo "==> Building ${PRODUCT_NAME}.app (${XCODE_ARCHS}) via SwiftPM universal bundle assembly..."
    (
        cd "${ROOT_DIR}"
        swift build -c release "${SPM_ARCH_ARGS[@]}" "${SPM_COMPAT_ARGS[@]}" --product BentoApp
    )
    BUILT_APP_EXEC="${SPM_BIN_DIR}/BentoApp"
    if [[ ! -x "${BUILT_APP_EXEC}" ]]; then
        echo "ERROR: Built BentoApp binary not found at ${BUILT_APP_EXEC}" >&2
        exit 1
    fi

    mkdir -p \
        "${FINAL_APP}/Contents/MacOS" \
        "${FINAL_APP}/Contents/Helpers" \
        "${FINAL_APP}/Contents/Resources"

    cp -f "${BUILT_APP_EXEC}" "${FINAL_APP}/Contents/MacOS/${PRODUCT_NAME}"
    chmod 755 "${FINAL_APP}/Contents/MacOS/${PRODUCT_NAME}"

    cp -f "${BUILT_CLI}" "${FINAL_APP}/Contents/Helpers/${CLI_NAME}"
    chmod 755 "${FINAL_APP}/Contents/Helpers/${CLI_NAME}"

    # Copy SwiftPM resource bundles into Contents/Resources and ensure valid CFBundle structure.
    shopt -s nullglob
    for res_bundle in "${SPM_BIN_DIR}"/*.bundle; do
        bundle_base="$(basename "${res_bundle}")"
        dest_bundle="${FINAL_APP}/Contents/Resources/${bundle_base}"
        if [[ -f "${res_bundle}/Contents/Info.plist" || -f "${res_bundle}/Info.plist" ]]; then
            ditto "${res_bundle}" "${dest_bundle}"
        else
            # Wrap flat SwiftPM resource directory in standard macOS Contents/{Info.plist,Resources} bundle layout.
            mkdir -p "${dest_bundle}/Contents/Resources"
            ditto "${res_bundle}" "${dest_bundle}/Contents/Resources"
            bundle_stem="${bundle_base%.bundle}"
            safe_id="${BUNDLE_ID}.resources.$(echo "${bundle_stem}" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
            cat > "${dest_bundle}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIdentifier</key>
	<string>${safe_id}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${bundle_stem}</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
</dict>
</plist>
EOF
        fi
    done
    shopt -u nullglob

    printf 'APPL????' > "${FINAL_APP}/Contents/PkgInfo"
    cat > "${FINAL_APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>${PRODUCT_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${PRODUCT_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${PRODUCT_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS}</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Uyen Thieu. Released under the MIT License.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>BentoEnableSparkle</key>
	<string>${ENABLE_SPARKLE}</string>
	<key>SUEnableAutomaticChecks</key>
	<false/>
	<key>SUFeedURL</key>
	<string>${FEED_URL}</string>
	<key>SUPublicEDKey</key>
	<string>${PUBLIC_ED_KEY}</string>
</dict>
</plist>
EOF
fi

# Inside-out Hardened Runtime code signing (never use `codesign --deep` for signing).
echo "==> Signing ${PRODUCT_NAME}.app inside-out with identity '${SIGN_IDENTITY}'..."
COMMON_SIGN_FLAGS=(--force --options runtime)
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    COMMON_SIGN_FLAGS+=(--timestamp)
fi

sign_without_entitlements() {
    local target="$1"
    if [[ -e "${target}" ]]; then
        /usr/bin/codesign "${COMMON_SIGN_FLAGS[@]}" --sign "${SIGN_IDENTITY}" "${target}"
    fi
}

sign_with_app_entitlements() {
    local target="$1"
    /usr/bin/codesign "${COMMON_SIGN_FLAGS[@]}" --entitlements "${ENTITLEMENTS_FILE}" --sign "${SIGN_IDENTITY}" "${target}"
}

SPARKLE_FW="${FINAL_APP}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${SPARKLE_FW}" ]]; then
    sign_without_entitlements "${SPARKLE_FW}/Versions/B/XPCServices/Downloader.xpc"
    sign_without_entitlements "${SPARKLE_FW}/Versions/B/XPCServices/Installer.xpc"
    sign_without_entitlements "${SPARKLE_FW}/Versions/B/Autoupdate"
    sign_without_entitlements "${SPARKLE_FW}/Versions/B/Updater.app"
    sign_without_entitlements "${SPARKLE_FW}"
fi

if [[ -d "${FINAL_APP}/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' dylib; do
        sign_without_entitlements "${dylib}"
    done < <(find "${FINAL_APP}/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print0)
fi

sign_with_app_entitlements "${FINAL_APP}/Contents/Helpers/${CLI_NAME}"
sign_with_app_entitlements "${FINAL_APP}"

echo "==> Verifying architectures, code signature, and embedded CLI execution..."
APP_EXEC="${FINAL_APP}/Contents/MacOS/${PRODUCT_NAME}"
HELPER_EXEC="${FINAL_APP}/Contents/Helpers/${CLI_NAME}"

APP_ARCHS="$(/usr/bin/lipo -archs "${APP_EXEC}")"
CLI_ARCHS="$(/usr/bin/lipo -archs "${HELPER_EXEC}")"
echo "    App architectures: ${APP_ARCHS}"
echo "    CLI architectures: ${CLI_ARCHS}"

for expected_arch in "${EXPECTED_ARCHS[@]}"; do
    if [[ " ${APP_ARCHS} " != *" ${expected_arch} "* ]]; then
        echo "ERROR: ${APP_EXEC} is missing required architecture '${expected_arch}' (got '${APP_ARCHS}')" >&2
        exit 1
    fi
    if [[ " ${CLI_ARCHS} " != *" ${expected_arch} "* ]]; then
        echo "ERROR: ${HELPER_EXEC} is missing required architecture '${expected_arch}' (got '${CLI_ARCHS}')" >&2
        exit 1
    fi
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "${FINAL_APP}"

CLI_VER_OUT="$("${HELPER_EXEC}" --version)"
if [[ "${CLI_VER_OUT}" != "${VERSION}" ]]; then
    echo "ERROR: Embedded CLI --version returned '${CLI_VER_OUT}', expected '${VERSION}'" >&2
    exit 1
fi
"${HELPER_EXEC}" --help >/dev/null

# Stage DMG folder with App + /Applications symlink.
DMG_NAME="${PRODUCT_NAME}-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"
rm -f "${DMG_PATH}" "${DMG_PATH}.sha256"

STAGE_DIR="${WORK_DIR}/dmg-stage"
mkdir -p "${STAGE_DIR}"
ditto "${FINAL_APP}" "${STAGE_DIR}/${PRODUCT_NAME}.app"
ln -s /Applications "${STAGE_DIR}/Applications"

echo "==> Packaging ${DMG_PATH}..."
if [[ "${PREFER_HDIUTIL}" -eq 0 ]] && command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "${PRODUCT_NAME}" \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "${PRODUCT_NAME}.app" 160 190 \
        --app-drop-link 440 190 \
        "${DMG_PATH}" \
        "${STAGE_DIR}" || {
            echo "WARN: create-dmg returned non-zero (headless environment); falling back to hdiutil..."
            rm -f "${DMG_PATH}"
            /usr/bin/hdiutil create \
                -volname "${PRODUCT_NAME}" \
                -srcfolder "${STAGE_DIR}" \
                -ov \
                -format UDZO \
                "${DMG_PATH}"
        }
else
    /usr/bin/hdiutil create \
        -volname "${PRODUCT_NAME}" \
        -srcfolder "${STAGE_DIR}" \
        -ov \
        -format UDZO \
        "${DMG_PATH}"
fi

if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    /usr/bin/codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
fi

shasum -a 256 "${DMG_PATH}" > "${DMG_PATH}.sha256"
echo "==> Built universal DMG: ${DMG_PATH}"
cat "${DMG_PATH}.sha256"
