#!/usr/bin/env bash
# 004_concurrency_test.sh — two-session regression for Codex 004 rev-1 finding 2: ingest_vauto_observation must determine the
# current episode AFTER acquiring the Deal lock. Session A cancels the Deal inside an open transaction (holds the Deal lock),
# waits until it observes B blocked (pg_blocking_pids), then commits. B (a changed observation for the same appraisal) must
# then see the ENDED episode and open a restart_candidate task — not apply the open-episode change flags to a cancelled Deal.
set -u; P=$1
REF=$($P -tA -c "SELECT id FROM iit.external_references WHERE system='vauto_appraisal' AND external_id='APPR-200' AND account_context=''")
DEAL=$($P -tA -c "SELECT deal_id FROM iit.appraisal_episodes WHERE appraisal_ref_id='$REF' AND ended_at IS NULL")
[ -n "$DEAL" ] || { echo "FAIL   CONC-3 fixture deal missing"; exit 1; }
AOUT=$(mktemp)
$P -tA -v ON_ERROR_STOP=1 >"$AOUT" 2>&1 <<SQL &
BEGIN;
SELECT iit.cancel_deal('$DEAL', 'cancelled while an observation arrives', 'b44-de');
DO \$\$ BEGIN RAISE NOTICE 'A_LOCK_HELD'; END \$\$;
DO \$\$ DECLARE i int := 0; n int := 0; BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    SELECT count(*) INTO n FROM pg_stat_activity b WHERE b.pid <> pg_backend_pid() AND b.query ILIKE '%ingest_vauto_observation%' AND pg_backend_pid() = ANY (pg_blocking_pids(b.pid));
    EXIT WHEN n > 0; i := i + 1; IF i > 100 THEN RAISE EXCEPTION 'BARRIER_TIMEOUT: B never blocked on A'; END IF; PERFORM pg_sleep(0.1);
  END LOOP; RAISE NOTICE 'B_BLOCKED_ON_A'; END \$\$;
COMMIT;
SQL
A=$!
for i in $(seq 1 100); do grep -q 'A_LOCK_HELD' "$AOUT" 2>/dev/null && break; sleep 0.1; done
grep -q 'A_LOCK_HELD' "$AOUT" || { echo "FAIL   CONC-3 A never reported holding the lock"; cat "$AOUT"; kill $A 2>/dev/null; exit 1; }
BOUT=$($P -tA -c "SELECT iit.ingest_vauto_observation('APPR-200','', '{\"vehicle\":{\"vin\":\"WAUZZZ8V7JA000200\"},\"appraisal\":{\"value\":5500,\"is_completed\":true},\"customer\":{\"last_name\":\"Race\",\"phone\":\"555-010-0200\"},\"timestamps\":{\"created\":\"2026-10-20T10:00:00Z\"}}', clock_timestamp())" 2>&1); RC=$?
wait $A; ARC=$?
if ! grep -q "B_BLOCKED_ON_A" "$AOUT" || [ $ARC -ne 0 ]; then echo "FAIL   CONC-3 barrier: A did not observe B blocked (rc=$ARC)"; cat "$AOUT"; echo "B: rc=$RC $BOUT"; rm -f "$AOUT"; exit 1; fi
rm -f "$AOUT"
FLAGS=$($P -tA -c "SELECT count(*) FROM iit.intake_flags WHERE deal_id='$DEAL' AND code LIKE 'vauto_mismatch%'")
TASKS=$($P -tA -c "SELECT count(*) FROM iit.work_items WHERE appraisal_ref_id='$REF' AND kind='restart_candidate' AND status='open'")
if [ $RC -eq 0 ] && printf '%s' "$BOUT" | grep -q '"action": "restart_candidate"' && [ "$FLAGS" = 0 ] && [ "$TASKS" = 1 ]; then
  echo "PASS   CONC-3 B blocked on A's cancellation, then re-read the ENDED episode: restart_candidate opened, no change flags on the cancelled Deal"; exit 0; fi
echo "FAIL   CONC-3 rc=$RC flags=$FLAGS tasks=$TASKS out=$BOUT"; exit 1
