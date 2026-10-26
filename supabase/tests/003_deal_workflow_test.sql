-- 003_deal_workflow_test.sql — runs after 001/002 tests on the same cluster (staff fixtures: b44-admin a, b44-de d, b44-aud b, b44-lead c).
\set ON_ERROR_STOP on
\set QUIET on

-- fixtures. TEST-ONLY vAuto channel (D-4: the owner's list is not seeded by any migration).
INSERT INTO iit.source_channels(name, route, origin) VALUES ('TEST vAuto Retail','risk_audit','vauto_intake'), ('TEST vAuto Service','risk_audit','vauto_intake');
INSERT INTO iit.vehicles(id, vin) VALUES
  ('00000000-0000-4000-8000-0000000000b4','WAUZZZ8V7JA000001'),
  ('00000000-0000-4000-8000-0000000000b5','WAUZZZ8V7JA000002'),
  ('00000000-0000-4000-8000-0000000000b7','WAUZZZ8V7JA000007');
-- e5: vAuto deal, deliberately incomplete at first
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, deposit_amount, buyer_id)
  VALUES ('00000000-0000-4000-8000-0000000000e5','00000000-0000-4000-8000-0000000000b4','vauto_intake', 20000, 500, '00000000-0000-4000-8000-00000000000a');
INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e5', 1, 'draft', 'intake');
INSERT INTO iit.seller_parties(id, party_type, first_name, last_name, phone) VALUES ('00000000-0000-4000-8000-0000000000a5','person','Olive','Owner','(555) 010-0005');
INSERT INTO iit.deal_parties(deal_id, party_id, role) VALUES ('00000000-0000-4000-8000-0000000000e5','00000000-0000-4000-8000-0000000000a5','owner');
-- e6: manual consignment (price NULL by G8)
INSERT INTO iit.deals(id, vehicle_id, origin, buyer_id, closer_id)
  VALUES ('00000000-0000-4000-8000-0000000000e6','00000000-0000-4000-8000-0000000000b5','manual_consignment','00000000-0000-4000-8000-00000000000a','00000000-0000-4000-8000-00000000000d');
INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e6', 1, 'draft', 'intake');
-- e7/e8: two auction deals on the SAME vehicle (restart-style sharing, T54)
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, buyer_id, closer_id) VALUES
  ('00000000-0000-4000-8000-0000000000e7','00000000-0000-4000-8000-0000000000b7','manual_exception', 9000, '00000000-0000-4000-8000-00000000000a','00000000-0000-4000-8000-00000000000d'),
  ('00000000-0000-4000-8000-0000000000e8','00000000-0000-4000-8000-0000000000b7','manual_exception', 9500, '00000000-0000-4000-8000-00000000000a','00000000-0000-4000-8000-00000000000d');
INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e7', 1, 'draft', 'intake'), ('00000000-0000-4000-8000-0000000000e8', 1, 'draft', 'intake');

-- W1 set_source_channel: role, unknown channel, origin mismatch, D-9 cache rule (one statement sets both columns)
DO $$ DECLARE d record; BEGIN
  BEGIN PERFORM iit.set_source_channel('00000000-0000-4000-8000-0000000000e5','TEST vAuto Retail','b44-aud'); RAISE EXCEPTION 'W1a auditor set a channel'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.set_source_channel('00000000-0000-4000-8000-0000000000e5','Nope','b44-de'); RAISE EXCEPTION 'W1b'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'CHANNEL_UNKNOWN%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.set_source_channel('00000000-0000-4000-8000-0000000000e5','Consignment','b44-de'); RAISE EXCEPTION 'W1c consignment channel on a vAuto deal'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'CHANNEL_ORIGIN_MISMATCH%' THEN RAISE; END IF; END;
  PERFORM iit.set_source_channel('00000000-0000-4000-8000-0000000000e5','TEST vAuto Retail','b44-de');
  SELECT * INTO d FROM iit.deals WHERE id = '00000000-0000-4000-8000-0000000000e5';
  IF d.consumer_route <> 'risk_audit' OR d.source_channel_id IS NULL THEN RAISE EXCEPTION 'W1d cache rule: route=%', d.consumer_route; END IF;
  IF current_setting('app.actor_kind', true) <> '' THEN RAISE EXCEPTION 'W1e actor context leaked'; END IF;
END $$;

