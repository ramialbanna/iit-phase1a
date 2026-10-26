#!/usr/bin/env bash
# 003_concurrency_test.sh — two-session regressions for Codex 003 rev-1 finding 2 (resolve_work_item must lock, re-read and
# re-authorize). Same barrier technique as 002: A holds the item row lock inside an open transaction, waits until it observes
# B blocked on it (pg_blocking_pids), then commits. Only the "B waits on A" interleaving can pass.
#  CONC-2a: A reassigns the open item to 'admin' (b44-de also holds auditor from the 001 fixtures) while B (data_entry) waits → B must be refused ROLE_MISSING; item stays open.
#  CONC-2b: A closes the item while B waits → B must get WORK_ITEM_NOT_OPEN; exactly one closure, A's outcome kept.
set -u; P=$1
run_case () { # $1 label, $2 item id, $3 A's statement, $4 expected B error, $5 expected status, $6 expected outcome
  local AOUT; AOUT=$(mktemp)
  $P -tA -v ON_ERROR_STOP=1 >"$AOUT" 2>&1 <<SQL &
BEGIN;
SELECT 1 FROM iit.work_items WHERE id='$2' FOR UPDATE;
$3;
DO \$\$ BEGIN RAISE NOTICE 'A_LOCK_HELD'; END \$\$;
DO \$\$ DECLARE i int := 0; n int := 0; BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    SELECT count(*) INTO n FROM pg_stat_activity b WHERE b.pid <> pg_backend_pid() AND b.query ILIKE '%resolve_work_item%' AND pg_backend_pid() = ANY (pg_blocking_pids(b.pid));
    EXIT WHEN n > 0; i := i + 1; IF i > 100 THEN RAISE EXCEPTION 'BARRIER_TIMEOUT: B never blocked on A'; END IF; PERFORM pg_sleep(0.1);
  END LOOP; RAISE NOTICE 'B_BLOCKED_ON_A'; END \$\$;
COMMIT;
SQL
  local A=$!
  for i in $(seq 1 100); do grep -q 'A_LOCK_HELD' "$AOUT" 2>/dev/null && break; sleep 0.1; done
  grep -q 'A_LOCK_HELD' "$AOUT" || { echo "FAIL   $1 A never reported holding the lock"; cat "$AOUT"; kill $A 2>/dev/null; return 1; }
  local BOUT RC; BOUT=$($P -tA -c "SELECT iit.resolve_work_item('$2','B outcome','b44-de')" 2>&1); RC=$?
  wait $A; local ARC=$?
  if ! grep -q "B_BLOCKED_ON_A" "$AOUT" || [ $ARC -ne 0 ]; then echo "FAIL   $1 barrier: A did not observe B blocked (rc=$ARC)"; cat "$AOUT"; echo "B: rc=$RC $BOUT"; rm -f "$AOUT"; return 1; fi
  rm -f "$AOUT"
  local ST; ST=$($P -tA -c "SELECT status || '/' || coalesce(outcome,'-') FROM iit.work_items WHERE id='$2'")
  if [ $RC -ne 0 ] && printf '%s' "$BOUT" | grep -q "$4" && [ "$ST" = "$5/$6" ]; then echo "PASS   $1 B blocked on A's item lock, then re-read and was refused ($4); item is $ST"; return 0; fi
  echo "FAIL   $1 rc=$RC state=$ST out=$BOUT"; return 1
}
rc=0
run_case CONC-2a 00000000-0000-4000-8000-00000000c0a1 "UPDATE iit.work_items SET assigned_role='admin' WHERE id='00000000-0000-4000-8000-00000000c0a1'" "ROLE_MISSING: admin" open - || rc=1
run_case CONC-2b 00000000-0000-4000-8000-00000000c0a2 "SELECT iit.resolve_work_item('00000000-0000-4000-8000-00000000c0a2','A outcome','b44-de')" "WORK_ITEM_NOT_OPEN" closed "A outcome" || rc=1
exit $rc
