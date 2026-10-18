#!/usr/bin/env bash
# The local stand-in stack for two-browser tests: a throwaway PostgreSQL (shim + every migration +
# seed, via test/backend/run.sh KEEP=1), the local PostgREST/GoTrue stand-in (local-backend.py) and
# a static server for the page. No Docker, no Supabase project, nothing written to assets/js/config.js.
#
#   sh test/e2e/local-stack.sh start    # prints OC_SUPABASE_URL / OC_SUPABASE_ANON_KEY / OC_PAGE_URL
#   sh test/e2e/local-stack.sh status
#   sh test/e2e/local-stack.sh stop     # kills page, backend, cluster (in that order) and removes the cluster
#
# Ports (override by env): OC_PGPORT 54410, OC_BACKEND_PORT 54400, OC_PAGE_PORT 8020.
# PGBIN: PostgreSQL 16 server binaries (default /usr/lib/postgresql/16/bin or the newest found).
# State lives in test/e2e/.stack/ (gitignored): pids, logs, pg.env, urls.env.
# Bash is needed (arrays); re-exec when started as `sh`.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STACK="$ROOT/test/e2e/.stack"
OC_PGPORT=${OC_PGPORT:-54410}
OC_BACKEND_PORT=${OC_BACKEND_PORT:-54400}
OC_PAGE_PORT=${OC_PAGE_PORT:-8020}
OC_ANON_KEY=${OC_ANON_KEY:-local-anon}
if [ -z "${PGBIN:-}" ]; then
  if [ -x /usr/lib/postgresql/16/bin/initdb ]; then PGBIN=/usr/lib/postgresql/16/bin;
  elif command -v pg_ctl >/dev/null 2>&1; then PGBIN=$(dirname "$(command -v pg_ctl)");
  else PGBIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true); fi