-- W2 release_deal: every refusal in order (§5.7 checks 1–6), then a successful freeze with snapshot + watermark + attempt
DO $$ DECLARE v int; msg text; f uuid; r uuid; n bigint; ver record; snap jsonb; wm bigint; BEGIN
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-aud'); RAISE EXCEPTION 'W2a auditor released'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  -- 3. required facts: closer, title custody, lien position missing (G13 vauto list)
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de'); RAISE EXCEPTION 'W2b released with missing facts';
  EXCEPTION WHEN OTHERS THEN msg := SQLERRM; IF msg NOT LIKE 'RELEASE_REFUSED: missing required facts: closer, lien_position, title_custody' THEN RAISE EXCEPTION 'W2b wrong list: %', msg; END IF; END;
  UPDATE iit.deals SET closer_id = '00000000-0000-4000-8000-00000000000d' WHERE id = '00000000-0000-4000-8000-0000000000e5';
  INSERT INTO iit.deal_titles(deal_id, custody, title_state, is_tribal) VALUES ('00000000-0000-4000-8000-0000000000e5','in_hand','FL',false);
  INSERT INTO iit.deal_liens(deal_id, position) VALUES ('00000000-0000-4000-8000-0000000000e5','none');
  -- 4. blocking flag
  INSERT INTO iit.intake_flags(id, deal_id, code, blocks_release) VALUES ('00000000-0000-4000-8000-0000000000f1','00000000-0000-4000-8000-0000000000e5','vin_check_digit', true);
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de'); RAISE EXCEPTION 'W2c released with a blocking flag'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'RELEASE_REFUSED: % blocking flags' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.resolve_flag('00000000-0000-4000-8000-0000000000f1','closed','x','b44-de'); RAISE EXCEPTION 'W2d bad flag status'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'FLAG_STATUS%' THEN RAISE; END IF; END;
  PERFORM iit.resolve_flag('00000000-0000-4000-8000-0000000000f1','accepted','check digit verified by hand','b44-de');
  BEGIN PERFORM iit.resolve_flag('00000000-0000-4000-8000-0000000000f1','resolved','again','b44-de'); RAISE EXCEPTION 'W2e re-resolved'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'FLAG_NOT_OPEN%' THEN RAISE; END IF; END;
  IF (SELECT resolved_by FROM iit.intake_flags WHERE id = '00000000-0000-4000-8000-0000000000f1') <> '00000000-0000-4000-8000-00000000000d' THEN RAISE EXCEPTION 'W2f resolver not recorded'; END IF;
  -- 6. FL title → FL_DMV requirement, unsatisfied
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de'); RAISE EXCEPTION 'W2g released with an unsatisfied requirement'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'RELEASE_REFUSED: % unsatisfied report requirements' THEN RAISE; END IF; END;
  IF (SELECT count(*) FROM iit.deal_report_requirements WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND version_no=1) <> 0 THEN RAISE EXCEPTION 'W2h a refused release left writes behind'; END IF;   -- refusal writes nothing
  PERFORM iit.compute_requirements('00000000-0000-4000-8000-0000000000e5', 1);   -- as the intake functions will (004); release recomputes anyway
  INSERT INTO iit.external_vehicle_reports(id, deal_id, subject_type, vehicle_id, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000c5','00000000-0000-4000-8000-0000000000e5','vehicle','00000000-0000-4000-8000-0000000000b4','FL_DMV','api_pull', now());
  n := iit.validate_report('00000000-0000-4000-8000-0000000000c5','FL_DMV:WAUZZZ8V7JA000001','valid','{"readable":true,"fresh":true}','ok','b44-de');
  SELECT max(id) INTO wm FROM iit.record_history;
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de');
  IF v <> 1 THEN RAISE EXCEPTION 'W2i released v%', v; END IF;
  SELECT * INTO ver FROM iit.deal_versions WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND version_no=1;
  IF ver.status <> 'released' OR ver.released_by <> '00000000-0000-4000-8000-00000000000d' OR ver.snapshot IS NULL OR ver.history_watermark < wm THEN RAISE EXCEPTION 'W2j freeze incomplete'; END IF;
  snap := ver.snapshot;
  IF (snap -> 'deal' ->> 'purchase_price')::numeric <> 20000 OR snap -> 'vehicle' ->> 'vin_normalized' <> 'WAUZZZ8V7JA000001' OR snap -> 'title' ->> 'title_state' <> 'FL'
     OR jsonb_array_length(snap -> 'parties') <> 1 OR (snap -> 'parties' -> 0) ? 'phone' OR snap -> 'parties' -> 0 ->> 'phone_normalized' <> '5550100005'
     OR snap -> 'requirements' -> 0 ->> 'requirement_key' <> 'FL_DMV:WAUZZZ8V7JA000001' OR (snap ? 'consignment') THEN RAISE EXCEPTION 'W2k snapshot content: %', snap; END IF;
  IF (SELECT intake_status || '/' || current_version_no FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e5') <> 'released/1' THEN RAISE EXCEPTION 'W2l deal caches'; END IF;
  -- risk_audit route: the attempt for v1 exists and the Deal is pending
  r := iit.current_attempt('00000000-0000-4000-8000-0000000000e5');
  IF r IS NULL OR (SELECT deal_version_no FROM iit.prequalification_checks WHERE id = r) <> 1 OR (SELECT audit_status FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e5') <> 'pending' THEN RAISE EXCEPTION 'W2m attempt not opened at release'; END IF;
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de'); RAISE EXCEPTION 'W2n released twice'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'RELEASE_REFUSED: % no open draft' THEN RAISE; END IF; END;
  -- D-5: Source change after release is refused; the same channel is a no-op
  BEGIN PERFORM iit.set_source_channel('00000000-0000-4000-8000-0000000000e5','TEST vAuto Service','b44-de'); RAISE EXCEPTION 'W2o source changed after release'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'SOURCE_CHANGE_AFTER_RELEASE_UNDECIDED%' THEN RAISE; END IF; END;
  PERFORM iit.set_source_channel('00000000-0000-4000-8000-0000000000e5','TEST vAuto Retail','b44-de');
  IF current_setting('app.actor_kind', true) <> '' THEN RAISE EXCEPTION 'W2p actor context leaked'; END IF;
END $$;

-- W2x snapshot policy at the DB boundary: a non-allowlisted key is rejected on a direct write; allowlisted keys pass
DO $$ BEGIN
  BEGIN INSERT INTO iit.deal_versions(deal_id, version_no, status, cause, released_at, snapshot) VALUES ('00000000-0000-4000-8000-0000000000e8', 9, 'released', 'intake', now(), '{"deal":{"bogus":1}}'); RAISE EXCEPTION 'W2x-a stray snapshot key accepted'; EXCEPTION WHEN SQLSTATE '23514' THEN NULL; END;
  BEGIN INSERT INTO iit.deal_versions(deal_id, version_no, status, cause, released_at, snapshot) VALUES ('00000000-0000-4000-8000-0000000000e8', 9, 'released', 'intake', now(), '{"parties":[{"phone":"555"}]}'); RAISE EXCEPTION 'W2x-b raw phone accepted'; EXCEPTION WHEN SQLSTATE '23514' THEN NULL; END;
END $$;

-- W3 amend_field: administrative amendment on the released version — no draft, no hold, approval kept (invariant 29); 3.1-mirrored field → work item
DO $$ DECLARE no int; dec uuid; wi record; BEGIN
  BEGIN PERFORM iit.amend_field('00000000-0000-4000-8000-0000000000e6','dealer_sold_to','"X"','x','b44-de'); RAISE EXCEPTION 'W3a amended an unreleased deal'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'NOT_RELEASED%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.amend_field('00000000-0000-4000-8000-0000000000e5','purchase_price','1','x','b44-de'); RAISE EXCEPTION 'W3b material field amended'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'MATERIAL_FIELD%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.amend_field('00000000-0000-4000-8000-0000000000e5','deposit_amount','1','x','b44-de'); RAISE EXCEPTION 'W3c deposit amended (D-20 open)'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'FIELD_UNSUPPORTED%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.amend_field('00000000-0000-4000-8000-0000000000e5','dealer_sold_to','"Dealer X"','','b44-de'); RAISE EXCEPTION 'W3d no reason'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REASON_REQUIRED%' THEN RAISE; END IF; END;
  -- approve v1 first, so we can show the approval survives the amendment
  dec := iit.record_decision(iit.current_attempt('00000000-0000-4000-8000-0000000000e5'), 'approved', 'clean', 'b44-aud');
  IF NOT iit.approval_eligible('00000000-0000-4000-8000-0000000000e5') THEN RAISE EXCEPTION 'W3e not eligible after approval'; END IF;
  no := iit.amend_field('00000000-0000-4000-8000-0000000000e5','dealer_sold_to','"Dealer X"','typo','b44-de');
  IF no <> 1 OR (SELECT dealer_sold_to FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e5') <> 'Dealer X' THEN RAISE EXCEPTION 'W3f amendment not applied'; END IF;
  IF (SELECT coalesce(before::text,'null') || '>' || coalesce(after::text,'null') FROM iit.deal_amendments WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND version_no=1 AND amendment_no=1) <> 'null>"Dealer X"' THEN RAISE EXCEPTION 'W3g amendment before/after'; END IF;
  IF iit.open_draft_version('00000000-0000-4000-8000-0000000000e5') IS NOT NULL OR iit.deal_has_open_hold('00000000-0000-4000-8000-0000000000e5') THEN RAISE EXCEPTION 'W3h amendment opened a draft or hold'; END IF;
  IF NOT iit.approval_eligible('00000000-0000-4000-8000-0000000000e5') THEN RAISE EXCEPTION 'W3i approval lost by an administrative amendment'; END IF;
  BEGIN PERFORM iit.amend_field('00000000-0000-4000-8000-0000000000e5','dealer_sold_to','"Dealer X"','same','b44-de'); RAISE EXCEPTION 'W3j no-change amendment recorded'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'NO_CHANGE%' THEN RAISE; END IF; END;
  -- 3.1-mirrored field (TEST row; the real list is D-8): same-day correction work item for Data Entry
  INSERT INTO iit.legacy_31_fields(field, note) VALUES ('dealer_auction_name','TEST ONLY — the 3.1 field map is not in the repo');
  no := iit.amend_field('00000000-0000-4000-8000-0000000000e5','dealer_auction_name','"Manheim Dallas"','added','b44-de');
  SELECT * INTO wi FROM iit.work_items WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND kind='same_day_31_correction' AND status='open';
  IF wi IS NULL OR wi.assigned_role <> 'data_entry' OR wi.detail ->> 'field' <> 'dealer_auction_name' OR wi.due_at IS NULL THEN RAISE EXCEPTION 'W3k same-day work item missing'; END IF;
  IF no <> 2 THEN RAISE EXCEPTION 'W3l amendment numbering'; END IF;
  BEGIN PERFORM iit.resolve_work_item(wi.id, 'done', 'b44-aud'); RAISE EXCEPTION 'W3m auditor closed a data_entry item'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  PERFORM iit.resolve_work_item(wi.id, '3.1 row corrected by hand', 'b44-de');
  IF (SELECT status || '/' || outcome FROM iit.work_items WHERE id = wi.id) <> 'closed/3.1 row corrected by hand' THEN RAISE EXCEPTION 'W3n work item not closed'; END IF;
  BEGIN PERFORM iit.resolve_work_item(wi.id, 'again', 'b44-de'); RAISE EXCEPTION 'W3o closed twice'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'WORK_ITEM_NOT_OPEN%' THEN RAISE; END IF; END;
  -- an unmirrored amendment opens no work item
  IF (SELECT count(*) FROM iit.work_items WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND kind='same_day_31_correction') <> 1 THEN RAISE EXCEPTION 'W3p unexpected work items'; END IF;
END $$;

-- W4 correct_field: material correction opens draft N+1 + hold at once (invariants 23, 29); exact history ids; carry-over; decisions refused; release v2 binds, approval releases
DO $$ DECLARE corr uuid; h record; mc record; c1 uuid; c2 uuid; dec uuid; v int; BEGIN
  BEGIN PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e5','dealer_sold_to','"Y"','x','b44-de'); RAISE EXCEPTION 'W4a non-material corrected'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'NOT_MATERIAL%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e5','seller_parties','{}','x','b44-de'); RAISE EXCEPTION 'W4b parties corrected'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'CORRECTION_UNSUPPORTED%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e6','purchase_price','1','x','b44-de'); RAISE EXCEPTION 'W4c unreleased deal corrected'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'NOT_RELEASED%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e5','purchase_price','20000','x','b44-de'); RAISE EXCEPTION 'W4d no-change correction'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'NO_CHANGE%' THEN RAISE; END IF; END;
  IF iit.open_draft_version('00000000-0000-4000-8000-0000000000e5') IS NOT NULL THEN RAISE EXCEPTION 'W4d2 a refused correction left a draft'; END IF;
  c1 := iit.current_attempt('00000000-0000-4000-8000-0000000000e5');
  corr := iit.correct_field('00000000-0000-4000-8000-0000000000e5','purchase_price','21000','price on the bill of sale','b44-de');
  IF (SELECT purchase_price FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e5') <> 21000 THEN RAISE EXCEPTION 'W4e value not applied'; END IF;
  IF (SELECT cause FROM iit.deal_versions WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND version_no=2 AND status='draft') <> 'material_correction' THEN RAISE EXCEPTION 'W4f draft v2 not opened'; END IF;
  SELECT * INTO mc FROM iit.material_corrections WHERE id = corr;
  IF mc.from_version_no <> 1 OR mc.draft_version_no <> 2 OR mc.fields <> ARRAY['purchase_price'] OR cardinality(mc.history_ids) < 1 THEN RAISE EXCEPTION 'W4g correction row'; END IF;
  IF EXISTS (SELECT 1 FROM iit.record_history WHERE id = ANY (mc.history_ids) AND (table_name <> 'deals' OR record_id <> '00000000-0000-4000-8000-0000000000e5' OR (after ->> 'purchase_price')::numeric <> 21000)) THEN RAISE EXCEPTION 'W4h history ids are not the exact change'; END IF;
  SELECT * INTO h FROM iit.audit_holds WHERE correction_id = corr;
  IF h IS NULL OR h.cause <> 'material_correction' OR h.covers_version_no <> 2 OR h.covering_check_id IS NOT NULL OR h.released_at IS NOT NULL THEN RAISE EXCEPTION 'W4i hold not opened for the draft'; END IF;
  IF NOT (SELECT on_hold FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e5') THEN RAISE EXCEPTION 'W4j on_hold cache'; END IF;
  IF iit.approval_eligible('00000000-0000-4000-8000-0000000000e5') THEN RAISE EXCEPTION 'W4k still eligible with an open material draft'; END IF;
  -- carry-over: the valid FL_DMV validation from v1 is carried onto draft v2 (same key, same subject, fresh)
  IF NOT EXISTS (SELECT 1 FROM iit.report_validations WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND version_no=2 AND requirement_key='FL_DMV:WAUZZZ8V7JA000001' AND outcome='valid' AND carried_from_validation_id IS NOT NULL) THEN RAISE EXCEPTION 'W4l carry-over missing'; END IF;
  -- a decision on the v1 attempt is refused while the material draft is open (§5.7)
  BEGIN PERFORM iit.record_decision(c1, 'approved', 'x', 'b44-aud'); RAISE EXCEPTION 'W4m decision recorded with an open material draft'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'DECISION_REJECTED: % open material draft' THEN RAISE; END IF; END;
  -- a second correction into the SAME draft: another correction row and hold, no new draft
  PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e5','is_tribal','true','tribal title','b44-de');
  IF (SELECT count(*) FROM iit.deal_versions WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND status='draft') <> 1 OR (SELECT count(*) FROM iit.audit_holds WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND released_at IS NULL) <> 2 THEN RAISE EXCEPTION 'W4n second correction'; END IF;
  PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e5','is_tribal','false','not tribal after all','b44-de');
  -- release v2: v1 superseded, attempt for v2 created, BOTH holds bound to it; approval releases both
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de');
  IF v <> 2 OR (SELECT status FROM iit.deal_versions WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND version_no=1) <> 'superseded' THEN RAISE EXCEPTION 'W4o v1 not superseded'; END IF;
  c2 := iit.current_attempt('00000000-0000-4000-8000-0000000000e5');
  IF c2 = c1 OR (SELECT status FROM iit.prequalification_checks WHERE id = c1) <> 'superseded' THEN RAISE EXCEPTION 'W4p attempt'; END IF;
  IF (SELECT count(*) FROM iit.audit_holds WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND released_at IS NULL AND covering_check_id = c2) <> 3 THEN RAISE EXCEPTION 'W4q holds not bound to the v2 attempt'; END IF;
  IF (SELECT count(*) FROM iit.audit_hold_events e JOIN iit.audit_holds hh ON hh.id = e.hold_id WHERE hh.deal_id='00000000-0000-4000-8000-0000000000e5' AND e.event='bound' AND e.check_id = c2) <> 3 THEN RAISE EXCEPTION 'W4r bound events'; END IF;
  IF (SELECT (snapshot -> 'deal' ->> 'purchase_price')::numeric FROM iit.deal_versions WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND version_no=2) <> 21000 THEN RAISE EXCEPTION 'W4s v2 snapshot'; END IF;
  dec := iit.record_decision(c2, 'approved', 'ok', 'b44-aud');
  IF iit.deal_has_open_hold('00000000-0000-4000-8000-0000000000e5') OR (SELECT on_hold FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e5') OR NOT iit.approval_eligible('00000000-0000-4000-8000-0000000000e5') THEN RAISE EXCEPTION 'W4t approval did not release the holds'; END IF;
END $$;

-- W5 rebind_hold (§5.7a G4, invariant 42): proof-based rebinding when the covering version was superseded before approval
DO $$ DECLARE h3 uuid; h4 uuid; h5 uuid; h6 uuid; c4 uuid; c6 uuid; v int; dec uuid; msg text; corr uuid; BEGIN
  -- v3: price 22000, released, NOT approved
  corr := iit.correct_field('00000000-0000-4000-8000-0000000000e5','purchase_price','22000','second invoice','b44-de'); SELECT id INTO h3 FROM iit.audit_holds WHERE correction_id = corr;
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de'); IF v <> 3 THEN RAISE EXCEPTION 'W5a'; END IF;
  BEGIN PERFORM iit.rebind_hold(h3, 'x', 'b44-lead'); RAISE EXCEPTION 'W5b rebound while its covering version is current'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REBIND_REFUSED: covering version v3 % is released%' THEN RAISE; END IF; END;
  -- v4: a DIFFERENT field corrected before v3 is approved → v3 superseded; H3 is left bound to a superseded attempt
  corr := iit.correct_field('00000000-0000-4000-8000-0000000000e5','lien_position','"lien"','lien found','b44-de'); SELECT id INTO h4 FROM iit.audit_holds WHERE correction_id = corr;
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de'); IF v <> 4 THEN RAISE EXCEPTION 'W5c'; END IF;
  c4 := iit.current_attempt('00000000-0000-4000-8000-0000000000e5');
  IF (SELECT covers_version_no FROM iit.audit_holds WHERE id = h3) <> 3 OR (SELECT covering_check_id FROM iit.audit_holds WHERE id = h4) <> c4 THEN RAISE EXCEPTION 'W5d binding state'; END IF;
  -- approving v4's attempt releases H4 only: H3 is bound to the superseded v3 attempt (exact binding)
  dec := iit.record_decision(c4, 'approved', 'ok', 'b44-aud');
  IF (SELECT released_at FROM iit.audit_holds WHERE id = h4) IS NULL OR (SELECT released_at FROM iit.audit_holds WHERE id = h3) IS NOT NULL THEN RAISE EXCEPTION 'W5e exact binding'; END IF;
  -- role, then the proof-based rebind: v4's snapshot contains the 22000 change recorded in H3's correction
  BEGIN PERFORM iit.rebind_hold(h3, 'x', 'b44-de'); RAISE EXCEPTION 'W5f data_entry rebound'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  v := iit.rebind_hold(h3, 'v3 change is contained in v4', 'b44-lead');
  IF v <> 4 OR (SELECT covers_version_no FROM iit.audit_holds WHERE id = h3) <> 4 OR (SELECT covering_check_id FROM iit.audit_holds WHERE id = h3) <> c4 THEN RAISE EXCEPTION 'W5g rebind state'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.audit_hold_events WHERE hold_id = h3 AND event='rebound' AND from_version_no=3 AND to_version_no=4 AND check_id = c4 AND reason LIKE '%proof: v4 snapshot%') THEN RAISE EXCEPTION 'W5h rebound event'; END IF;
  -- the rebound hold is still open (approval of c4 happened BEFORE the rebind): a decision on c4 is already recorded and
  -- record_decision releases only at decision time → the hold needs a fresh decision path; here the lead requests a re-audit
  IF (SELECT released_at FROM iit.audit_holds WHERE id = h3) IS NOT NULL THEN RAISE EXCEPTION 'W5i rebind must not release by itself'; END IF;
  PERFORM iit.request_reaudit('00000000-0000-4000-8000-0000000000e5', 'review the rebound v3 correction', 'b44-lead');
  c4 := iit.current_attempt('00000000-0000-4000-8000-0000000000e5');
  IF (SELECT covering_check_id FROM iit.audit_holds WHERE id = h3) <> c4 THEN RAISE EXCEPTION 'W5j rebound hold not bound to the new attempt'; END IF;
  dec := iit.record_decision(c4, 'approved', 'ok', 'b44-aud');
  IF iit.deal_has_open_hold('00000000-0000-4000-8000-0000000000e5') THEN RAISE EXCEPTION 'W5k holds still open'; END IF;
  BEGIN PERFORM iit.rebind_hold(h3, 'x', 'b44-lead'); RAISE EXCEPTION 'W5l released hold rebound'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REBIND_REFUSED: hold % is released' THEN RAISE; END IF; END;
  -- NEGATIVE proof: v5 sets price 23000 (not approved); v6 overwrites it with 24000 → v6's snapshot does NOT contain v5's change
  corr := iit.correct_field('00000000-0000-4000-8000-0000000000e5','purchase_price','23000','third invoice','b44-de'); SELECT id INTO h5 FROM iit.audit_holds WHERE correction_id = corr;
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de'); IF v <> 5 THEN RAISE EXCEPTION 'W5m'; END IF;
  corr := iit.correct_field('00000000-0000-4000-8000-0000000000e5','purchase_price','24000','fourth invoice','b44-de'); SELECT id INTO h6 FROM iit.audit_holds WHERE correction_id = corr;
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de'); IF v <> 6 THEN RAISE EXCEPTION 'W5n'; END IF;
  BEGIN PERFORM iit.rebind_hold(h5, 'try', 'b44-lead'); RAISE EXCEPTION 'W5o rebound without containment';
  EXCEPTION WHEN OTHERS THEN msg := SQLERRM; IF msg NOT LIKE 'REBIND_REFUSED: proof failed for hold % → v6: history %: deals.% in the change, % in snapshot v6' THEN RAISE EXCEPTION 'W5o wrong refusal: %', msg; END IF; END;
  IF (SELECT covers_version_no FROM iit.audit_holds WHERE id = h5) <> 5 OR (SELECT released_at FROM iit.audit_holds WHERE id = h5) IS NOT NULL THEN RAISE EXCEPTION 'W5p refused rebind changed the hold'; END IF;
  IF EXISTS (SELECT 1 FROM iit.audit_hold_events WHERE hold_id = h5 AND event='rebound') THEN RAISE EXCEPTION 'W5q refused rebind wrote an event'; END IF;
  -- approving v6 releases H6 only; H5 stays open for Data Entry (design: "Without that proof, the hold stays open")
  c6 := iit.current_attempt('00000000-0000-4000-8000-0000000000e5');
  dec := iit.record_decision(c6, 'approved', 'ok', 'b44-aud');
  IF (SELECT released_at FROM iit.audit_holds WHERE id = h6) IS NULL OR (SELECT released_at FROM iit.audit_holds WHERE id = h5) IS NOT NULL OR NOT (SELECT on_hold FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e5') THEN RAISE EXCEPTION 'W5r H5 must stay open'; END IF;
  -- a direct (non-function) rebind that lies about the version is caught by the 002 constraints: bound check must match the version
  BEGIN UPDATE iit.audit_holds SET covers_version_no = 6 WHERE id = h5; RAISE EXCEPTION 'W5s direct rebind with a stale check accepted'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  -- snapshot_contains_changes fails closed on a history row of a table outside the snapshot
  IF iit.snapshot_contains_changes('00000000-0000-4000-8000-0000000000e5', 6, ARRAY[(SELECT min(id) FROM iit.record_history WHERE table_name='intake_flags')]) NOT LIKE '%has no section in the v6 snapshot' THEN RAISE EXCEPTION 'W5t fail-closed proof'; END IF;
  IF iit.snapshot_contains_changes('00000000-0000-4000-8000-0000000000e5', 6, '{}'::bigint[]) IS NULL THEN RAISE EXCEPTION 'W5u empty proof accepted'; END IF;
END $$;

-- W6 consignment release (G8/G13/G14): no price, consignor + buyer + closer required; skip_audit → no attempt; then cancellation (G12, invariant 43)
DO $$ DECLARE v int; p uuid; hold uuid; msg text; BEGIN
  PERFORM iit.set_source_channel('00000000-0000-4000-8000-0000000000e6','Consignment','b44-de');
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8000-0000000000e6','b44-de'); RAISE EXCEPTION 'W6a';
  EXCEPTION WHEN OTHERS THEN msg := SQLERRM; IF msg <> 'RELEASE_REFUSED: missing required facts: consignor' THEN RAISE EXCEPTION 'W6a wrong list: %', msg; END IF; END;
  INSERT INTO iit.seller_parties(party_type, first_name, last_name) VALUES ('person','Carl','Consignor') RETURNING id INTO p;   -- no phone: not required (G13)
  INSERT INTO iit.consignments(deal_id, consignor_party_id, consignment_amount) VALUES ('00000000-0000-4000-8000-0000000000e6', p, 15000);
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e6','b44-de'); IF v <> 1 THEN RAISE EXCEPTION 'W6b'; END IF;
  IF iit.current_attempt('00000000-0000-4000-8000-0000000000e6') IS NOT NULL OR (SELECT audit_status FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e6') <> 'not_required' THEN RAISE EXCEPTION 'W6c skip_audit opened an attempt'; END IF;
  IF (SELECT snapshot -> 'consignment' ->> 'consignment_amount' FROM iit.deal_versions WHERE deal_id='00000000-0000-4000-8000-0000000000e6' AND version_no=1)::numeric <> 15000
     OR (SELECT snapshot -> 'deal' ? 'purchase_price' FROM iit.deal_versions WHERE deal_id='00000000-0000-4000-8000-0000000000e6' AND version_no=1) THEN RAISE EXCEPTION 'W6d consignment snapshot (PR3: amount separate, price absent)'; END IF;
  -- a linked current 3.1 row exists → cancellation must hand 3.1 to Data Entry
  INSERT INTO iit.source_records(deal_id, legacy_iid, kind, created_via, link_status, linked_at) VALUES ('00000000-0000-4000-8000-0000000000e6','TSTIID0006','initial','manual_fallback','linked', now());
  BEGIN PERFORM iit.cancel_deal('00000000-0000-4000-8000-0000000000e6','','b44-de'); RAISE EXCEPTION 'W6e no reason'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REASON_REQUIRED%' THEN RAISE; END IF; END;
  hold := iit.cancel_deal('00000000-0000-4000-8000-0000000000e6','seller withdrew','b44-de');
  IF (SELECT cancelled_at IS NULL OR cancellation_reason <> 'seller withdrew' OR audit_status <> 'cancelled' OR NOT on_hold FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e6') THEN RAISE EXCEPTION 'W6f cancel state'; END IF;
  IF (SELECT cause FROM iit.audit_holds WHERE id = hold) <> 'cancel' THEN RAISE EXCEPTION 'W6g cancel hold'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.work_items WHERE deal_id='00000000-0000-4000-8000-0000000000e6' AND kind='cancel_31_update' AND status='open' AND assigned_role='data_entry') THEN RAISE EXCEPTION 'W6h cancel_31_update work item'; END IF;
  -- terminal: nothing else works, the hold never releases, rebind refuses it
  BEGIN PERFORM iit.cancel_deal('00000000-0000-4000-8000-0000000000e6','again','b44-de'); RAISE EXCEPTION 'W6i cancelled twice'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'DEAL_CANCELLED%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.amend_field('00000000-0000-4000-8000-0000000000e6','dealer_sold_to','"Z"','x','b44-de'); RAISE EXCEPTION 'W6j amended after cancel'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'DEAL_CANCELLED%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e6','title_state','"TX"','x','b44-de'); RAISE EXCEPTION 'W6k corrected after cancel'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'DEAL_CANCELLED%' THEN RAISE; END IF; END;
  INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e6', 2, 'draft', 'resubmission');   -- direct write, to show release still refuses
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8000-0000000000e6','b44-de'); RAISE EXCEPTION 'W6l released after cancel'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'RELEASE_REFUSED: % cancelled or voided' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.rebind_hold(hold, 'x', 'b44-lead'); RAISE EXCEPTION 'W6m cancel hold rebound'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REBIND_REFUSED: only material_correction holds rebind%' THEN RAISE; END IF; END;
  BEGIN UPDATE iit.audit_holds SET released_at = now(), released_by_decision_id = (SELECT id FROM iit.audit_decisions LIMIT 1) WHERE id = hold; RAISE EXCEPTION 'W6n cancel hold released'; EXCEPTION WHEN OTHERS THEN NULL; END;
END $$;

-- W7 VIN correction on a shared vehicle (D-22), VIN collision, and the requirement-key change it causes; open episode ended by cancellation
DO $$ DECLARE v int; corr uuid; mc record; ref uuid; BEGIN
  PERFORM iit.set_source_channel('00000000-0000-4000-8000-0000000000e7','Brown Fig – Manheim','b44-de');
  PERFORM iit.set_source_channel('00000000-0000-4000-8000-0000000000e8','Brown Fig – ACV','b44-de');
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e7','b44-de'); v := iit.release_deal('00000000-0000-4000-8000-0000000000e8','b44-de');
  BEGIN PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e7','vin','"WAUZZZ8V7JA000077"','typo','b44-de'); RAISE EXCEPTION 'W7a shared vehicle VIN changed'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'VIN_SHARED%' THEN RAISE; END IF; END;
  -- e8 gets an appraisal episode (open), then is cancelled: the episode ends with reason cancelled; e7 then owns the vehicle alone
  INSERT INTO iit.external_references(id, system, external_id) VALUES ('00000000-0000-4000-8000-0000000000d8','vauto_appraisal','APPR-8') RETURNING id INTO ref;
  INSERT INTO iit.appraisal_episodes(appraisal_ref_id, deal_id, episode_no, start_basis) VALUES (ref, '00000000-0000-4000-8000-0000000000e8', 1, 'first_completion');
  PERFORM iit.cancel_deal('00000000-0000-4000-8000-0000000000e8','bought elsewhere','b44-de');
  IF (SELECT end_reason FROM iit.appraisal_episodes WHERE appraisal_ref_id = ref) <> 'cancelled' THEN RAISE EXCEPTION 'W7b episode not ended'; END IF;
  IF EXISTS (SELECT 1 FROM iit.work_items WHERE deal_id='00000000-0000-4000-8000-0000000000e8' AND kind='cancel_31_update') THEN RAISE EXCEPTION 'W7c work item without a linked 3.1 row'; END IF;
  BEGIN PERFORM iit.correct_field('00000000-0000-4000-8000-0000000000e7','vin','"wauzzz8v7ja000001"','typo','b44-de'); RAISE EXCEPTION 'W7d VIN of another vehicle accepted'; EXCEPTION WHEN SQLSTATE '23505' THEN NULL; END;
  corr := iit.correct_field('00000000-0000-4000-8000-0000000000e7','vin','"WAUZZZ8V7JA000077"','typo','b44-de');
  SELECT * INTO mc FROM iit.material_corrections WHERE id = corr;
  IF (SELECT vin_normalized FROM iit.vehicles WHERE id='00000000-0000-4000-8000-0000000000b7') <> 'WAUZZZ8V7JA000077'
     OR EXISTS (SELECT 1 FROM iit.record_history WHERE id = ANY (mc.history_ids) AND (table_name <> 'vehicles' OR record_id <> '00000000-0000-4000-8000-0000000000b7')) THEN RAISE EXCEPTION 'W7e VIN correction history'; END IF;
  v := iit.release_deal('00000000-0000-4000-8000-0000000000e7','b44-de'); IF v <> 2 THEN RAISE EXCEPTION 'W7f'; END IF;
  IF (SELECT snapshot -> 'vehicle' ->> 'vin_normalized' FROM iit.deal_versions WHERE deal_id='00000000-0000-4000-8000-0000000000e7' AND version_no=2) <> 'WAUZZZ8V7JA000077' THEN RAISE EXCEPTION 'W7g'; END IF;
  -- skip_audit route: the hold has no attempt to bind to; it stays open until the owner decides how skip-audit corrections clear (D-25)
  IF NOT iit.deal_has_open_hold('00000000-0000-4000-8000-0000000000e7') OR iit.current_attempt('00000000-0000-4000-8000-0000000000e7') IS NOT NULL THEN RAISE EXCEPTION 'W7h skip-audit correction state'; END IF;
END $$;

-- W8 requirement-key change through a material correction on a vAuto deal: title FL → OK drops FL_DMV, adds OK_DMV; the old validation does not carry
DO $$ DECLARE corr uuid; keys text; BEGIN
  corr := iit.correct_field('00000000-0000-4000-8000-0000000000e5','title_state','"OK"','title re-read','b44-de');
  SELECT string_agg(requirement_key, ',' ORDER BY requirement_key) INTO keys FROM iit.deal_report_requirements WHERE deal_id='00000000-0000-4000-8000-0000000000e5' AND version_no = iit.open_draft_version('00000000-0000-4000-8000-0000000000e5');
  IF keys <> 'OK_DMV:WAUZZZ8V7JA000001' THEN RAISE EXCEPTION 'W8a keys after title change: %', keys; END IF;
  IF iit.requirements_all_satisfied('00000000-0000-4000-8000-0000000000e5', iit.open_draft_version('00000000-0000-4000-8000-0000000000e5')) THEN RAISE EXCEPTION 'W8b OK_DMV satisfied by an FL validation'; END IF;
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8000-0000000000e5','b44-de'); RAISE EXCEPTION 'W8c released without OK_DMV'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'RELEASE_REFUSED: % unsatisfied report requirements' THEN RAISE; END IF; END;
END $$;

-- W9 grants: staff functions → iit_integration only; helpers owner-only
DO $$ BEGIN
  IF NOT has_function_privilege('iit_integration','iit.release_deal(uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'W9a'; END IF;
  IF NOT has_function_privilege('iit_integration','iit.rebind_hold(uuid,text,text)','EXECUTE') THEN RAISE EXCEPTION 'W9b'; END IF;
  IF has_function_privilege('anon','iit.release_deal(uuid,text)','EXECUTE') OR has_function_privilege('authenticated','iit.cancel_deal(uuid,text,text)','EXECUTE') OR has_function_privilege('tav_worker','iit.correct_field(uuid,text,jsonb,text,text)','EXECUTE') THEN RAISE EXCEPTION 'W9c'; END IF;
  IF has_function_privilege('iit_integration','iit._apply_field(uuid,text,jsonb)','EXECUTE') OR has_function_privilege('iit_integration','iit.build_deal_snapshot(uuid,int)','EXECUTE')
     OR has_function_privilege('iit_integration','iit.snapshot_contains_changes(uuid,int,bigint[])','EXECUTE') OR has_function_privilege('iit_integration','iit.missing_required_facts(uuid)','EXECUTE') THEN RAISE EXCEPTION 'W9d helper executable by the integration'; END IF;
  IF current_setting('app.actor_kind', true) <> '' THEN RAISE EXCEPTION 'W9e actor context leaked'; END IF;
END $$;

-- W10 coverage inventory: every table in iit still carries zz_history or zz_append_only (new: legacy_31_fields)
DO $$ DECLARE r record; missing text := ''; BEGIN
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='iit' AND c.relkind='r' LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c2 ON c2.oid=t.tgrelid JOIN pg_namespace s2 ON s2.oid=c2.relnamespace WHERE s2.nspname='iit' AND c2.relname=r.relname AND t.tgname IN ('zz_history','zz_append_only')) THEN missing := missing || r.relname || ' '; END IF; END LOOP;
  IF missing <> '' THEN RAISE EXCEPTION 'W10 uncovered: %', missing; END IF;
END $$;

SELECT 'ALL 003 TESTS PASS' AS result;
