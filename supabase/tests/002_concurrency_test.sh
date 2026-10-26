#!/usr/bin/env bash
# 002_concurrency_test.sh — two-session regression for Codex 002 finding 1 (re-read after lock). Invoked by run_local.sh with
# $1 = psql connection prefix. Session A locks the Deal and supersedes the current attempt inside a held transaction; session B
# starts record_decision on the OLD attempt while A holds the lock; after A commits, B must see the superseded state and reject.
set -u; P=$1
DEAL=00000000-0000-4000-8000-0000000000e3
OLD=$($P -tA -c "SELECT iit.current_attempt('$DEAL')")
[ -n "$OLD" ] || { echo "CONC: no current attempt"; exit 1; }
$P -tA -c "BEGIN; SELECT 1 FROM iit.deals WHERE id='$DEAL' FOR UPDATE; SELECT iit.create_audit_attempt('$DEAL','00000000-0000-4000-8000-00000000000b'); SELECT pg_sleep(3); COMMIT;" >/dev/null 2>&1 &
A=$!; sleep 0.7
OUT=$($P -tA -c "SELECT iit.record_decision('$OLD','approved','stale caller','b44-aud')" 2>&1); RC=$?
wait $A
if [ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q "DECISION_REJECTED: attempt $OLD is superseded"; then
  ST=$($P -tA -c "SELECT status FROM iit.prequalification_checks WHERE id='$OLD'")
  [ "$ST" = superseded ] && { echo "PASS   CONC-1 waiting record_decision re-read the superseded attempt and rejected (status stays $ST)"; exit 0; }
  echo "FAIL   CONC-1 status changed to $ST"; exit 1
fi
echo "FAIL   CONC-1 record_decision rc=$RC out=$OUT"; exit 1