fi
export PGBIN
# node for the seed check inside run.sh; curl to 127.0.0.1 must not go through a proxy.
[ -d /opt/node22/bin ] && PATH="/opt/node22/bin:$PATH"
export no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}" NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
pid_of() { [ -f "$STACK/$1.pid" ] && cat "$STACK/$1.pid" || true; }
wait_http() { # url tries
  local i=0
  while [ $i -lt "${2:-50}" ]; do
    curl -fsS -o /dev/null "$1" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

start() {
  if [ -f "$STACK/pg.env" ]; then
    echo "local-stack: $STACK/pg.env exists — a stack is up or was not stopped; run: sh test/e2e/local-stack.sh stop" >&2
    exit 1
  fi
  if [ -z "$PGBIN" ] || [ ! -x "$PGBIN/initdb" ]; then
    echo "local-stack: PostgreSQL server binaries not found (set PGBIN)" >&2; exit 1
  fi
  mkdir -p "$STACK"

  echo "== cluster (shim, migrations, seed) on port $OC_PGPORT"
  KEEP=1 PGPORT="$OC_PGPORT" PGBIN="$PGBIN" bash "$ROOT/test/backend/run.sh" > "$STACK/cluster.log" 2>&1 || {
    echo "local-stack: cluster start failed:" >&2; tail -20 "$STACK/cluster.log" >&2; rm -rf "$STACK"; exit 1; }
  keep=$(grep -E '^KEEP ' "$STACK/cluster.log" | tail -1 | sed 's/^KEEP //')
  [ -n "$keep" ] || { echo "local-stack: run.sh printed no KEEP line" >&2; tail -20 "$STACK/cluster.log" >&2; exit 1; }
  printf '%s\n' $keep > "$STACK/pg.env"          # PGHOST=… PGPORT=… PGDATA=… PGBIN=… WORK=… PGDATABASE=… PGUSER=…
  # shellcheck disable=SC1090
  . "$STACK/pg.env"
  grep -E '^== ' "$STACK/cluster.log" | sed 's/^/   /'

  echo "== local-backend on http://127.0.0.1:$OC_BACKEND_PORT"
  PGHOST="$PGHOST" PGPORT="$PGPORT" PGDATABASE="$PGDATABASE" PGUSER="$PGUSER" PSQL="$PGBIN/psql" \
    OC_BACKEND_PORT="$OC_BACKEND_PORT" OC_ANON_KEY="$OC_ANON_KEY" \
    python3 -I "$ROOT/test/e2e/local-backend.py" > "$STACK/backend.log" 2>&1 &
  echo $! > "$STACK/backend.pid"
  if ! wait_http "http://127.0.0.1:$OC_BACKEND_PORT/auth/v1/health" 50; then
    echo "local-stack: local-backend did not answer:" >&2; tail -20 "$STACK/backend.log" >&2; stop; exit 1
  fi

  echo "== page on http://127.0.0.1:$OC_PAGE_PORT"
  # Loopback only: the directory served is the repository root (.git/, working/ included), and the
  # backend and the proof address 127.0.0.1 anyway; http.server would otherwise bind every interface.
  python3 -m http.server "$OC_PAGE_PORT" --bind 127.0.0.1 --directory "$ROOT" >/dev/null 2>&1 &
  echo $! > "$STACK/page.pid"
  if ! wait_http "http://127.0.0.1:$OC_PAGE_PORT/index.html" 50; then
    echo "local-stack: the page server did not answer on $OC_PAGE_PORT" >&2; stop; exit 1
  fi

  {
    echo "OC_SUPABASE_URL=http://127.0.0.1:$OC_BACKEND_PORT"
    echo "OC_SUPABASE_ANON_KEY=$OC_ANON_KEY"
    echo "OC_PAGE_URL=http://127.0.0.1:$OC_PAGE_PORT/"
  } > "$STACK/urls.env"
  echo
  echo "Stack is up. Route the page's assets/js/config.js to these values (never edit the file):"
  cat "$STACK/urls.env"
  echo "Logs: $STACK/backend.log (one line per request), $STACK/cluster.log"
}

stop() {
  local p
  p=$(pid_of page);    if alive "$p"; then kill "$p" 2>/dev/null || true; echo "stopped page ($p)"; fi
  p=$(pid_of backend); if alive "$p"; then kill "$p" 2>/dev/null || true; echo "stopped local-backend ($p)"; fi
  if [ -f "$STACK/pg.env" ]; then
    # shellcheck disable=SC1090
    . "$STACK/pg.env"
    RUNAS=()
    if [ "$(id -u)" = 0 ]; then RUNAS=(runuser -u "${PG_USER:-ubuntu}" --); fi
    "${RUNAS[@]}" "$PGBIN/pg_ctl" -D "$PGDATA" stop -m immediate >/dev/null 2>&1 && echo "stopped cluster ($PGDATA)" || true
    case "$WORK" in /tmp/opencourt-pg.*) rm -rf "$WORK" ;; esac
  fi
  rm -rf "$STACK"
}

status() {
  local p up=0
  [ -d "$STACK" ] || { echo "local-stack: not started"; return 1; }
  p=$(pid_of page);    if alive "$p"; then echo "page         up  pid $p  http://127.0.0.1:$OC_PAGE_PORT/"; up=$((up+1)); else echo "page         down"; fi
  p=$(pid_of backend); if alive "$p"; then echo "local-backend up  pid $p  http://127.0.0.1:$OC_BACKEND_PORT  ($(curl -fsS "http://127.0.0.1:$OC_BACKEND_PORT/auth/v1/health" 2>/dev/null || echo 'not answering'))"; up=$((up+1)); else echo "local-backend down"; fi
  if [ -f "$STACK/pg.env" ]; then
    # shellcheck disable=SC1090
    . "$STACK/pg.env"
    if "$PGBIN/pg_isready" -h "$PGHOST" -p "$PGPORT" -q 2>/dev/null; then echo "cluster      up  $PGHOST:$PGPORT  db $PGDATABASE"; up=$((up+1)); else echo "cluster      down ($PGHOST:$PGPORT)"; fi
  else
    echo "cluster      down (no pg.env)"
  fi
  [ -f "$STACK/urls.env" ] && cat "$STACK/urls.env"
  [ $up -eq 3 ]
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) echo "usage: sh test/e2e/local-stack.sh start|stop|status" >&2; exit 2 ;;
esac
