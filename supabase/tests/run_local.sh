#!/usr/bin/env bash
# run_local.sh [N] — fresh local Postgres 16, apply migrations 001..N, run their tests. Never touches Supabase.
set -euo pipefail
export PATH=/usr/lib/postgresql/16/bin:$PATH
HERE=$(cd "$(dirname "$0")/.." && pwd); D=${PGTEST_DIR:-/tmp/iit_pgtest}; PORT=${PGTEST_PORT:-54331}
pg_ctl -D "$D" stop >/dev/null 2>&1 || true; rm -rf "$D"; mkdir -p "$D"
initdb -D "$D" -U postgres --auth=trust >/dev/null 2>&1
pg_ctl -D "$D" -o "-p $PORT -k $D" -l "$D/log" start >/dev/null; sleep 1.5
P="psql -h $D -p $PORT -U postgres -d iit_local -v ON_ERROR_STOP=1 -q"
psql -h "$D" -p "$PORT" -U postgres -d postgres -q -c "create database iit_local" -c "create role anon nologin" -c "create role authenticated nologin" -c "create role service_role nologin"
UPTO=${1:-999}; rc=0
for m in "$HERE"/migrations/*.sql; do n=$(basename "$m" | cut -c1-3); [ "$n" -le "$UPTO" ] || continue
  if $P -f "$m" >/dev/null 2>"$D/err"; then echo "APPLY  $(basename "$m")"; else echo "FAIL   $(basename "$m")"; grep -E "ERROR|LINE|DETAIL|CONTEXT" "$D/err" | head -8; rc=1; break; fi
  t="$HERE/tests/${n}_"*_test.sql; for tf in $t; do [ -e "$tf" ] || continue
    if out=$($P -f "$tf" 2>&1); then echo "PASS   $(basename "$tf"): $(echo "$out" | grep -o 'ALL [0-9]* TESTS PASS')"; else echo "FAIL   $(basename "$tf")"; echo "$out" | grep -E "ERROR|LINE|DETAIL" | head -6; rc=1; fi; done
  for sh in "$HERE/tests/${n}_"*_test.sh; do [ -e "$sh" ] || continue
    if out=$(bash "$sh" "$P" 2>&1); then echo "$out" | grep -E '^PASS' || echo "PASS   $(basename "$sh")"; else echo "FAIL   $(basename "$sh")"; echo "$out" | tail -3; rc=1; fi; done
  [ $rc = 0 ] || break
done
pg_ctl -D "$D" stop >/dev/null 2>&1 || true; exit $rc
