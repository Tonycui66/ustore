#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GSQL="${GSQL:-gsql}"
GS_CTL="${GS_CTL:-gs_ctl}"
DB="${DB:-postgres}"
SESSION_PID=""

if [[ "${ALLOW_DESTRUCTIVE_RECOVERY:-0}" != "1" ]]; then
    echo "Refusing to run: set ALLOW_DESTRUCTIVE_RECOVERY=1 on a disposable instance." >&2
    exit 2
fi
if [[ -z "${PGDATA:-}" ]]; then
    echo "PGDATA must point to the disposable openGauss data directory." >&2
    exit 2
fi
if ! command -v "${GSQL}" >/dev/null 2>&1; then
    echo "gsql executable not found: ${GSQL}" >&2
    exit 127
fi
if ! command -v "${GS_CTL}" >/dev/null 2>&1; then
    echo "gs_ctl executable not found: ${GS_CTL}" >&2
    exit 127
fi

cleanup() {
    if [[ -n "${SESSION_PID}" ]] && kill -0 "${SESSION_PID}" >/dev/null 2>&1; then
        kill "${SESSION_PID}" >/dev/null 2>&1 || true
        wait "${SESSION_PID}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

run_sql() {
    "${GSQL}" -X -d "${DB}" -v ON_ERROR_STOP=1 -f "$1"
}

wait_ready() {
    for _ in $(seq 1 120); do
        if "${GSQL}" -X -At -d "${DB}" -c "select 1" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "database did not become ready after restart" >&2
    return 1
}

restart_immediate() {
    "${GS_CTL}" stop -D "${PGDATA}" -m immediate
    "${GS_CTL}" start -D "${PGDATA}"
    wait_ready
}

echo "==> committed DML crash recovery"
run_sql "${SCRIPT_DIR}/13_prepare_committed.sql"
restart_immediate
run_sql "${SCRIPT_DIR}/13_verify_committed.sql"
run_sql "${SCRIPT_DIR}/13_post_recovery_write.sql"

echo "==> uncommitted transaction crash recovery"
"${GSQL}" -X -d "${DB}" -v ON_ERROR_STOP=1 \
    -f "${SCRIPT_DIR}/13_prepare_uncommitted.sql" \
    >/tmp/ustore_recovery_uncommitted.log 2>&1 &
SESSION_PID=$!

transaction_started=false
for _ in $(seq 1 60); do
    if ! kill -0 "${SESSION_PID}" >/dev/null 2>&1; then
        echo "uncommitted recovery session exited before the crash" >&2
        cat /tmp/ustore_recovery_uncommitted.log >&2
        exit 1
    fi

    active="$(
        "${GSQL}" -X -At -d "${DB}" \
            -c "select count(*) from pg_stat_activity where application_name = 'ustore_recovery_uncommitted' and state = 'active'"
    )"
    if [[ "${active}" -gt 0 ]]; then
        transaction_started=true
        break
    fi
    sleep 0.1
done

if [[ "${transaction_started}" != true ]]; then
    echo "timed out waiting for the uncommitted transaction" >&2
    exit 1
fi

restart_immediate
if kill -0 "${SESSION_PID}" >/dev/null 2>&1; then
    kill "${SESSION_PID}" >/dev/null 2>&1 || true
fi
wait "${SESSION_PID}" >/dev/null 2>&1 || true
SESSION_PID=""
run_sql "${SCRIPT_DIR}/13_verify_uncommitted.sql"

echo "USTORE crash recovery passed."
