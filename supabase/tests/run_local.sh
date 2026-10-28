#!/usr/bin/env bash
# run_local.sh [N] — fresh local Postgres 16, apply migrations 001..N, run their tests. Never touches Supabase.
set -euo pipefail
export PATH=/usr/lib/postgresql/16/bin:$PATH
HERE=$(cd "$(dirname "$0")/.." && pwd); D=${PGTEST_DIR:-/tmp/iit_pgtest}; PORT=${PGTEST_PORT:-54331}
pg_ctl -D "$D" stop >/dev/null 2>&1 || true; rm -rf "$D"; mkdir -p "$D"
initdb -D "$D" -U postgres --auth=trust >/dev/null 2>&1
pg_ctl -D "$D" -o "-p $PORT -k $D" -l "$D/log" start >/dev/null; sleep 1.5
P="psql -h $D -p $PORT -U postgres -d iit_local -v ON_ERROR_STOP=1 -q"
psql -h "$D" -p "$PORT" -U postgres -d postgres -q -c "create database iit_local" -c "create role anon nologin" -c "create role authenticated nologin" -c "create role service_role nologin" -c "create role authenticator noinherit login"
# Migrations are applied the way Supabase applies them: by a non-superuser CREATEROLE login (Supabase's `postgres`), never the
# local bootstrap superuser, whose bypass of every membership check hid the 001 SET ROLE failure. Tests still run as superuser.
psql -h "$D" -p "$PORT" -U postgres -d postgres -q -c "create role deployer login nosuperuser createrole inherit" -c "grant create on database iit_local to deployer"
PD="psql -h $D -p $PORT -U deployer -d iit_local -v ON_ERROR_STOP=1 -q"
UPTO=${1:-999}; rc=0
# Migrations carry CLI timestamp versions and no BEGIN/COMMIT (the Supabase runner supplies the transaction), so the
# test number comes from the matching NNN_<name>_test.sql and psql -1 gives each file the same all-or-nothing apply.
for m in "$HERE"/migrations/*.sql; do mn=$(basename "$m" .sql); mn=${mn#*_}
  tfs=("$HERE"/tests/[0-9][0-9][0-9]_"$mn"_test.sql)
  [ ${#tfs[@]} = 1 ] && [ -e "${tfs[0]}" ] || { echo "FAIL   $(basename "$m"): need exactly one tests/NNN_${mn}_test.sql"; rc=1; break; }
  n=$(basename "${tfs[0]}" | cut -c1-3); [ "$n" -le "$UPTO" ] || continue
  if $PD -1 -f "$m" >/dev/null 2>"$D/err"; then echo "APPLY  $(basename "$m")"; else echo "FAIL   $(basename "$m")"; grep -E "ERROR|LINE|DETAIL|CONTEXT" "$D/err" | head -8; rc=1; break; fi
  t="$HERE/tests/${n}_"*_test.sql; for tf in $t; do [ -e "$tf" ] || continue
    if out=$($P -f "$tf" 2>&1); then echo "PASS   $(basename "$tf"): $(echo "$out" | grep -o 'ALL [0-9]* TESTS PASS')"; else echo "FAIL   $(basename "$tf")"; echo "$out" | grep -E "ERROR|LINE|DETAIL" | head -6; rc=1; fi; done
  for sh in "$HERE/tests/${n}_"*_test.sh; do [ -e "$sh" ] || continue
    if out=$(bash "$sh" "$P" 2>&1); then echo "$out" | grep -E '^PASS' || echo "PASS   $(basename "$sh")"; else echo "FAIL   $(basename "$sh")"; echo "$out" | tail -3; rc=1; fi; done
  [ $rc = 0 ] || break
done
# Executor and privilege properties are checked on a second, test-free install, because the 005 tests seed D-40 rows on purpose.
if [ $rc = 0 ] && [ "$UPTO" -ge 999 ]; then
  psql -h "$D" -p "$PORT" -U postgres -d postgres -q -c "create database iit_fresh" -c "grant create on database iit_fresh to deployer"
  for m in "$HERE"/migrations/*.sql; do
    psql -h "$D" -p "$PORT" -U deployer -d iit_fresh -v ON_ERROR_STOP=1 -q -1 -f "$m" >/dev/null 2>"$D/err" || { echo "FAIL   fresh apply $(basename "$m")"; grep -E "ERROR|LINE|DETAIL" "$D/err" | head -6; rc=1; break; }
  done
  if [ $rc = 0 ]; then
    if out=$(psql -h "$D" -p "$PORT" -U postgres -d iit_fresh -v ON_ERROR_STOP=1 -q -f "$HERE/tests/deploy_executor_test.sql" 2>&1); then echo "PASS   deploy_executor_test.sql: $(echo "$out" | grep -o 'ALL EXECUTOR TESTS PASS')"; else echo "FAIL   deploy_executor_test.sql"; echo "$out" | grep -E "ERROR|LINE|DETAIL" | head -6; rc=1; fi
  fi
  # bracketed so this line is not itself a match
  if hits=$(grep -rliE 's2[t]est' "$HERE/migrations" "$HERE/tests"); then echo "FAIL   spike schema named in: $hits"; rc=1; else echo "PASS   no migration or test names the spike schema"; fi
fi
pg_ctl -D "$D" stop >/dev/null 2>&1 || true; exit $rc
