#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GSQL="${GSQL:-gsql}"
DB="${DB:-postgres}"
TMP_DIR="$(mktemp -d)"
A_PID=""

cleanup() {
    if [[ -n "${A_PID}" ]] && kill -0 "${A_PID}" >/dev/null 2>&1; then
        kill "${A_PID}" >/dev/null 2>&1 || true
        wait "${A_PID}" >/dev/null 2>&1 || true
    fi
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

run_sql() {
    "${GSQL}" -X -d "${DB}" -v ON_ERROR_STOP=1 -f "$1"
}

run_sql "${SCRIPT_DIR}/08_setup.sql"

"${GSQL}" -X -d "${DB}" -v ON_ERROR_STOP=1 \
    -f "${SCRIPT_DIR}/08_session_a.sql" >"${TMP_DIR}/session_a.log" 2>&1 &
A_PID=$!

advisory_held=false
for _ in $(seq 1 50); do
    if ! kill -0 "${A_PID}" >/dev/null 2>&1; then
        echo "session A exited before acquiring the advisory lock" >&2
        cat "${TMP_DIR}/session_a.log" >&2
        exit 1
    fi

    held="$(
        "${GSQL}" -X -At -d "${DB}" \
            -c "select count(*) from pg_locks where locktype = 'advisory' and objid = 918081 and granted"
    )"
    if [[ "${held:-0}" -gt 0 ]]; then
        advisory_held=true
        break
    fi
    sleep 0.1
done

if [[ "${advisory_held}" != true ]]; then
    echo "timed out waiting for session A to acquire the row lock" >&2
    exit 1
fi

set +e
"${GSQL}" -X -d "${DB}" -v ON_ERROR_STOP=1 \
    -f "${SCRIPT_DIR}/08_session_b_expect_timeout.sql" \
    >"${TMP_DIR}/session_b_timeout.log" 2>&1
timeout_rc=$?
set -e

if [[ "${timeout_rc}" -eq 0 ]]; then
    echo "session B unexpectedly acquired the row lock before session A committed" >&2
    exit 1
fi
if ! grep -Eq '55P03|lock timeout|canceling statement due to lock timeout' \
    "${TMP_DIR}/session_b_timeout.log"; then
    echo "session B failed for a reason other than lock timeout" >&2
    cat "${TMP_DIR}/session_b_timeout.log" >&2
    exit 1
fi

wait "${A_PID}"
A_PID=""

run_sql "${SCRIPT_DIR}/08_session_b_retry.sql"
run_sql "${SCRIPT_DIR}/08_verify.sql"

echo "USTORE concurrency passed."
