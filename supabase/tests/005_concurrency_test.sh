#!/usr/bin/env bash
# 005_concurrency_test.sh — two-session regressions for §6.1/§6.4 (same barriers as CONC-1: A holds a lock inside an open
# transaction, waits until it observes B blocked via pg_blocking_pids, then commits; only the "B waits on A" interleaving passes).
#  CONC-5a single executor under concurrency: A authorizes key K (granted, uncommitted); B authorizes the same K and blocks on
#          the action row; after A commits, B must get in_progress — exactly one attempt exists.
#  CONC-5b hold vs consume (T56 3/4): A opens a hold (request_reaudit → Deal FOR UPDATE) with a granted attempt outstanding; B's
#          authorize for a NEW key blocks on the Deal lock; after A commits, B is denied 'hold', the outstanding attempt has a
#          gate_unfinished_action work item, and nothing was released.
set -u; P=$1
barrier_case () { # $1 label, $2 A sql, $3 B sql, $4 B query marker
  local AOUT; AOUT=$(mktemp)
  $P -tA -v ON_ERROR_STOP=1 >"$AOUT" 2>&1 <<SQL &
BEGIN;
$2;
DO \$\$ BEGIN RAISE NOTICE 'A_LOCK_HELD'; END \$\$;
DO \$\$ DECLARE i int := 0; n int := 0; BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    SELECT count(*) INTO n FROM pg_stat_activity b WHERE b.pid <> pg_backend_pid() AND b.query ILIKE '%$4%' AND pg_backend_pid() = ANY (pg_blocking_pids(b.pid));
    EXIT WHEN n > 0; i := i + 1; IF i > 100 THEN RAISE EXCEPTION 'BARRIER_TIMEOUT: B never blocked on A'; END IF; PERFORM pg_sleep(0.1);
  END LOOP; RAISE NOTICE 'B_BLOCKED_ON_A'; END \$\$;
COMMIT;
SQL
  local A=$!
  for i in $(seq 1 100); do grep -q 'A_LOCK_HELD' "$AOUT" 2>/dev/null && break; sleep 0.1; done
  grep -q 'A_LOCK_HELD' "$AOUT" || { echo "FAIL   $1 A never reported holding the lock"; cat "$AOUT"; kill $A 2>/dev/null; return 1; }
  BOUT=$($P -tA -c "$3" 2>&1); BRC=$?
  wait $A; local ARC=$?
  if ! grep -q "B_BLOCKED_ON_A" "$AOUT" || [ $ARC -ne 0 ]; then echo "FAIL   $1 barrier: A did not observe B blocked (rc=$ARC)"; cat "$AOUT"; echo "B: rc=$BRC $BOUT"; rm -f "$AOUT"; return 1; fi
  rm -f "$AOUT"; return 0
}
rc=0
# CONC-5a
K='package:IID-300:conc5a'
barrier_case CONC-5a "SELECT iit.authorize_and_consume('$K','IID-300','package','appsheet:31','run-A',NULL,'In-Progress','In-Progress',clock_timestamp())" \
  "SELECT iit.authorize_and_consume('$K','IID-300','package','appsheet:31','run-B',NULL,'In-Progress','In-Progress',clock_timestamp())" "run-B" || rc=1
ATT=$($P -tA -c "SELECT count(*) FROM iit.gated_action_attempts t JOIN iit.gated_actions g ON g.id=t.action_id WHERE g.action_key='$K'")
if [ $rc = 0 ] && printf '%s' "$BOUT" | grep -q '"reason": "in_progress"' && [ "$ATT" = 1 ]; then echo "PASS   CONC-5a B blocked on A's grant for the same key, then got in_progress; exactly 1 attempt"; else echo "FAIL   CONC-5a attempts=$ATT B=$BOUT"; rc=1; fi
# CONC-5b
DEAL=$($P -tA -c "SELECT deal_id FROM iit.source_records WHERE legacy_iid='IID-300' AND kind='initial'")
ACT=$($P -tA -c "SELECT id FROM iit.gated_actions WHERE action_key='package:IID-300:conc'")
barrier_case CONC-5b "SELECT iit.request_reaudit('$DEAL','conc hold','b44-lead')" \
  "SELECT iit.authorize_and_consume('package:IID-300:conc5b','IID-300','package','appsheet:31','run-C',NULL,'In-Progress','In-Progress',clock_timestamp())" "run-C" || rc=1
WI=$($P -tA -c "SELECT count(*) FROM iit.work_items WHERE gated_action_id='$ACT' AND kind='gate_unfinished_action' AND status='open'")
OPEN=$($P -tA -c "SELECT iit.deal_has_open_hold('$DEAL')")
GR=$($P -tA -c "SELECT state FROM iit.gated_action_attempts WHERE action_id='$ACT'")
if [ $rc = 0 ] && printf '%s' "$BOUT" | grep -q '"reason": "hold"' && [ "$WI" = 1 ] && [ "$OPEN" = t ] && [ "$GR" = granted ]; then echo "PASS   CONC-5b B blocked on A's hold, then was denied 'hold'; the outstanding attempt was swept to a work item; hold still open"; else echo "FAIL   CONC-5b wi=$WI open=$OPEN attempt=$GR B=$BOUT"; rc=1; fi
exit $rc
