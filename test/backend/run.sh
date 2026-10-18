#!/usr/bin/env bash
# The backend test leg. Starts a throwaway PostgreSQL cluster, applies the Supabase shim, every
# migration under supabase/migrations/ and the seed, runs test/backend/t_*.sql in order, and tears
# the cluster down. Exit code 0 only if every assertion passed.
#
# Needs the PostgreSQL server binaries (16+; set PGBIN if they are not on PATH) and, when run as
# root, an unprivileged user to own the server process (PG_USER, default: ubuntu).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
if [ -z "${PGBIN:-}" ]; then
  if command -v pg_ctl >/dev/null 2>&1; then PGBIN=$(dirname "$(command -v pg_ctl)");
  else PGBIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true); fi
fi
if [ -z "$PGBIN" ] || [ ! -x "$PGBIN/initdb" ]; then
  echo "backend tests: PostgreSQL server binaries not found (set PGBIN); skipping" >&2
  exit "${REQUIRE_BACKEND:+1}0"
fi

WORK=$(mktemp -d /tmp/opencourt-pg.XXXXXX)
PORT=${PGPORT:-54329}
RUNAS=()
if [ "$(id -u)" = 0 ]; then
  PG_USER=${PG_USER:-ubuntu}
  chown -R "$PG_USER" "$WORK"
  RUNAS=(runuser -u "$PG_USER" --)
fi
cleanup() {
  "${RUNAS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/data" "$WORK/s"
[ ${#RUNAS[@]} -gt 0 ] && chown -R "$PG_USER" "$WORK"
"${RUNAS[@]}" "$PGBIN/initdb" -D "$WORK/data" -U postgres -A trust --no-locale -E UTF8 >"$WORK/initdb.log" 2>&1
"${RUNAS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -o "-k $WORK/s -p $PORT -c listen_addresses=''" -l "$WORK/server.log" -w start >/dev/null

PSQL=(psql -h "$WORK/s" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q -X)
"${PSQL[@]}" -d postgres -c "create database opencourt_test" >/dev/null

echo "== shim"
"${PSQL[@]}" -d opencourt_test -f "$ROOT/test/backend/shim.sql"
for m in "$ROOT"/supabase/migrations/*.sql; do
  echo "== migration $(basename "$m")"
  "${PSQL[@]}" -d opencourt_test -f "$m" 2>&1 | grep -E 'NOTICE' | sed 's/^psql:[^:]*:[0-9]*: //' || true
done

echo "== seed"
node "$ROOT/scripts/export-courts-seed.mjs" > "$WORK/seed.sql"
if ! diff -q "$WORK/seed.sql" "$ROOT/supabase/seed.sql" >/dev/null 2>&1; then
  echo "FAIL: supabase/seed.sql is out of date; run: node scripts/export-courts-seed.mjs > supabase/seed.sql" >&2
  exit 1
fi
"${PSQL[@]}" -d opencourt_test -f "$ROOT/supabase/seed.sql"

# KEEP=1 (used by test/e2e/local-stack.sh): stop here and leave the seeded cluster running as the
# database of the local Supabase stand-in. No test file runs, nothing is torn down, and one line
# says where the cluster is; the caller stops it (pg_ctl stop) and removes WORK. Without KEEP the
# script behaves exactly as before.
if [ -n "${KEEP:-}" ]; then
  trap - EXIT
  echo "KEEP PGHOST=$WORK/s PGPORT=$PORT PGDATA=$WORK/data PGBIN=$PGBIN WORK=$WORK PGDATABASE=opencourt_test PGUSER=postgres"
  exit 0
fi

status=0
passed=0
for t in "$ROOT"/test/backend/t_*.sql; do
  echo "== $(basename "$t")"
  log="$WORK/$(basename "$t").log"
  if "${PSQL[@]}" -d opencourt_test -f "$t" >"$log" 2>&1; then
    n=$(grep -c 'NOTICE:  ok' "$log" || true)
    passed=$((passed + n))
    [ -n "${VERBOSE:-}" ] && sed -E 's/^psql:[^:]*:[0-9]+: //; s/^NOTICE:  //' "$log" | grep -E '^ok' || true
    echo "   $n assertions passed"
  else
    status=1
    echo "FAILED: $(basename "$t")" >&2
    sed -E 's/^psql:[^:]*:[0-9]+: //' "$log" | grep -E '^(ERROR|DETAIL|HINT|CONTEXT|NOTICE:  ok)' | tail -12 >&2
  fi
done

if [ $status -eq 0 ]; then echo "BACKEND TESTS PASSED ($passed assertions)"; else echo "BACKEND TESTS FAILED" >&2; fi
exit $status
