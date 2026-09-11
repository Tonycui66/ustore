#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GSQL="${GSQL:-gsql}"
DB="${DB:-postgres}"

if ! command -v "${GSQL}" >/dev/null 2>&1; then
    echo "gsql executable not found: ${GSQL}" >&2
    exit 127
fi

for test_file in "${SCRIPT_DIR}"/regression/[0-9][0-9]_*.sql; do
    if [[ "${USTORE_WHITEBOX:-0}" != "1" && "$(basename "${test_file}")" == "12_fault_injection_whitebox.sql" ]]; then
        echo "==> $(basename "${test_file}") (skipped: set USTORE_WHITEBOX=1 after arming the stub)"
        continue
    fi

    echo "==> $(basename "${test_file}")"
    "${GSQL}" -X -d "${DB}" -v ON_ERROR_STOP=1 -f "${test_file}"
done

echo "USTORE regression passed."
