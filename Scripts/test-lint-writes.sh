#!/usr/bin/env bash
set -euo pipefail

# Self-test for Scripts/lint-writes.sh (PLAN.md §11 T01 AC):
# Verifies that deliberately adding Data.write (and other forbidden write APIs)
# outside BentoFixes and BentoStore causes lint-writes.sh to fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LINT_SCRIPT="${SCRIPT_DIR}/lint-writes.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cp -R "${REPO_ROOT}/Sources" "${TMP_DIR}/Sources"

# 1. Clean tree must pass.
"${LINT_SCRIPT}" "${TMP_DIR}" >/dev/null

# 2. Deliberately added Data.write in BentoCore must fail.
cat > "${TMP_DIR}/Sources/BentoCore/DeliberateWrite.swift" <<'EOF'
import Foundation

func badWrite(data: Data, url: URL) throws {
    try data.write(to: url)
}
EOF

if "${LINT_SCRIPT}" "${TMP_DIR}" >/dev/null 2>&1; then
    echo "FAIL: lint-writes.sh unexpectedly succeeded with Data.write in BentoCore" >&2
    exit 1
fi
rm -f "${TMP_DIR}/Sources/BentoCore/DeliberateWrite.swift"

# 3. Other forbidden APIs (String.write, FileHandle(forWriting...), createSymbolicLink, trashItem, removeItem) must fail.
for snippet in \
    'try "hi".write(toFile: "/tmp/x", atomically: true, encoding: .utf8)' \
    'let _ = try FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/x"))' \
    'try FileManager.default.createSymbolicLink(atPath: "/tmp/a", withDestinationPath: "/tmp/b")' \
    'try FileManager.default.trashItem(at: URL(fileURLWithPath: "/tmp/x"), resultingItemURL: nil)' \
    'try FileManager.default.removeItem(atPath: "/tmp/x")'
do
    cat > "${TMP_DIR}/Sources/BentoScanner/DeliberateViolation.swift" <<EOF
import Foundation

func violation() throws {
    ${snippet}
}
EOF
    if "${LINT_SCRIPT}" "${TMP_DIR}" >/dev/null 2>&1; then
        echo "FAIL: lint-writes.sh unexpectedly succeeded for snippet: ${snippet}" >&2
        exit 1
    fi
    rm -f "${TMP_DIR}/Sources/BentoScanner/DeliberateViolation.swift"
done

# 4. Writes inside BentoFixes and BentoStore must remain allowed.
cat > "${TMP_DIR}/Sources/BentoFixes/AllowedFixWrite.swift" <<'EOF'
import Foundation

func allowedFixWrite(data: Data, url: URL) throws {
    try data.write(to: url, options: .atomic)
}
EOF

cat > "${TMP_DIR}/Sources/BentoStore/AllowedStoreWrite.swift" <<'EOF'
import Foundation

func allowedStoreDir(url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}
EOF

"${LINT_SCRIPT}" "${TMP_DIR}" >/dev/null

echo "OK: lint-writes.sh self-tests passed."
