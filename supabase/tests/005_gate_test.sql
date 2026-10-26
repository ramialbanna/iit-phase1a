-- 005_gate_test.sql — runs after 001–004 tests. Fixtures reused: d1 (consignment, released, skip_audit, no holds), the APPR-300 deal
-- (risk_audit, v3 released and approved, no holds), e7 (skip_audit, open hold), e5 (risk_audit, open material draft + holds), e6 (cancelled).
\set ON_ERROR_STOP on
\set QUIET on

-- fixtures: 3.1 rows (source_records) for the gate to evaluate
DO $$ DECLARE d1 uuid; d300 uuid; v uuid; BEGIN
  SELECT d.id INTO d1 FROM iit.deals d JOIN iit.vehicles vv ON vv.id = d.vehicle_id WHERE vv.vin_normalized='WAUZZZ8V7JA000010' AND d.origin='manual_consignment';
  SELECT e.deal_id INTO d300 FROM iit.appraisal_episodes e JOIN iit.external_references x ON x.id = e.appraisal_ref_id WHERE x.external_id='APPR-300';
  INSERT INTO iit.source_records(deal_id, legacy_iid, kind, created_via, link_status, linked_at, appsheet_link_confirmed_at) VALUES
    (d1,  'IID-D1',  'initial', 'manual_fallback', 'linked', now(), now()),
    (d300,'IID-300', 'initial', 'manual_fallback', 'linked', now(), now()),
    ('00000000-0000-4000-8000-0000000000e7', 'IID-E7', 'initial', 'manual_fallback', 'linked', now(), now()),
    ('00000000-0000-4000-8000-0000000000e5', 'IID-E5', 'initial', 'manual_fallback', 'linked', now(), now()),
    (d300,'IID-UNC', 'cutover_legacy', 'cutover', 'linked', now(), NULL),
    (NULL,'IID-UNL', 'initial', 'manual_fallback', 'unlinked', NULL, NULL);
  INSERT INTO iit.source_records(deal_id, legacy_iid, kind, created_via, link_status, linked_at, appsheet_link_confirmed_at, status) VALUES (d300, 'IID-RES', 'cutover_legacy', 'cutover', 'linked', now(), now(), 'rescheduled');
  UPDATE iit.source_records SET appsheet_link_confirmed_at = now() WHERE legacy_iid = 'TSTIID0006';   -- e6 (cancelled)
  -- a released Deal on an undecided route (hold_in_data_entry)
  INSERT INTO iit.source_channels(name, route, origin) VALUES ('TEST vAuto Hold', 'hold_in_data_entry', 'vauto_intake');
  INSERT INTO iit.vehicles(id, vin) VALUES ('00000000-0000-4000-8000-0000000000b9', 'WAUZZZ8V7JA000900') RETURNING id INTO v;
  INSERT INTO iit.deals(id, vehicle_id, origin, source_channel_id, consumer_route, purchase_price, intake_status, current_version_no)
    SELECT '00000000-0000-4000-8000-0000000000e9', v, 'vauto_intake', id, route, 1, 'released', 1 FROM iit.source_channels WHERE name = 'TEST vAuto Hold';
  INSERT INTO iit.deal_versions(deal_id, version_no, status, cause, released_at, snapshot, history_watermark) VALUES ('00000000-0000-4000-8000-0000000000e9', 1, 'released', 'intake', now(), '{}', 1);
  INSERT INTO iit.source_records(deal_id, legacy_iid, kind, created_via, link_status, linked_at, appsheet_link_confirmed_at) VALUES ('00000000-0000-4000-8000-0000000000e9', 'IID-HOLD', 'initial', 'manual_fallback', 'linked', now(), now());
END $$;

