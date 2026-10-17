#!/bin/sh
# The gate for a no-build repository: data files parse, scripts parse, no secret-shaped strings, the seed
# is current. Run from the repository root:  sh scripts/check.sh   (add --backend for the SQL test leg)
set -eu
cd "$(dirname "$0")/.."
fail=0

echo "[1/4] JSON data files parse"
for f in assets/data/*.json; do
  if python3 -m json.tool "$f" >/dev/null 2>&1; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
done

echo "[2/4] JavaScript parses"
for f in assets/js/*.js; do
  if command -v node >/dev/null 2>&1; then
    if node --check "$f" 2>/dev/null; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
  else
    echo "  skip $f (node not installed)"
  fi
done

echo "[3/4] No secret-shaped strings in tracked files"
# Private keys, service-account files, Supabase service-role keys (by name, and any JWT whose payload
# names the service_role), payment and GitHub tokens. The role name "service_role" alone is legitimate
# SQL (grants to it live in the migrations and the test shim); the Maps browser key and the Supabase anon
# key are client credentials and are allowed (CLAUDE.md, Invariants).
files_z() { git ls-files -z --cached --others --exclude-standard -- . ':!scripts/check.sh'; }
if files_z | xargs -0 grep -nE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|"private_key_id"|service_role_key|SERVICE_ROLE|SUPABASE_SERVICE|sk_live_|ghp_[A-Za-z0-9]{20,}' 2>/dev/null; then
  echo "  FAIL secret-shaped string found (see above)"; fail=1
elif files_z | xargs -0 grep -noE 'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}' 2>/dev/null | python3 -I -c '
import sys, base64, json
bad = 0
for line in sys.stdin:
    where, _, tok = line.rstrip("\n").rpartition(":")
    try:
        payload = tok.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        continue
    if claims.get("role") == "service_role":
        print(f"  {where}: a JWT whose role is service_role"); bad = 1
sys.exit(bad)
'; then
  echo "  ok   none found"
else
  echo "  FAIL secret-shaped string found (see above)"; fail=1
fi

echo "[4/4] Backend seed is current"
if command -v node >/dev/null 2>&1; then
  if node scripts/export-courts-seed.mjs | diff -q - supabase/seed.sql >/dev/null; then echo "  ok   supabase/seed.sql matches courts.json"; else echo "  FAIL supabase/seed.sql is stale: node scripts/export-courts-seed.mjs > supabase/seed.sql"; fail=1; fi
else
  echo "  skip (node not installed)"
fi

if [ "${1:-}" = "--backend" ]; then
  echo "[backend] migrations, RLS and the ported 2021 flows against a throwaway PostgreSQL"
  if bash test/backend/run.sh; then :; else fail=1; fi
fi

if [ "$fail" -ne 0 ]; then echo "GATE FAILED"; exit 1; fi
echo "GATE PASSED"
