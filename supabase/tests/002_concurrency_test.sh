#!/usr/bin/env bash
# 002_concurrency_test.sh — two-session regression for Codex 002 finding 1 (re-read after the Deal lock), with a real barrier:
# session A locks the Deal and supersedes the current attempt, then WAITS (inside its open transaction) until it observes
# session B blocked on A's lock (pg_blocking_pids) before committing. If B never blocks, A raises and the test fails —
# so a pass proves B was waiting on A, not merely started after A committed. Barrier 1 (A_LOCK_HELD) also prevents B from
# running BEFORE A takes the lock. Both orderings are therefore excluded; only the interleaving under test can pass.
set -u; P=$1
DEAL=00000000-0000-4000-8000-0000000000e3
OLD=$($P -tA -c "SELECT iit.current_attempt('$DEAL')"); [ -n "$OLD" ] || { echo "CONC: no current attempt"; exit 1; }
AOUT=$(mktemp)
$P -tA -v ON_ERROR_STOP=1 >"$AOUT" 2>&1 <<SQL &
BEGIN;
SELECT 1 FROM iit.deals WHERE id='$DEAL' FOR UPDATE;
SELECT iit.create_audit_attempt('$DEAL','00000000-0000-4000-8000-00000000000b');
DO \$\$ BEGIN RAISE NOTICE 'A_LOCK_HELD'; END \$\$;
DO \$\$ DECLARE i int := 0; n int := 0; BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();   -- pg_stat_activity is snapshot-stable inside a transaction; refresh each iteration
    SELECT count(*) INTO n FROM pg_stat_activity b
     WHERE b.pid <> pg_backend_pid() AND b.query ILIKE '%record_decision%' AND pg_backend_pid() = ANY (pg_blocking_pids(b.pid));
    EXIT WHEN n > 0; i := i + 1; IF i > 100 THEN RAISE EXCEPTION 'BARRIER_TIMEOUT: B never blocked on A'; END IF; PERFORM pg_sleep(0.1);
  END LOOP; RAISE NOTICE 'B_BLOCKED_ON_A'; END \$\$;
COMMIT;
SQL
A=$!
# barrier 1: do not start B until A reports it holds the lock (so B cannot run first)
for i in $(seq 1 100); do grep -q 'A_LOCK_HELD' "$AOUT" 2>/dev/null && break; sleep 0.1; done
grep -q 'A_LOCK_HELD' "$AOUT" || { echo "FAIL   CONC-1 A never reported holding the lock"; cat "$AOUT"; kill $A 2>/dev/null; exit 1; }
BOUT=$($P -tA -c "SELECT iit.record_decision('$OLD','approved','stale caller','b44-aud')" 2>&1); RC=$?
wait $A; ARC=$?
if ! grep -q "B_BLOCKED_ON_A" "$AOUT" || [ $ARC -ne 0 ]; then echo "FAIL   CONC-1 barrier: A did not observe B blocked (rc=$ARC)"; cat "$AOUT"; echo "B: rc=$RC $BOUT"; rm -f "$AOUT"; exit 1; fi
rm -f "$AOUT"
ST=$($P -tA -c "SELECT status FROM iit.prequalification_checks WHERE id='$OLD'")
if [ $RC -ne 0 ] && printf '%s' "$BOUT" | grep -q "DECISION_REJECTED: attempt $OLD is superseded" && [ "$ST" = superseded ]; then
  echo "PASS   CONC-1 B was blocked on A's Deal lock (observed via pg_blocking_pids), then re-read the superseded attempt and rejected; status stays $ST"; exit 0; fi
echo "FAIL   CONC-1 rc=$RC status=$ST out=$BOUT"; exit 1