-- Y1 row_actionable (§6.3; T56 7 and 8)
DO $$ DECLARE r record; BEGIN
  SELECT * INTO r FROM iit.row_actionable('IID-NOPE');  IF r.actionable OR r.reason <> 'unknown_iid'       THEN RAISE EXCEPTION 'Y1a %', r; END IF;
  SELECT * INTO r FROM iit.row_actionable('IID-UNL');   IF r.actionable OR r.reason <> 'unlinked'          THEN RAISE EXCEPTION 'Y1b %', r; END IF;
  SELECT * INTO r FROM iit.row_actionable('IID-UNC');   IF r.actionable OR r.reason <> 'link_unconfirmed'  THEN RAISE EXCEPTION 'Y1c %', r; END IF;
  SELECT * INTO r FROM iit.row_actionable('IID-RES');   IF r.actionable OR r.reason <> 'row_rescheduled'   THEN RAISE EXCEPTION 'Y1d %', r; END IF;
  SELECT * INTO r FROM iit.row_actionable('TSTIID0006');IF r.actionable OR r.reason <> 'deal_cancelled'    THEN RAISE EXCEPTION 'Y1e %', r; END IF;
  SELECT * INTO r FROM iit.row_actionable('IID-E7');    IF r.actionable OR r.reason <> 'hold'              THEN RAISE EXCEPTION 'Y1f %', r; END IF;
  SELECT * INTO r FROM iit.row_actionable('IID-E5');    IF r.actionable OR r.reason <> 'hold'              THEN RAISE EXCEPTION 'Y1g %', r; END IF;
  SELECT * INTO r FROM iit.row_actionable('IID-HOLD');  IF r.actionable OR r.reason <> 'route_hold_in_data_entry' THEN RAISE EXCEPTION 'Y1h %', r; END IF;
  SELECT * INTO r FROM iit.row_actionable('IID-D1');    IF NOT r.actionable OR r.reason <> 'skip_audit' OR r.deal_version <> 1 THEN RAISE EXCEPTION 'Y1i %', r; END IF;
  SELECT * INTO r FROM iit.row_actionable('IID-300');   IF NOT r.actionable OR r.reason <> 'approved' OR r.deal_version <> 3 THEN RAISE EXCEPTION 'Y1j %', r; END IF;
  -- the route is read from source_channels, never from the cache: a stale cache cannot allow
  UPDATE iit.deals SET consumer_route = 'skip_audit' WHERE id = '00000000-0000-4000-8000-0000000000e9';
  SELECT * INTO r FROM iit.row_actionable('IID-HOLD');  IF r.actionable THEN RAISE EXCEPTION 'Y1k cache allowed'; END IF;
  UPDATE iit.deals SET consumer_route = 'hold_in_data_entry' WHERE id = '00000000-0000-4000-8000-0000000000e9';
END $$;

