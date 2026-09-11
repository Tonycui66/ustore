#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 CASE_DIR" >&2
    exit 2
fi

CASE_DIR="$(cd "$1" && pwd)"
GSQL="${GSQL:-gsql}"
DB="${DB:-postgres}"

for required in setup.sql inject_and_trigger.sql verify.sql; do
    if [[ ! -f "${CASE_DIR}/${required}" ]]; then
        echo "missing case file: ${CASE_DIR}/${required}" >&2
        exit 2
    fi
done

run_sql() {
    "${GSQL}" -X -d "${DB}" -v ON_ERROR_STOP=1 -f "$1"
}

run_sql "${CASE_DIR}/setup.sql"

set +e
"${GSQL}" -X -d "${DB}" -v ON_ERROR_STOP=1 \
    -f "${CASE_DIR}/inject_and_trigger.sql"
trigger_rc=$?
set -e

if [[ "${trigger_rc}" -eq 0 ]]; then
    echo "injected DML unexpectedly succeeded" >&2
    exit 1
fi

if [[ -f "${CASE_DIR}/cleanup.sql" ]]; then
    run_sql "${CASE_DIR}/cleanup.sql"
fi

run_sql "${CASE_DIR}/verify.sql"
echo "USTORE whitebox injection case passed: $(basename "${CASE_DIR}")"
