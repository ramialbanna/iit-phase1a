#!/usr/bin/env bash
# 009_concurrency_test.sh — a concurrent state change cannot pass the expected-state gate. Same barrier technique as 003: A
# holds the Deal lock inside an open transaction and waits until it observes B blocked on it (pg_blocking_pids), then commits.
# B was handed the token A also started from, so B is only correct if it recomputes the token AFTER the lock is released.
#  CONC-9a: A changes the deal (set_deal_fact with the current token) while B waits to release it → B must be refused
#           STALE_STATE and the deal must stay unreleased.
#  CONC-9b: A only holds the lock (no change) while B waits → B's token is still current, so B must succeed (no false conflict).
set -u; P=$1
K=00000000-0000-4000-8009-0000000000cc
run_case () { # $1 label, $2 A's statement, $3 expected B outcome (STALE_STATE | OK), $4 expected latest released version
  local T; T=$($P -tA -c "SELECT iit._deal_state_token('$K')")
  local A_SQL; A_SQL=${2//@TOKEN@/$T}
  local AOUT; AOUT=$(mktemp)
  $P -tA -v ON_ERROR_STOP=1 >"$AOUT" 2>&1 <<SQL &
BEGIN;
SELECT 1 FROM iit.deals WHERE id='$K' FOR UPDATE;
$A_SQL;
DO \$\$ BEGIN RAISE NOTICE 'A_LOCK_HELD'; END \$\$;
DO \$\$ DECLARE i int := 0; n int := 0; BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    SELECT count(*) INTO n FROM pg_stat_activity b WHERE b.pid <> pg_backend_pid() AND b.query ILIKE '%release_deal%' AND pg_backend_pid() = ANY (pg_blocking_pids(b.pid));
    EXIT WHEN n > 0; i := i + 1; IF i > 100 THEN RAISE EXCEPTION 'BARRIER_TIMEOUT: B never blocked on A'; END IF; PERFORM pg_sleep(0.1);
  END LOOP; RAISE NOTICE 'B_BLOCKED_ON_A'; END \$\$;
COMMIT;
SQL
  local A=$!
  for i in $(seq 1 100); do grep -q 'A_LOCK_HELD' "$AOUT" 2>/dev/null && break; sleep 0.1; done
  grep -q 'A_LOCK_HELD' "$AOUT" || { echo "FAIL   $1 A never reported holding the lock"; cat "$AOUT"; kill $A 2>/dev/null; return 1; }
  local BOUT RC; BOUT=$($P -tA -c "SELECT iit.release_deal('$K', '$T', 'b44-9-de')" 2>&1); RC=$?
  wait $A; local ARC=$?
  if ! grep -q "B_BLOCKED_ON_A" "$AOUT" || [ $ARC -ne 0 ]; then echo "FAIL   $1 barrier: A did not observe B blocked (rc=$ARC)"; cat "$AOUT"; echo "B: rc=$RC $BOUT"; rm -f "$AOUT"; return 1; fi
  rm -f "$AOUT"
  local REL; REL=$($P -tA -c "SELECT coalesce(iit.latest_released_version('$K')::text, 'none')")
  if [ "$3" = STALE_STATE ] && [ $RC -ne 0 ] && printf '%s' "$BOUT" | grep -q "STALE_STATE" && [ "$REL" = "$4" ]; then
    echo "PASS   $1 B blocked on A's Deal lock, recomputed the token after A committed and was refused STALE_STATE; released=$REL"; return 0; fi
  if [ "$3" = OK ] && [ $RC -eq 0 ] && [ "$REL" = "$4" ]; then
    echo "PASS   $1 B blocked on A's Deal lock; A changed nothing, so B's token was still current and the release succeeded; released=$REL"; return 0; fi
  echo "FAIL   $1 rc=$RC released=$REL out=$BOUT"; return 1
}
rc=0
run_case CONC-9a "SELECT iit.set_deal_fact('$K', 'dealer_sold_to', '\"A wins\"', '@TOKEN@', 'b44-9-de')" STALE_STATE none || rc=1
run_case CONC-9b "SELECT 1" OK 1 || rc=1
exit $rc
