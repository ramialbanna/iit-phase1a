-- 004_intake_test.sql — runs after 001–003 tests (fixtures: b44-admin a, b44-de d [data_entry+auditor], b44-aud b, b44-lead c; deals e5 (risk_audit,
-- open material draft v7, hold H5 open), e6/e8 cancelled, e7 (skip_audit, v2 released, hold covers 2 still open from before 004)).
\set ON_ERROR_STOP on
\set QUIET on

-- X1 D-20: deposit_amount is administrative after release — amendment, no draft/hold change, approval unaffected
DO $$ DECLARE no int; holds int; BEGIN
  SELECT count(*) INTO holds FROM iit.audit_holds WHERE deal_id='00000000-0000-4000-8000-0000000000e5';
  no := iit.amend_field('00000000-0000-4000-8000-0000000000e5','deposit_amount','600','receipt shows 600','b44-de');
  IF (SELECT deposit_amount FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e5') <> 600 OR (SELECT count(*) FROM iit.audit_holds WHERE deal_id='00000000-0000-4000-8000-0000000000e5') <> holds THEN RAISE EXCEPTION 'X1a'; END IF;
  IF (SELECT field || ':' || coalesce(before::text,'null') || '>' || after::text FROM iit.deal_amendments WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND amendment_no = no AND version_no = iit.latest_released_version('00000000-0000-4000-8000-0000000000e5')) <> 'deposit_amount:500.00>600.00' THEN RAISE EXCEPTION 'X1b amendment row'; END IF;
  BEGIN PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e5','deposit_amount','700','x','b44-de'); RAISE EXCEPTION 'X1c deposit treated as material'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'NOT_MATERIAL%' THEN RAISE; END IF; END;
END $$;

-- X2 D-25a: skip-audit route — the release of the corrected version releases the hold it covers; the guard admits nothing else
DO $$ DECLARE corr uuid; h8 uuid; h7 uuid; v int; BEGIN
  SELECT id INTO h7 FROM iit.audit_holds WHERE deal_id='00000000-0000-4000-8000-0000000000e7' AND released_at IS NULL;   -- pre-004 hold, covers v2 (already released): stays open, documented
  corr := iit.correct_field('00000000-0000-4000-8000-0000000000e7','purchase_price','9100','auction invoice','b44-de');
  SELECT id INTO h8 FROM iit.audit_holds WHERE correction_id = corr;
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e7','b44-de'); IF v <> 3 THEN RAISE EXCEPTION 'X2a'; END IF;
  IF (SELECT released_at IS NULL OR released_by_version_no <> 3 OR released_by_decision_id IS NOT NULL FROM iit.audit_holds WHERE id = h8) THEN RAISE EXCEPTION 'X2b hold not released by the release'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.audit_hold_events WHERE hold_id = h8 AND event = 'released' AND to_version_no = 3 AND check_id IS NULL) THEN RAISE EXCEPTION 'X2c released event'; END IF;
  IF (SELECT released_at FROM iit.audit_holds WHERE id = h7) IS NOT NULL THEN RAISE EXCEPTION 'X2d pre-existing hold covering an older version was released'; END IF;
  IF NOT (SELECT on_hold FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e7') THEN RAISE EXCEPTION 'X2e on_hold cache (H7 still open)'; END IF;
  -- guard: version path refused on the Risk Audit route (e5's open hold), on a non-covering version, on a non-released version, with both references, and immutable once set
  BEGIN UPDATE iit.audit_holds SET released_at = now(), released_by_version_no = covers_version_no WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND released_at IS NULL AND cause='material_correction' AND covers_version_no = 5; RAISE EXCEPTION 'X2f risk_audit hold released by version'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_RELEASE_BY_VERSION: deal % is on route risk_audit%' THEN RAISE; END IF; END;
  BEGIN UPDATE iit.audit_holds SET released_at = now(), released_by_version_no = 3 WHERE id = h7; RAISE EXCEPTION 'X2g non-covering version accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_RELEASE_BY_VERSION: v3 is not the covering version v2%' THEN RAISE; END IF; END;
  BEGIN UPDATE iit.audit_holds SET released_at = now(), released_by_version_no = 3, released_by_decision_id = (SELECT id FROM iit.audit_decisions LIMIT 1) WHERE id = h7; RAISE EXCEPTION 'X2h both references accepted'; EXCEPTION WHEN check_violation THEN NULL; WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_RELEASE%' THEN RAISE; END IF; END;
  BEGIN UPDATE iit.audit_holds SET released_by_version_no = 2 WHERE id = h8; RAISE EXCEPTION 'X2i released reference changed'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_RELEASE_IMMUTABLE%' THEN RAISE; END IF; END;
  BEGIN INSERT INTO iit.audit_holds(deal_id, cause, opened_by, released_at, released_by_version_no) VALUES ('00000000-0000-4000-8000-0000000000e7','reaudit_request','00000000-0000-4000-8000-00000000000d', now(), 3); RAISE EXCEPTION 'X2j inserted released'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_INSERT_RELEASED%' THEN RAISE; END IF; END;
  -- the decision path still works exactly as in 002/003 (e5: a cancel-free Risk Audit deal is exercised in 003 W4/W5)
END $$;

-- X3 manual Deals and draft editing
DO $$ DECLARE d1 uuid; d2 uuid; p uuid; v int; msg text; BEGIN
  BEGIN PERFORM iit.create_manual_deal('vauto_intake','WAUZZZ8V7JA000010','Consignment','b44-de'); RAISE EXCEPTION 'X3a'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'ORIGIN_INVALID%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.create_manual_deal('manual_consignment','WAUZZZ8V7JA000010','Brown Fig – ACV','b44-de'); RAISE EXCEPTION 'X3b'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'CHANNEL_ORIGIN_MISMATCH%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.create_manual_deal('manual_consignment','WAUZZZ8V7JA000010','Consignment','b44-aud'); RAISE EXCEPTION 'X3c'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  d1 := iit.create_manual_deal('manual_consignment',' wauzzz8v7ja000010 ','Consignment','b44-de');
  IF (SELECT v.vin_normalized || '/' || d.origin || '/' || d.consumer_route || '/' || d.intake_status FROM iit.deals d JOIN iit.vehicles v ON v.id = d.vehicle_id WHERE d.id = d1) <> 'WAUZZZ8V7JA000010/manual_consignment/skip_audit/new' THEN RAISE EXCEPTION 'X3d deal state'; END IF;
  IF iit.open_draft_version(d1) <> 1 THEN RAISE EXCEPTION 'X3e draft v1'; END IF;
  d2 := iit.create_manual_deal('manual_exception','WAUZZZ8V7JA000010','Brown Fig – Manheim','b44-de');   -- same VIN → same vehicle row
  IF (SELECT vehicle_id FROM iit.deals WHERE id = d2) <> (SELECT vehicle_id FROM iit.deals WHERE id = d1) THEN RAISE EXCEPTION 'X3f vehicle not reused'; END IF;
  BEGIN PERFORM iit.set_deal_fact(d1,'purchase_price','1000','b44-de'); RAISE EXCEPTION 'X3g consignment price accepted (G8)'; EXCEPTION WHEN check_violation THEN NULL; END;
  PERFORM iit.set_deal_fact(d1,'buyer_id','"00000000-0000-4000-8000-00000000000a"','b44-de');
  PERFORM iit.set_deal_fact(d1,'closer_id','"00000000-0000-4000-8000-00000000000d"','b44-de');
  BEGIN PERFORM iit.set_seller_party(d1,'owner',1,'{"first_name":"No","street":"1 Main St"}','b44-de'); RAISE EXCEPTION 'X3h street accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'PARTY_PATCH: key street%' THEN RAISE; END IF; END;
  p := iit.set_seller_party(d1,'owner',1,'{"party_type":"person","first_name":"Cora","last_name":"Consignor","phone":"(555) 010-0010"}','b44-de');
  IF (SELECT phone_normalized FROM iit.seller_parties WHERE id = p) <> '5550100010' THEN RAISE EXCEPTION 'X3i party'; END IF;
  IF iit.set_seller_party(d1,'owner',1,'{"party_type":"person","last_name":"Consignor-Smith"}','b44-de') <> p THEN RAISE EXCEPTION 'X3j replace kept the same party row'; END IF;
  BEGIN PERFORM iit.release_deal(d1,'b44-de'); RAISE EXCEPTION 'X3k'; EXCEPTION WHEN OTHERS THEN msg := SQLERRM; IF msg <> 'RELEASE_REFUSED: missing required facts: consignor' THEN RAISE EXCEPTION 'X3k: %', msg; END IF; END;
  INSERT INTO iit.consignments(deal_id, consignor_party_id, consignment_amount) VALUES (d1, p, 9000);   -- D-30: no consignment function yet
  v := iit.release_deal(d1,'b44-de'); IF v <> 1 THEN RAISE EXCEPTION 'X3l'; END IF;
  BEGIN PERFORM iit.set_deal_fact(d1,'dealer_sold_to','"X"','b44-de'); RAISE EXCEPTION 'X3m draft edit after release'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'RELEASED_USE_CORRECTIONS%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.set_seller_party(d1,'owner',1,'{"party_type":"person"}','b44-de'); RAISE EXCEPTION 'X3n party set after release'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'RELEASED_USE_CORRECTIONS%' THEN RAISE; END IF; END;
  IF current_setting('app.actor_kind', true) <> '' THEN RAISE EXCEPTION 'X3o actor context leaked'; END IF;
END $$;

-- X4 vAuto intake (Worker): first completion, unchanged, change flags, cancelled episode → restart only on a transition, restart decision
INSERT INTO iit.external_user_map(system, external_username, user_id) VALUES ('vauto','rami.b','00000000-0000-4000-8000-00000000000a');
DO $$ DECLARE r jsonb; r2 jsonb; deal uuid; deal2 uuid; item uuid; ref uuid; n int; BEGIN
  -- allowlist still enforced on the body
  BEGIN PERFORM iit.ingest_vauto_observation('APPR-100','', '{"vehicle":{"vin":"WAUZZZ8V7JA000100"},"lien":{"accountNumber":"1"}}'); RAISE EXCEPTION 'X4a account number stored'; EXCEPTION WHEN SQLSTATE '23514' THEN NULL; END;
  -- not completed: recorded, nothing created
  r := iit.ingest_vauto_observation('APPR-100','', '{"vehicle":{"vin":"WAUZZZ8V7JA000100","year":2019,"make":"Audi","model":"A4"},"appraisal":{"value":14500,"is_completed":false},"timestamps":{"created":"2026-10-20T10:00:00Z"}}');
  IF r ->> 'outcome' <> 'stored' OR r ->> 'action' <> 'none' OR r ? 'deal_id' AND r ->> 'deal_id' IS NOT NULL THEN RAISE EXCEPTION 'X4b incomplete created something: %', r; END IF;
  IF EXISTS (SELECT 1 FROM iit.vehicles WHERE vin_normalized='WAUZZZ8V7JA000100') THEN RAISE EXCEPTION 'X4b2 vehicle created before completion'; END IF;
  -- completion: Deal + episode 1 + facts
  r := iit.ingest_vauto_observation('APPR-100','', '{"vehicle":{"vin":"WAUZZZ8V7JA000100","year":2019,"make":"Audi","model":"A4"},"appraisal":{"value":14500,"is_completed":true},
     "personnel":{"buyer":"rami.b","closer":"nobody.x"},"customer":{"first_name":"Ann","last_name":"Seller","phone":"555-010-0100","city":"Dallas","state":"TX"},
     "title":{"region":"FL"},"lien":{"owner":"Big Bank","phone":"555-1","payoff":"12000.50","payoff_date":"2026-11-01","per_diem":"4.10"},"timestamps":{"created":"2026-10-20T10:00:00Z","completed":"2026-10-21T09:00:00Z"}}');
  deal := (r ->> 'deal_id')::uuid;
  IF r ->> 'action' <> 'created' OR deal IS NULL THEN RAISE EXCEPTION 'X4c: %', r; END IF;
  IF (SELECT d.origin || '/' || d.purchase_price || '/' || coalesce(d.buyer_id::text,'-') || '/' || coalesce(d.closer_id::text,'-') FROM iit.deals d WHERE d.id = deal) <> 'vauto_intake/14500.00/00000000-0000-4000-8000-00000000000a/-' THEN RAISE EXCEPTION 'X4d deal facts'; END IF;
  IF (SELECT sp.phone_normalized || '/' || sp.last_name || '/' || sp.state FROM iit.deal_parties dp JOIN iit.seller_parties sp ON sp.id = dp.party_id WHERE dp.deal_id = deal AND dp.role='owner') <> '5550100100/Seller/TX' THEN RAISE EXCEPTION 'X4e owner'; END IF;
  IF (SELECT position || '/' || lienholder_name_raw || '/' || payoff_amount || '/' || source FROM iit.deal_liens WHERE deal_id = deal) <> 'lien/Big Bank/12000.50/vauto' THEN RAISE EXCEPTION 'X4f lien'; END IF;
  IF (SELECT title_state FROM iit.deal_titles WHERE deal_id = deal) <> 'FL' OR (SELECT count(*) FROM iit.deal_report_requirements WHERE deal_id = deal AND version_no = 1 AND report_type='FL_DMV') <> 1 THEN RAISE EXCEPTION 'X4g title / requirement'; END IF;
  IF (SELECT episode_no || '/' || start_basis FROM iit.appraisal_episodes e JOIN iit.external_references x ON x.id = e.appraisal_ref_id WHERE x.external_id='APPR-100' AND e.deal_id = deal) <> '1/first_completion' THEN RAISE EXCEPTION 'X4h episode'; END IF;
  IF (SELECT count(*) FROM iit.intake_flags WHERE deal_id = deal AND code='vauto_closer_unmapped' AND NOT blocks_release) <> 1 OR EXISTS (SELECT 1 FROM iit.intake_flags WHERE deal_id = deal AND code='vauto_buyer_unmapped') THEN RAISE EXCEPTION 'X4i personnel flags'; END IF;
  -- attribution: the Worker's writes are 'worker' / service user, never a human
  IF (SELECT actor_kind || '/' || changed_by::text FROM iit.record_history WHERE table_name='deals' AND record_id = deal AND op='I') <> 'worker/00000000-0000-4000-8000-00000000f00d' THEN RAISE EXCEPTION 'X4j attribution'; END IF;
  -- unchanged content: nothing (invariant 15); a different account_context is a different reference
  r2 := iit.ingest_vauto_observation('APPR-100','', (SELECT body FROM iit.vauto_observations o JOIN iit.external_references x ON x.id = o.appraisal_ref_id WHERE x.external_id='APPR-100' ORDER BY seq DESC LIMIT 1));
  IF r2 ->> 'outcome' <> 'unchanged' OR (SELECT count(*) FROM iit.vauto_observations o JOIN iit.external_references x ON x.id = o.appraisal_ref_id WHERE x.external_id='APPR-100') <> 2 THEN RAISE EXCEPTION 'X4k unchanged: %', r2; END IF;
  IF (SELECT count(*) FROM iit.external_references WHERE external_id='APPR-100') <> 1 THEN RAISE EXCEPTION 'X4k2'; END IF;
  -- open episode, changed price and phone → blocking change flags, one per code
  r := iit.ingest_vauto_observation('APPR-100','', '{"vehicle":{"vin":"WAUZZZ8V7JA000100"},"appraisal":{"value":14000,"is_completed":true},"customer":{"first_name":"Ann","last_name":"Seller","phone":"555-010-0199"},"timestamps":{"created":"2026-10-20T10:00:00Z"}}');
  IF r ->> 'action' <> 'updated' OR (r ->> 'flags')::int <> 2 THEN RAISE EXCEPTION 'X4l: %', r; END IF;
  IF (SELECT string_agg(code, ',' ORDER BY code) FROM iit.intake_flags WHERE deal_id = deal AND status='open' AND blocks_release) <> 'vauto_mismatch_customer,vauto_mismatch_price' THEN RAISE EXCEPTION 'X4m flags'; END IF;
  r := iit.ingest_vauto_observation('APPR-100','', '{"vehicle":{"vin":"WAUZZZ8V7JA000100"},"appraisal":{"value":13900,"is_completed":true},"customer":{"first_name":"Ann","last_name":"Seller","phone":"555-010-0199"},"timestamps":{"created":"2026-10-20T10:00:00Z"}}');
  IF (r ->> 'flags')::int <> 0 OR (SELECT count(*) FROM iit.intake_flags WHERE deal_id = deal AND code='vauto_mismatch_price' AND status='open') <> 1 THEN RAISE EXCEPTION 'X4n duplicate flag'; END IF;
  IF (SELECT purchase_price FROM iit.deals WHERE id = deal) <> 14500 THEN RAISE EXCEPTION 'X4o update path changed the Deal'; END IF;
  -- cancelled episode: an UNCHANGED observation never creates a task; a transition creates exactly one; later evidence joins it
  PERFORM iit.cancel_deal(deal, 'customer backed out', 'b44-de');
  r := iit.ingest_vauto_observation('APPR-100','', '{"vehicle":{"vin":"WAUZZZ8V7JA000100"},"appraisal":{"value":13900,"is_completed":true},"customer":{"first_name":"Ann","last_name":"Seller","phone":"555-010-0199"},"timestamps":{"created":"2026-10-20T10:00:00Z"}}', now() + interval '1 minute');
  IF r ->> 'outcome' <> 'unchanged' OR EXISTS (SELECT 1 FROM iit.work_items WHERE deal_id = deal AND kind='restart_candidate') THEN RAISE EXCEPTION 'X4p task from an unchanged appraisal'; END IF;
  r := iit.ingest_vauto_observation('APPR-100','', '{"vehicle":{"vin":"WAUZZZ8V7JA000100"},"appraisal":{"value":15000,"is_completed":true},"customer":{"first_name":"Ann","last_name":"Seller","phone":"555-010-0199"},"timestamps":{"created":"2026-10-20T10:00:00Z"}}', now() + interval '2 minutes');
  IF r ->> 'action' <> 'restart_candidate' THEN RAISE EXCEPTION 'X4q: %', r; END IF;
  r := iit.ingest_vauto_observation('APPR-100','', '{"vehicle":{"vin":"WAUZZZ8V7JA000100"},"appraisal":{"value":15100,"is_completed":true},"customer":{"first_name":"Ann","last_name":"Seller","phone":"555-010-0199"},"timestamps":{"created":"2026-10-20T10:00:00Z"}}', now() + interval '3 minutes');
  SELECT count(*) INTO n FROM iit.work_items WHERE deal_id = deal AND kind='restart_candidate' AND status='open';
  SELECT id INTO item FROM iit.work_items WHERE deal_id = deal AND kind='restart_candidate' AND status='open';
  IF n <> 1 OR jsonb_array_length((SELECT detail -> 'evidence' FROM iit.work_items WHERE id = item)) <> 2 THEN RAISE EXCEPTION 'X4r one task, two pieces of evidence'; END IF;
  IF (SELECT end_reason FROM iit.appraisal_episodes e JOIN iit.external_references x ON x.id = e.appraisal_ref_id WHERE x.external_id='APPR-100' AND episode_no=1) <> 'cancelled' THEN RAISE EXCEPTION 'X4s episode not ended'; END IF;
  -- restart decision
  BEGIN PERFORM iit.resolve_work_item(item, 'x', 'b44-de'); RAISE EXCEPTION 'X4t generic close of a restart task'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'WORK_ITEM_KIND_DEFERRED%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.resolve_restart(item, 'no_restart', '', 'b44-de'); RAISE EXCEPTION 'X4u no reason'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REASON_REQUIRED%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.resolve_restart(item, 'restart_new_episode', 'x', 'b44-aud'); RAISE EXCEPTION 'X4v auditor restarted'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  deal2 := iit.resolve_restart(item, 'restart_new_episode', 'customer came back', 'b44-de');
  IF deal2 IS NULL OR (SELECT restarted_from_deal_id FROM iit.deals WHERE id = deal2) <> deal OR (SELECT purchase_price FROM iit.deals WHERE id = deal2) <> 15100 THEN RAISE EXCEPTION 'X4w restart deal'; END IF;
  IF (SELECT episode_no || '/' || start_basis || '/' || started_by::text FROM iit.appraisal_episodes WHERE deal_id = deal2) <> '2/data_entry_restart/00000000-0000-4000-8000-00000000000d' THEN RAISE EXCEPTION 'X4x episode 2'; END IF;
  IF (SELECT status FROM iit.work_items WHERE id = item) <> 'closed' OR iit.open_draft_version(deal2) <> 1 THEN RAISE EXCEPTION 'X4y task / draft'; END IF;
  -- the new episode is open: further observations are the update path for deal2, not the cancelled deal
  r := iit.ingest_vauto_observation('APPR-100','', '{"vehicle":{"vin":"WAUZZZ8V7JA000100"},"appraisal":{"value":15200,"is_completed":true},"timestamps":{"created":"2026-10-20T10:00:00Z"}}', now() + interval '4 minutes');
  IF (r ->> 'deal_id')::uuid <> deal2 OR r ->> 'action' <> 'updated' THEN RAISE EXCEPTION 'X4z: %', r; END IF;
  -- restart decision 'no_restart' on a second appraisal
  r := iit.ingest_vauto_observation('APPR-101','ctx-b', '{"vehicle":{"vin":"WAUZZZ8V7JA000101"},"appraisal":{"value":1,"is_completed":true},"timestamps":{"created":"2026-10-20T10:00:00Z"}}');
  PERFORM iit.cancel_deal((r ->> 'deal_id')::uuid, 'test', 'b44-de');
  r := iit.ingest_vauto_observation('APPR-101','ctx-b', '{"vehicle":{"vin":"WAUZZZ8V7JA000101"},"appraisal":{"value":2,"is_completed":true},"timestamps":{"created":"2026-10-20T10:00:00Z"}}', now() + interval '1 minute');
  SELECT id INTO item FROM iit.work_items WHERE appraisal_ref_id = (SELECT id FROM iit.external_references WHERE external_id='APPR-101' AND account_context='ctx-b') AND status='open';
  IF iit.resolve_restart(item, 'no_restart', 'junk appraisal', 'b44-de') IS NOT NULL OR (SELECT outcome FROM iit.work_items WHERE id = item) <> 'no_restart: junk appraisal' THEN RAISE EXCEPTION 'X4aa no_restart'; END IF;
  IF current_setting('app.actor_kind', true) <> '' THEN RAISE EXCEPTION 'X4ab actor context leaked'; END IF;
END $$;

-- X5 parties after release: identity → material (draft + hold); contact → amendment; misuse refused
DO $$ DECLARE p uuid; corr uuid; no int; holds int; ids bigint[]; BEGIN
  SELECT dp.party_id INTO p FROM iit.deal_parties dp WHERE dp.deal_id='00000000-0000-4000-8000-0000000000e5' AND dp.role='owner';
  BEGIN PERFORM iit.correct_party('00000000-0000-4000-8000-0000000000e5','owner',1,'{"phone":"555-1"}','x','b44-de'); RAISE EXCEPTION 'X5a contact-only correction'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'NOT_MATERIAL%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.amend_party('00000000-0000-4000-8000-0000000000e5', p, '{"last_name":"X"}','x','b44-de'); RAISE EXCEPTION 'X5b identity amended'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'MATERIAL_FIELD%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.amend_party('00000000-0000-4000-8000-0000000000e5', '00000000-0000-4000-8000-0000000000a1', '{"phone":"555-1"}','x','b44-de'); RAISE EXCEPTION 'X5c foreign party amended'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'PARTY_NOT_ON_DEAL%' THEN RAISE; END IF; END;
  SELECT count(*) INTO holds FROM iit.audit_holds WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND released_at IS NULL;
  corr := iit.correct_party('00000000-0000-4000-8000-0000000000e5','owner',1,'{"last_name":"Owner-Jones","email":"o@x"}','name on title','b44-de');
  IF (SELECT last_name || '/' || email FROM iit.seller_parties WHERE id = p) <> 'Owner-Jones/o@x' THEN RAISE EXCEPTION 'X5d'; END IF;
  IF (SELECT count(*) FROM iit.audit_holds WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND released_at IS NULL) <> holds + 1 OR (SELECT fields FROM iit.material_corrections WHERE id = corr) <> ARRAY['seller_parties'] THEN RAISE EXCEPTION 'X5e hold / correction'; END IF;
  SELECT history_ids INTO ids FROM iit.material_corrections WHERE id = corr;
  IF EXISTS (SELECT 1 FROM iit.record_history WHERE id = ANY (ids) AND (table_name <> 'seller_parties' OR record_id <> p)) THEN RAISE EXCEPTION 'X5f history ids'; END IF;
  -- a new co-owner after release: both the party row and the link are in the history ids
  corr := iit.correct_party('00000000-0000-4000-8000-0000000000e5','co_owner',1,'{"party_type":"person","first_name":"Co","last_name":"Owner"}','second name on title','b44-de');
  SELECT history_ids INTO ids FROM iit.material_corrections WHERE id = corr;
  IF (SELECT string_agg(DISTINCT table_name, ',' ORDER BY table_name) FROM iit.record_history WHERE id = ANY (ids)) <> 'deal_parties,seller_parties' THEN RAISE EXCEPTION 'X5g new party history'; END IF;
  no := iit.amend_party('00000000-0000-4000-8000-0000000000e5', p, '{"phone":"(555) 010-9999"}','new number','b44-de');
  IF (SELECT phone_normalized FROM iit.seller_parties WHERE id = p) <> '5550109999' OR (SELECT field FROM iit.deal_amendments WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND amendment_no = no AND version_no = iit.latest_released_version('00000000-0000-4000-8000-0000000000e5')) <> 'party:owner:' || p::text THEN RAISE EXCEPTION 'X5h amendment'; END IF;
  IF (SELECT count(*) FROM iit.audit_holds WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND released_at IS NULL) <> holds + 2 THEN RAISE EXCEPTION 'X5i amendment opened a hold'; END IF;
  BEGIN PERFORM iit.amend_party('00000000-0000-4000-8000-0000000000e5', p, '{"phone":"(555) 010-9999"}','same','b44-de'); RAISE EXCEPTION 'X5j no-change'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'NO_CHANGE%' THEN RAISE; END IF; END;
END $$;

-- X6 grants and coverage
DO $$ DECLARE r record; missing text := ''; BEGIN
  IF NOT has_function_privilege('tav_worker','iit.ingest_vauto_observation(text,text,jsonb,timestamptz)','EXECUTE') THEN RAISE EXCEPTION 'X6a'; END IF;
  IF has_function_privilege('iit_integration','iit.ingest_vauto_observation(text,text,jsonb,timestamptz)','EXECUTE') OR has_function_privilege('anon','iit.ingest_vauto_observation(text,text,jsonb,timestamptz)','EXECUTE') THEN RAISE EXCEPTION 'X6b'; END IF;
  IF has_function_privilege('tav_worker','iit.release_deal(uuid,text)','EXECUTE') OR has_function_privilege('tav_worker','iit.resolve_restart(uuid,text,text,text)','EXECUTE') THEN RAISE EXCEPTION 'X6c'; END IF;
  IF NOT has_function_privilege('iit_integration','iit.correct_party(uuid,text,int,jsonb,text,text)','EXECUTE') OR has_function_privilege('iit_integration','iit._deal_from_observation(jsonb,uuid)','EXECUTE') OR has_function_privilege('iit_integration','iit._begin_material_correction(uuid)','EXECUTE') THEN RAISE EXCEPTION 'X6d'; END IF;
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='iit' AND c.relkind='r' LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c2 ON c2.oid=t.tgrelid JOIN pg_namespace s2 ON s2.oid=c2.relnamespace WHERE s2.nspname='iit' AND c2.relname=r.relname AND t.tgname IN ('zz_history','zz_append_only')) THEN missing := missing || r.relname || ' '; END IF; END LOOP;
  IF missing <> '' THEN RAISE EXCEPTION 'X6e uncovered: %', missing; END IF;
END $$;

SELECT 'ALL 004 TESTS PASS' AS result;