-- Y2 authorize_and_consume: the 3.1 read, denials kept, grant, single executor, key reuse
DO $$ DECLARE r jsonb; a1 uuid; act uuid; BEGIN
  BEGIN PERFORM iit.authorize_and_consume('', 'IID-D1', 'package', 'appsheet:31', 'run-1', NULL, NULL, 'In-Progress', now()); RAISE EXCEPTION 'Y2a'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'GATE_ARGS%' THEN RAISE; END IF; END;
  r := iit.authorize_and_consume('package:IID-D1:v1', 'IID-D1', 'package', 'appsheet:31', 'run-1', 'de@test', 'In-Progress', NULL, NULL);
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'read_31_failed' THEN RAISE EXCEPTION 'Y2b %', r; END IF;
  r := iit.authorize_and_consume('package:IID-D1:v1', 'IID-D1', 'package', 'appsheet:31', 'run-1', 'de@test', 'In-Progress', 'In-Progress', now() - interval '2 minutes');
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'read_31_stale' THEN RAISE EXCEPTION 'Y2c %', r; END IF;
  r := iit.authorize_and_consume('package:IID-D1:v1', 'IID-D1', 'package', 'appsheet:31', 'run-1', 'de@test', 'In-Progress', 'Weird Status', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'status_31_unknown' THEN RAISE EXCEPTION 'Y2d %', r; END IF;
  r := iit.authorize_and_consume('package:IID-D1:v1', 'IID-D1', 'package', 'appsheet:31', 'run-1', 'de@test', 'In-Progress', 'Rescheduled', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'status_31_inactive' THEN RAISE EXCEPTION 'Y2e %', r; END IF;
  act := (r ->> 'action_id')::uuid;
  IF (SELECT state FROM iit.gated_actions WHERE id = act) <> 'denied' OR (SELECT count(*) FROM iit.gated_action_events WHERE action_id = act AND event = 'denied') <> 4 THEN RAISE EXCEPTION 'Y2f denials not kept'; END IF;
  r := iit.authorize_and_consume('package:IID-E7:v3', 'IID-E7', 'package', 'appsheet:31', 'run-1', NULL, 'In-Progress', 'In-Progress', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'hold' THEN RAISE EXCEPTION 'Y2g %', r; END IF;
  r := iit.authorize_and_consume('package:IID-NOPE:v1', 'IID-NOPE', 'package', 'appsheet:31', 'run-1', NULL, 'In-Progress', 'In-Progress', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'unknown_iid' OR (SELECT deal_id FROM iit.gated_actions WHERE id = (r ->> 'action_id')::uuid) IS NOT NULL THEN RAISE EXCEPTION 'Y2h %', r; END IF;
  -- grant after denials (earlier denials stay); caller status mismatch recorded, never decisive
  r := iit.authorize_and_consume('package:IID-D1:v1', 'IID-D1', 'package', 'appsheet:31', 'run-2', 'de@test', 'Same Day Deal', 'In-Progress', now());
  IF NOT (r ->> 'allowed')::boolean OR (r ->> 'replay')::boolean OR (r ->> 'deal_version')::int <> 1 THEN RAISE EXCEPTION 'Y2i %', r; END IF;
  a1 := (r ->> 'attempt_id')::uuid;
  IF (SELECT state || '/' || current_attempt_id::text || '/' || deal_version FROM iit.gated_actions WHERE id = act) <> 'in_progress/' || a1::text || '/1' THEN RAISE EXCEPTION 'Y2j action state'; END IF;
  IF (SELECT attempt_no || '/' || state || '/' || supplied_row_status || '/' || read_31_status FROM iit.gated_action_attempts WHERE id = a1) <> '1/granted/Same Day Deal/In-Progress' THEN RAISE EXCEPTION 'Y2k attempt facts'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.gated_action_events WHERE attempt_id = a1 AND event = 'granted' AND (detail ->> 'status_mismatch')::boolean) THEN RAISE EXCEPTION 'Y2l mismatch not recorded'; END IF;
  -- single executor (T56 5): same run, other run, other integration → in_progress; no second attempt
  r := iit.authorize_and_consume('package:IID-D1:v1', 'IID-D1', 'package', 'appsheet:31', 'run-2', NULL, 'In-Progress', 'In-Progress', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'in_progress' THEN RAISE EXCEPTION 'Y2m same-run replay allowed'; END IF;
  r := iit.authorize_and_consume('package:IID-D1:v1', 'IID-D1', 'package', 'zap:texts', 'zrun-9', NULL, 'In-Progress', 'In-Progress', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'in_progress' OR (SELECT count(*) FROM iit.gated_action_attempts WHERE action_id = act) <> 1 THEN RAISE EXCEPTION 'Y2n second executor'; END IF;
  BEGIN PERFORM iit.authorize_and_consume('package:IID-D1:v1', 'IID-300', 'package', 'appsheet:31', 'run-3', NULL, 'In-Progress', 'In-Progress', now()); RAISE EXCEPTION 'Y2o key reused'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'GATE_KEY_REUSED%' THEN RAISE; END IF; END;
  -- attempt grant facts are immutable; a terminal attempt never changes state
  BEGIN UPDATE iit.gated_action_attempts SET caller_integration = 'zap:texts' WHERE id = a1; RAISE EXCEPTION 'Y2p'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'ATTEMPT_IMMUTABLE%' THEN RAISE; END IF; END;
  IF current_setting('app.actor_kind', true) <> '' THEN RAISE EXCEPTION 'Y2q actor context leaked'; END IF;
END $$;

-- Y3 report_action_outcome: wrong integration (rejected + logged), evidence allowlist, completed → already_completed, failed_definitive → retry, failed_ambiguous → outcome_unknown, conflict, late evidence, Data Entry resolution
DO $$ DECLARE r jsonb; act uuid; a1 uuid; a2 uuid; a3 uuid; a4 uuid; wi uuid; BEGIN
  SELECT id, current_attempt_id INTO act, a1 FROM iit.gated_actions WHERE action_key = 'package:IID-D1:v1';
  r := iit.report_action_outcome(a1, 'completed', '{"package_id":"PK1"}', 'zap:texts', 'zrun-9');
  IF (r ->> 'recorded')::boolean OR r ->> 'result' <> 'wrong_integration' OR (SELECT state FROM iit.gated_actions WHERE id = act) <> 'in_progress' THEN RAISE EXCEPTION 'Y3a %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.gated_action_events WHERE attempt_id = a1 AND event = 'late_report' AND detail ->> 'reason' = 'wrong_integration') THEN RAISE EXCEPTION 'Y3b rejection not logged'; END IF;
  BEGIN PERFORM iit.report_action_outcome(a1, 'completed', '{"package_id":"PK1","raw_payload":"x"}', 'appsheet:31', 'run-2'); RAISE EXCEPTION 'Y3c evidence outside allowlist'; EXCEPTION WHEN SQLSTATE '23514' THEN NULL; END;
  BEGIN PERFORM iit.report_action_outcome(a1, 'done', '{}', 'appsheet:31', 'run-2'); RAISE EXCEPTION 'Y3d bad outcome'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'GATE_OUTCOME%' THEN RAISE; END IF; END;
  -- completed: evidence stored; a new authorize → already_completed (T56 5 "after completion")
  r := iit.report_action_outcome(a1, 'completed', '{"package_id":"PK1"}', 'appsheet:31', 'run-2');
  IF r ->> 'state' <> 'completed' OR (r ->> 'completed_after_hold')::boolean OR (SELECT outcome_evidence ->> 'package_id' FROM iit.gated_actions WHERE id = act) <> 'PK1' THEN RAISE EXCEPTION 'Y3e %', r; END IF;
  r := iit.authorize_and_consume('package:IID-D1:v1', 'IID-D1', 'package', 'appsheet:31', 'run-4', NULL, 'In-Progress', 'In-Progress', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'already_completed' THEN RAISE EXCEPTION 'Y3f %', r; END IF;
  -- a conflicting later report on the finished attempt: kept, action → outcome_unknown + work item; then Data Entry resolves it
  r := iit.report_action_outcome(a1, 'failed_definitive', NULL, 'appsheet:31', 'run-2');
  IF r ->> 'result' <> 'conflict_outcome_unknown' OR (SELECT state FROM iit.gated_actions WHERE id = act) <> 'outcome_unknown' THEN RAISE EXCEPTION 'Y3g %', r; END IF;
  SELECT id INTO wi FROM iit.work_items WHERE gated_action_id = act AND kind = 'gate_conflicting_reports' AND status = 'open';
  IF wi IS NULL THEN RAISE EXCEPTION 'Y3h conflict work item'; END IF;
  r := iit.authorize_and_consume('package:IID-D1:v1', 'IID-D1', 'package', 'appsheet:31', 'run-5', NULL, 'In-Progress', 'In-Progress', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'outcome_unknown' THEN RAISE EXCEPTION 'Y3i unknown outcome retried automatically'; END IF;
  BEGIN PERFORM iit.resolve_unknown_outcome(act, 'completed', '{"package_id":"PK1"}', 'found in carrier portal', 'b44-aud'); RAISE EXCEPTION 'Y3j auditor resolved'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.resolve_unknown_outcome(act, NULL, NULL, 'x', 'b44-de'); RAISE EXCEPTION 'Y3k NULL resolution'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'GATE_RESOLUTION: NULL%' THEN RAISE; END IF; END;
  PERFORM iit.resolve_unknown_outcome(act, 'completed', '{"package_id":"PK1","note":"carrier portal shows one shipment"}', 'found in carrier portal', 'b44-de');
  IF (SELECT state FROM iit.gated_actions WHERE id = act) <> 'completed' OR (SELECT status FROM iit.work_items WHERE id = wi) <> 'closed' THEN RAISE EXCEPTION 'Y3l resolution'; END IF;
  BEGIN PERFORM iit.resolve_unknown_outcome(act, 'failed_definitive', NULL, 'x', 'b44-de'); RAISE EXCEPTION 'Y3m resolved twice'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'GATE_NOT_UNKNOWN%' THEN RAISE; END IF; END;
  -- failed_definitive → the only path to a retry: attempt 2; failed_ambiguous → outcome_unknown, never retried; resolution 'failed_definitive' → attempt 3
  r := iit.authorize_and_consume('text:IID-300:welcome:2026-10-27', 'IID-300', 'text', 'zap:texts', 'z1', NULL, 'In-Progress', 'In-Progress', now());
  a2 := (r ->> 'attempt_id')::uuid; act := (r ->> 'action_id')::uuid;
  IF NOT (r ->> 'allowed')::boolean THEN RAISE EXCEPTION 'Y3n %', r; END IF;
  r := iit.report_action_outcome(a2, 'failed_definitive', '{"http_status":400}', 'zap:texts', 'z1');
  IF r ->> 'state' <> 'failed_definitive' THEN RAISE EXCEPTION 'Y3o'; END IF;
  r := iit.authorize_and_consume('text:IID-300:welcome:2026-10-27', 'IID-300', 'text', 'zap:texts', 'z2', NULL, 'In-Progress', 'In-Progress', now());
  a3 := (r ->> 'attempt_id')::uuid;
  IF NOT (r ->> 'allowed')::boolean OR (SELECT attempt_no FROM iit.gated_action_attempts WHERE id = a3) <> 2 THEN RAISE EXCEPTION 'Y3p retry after definitive failure'; END IF;
  r := iit.report_action_outcome(a3, 'failed_ambiguous', NULL, 'zap:texts', 'z2');
  IF r ->> 'state' <> 'outcome_unknown' OR NOT EXISTS (SELECT 1 FROM iit.work_items WHERE gated_action_id = act AND kind = 'gate_outcome_unknown' AND status = 'open') THEN RAISE EXCEPTION 'Y3q ambiguous'; END IF;
  r := iit.authorize_and_consume('text:IID-300:welcome:2026-10-27', 'IID-300', 'text', 'zap:texts', 'z3', NULL, 'In-Progress', 'In-Progress', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'outcome_unknown' THEN RAISE EXCEPTION 'Y3r ambiguous retried'; END IF;
  -- late evidence for a finished attempt (same outcome): kept, no state change
  r := iit.report_action_outcome(a2, 'failed_definitive', NULL, 'zap:texts', 'z1');
  IF r ->> 'result' <> 'late_evidence' OR (SELECT state FROM iit.gated_actions WHERE id = act) <> 'outcome_unknown' THEN RAISE EXCEPTION 'Y3s late evidence'; END IF;
  PERFORM iit.resolve_unknown_outcome(act, 'failed_definitive', NULL, 'provider log shows no send', 'b44-de');
  r := iit.authorize_and_consume('text:IID-300:welcome:2026-10-27', 'IID-300', 'text', 'zap:texts', 'z4', NULL, 'In-Progress', 'In-Progress', now());
  a4 := (r ->> 'attempt_id')::uuid;
  IF NOT (r ->> 'allowed')::boolean OR (SELECT attempt_no FROM iit.gated_action_attempts WHERE id = a4) <> 3 THEN RAISE EXCEPTION 'Y3t attempt 3 after resolution'; END IF;
  r := iit.report_action_outcome(a4, 'completed', '{"provider_message_id":"SM1"}', 'zap:texts', 'z4');
  -- idempotent-target replay: ONLY when the action is on the proven list (seeded empty; test row added then removed)
  r := iit.authorize_and_consume('dispatch:IID-300:T1', 'IID-300', 'dispatch', 'appsheet:31', 'run-7', NULL, 'In-Progress', 'In-Progress', now());
  a4 := (r ->> 'attempt_id')::uuid;
  r := iit.authorize_and_consume('dispatch:IID-300:T1', 'IID-300', 'dispatch', 'appsheet:31', 'run-8', NULL, 'In-Progress', 'In-Progress', now());
  IF (r ->> 'allowed')::boolean THEN RAISE EXCEPTION 'Y3u replay without proof'; END IF;
  INSERT INTO iit.gate_idempotent_targets VALUES ('dispatch', 'TEST ONLY');
  r := iit.authorize_and_consume('dispatch:IID-300:T1', 'IID-300', 'dispatch', 'appsheet:31', 'run-8', NULL, 'In-Progress', 'In-Progress', now());
  IF NOT (r ->> 'allowed')::boolean OR NOT (r ->> 'replay')::boolean OR (r ->> 'attempt_id')::uuid <> a4 OR (SELECT count(*) FROM iit.gated_action_attempts WHERE action_id = (r ->> 'action_id')::uuid) <> 1 THEN RAISE EXCEPTION 'Y3v replay on proven target: %', r; END IF;
  DELETE FROM iit.gate_idempotent_targets WHERE action = 'dispatch';
  r := iit.report_action_outcome(a4, 'completed', '{"trip_id":"T1"}', 'appsheet:31', 'run-7');
END $$;

-- Y4 timeout (§6.2, T56 5b) and the §6.4 sweep / completed_after_hold (T56 4)
DO $$ DECLARE r jsonb; act uuid; a uuid; n int; h uuid; d300 uuid; c uuid; dec uuid; BEGIN
  SELECT e.deal_id INTO d300 FROM iit.appraisal_episodes e JOIN iit.external_references x ON x.id = e.appraisal_ref_id WHERE x.external_id='APPR-300';
  -- timeout: an unreported attempt becomes outcome_unknown after the setting; a report after that is late evidence
  r := iit.authorize_and_consume('text:IID-300:reminder:2026-10-27', 'IID-300', 'text', 'zap:texts', 'z10', NULL, 'In-Progress', 'In-Progress', now());
  a := (r ->> 'attempt_id')::uuid; act := (r ->> 'action_id')::uuid;
  IF iit.expire_stale_attempts(now() + interval '5 minutes') <> 0 THEN RAISE EXCEPTION 'Y4a expired too early'; END IF;
  n := iit.expire_stale_attempts(now() + interval '11 minutes');
  IF n <> 1 OR (SELECT state FROM iit.gated_actions WHERE id = act) <> 'outcome_unknown' OR (SELECT state FROM iit.gated_action_attempts WHERE id = a) <> 'outcome_unknown'
     OR NOT EXISTS (SELECT 1 FROM iit.work_items WHERE gated_action_id = act AND kind = 'gate_outcome_unknown' AND status = 'open') THEN RAISE EXCEPTION 'Y4b expiry'; END IF;
  r := iit.report_action_outcome(a, 'completed', '{"provider_message_id":"SM9"}', 'zap:texts', 'z10');
  IF r ->> 'result' <> 'late_evidence' OR (SELECT state FROM iit.gated_actions WHERE id = act) <> 'outcome_unknown' THEN RAISE EXCEPTION 'Y4c late report changed state'; END IF;
  -- sweep: a granted attempt exists when a hold opens → work item + swept event; a new authorize is denied; the late completion is flagged
  r := iit.authorize_and_consume('package:IID-300:v3', 'IID-300', 'package', 'appsheet:31', 'run-20', NULL, 'In-Progress', 'In-Progress', now());
  a := (r ->> 'attempt_id')::uuid; act := (r ->> 'action_id')::uuid;
  IF NOT (r ->> 'allowed')::boolean THEN RAISE EXCEPTION 'Y4d %', r; END IF;
  h := iit.request_reaudit(d300, 'spot check', 'b44-lead');
  IF (SELECT count(*) FROM iit.work_items WHERE gated_action_id = act AND kind = 'gate_unfinished_action' AND status = 'open') <> 1 THEN RAISE EXCEPTION 'Y4e sweep: granted attempt not listed'; END IF;
  IF (SELECT count(*) FROM iit.work_items w JOIN iit.gated_actions g ON g.id = w.gated_action_id WHERE w.kind = 'gate_unfinished_action' AND g.action_key = 'text:IID-300:reminder:2026-10-27') <> 1 THEN RAISE EXCEPTION 'Y4f sweep: outcome_unknown action not listed (regardless of age)'; END IF;
  IF (SELECT count(*) FROM iit.work_items w JOIN iit.gated_actions g ON g.id = w.gated_action_id WHERE w.kind = 'gate_unfinished_action' AND g.action_key = 'text:IID-300:welcome:2026-10-27') <> 0 THEN RAISE EXCEPTION 'Y4g sweep listed a completed action'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.gated_action_events WHERE action_id = act AND event = 'swept' AND (detail ->> 'hold_id')::uuid = h) THEN RAISE EXCEPTION 'Y4h swept event'; END IF;
  r := iit.authorize_and_consume('package:IID-300:v3:b', 'IID-300', 'package', 'appsheet:31', 'run-21', NULL, 'In-Progress', 'In-Progress', now());
  IF (r ->> 'allowed')::boolean OR r ->> 'reason' <> 'hold' THEN RAISE EXCEPTION 'Y4i authorized under a hold'; END IF;
  r := iit.report_action_outcome(a, 'completed', '{"package_id":"PK300"}', 'appsheet:31', 'run-20');
  IF NOT (r ->> 'completed_after_hold')::boolean OR NOT (SELECT completed_after_hold FROM iit.gated_actions WHERE id = act)
     OR NOT EXISTS (SELECT 1 FROM iit.work_items WHERE gated_action_id = act AND kind = 'gate_completed_after_hold' AND status = 'open') THEN RAISE EXCEPTION 'Y4j completion after hold not flagged'; END IF;
  -- the hold is released only by the audit decision (sweep released nothing)
  IF NOT iit.deal_has_open_hold(d300) THEN RAISE EXCEPTION 'Y4k sweep released a hold'; END IF;
  c := iit.current_attempt(d300); dec := iit.record_decision(c, 'approved', 'ok', 'b44-aud');
  IF iit.deal_has_open_hold(d300) THEN RAISE EXCEPTION 'Y4l'; END IF;
  r := iit.authorize_and_consume('package:IID-300:v3:b', 'IID-300', 'package', 'appsheet:31', 'run-22', NULL, 'In-Progress', 'In-Progress', now());
  IF NOT (r ->> 'allowed')::boolean THEN RAISE EXCEPTION 'Y4m not actionable after release of the hold: %', r; END IF;
  r := iit.report_action_outcome((r ->> 'attempt_id')::uuid, 'completed', '{"package_id":"PK300b"}', 'appsheet:31', 'run-22');
  IF current_setting('app.actor_kind', true) <> '' THEN RAISE EXCEPTION 'Y4n actor context leaked'; END IF;
END $$;

-- Y5 D-32: a non-two-letter title region is flagged (non-blocking), state left empty; a proper code is not flagged
DO $$ DECLARE r jsonb; d uuid; BEGIN
  r := iit.ingest_vauto_observation('APPR-400','', '{"vehicle":{"vin":"WAUZZZ8V7JA000400"},"appraisal":{"value":1,"is_completed":true},"title":{"region":"Texas"},"timestamps":{"created":"2026-10-20T10:00:00Z"}}');
  d := (r ->> 'deal_id')::uuid;
  IF (SELECT title_state FROM iit.deal_titles WHERE deal_id = d) IS NOT NULL OR (SELECT count(*) FROM iit.intake_flags WHERE deal_id = d AND code = 'vauto_title_region_unmapped' AND NOT blocks_release AND detail = 'Texas') <> 1 THEN RAISE EXCEPTION 'Y5a'; END IF;
  r := iit.ingest_vauto_observation('APPR-401','', '{"vehicle":{"vin":"WAUZZZ8V7JA000401"},"appraisal":{"value":1,"is_completed":true},"title":{"region":"tx"},"timestamps":{"created":"2026-10-20T10:00:00Z"}}');
  d := (r ->> 'deal_id')::uuid;
  IF (SELECT title_state FROM iit.deal_titles WHERE deal_id = d) <> 'TX' OR EXISTS (SELECT 1 FROM iit.intake_flags WHERE deal_id = d AND code = 'vauto_title_region_unmapped') THEN RAISE EXCEPTION 'Y5b'; END IF;
END $$;

-- Y6 D-30 set_consignment
DO $$ DECLARE d1 uuid; d3 uuid; p uuid; q uuid; c uuid; v int; msg text; BEGIN
  SELECT d.id INTO d1 FROM iit.deals d JOIN iit.vehicles vv ON vv.id = d.vehicle_id WHERE vv.vin_normalized='WAUZZZ8V7JA000010' AND d.origin='manual_consignment';
  SELECT party_id INTO p FROM iit.deal_parties WHERE deal_id = d1 AND role = 'owner';
  BEGIN PERFORM iit.set_consignment(d1, p, 9500, NULL, 'b44-de'); RAISE EXCEPTION 'Y6a released consignment changed'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'RELEASED_CONSIGNMENT_UNDECIDED%' THEN RAISE; END IF; END;
  d3 := iit.create_manual_deal('manual_consignment', 'WAUZZZ8V7JA000030', 'Consignment', 'b44-de');
  BEGIN PERFORM iit.set_consignment(d3, p, 100, NULL, 'b44-de'); RAISE EXCEPTION 'Y6b foreign party'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'PARTY_NOT_ON_DEAL%' THEN RAISE; END IF; END;
  q := iit.set_seller_party(d3, 'owner', 1, '{"party_type":"person","first_name":"Con","last_name":"Signor"}', 'b44-de');
  BEGIN PERFORM iit.set_consignment(d3, q, -1, NULL, 'b44-de'); RAISE EXCEPTION 'Y6c negative'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'FIELD_VALUE%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.set_consignment('00000000-0000-4000-8000-0000000000e7', q, 1, NULL, 'b44-de'); RAISE EXCEPTION 'Y6d non-consignment'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'NOT_CONSIGNMENT%' THEN RAISE; END IF; END;
  c := iit.set_consignment(d3, q, 7000, 'wants it gone by Friday', 'b44-de');
  IF (SELECT consignment_id FROM iit.deals WHERE id = d3) <> c OR (SELECT consignment_amount FROM iit.consignments WHERE id = c) <> 7000 THEN RAISE EXCEPTION 'Y6e'; END IF;
  IF iit.set_consignment(d3, q, 7500, NULL, 'b44-de') <> c THEN RAISE EXCEPTION 'Y6f new row instead of update'; END IF;
  IF (SELECT consignment_amount FROM iit.consignments WHERE id = c) <> 7500 THEN RAISE EXCEPTION 'Y6f2 amount not updated'; END IF;
  IF (SELECT purchase_price FROM iit.deals WHERE id = d3) IS NOT NULL THEN RAISE EXCEPTION 'Y6g PR3: amount fed the price'; END IF;
  PERFORM iit.set_deal_fact(d3, 'buyer_id', '"00000000-0000-4000-8000-00000000000a"', 'b44-de'); PERFORM iit.set_deal_fact(d3, 'closer_id', '"00000000-0000-4000-8000-00000000000d"', 'b44-de');
  v := iit.release_deal(d3, 'b44-de'); IF v <> 1 THEN RAISE EXCEPTION 'Y6h'; END IF;
  IF (SELECT snapshot -> 'consignment' ->> 'consignment_amount' FROM iit.deal_versions WHERE deal_id = d3 AND version_no = 1)::numeric <> 7500 THEN RAISE EXCEPTION 'Y6i snapshot'; END IF;
END $$;

-- fixtures for 005_concurrency_test.sh: a granted attempt on IID-300 that will be unfinished when a hold opens (CONC-5b)
DO $$ DECLARE r jsonb; BEGIN
  r := iit.authorize_and_consume('package:IID-300:conc', 'IID-300', 'package', 'appsheet:31', 'run-c0', NULL, 'In-Progress', 'In-Progress', now());
  IF NOT (r ->> 'allowed')::boolean THEN RAISE EXCEPTION 'CONC-5 fixture: %', r; END IF;
END $$;

-- Y7 grants and coverage
DO $$ DECLARE r record; missing text := ''; BEGIN
  IF NOT has_function_privilege('tav_worker','iit.authorize_and_consume(text,text,text,text,text,text,text,text,timestamptz)','EXECUTE') OR NOT has_function_privilege('tav_worker','iit.report_action_outcome(uuid,text,jsonb,text,text)','EXECUTE') OR NOT has_function_privilege('tav_worker','iit.expire_stale_attempts(timestamptz)','EXECUTE') THEN RAISE EXCEPTION 'Y7a'; END IF;
  IF has_function_privilege('tav_worker','iit.resolve_unknown_outcome(uuid,text,jsonb,text,text)','EXECUTE') OR has_function_privilege('tav_worker','iit.set_consignment(uuid,uuid,numeric,text,text)','EXECUTE') OR has_function_privilege('tav_worker','iit.row_actionable(text)','EXECUTE') OR has_function_privilege('tav_worker','iit.open_hold(uuid,text,uuid,uuid,int,uuid)','EXECUTE') THEN RAISE EXCEPTION 'Y7b worker over-privileged'; END IF;
  IF has_function_privilege('iit_integration','iit.authorize_and_consume(text,text,text,text,text,text,text,text,timestamptz)','EXECUTE') OR has_function_privilege('anon','iit.authorize_and_consume(text,text,text,text,text,text,text,text,timestamptz)','EXECUTE') OR has_function_privilege('authenticated','iit.report_action_outcome(uuid,text,jsonb,text,text)','EXECUTE') OR has_table_privilege('tav_worker','iit.gated_actions','SELECT') THEN RAISE EXCEPTION 'Y7c'; END IF;
  IF NOT has_function_privilege('iit_integration','iit.resolve_unknown_outcome(uuid,text,jsonb,text,text)','EXECUTE') OR NOT has_function_privilege('iit_integration','iit.set_consignment(uuid,uuid,numeric,text,text)','EXECUTE') THEN RAISE EXCEPTION 'Y7d'; END IF;
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='iit' AND c.relkind='r' LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c2 ON c2.oid=t.tgrelid JOIN pg_namespace s2 ON s2.oid=c2.relnamespace WHERE s2.nspname='iit' AND c2.relname=r.relname AND t.tgname IN ('zz_history','zz_append_only')) THEN missing := missing || r.relname || ' '; END IF; END LOOP;
  IF missing <> '' THEN RAISE EXCEPTION 'Y7e uncovered: %', missing; END IF;
END $$;

SELECT 'ALL 005 TESTS PASS' AS result;
