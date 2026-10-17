#!/bin/sh
# The gate for a no-build repository: data files parse, scripts parse, no secret-shaped strings.
# Run from the repository root:  sh scripts/check.sh
set -eu
cd "$(dirname "$0")/.."
fail=0

echo "[1/3] JSON data files parse"
for f in assets/data/*.json; do
  if python3 -m json.tool "$f" >/dev/null 2>&1; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
done

echo "[2/3] JavaScript parses"
for f in assets/js/*.js; do
  if command -v node >/dev/null 2>&1; then
    if node --check "$f" 2>/dev/null; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
  else
    echo "  skip $f (node not installed)"
  fi
done

echo "[3/3] No secret-shaped strings in tracked files"
# Service-account keys, private keys, Supabase service-role JWTs, generic bearer tokens.
if git ls-files -z --cached --others --exclude-standard -- . ':!scripts/check.sh' | xargs -0 grep -nE 'BEGIN (RSA |EC )?PRIVATE KEY|"private_key_id"|service_role|SUPABASE_SERVICE|sk_live_|ghp_[A-Za-z0-9]{20,}' 2>/dev/null; then
  echo "  FAIL secret-shaped string found (see above)"; fail=1
else
  echo "  ok   none found"
fi

if [ "$fail" -ne 0 ]; then echo "GATE FAILED"; exit 1; fi
echo "GATE PASSED"
