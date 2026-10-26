-- 002_reports_audit_holds_test.sql — runs after 001 tests on the same cluster (fixtures from 001 exist: admin a, data-entry d, deals e1/e2).
\set ON_ERROR_STOP on
\set QUIET on

-- fixtures: an auditor, an audit lead; a fresh vAuto deal with vehicle, FL title, draft v1 and a business seller
INSERT INTO iit.users(id, display_name) VALUES ('00000000-0000-4000-8000-00000000000b','Auditor B'), ('00000000-0000-4000-8000-00000000000c','Lead C');
INSERT INTO iit.staff_identities(base44_user_id, user_id) VALUES ('b44-aud','00000000-0000-4000-8000-00000000000b'), ('b44-lead','00000000-0000-4000-8000-00000000000c');
INSERT INTO iit.user_roles(user_id, role) VALUES ('00000000-0000-4000-8000-00000000000b','auditor'), ('00000000-0000-4000-8000-00000000000c','audit_lead'), ('00000000-0000-4000-8000-00000000000c','auditor');
INSERT INTO iit.vehicles(id, vin) VALUES ('00000000-0000-4000-8000-0000000000b2','5YJ3E1EA7KF317000');
INSERT INTO iit.organizations(id, name) VALUES ('00000000-0000-4000-8000-00000000000f','Fleet Seller LLC');
INSERT INTO iit.organization_roles VALUES ('00000000-0000-4000-8000-00000000000f','business_seller');
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, consumer_route) VALUES ('00000000-0000-4000-8000-0000000000e3','00000000-0000-4000-8000-0000000000b2','vauto_intake', 30000, 'risk_audit');
INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e3', 1, 'draft', 'intake');
INSERT INTO iit.deal_titles(deal_id, custody, title_state, is_tribal) VALUES ('00000000-0000-4000-8000-0000000000e3','in_hand','FL',false);
INSERT INTO iit.seller_parties(id, party_type, business_org_id, phone) VALUES ('00000000-0000-4000-8000-0000000000a1','business','00000000-0000-4000-8000-00000000000f','555-0100');
INSERT INTO iit.deal_parties(deal_id, party_id, role) VALUES ('00000000-0000-4000-8000-0000000000e3','00000000-0000-4000-8000-0000000000a1','business_seller');

-- RS1–RS9 report subject (§5.6)
DO $$ BEGIN
  INSERT INTO iit.external_vehicle_reports(id, deal_id, subject_type, vehicle_id, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000c1','00000000-0000-4000-8000-0000000000e3','vehicle','00000000-0000-4000-8000-0000000000b2','FL_DMV','api_pull', now());   -- RS1
  INSERT INTO iit.external_vehicle_reports(id, deal_id, subject_type, subject_org_id, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000c2','00000000-0000-4000-8000-0000000000e3','organization','00000000-0000-4000-8000-00000000000f','OPENCORPORATES','api_pull', now());  -- RS2
  BEGIN INSERT INTO iit.external_vehicle_reports(deal_id, subject_type, vehicle_id, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000e3', NULL,'00000000-0000-4000-8000-0000000000b2','CARFAX','manual_upload', now()); RAISE EXCEPTION 'RS3'; EXCEPTION WHEN not_null_violation THEN NULL; END;
  BEGIN INSERT INTO iit.external_vehicle_reports(deal_id, subject_type, vehicle_id, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000e3','person','00000000-0000-4000-8000-0000000000b2','CARFAX','manual_upload', now()); RAISE EXCEPTION 'RS4'; EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN INSERT INTO iit.external_vehicle_reports(deal_id, subject_type, vehicle_id, subject_org_id, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000e3','vehicle','00000000-0000-4000-8000-0000000000b2','00000000-0000-4000-8000-00000000000f','CARFAX','manual_upload', now()); RAISE EXCEPTION 'RS5'; EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN INSERT INTO iit.external_vehicle_reports(deal_id, subject_type, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000e3','vehicle','CARFAX','manual_upload', now()); RAISE EXCEPTION 'RS6'; EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN INSERT INTO iit.external_vehicle_reports(deal_id, subject_type, subject_org_id, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000e3','vehicle','00000000-0000-4000-8000-00000000000f','CARFAX','manual_upload', now()); RAISE EXCEPTION 'RS7'; EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN INSERT INTO iit.external_vehicle_reports(deal_id, subject_type, vehicle_id, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000e3','vehicle','00000000-0000-4000-8000-0000000000bf','CARFAX','manual_upload', now()); RAISE EXCEPTION 'RS8'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
END $$;

-- R1 requirements computed for the draft from rules + facts: FL title → FL_DMV; business seller → OPENCORPORATES; no OK_DMV
SELECT iit.compute_requirements('00000000-0000-4000-8000-0000000000e3', 1);
DO $$ DECLARE keys text; BEGIN
  SELECT string_agg(requirement_key, ',' ORDER BY requirement_key) INTO keys FROM iit.deal_report_requirements WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND version_no=1;
  IF keys <> 'FL_DMV:5YJ3E1EA7KF317000,OPENCORPORATES:00000000-0000-4000-8000-00000000000f' THEN RAISE EXCEPTION 'R1 requirement set: %', keys; END IF;
  -- manual deal gets none (G10)
  INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e1', 1, 'draft', 'intake');
  IF iit.compute_requirements('00000000-0000-4000-8000-0000000000e1', 1) <> 0 THEN RAISE EXCEPTION 'R1b manual deal got requirements'; END IF;
END $$;

-- R2 validation: rejected then valid → authoritative valid; a later rejection overrides; RS9 (wrong subject) stored but not satisfying
DO $$ DECLARE n bigint; BEGIN
  BEGIN PERFORM iit.validate_report('00000000-0000-4000-8000-0000000000c1','FL_DMV:5YJ3E1EA7KF317000','valid','{"subject_match":true,"bogus":1}','ok','b44-de'); RAISE EXCEPTION 'R2a stray checks key accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
  n := iit.validate_report('00000000-0000-4000-8000-0000000000c1','FL_DMV:5YJ3E1EA7KF317000','rejected','{"readable":false}','blurry','b44-de');
  IF iit.requirement_satisfied('00000000-0000-4000-8000-0000000000e3',1,'FL_DMV:5YJ3E1EA7KF317000') THEN RAISE EXCEPTION 'R2b satisfied after rejection'; END IF;
  n := iit.validate_report('00000000-0000-4000-8000-0000000000c1','FL_DMV:5YJ3E1EA7KF317000','valid','{"subject_match":true,"owned_by_deal":true,"readable":true,"complete":true,"fresh":true}','re-scan','b44-de');
  IF NOT iit.requirement_satisfied('00000000-0000-4000-8000-0000000000e3',1,'FL_DMV:5YJ3E1EA7KF317000') THEN RAISE EXCEPTION 'R2c not satisfied after valid'; END IF;
  n := iit.validate_report('00000000-0000-4000-8000-0000000000c1','FL_DMV:5YJ3E1EA7KF317000','rejected','{"fresh":false}','stale','b44-de');
  IF iit.requirement_satisfied('00000000-0000-4000-8000-0000000000e3',1,'FL_DMV:5YJ3E1EA7KF317000') THEN RAISE EXCEPTION 'R2d later rejection did not override'; END IF;
  -- RS9: a valid validation on the ORGANIZATION report cannot satisfy the vehicle requirement (subject mismatch)
  n := iit.validate_report('00000000-0000-4000-8000-0000000000c2','FL_DMV:5YJ3E1EA7KF317000','valid','{"subject_match":false}','wrong subject','b44-de');
  IF iit.requirement_satisfied('00000000-0000-4000-8000-0000000000e3',1,'FL_DMV:5YJ3E1EA7KF317000') THEN RAISE EXCEPTION 'RS9 wrong-subject report satisfied the requirement'; END IF;
  -- finding 3: a CARFAX report on the same VIN cannot satisfy FL_DMV even if someone validates it 'valid'
  INSERT INTO iit.external_vehicle_reports(id, deal_id, subject_type, vehicle_id, report_type, acquisition, pulled_at) VALUES ('00000000-0000-4000-8000-0000000000c3','00000000-0000-4000-8000-0000000000e3','vehicle','00000000-0000-4000-8000-0000000000b2','CARFAX','api_pull', now());
  n := iit.validate_report('00000000-0000-4000-8000-0000000000c3','FL_DMV:5YJ3E1EA7KF317000','valid','{"subject_match":true}','mislabelled','b44-de');
  IF iit.requirement_satisfied('00000000-0000-4000-8000-0000000000e3',1,'FL_DMV:5YJ3E1EA7KF317000') THEN RAISE EXCEPTION 'R2f wrong report type satisfied FL_DMV'; END IF;
  -- finding 3: an unfinished manual upload cannot be validated nor satisfy
  INSERT INTO iit.external_vehicle_reports(id, deal_id, subject_type, vehicle_id, report_type, acquisition, pulled_at, object_path) VALUES ('00000000-0000-4000-8000-0000000000c4','00000000-0000-4000-8000-0000000000e3','vehicle','00000000-0000-4000-8000-0000000000b2','FL_DMV','manual_upload', now(), 'report-files/x/c4');
  BEGIN PERFORM iit.validate_report('00000000-0000-4000-8000-0000000000c4','FL_DMV:5YJ3E1EA7KF317000','valid','{"readable":true}','x','b44-de'); RAISE EXCEPTION 'R2g unfinished upload validated'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REPORT_FILE_UNAVAILABLE%' THEN RAISE; END IF; END;
  INSERT INTO iit.report_validations(report_id, requirement_key, deal_id, version_no, outcome, checks, validated_by) VALUES ('00000000-0000-4000-8000-0000000000c4','FL_DMV:5YJ3E1EA7KF317000','00000000-0000-4000-8000-0000000000e3',1,'valid','{}','00000000-0000-4000-8000-00000000000d');  -- direct write bypassing the function
  IF iit.requirement_satisfied('00000000-0000-4000-8000-0000000000e3',1,'FL_DMV:5YJ3E1EA7KF317000') THEN RAISE EXCEPTION 'R2h unfinished upload satisfied the requirement'; END IF;
  -- role: an auditor cannot validate (data_entry only)
  BEGIN PERFORM iit.validate_report('00000000-0000-4000-8000-0000000000c1','FL_DMV:5YJ3E1EA7KF317000','valid','{}','x','b44-aud'); RAISE EXCEPTION 'R2e auditor validated'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END $$;

-- R3 waivers: latest counts; revocation unwaives; older waiver never returns; data_entry cannot waive
DO $$ DECLARE w1 uuid; w2 uuid; BEGIN
  BEGIN PERFORM iit.waive_report('00000000-0000-4000-8000-0000000000e3','OPENCORPORATES:00000000-0000-4000-8000-00000000000f','x','b44-de'); RAISE EXCEPTION 'R3a data_entry waived'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  w1 := iit.waive_report('00000000-0000-4000-8000-0000000000e3','OPENCORPORATES:00000000-0000-4000-8000-00000000000f','seller verified by phone','b44-lead');
  IF NOT iit.requirement_satisfied('00000000-0000-4000-8000-0000000000e3',1,'OPENCORPORATES:00000000-0000-4000-8000-00000000000f') THEN RAISE EXCEPTION 'R3b waiver not honoured'; END IF;
  PERFORM iit.revoke_waiver(w1, 'needs the report after all', 'b44-lead');
  IF iit.requirement_satisfied('00000000-0000-4000-8000-0000000000e3',1,'OPENCORPORATES:00000000-0000-4000-8000-00000000000f') THEN RAISE EXCEPTION 'R3c revoked waiver still counts'; END IF;
  w2 := iit.waive_report('00000000-0000-4000-8000-0000000000e3','OPENCORPORATES:00000000-0000-4000-8000-00000000000f','second waiver','b44-lead');
  IF NOT iit.requirement_satisfied('00000000-0000-4000-8000-0000000000e3',1,'OPENCORPORATES:00000000-0000-4000-8000-00000000000f') THEN RAISE EXCEPTION 'R3d new waiver not honoured'; END IF;
  IF iit.requirements_all_satisfied('00000000-0000-4000-8000-0000000000e3',1) THEN RAISE EXCEPTION 'R3e all satisfied while FL_DMV is rejected'; END IF;
END $$;

-- R4 Risk Audit: attempt needs a released version; decision rejected on superseded check / stale version / open material draft; approval releases ONLY the covering hold
UPDATE iit.deal_versions SET status='released', released_at=now(), released_by='00000000-0000-4000-8000-00000000000d', snapshot='{}', history_watermark=1 WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND version_no=1;
-- finding 4: requirement rows of a released version are frozen at the DB boundary
DO $$ BEGIN
  BEGIN DELETE FROM iit.deal_report_requirements WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND version_no=1; RAISE EXCEPTION 'R1c delete on released requirements'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REQUIREMENTS_FROZEN%' THEN RAISE; END IF; END;
  BEGIN UPDATE iit.deal_report_requirements SET subject_vin='X' WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND version_no=1 AND report_type='FL_DMV'; RAISE EXCEPTION 'R1d update on released requirements'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REQUIREMENTS_FROZEN%' THEN RAISE; END IF; END;
  BEGIN INSERT INTO iit.deal_report_requirements(deal_id, version_no, requirement_key, report_type, subject_type, subject_vin, freshness_baseline) VALUES ('00000000-0000-4000-8000-0000000000e3',1,'CARFAX:5YJ3E1EA7KF317000','CARFAX','vehicle','5YJ3E1EA7KF317000',now()); RAISE EXCEPTION 'R1e insert on released requirements'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REQUIREMENTS_FROZEN%' THEN RAISE; END IF; END;
  BEGIN PERFORM iit.compute_requirements('00000000-0000-4000-8000-0000000000e3', 1); RAISE EXCEPTION 'R1f recompute on released'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REQUIREMENTS_FROZEN%' THEN RAISE; END IF; END;
END $$;
DO $$ DECLARE chk1 uuid; chk2 uuid; h1 uuid; h2 uuid; dec uuid; BEGIN
  -- a hold covering v1 (simulating a material correction hold bound to v1) and a reaudit hold via the staff function
  INSERT INTO iit.material_corrections(id, deal_id, from_version_no, draft_version_no, fields, history_ids, by) VALUES ('00000000-0000-4000-8000-0000000000cc','00000000-0000-4000-8000-0000000000e3',0,1,'{purchase_price}','{1}','00000000-0000-4000-8000-00000000000d');
  h1 := iit.open_hold('00000000-0000-4000-8000-0000000000e3','material_correction','00000000-0000-4000-8000-00000000000d','00000000-0000-4000-8000-0000000000cc',1);
  IF NOT (SELECT on_hold FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e3') THEN RAISE EXCEPTION 'R4a on_hold cache not set'; END IF;
  chk1 := iit.create_audit_attempt('00000000-0000-4000-8000-0000000000e3','00000000-0000-4000-8000-00000000000b');
  IF (SELECT covering_check_id FROM iit.audit_holds WHERE id=h1) <> chk1 THEN RAISE EXCEPTION 'R4b hold not bound to the attempt'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.audit_hold_events WHERE hold_id=h1 AND event='bound' AND check_id=chk1) THEN RAISE EXCEPTION 'R4c no bound event'; END IF;
  -- a second hold NOT covering this check (reaudit on the same version binds too; so use a cancel-cause hold: never released)
  h2 := iit.open_hold('00000000-0000-4000-8000-0000000000e3','cancel','00000000-0000-4000-8000-00000000000d');
  -- data_entry cannot decide
  BEGIN PERFORM iit.record_decision(chk1,'approved',NULL,'b44-admin'); RAISE EXCEPTION 'R4d non-auditor decided'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  -- open material draft blocks a decision
  INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e3', 2, 'draft', 'material_correction');
  BEGIN PERFORM iit.record_decision(chk1,'approved',NULL,'b44-aud'); RAISE EXCEPTION 'R4e decision with open material draft accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'DECISION_REJECTED%' THEN RAISE; END IF; END;
  -- rev-3 finding 1: moving a requirement row from released v1 onto draft v2 must be rejected (OLD parent frozen)
  BEGIN UPDATE iit.deal_report_requirements SET version_no = 2 WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND version_no=1 AND report_type='FL_DMV'; RAISE EXCEPTION 'R1g released->draft move accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REQUIREMENTS_FROZEN%' THEN RAISE; END IF; END;
  -- release v2 (and supersede v1): chk1 is now for a stale version
  UPDATE iit.deal_versions SET status='released', released_at=now(), released_by='00000000-0000-4000-8000-00000000000d', snapshot='{}', history_watermark=2 WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND version_no=2;
  UPDATE iit.deal_versions SET status='superseded' WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND version_no=1;
  BEGIN PERFORM iit.record_decision(chk1,'approved',NULL,'b44-aud'); RAISE EXCEPTION 'R4f decision on stale version accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'DECISION_REJECTED%' THEN RAISE; END IF; END;
  -- new attempt for v2 supersedes chk1; chk1 then rejected as superseded; h1 (covers v1) is NOT rebound automatically (needs proof — 003)
  chk2 := iit.create_audit_attempt('00000000-0000-4000-8000-0000000000e3','00000000-0000-4000-8000-00000000000b');
  IF (SELECT status FROM iit.prequalification_checks WHERE id=chk1) <> 'superseded' THEN RAISE EXCEPTION 'R4g old attempt not superseded'; END IF;
  BEGIN PERFORM iit.record_decision(chk1,'approved',NULL,'b44-aud'); RAISE EXCEPTION 'R4h decision on superseded attempt accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'DECISION_REJECTED%' THEN RAISE; END IF; END;
  -- approve chk2: releases nothing bound to chk1; h1 stays open (G4 exact binding), h2 (cancel) stays open
  dec := iit.record_decision(chk2,'approved','looks good','b44-aud');
  IF (SELECT released_at FROM iit.audit_holds WHERE id=h1) IS NOT NULL THEN RAISE EXCEPTION 'R4i hold bound to another check was released'; END IF;
  IF (SELECT released_at FROM iit.audit_holds WHERE id=h2) IS NOT NULL THEN RAISE EXCEPTION 'R4j cancel hold released'; END IF;
  IF iit.approval_eligible('00000000-0000-4000-8000-0000000000e3') <> true THEN RAISE EXCEPTION 'R4k approval_eligible false after approval on latest version'; END IF;
  -- finding 2: a NEW attempt on the same version invalidates the earlier approval until it is itself approved
  chk2 := iit.create_audit_attempt('00000000-0000-4000-8000-0000000000e3','00000000-0000-4000-8000-00000000000b');
  IF iit.approval_eligible('00000000-0000-4000-8000-0000000000e3') THEN RAISE EXCEPTION 'R4k2 eligible while the new attempt is pending'; END IF;
  IF (SELECT count(*) FROM iit.prequalification_checks WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND status<>'superseded') <> 1 THEN RAISE EXCEPTION 'R4k3 more than one current attempt'; END IF;
  dec := iit.record_decision(chk2,'changes_required','fix lien','b44-aud');
  IF iit.approval_eligible('00000000-0000-4000-8000-0000000000e3') THEN RAISE EXCEPTION 'R4k4 eligible after a rejected decision'; END IF;
  dec := iit.record_decision(chk2,'approved','fixed','b44-aud');
  IF NOT iit.approval_eligible('00000000-0000-4000-8000-0000000000e3') THEN RAISE EXCEPTION 'R4k5 not eligible after approving the current attempt'; END IF;
  -- finding 5: cross-deal correction, cross-deal check, release with a decision from another check / a non-approved decision
  INSERT INTO iit.material_corrections(id, deal_id, from_version_no, draft_version_no, fields, history_ids, by) VALUES ('00000000-0000-4000-8000-0000000000cd','00000000-0000-4000-8000-0000000000e2',1,2,'{vin}','{1}','00000000-0000-4000-8000-00000000000d');
  -- rev-3: a bound check with NULL covering version cannot bypass the composite FK
  BEGIN UPDATE iit.audit_holds SET covering_check_id = chk2, covers_version_no = NULL WHERE id = h2; RAISE EXCEPTION 'R5y-a NULL covering version bypass'; EXCEPTION WHEN check_violation THEN NULL; END;
  -- rev-3: an already-released hold cannot be inserted (even citing a real approved decision)
  BEGIN INSERT INTO iit.audit_holds(deal_id, cause, covers_version_no, covering_check_id, opened_by, released_at, released_by_decision_id) VALUES ('00000000-0000-4000-8000-0000000000e3','reaudit_request',2,chk2,'00000000-0000-4000-8000-00000000000d',now(),dec); RAISE EXCEPTION 'R5y-b released hold inserted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_INSERT_RELEASED%' THEN RAISE; END IF; END;
  -- rev-3: initial covering version must equal the correction's draft version (same deal, wrong version)
  INSERT INTO iit.material_corrections(id, deal_id, from_version_no, draft_version_no, fields, history_ids, by) VALUES ('00000000-0000-4000-8000-0000000000ce','00000000-0000-4000-8000-0000000000e3',2,3,'{vin}','{1}','00000000-0000-4000-8000-00000000000d');
  BEGIN PERFORM iit.open_hold('00000000-0000-4000-8000-0000000000e3','material_correction','00000000-0000-4000-8000-00000000000d','00000000-0000-4000-8000-0000000000ce',2); RAISE EXCEPTION 'R5y-c wrong initial covering version accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_COVERS_MISMATCH%' THEN RAISE; END IF; END;
  -- rebinding-compatible: a direct covers_version_no change on an unbound material hold is NOT blocked by the FK (reviewed rebind path in 003 will own it)
  INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e3', 3, 'draft', 'material_correction');
  h1 := iit.open_hold('00000000-0000-4000-8000-0000000000e3','material_correction','00000000-0000-4000-8000-00000000000d','00000000-0000-4000-8000-0000000000ce',3);
  UPDATE iit.audit_holds SET covers_version_no = 4 WHERE id = h1;   -- permitted at the constraint level (unbound); 003 governs it
  UPDATE iit.audit_holds SET covers_version_no = 3 WHERE id = h1;
  UPDATE iit.deal_versions SET status='released', released_at=now(), released_by='00000000-0000-4000-8000-00000000000d', snapshot='{}', history_watermark=3 WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND version_no=3;
  UPDATE iit.deal_versions SET status='superseded' WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND version_no=2;
  BEGIN PERFORM iit.open_hold('00000000-0000-4000-8000-0000000000e3','material_correction','00000000-0000-4000-8000-00000000000d','00000000-0000-4000-8000-0000000000cd',2); RAISE EXCEPTION 'R5x-a hold referenced another deal''s correction (function)'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_COVERS_MISMATCH%' THEN RAISE; END IF; END;
  BEGIN INSERT INTO iit.audit_holds(deal_id, cause, correction_id, covers_version_no, opened_by) VALUES ('00000000-0000-4000-8000-0000000000e3','material_correction','00000000-0000-4000-8000-0000000000cd',2,'00000000-0000-4000-8000-00000000000d'); RAISE EXCEPTION 'R5x-a2 hold referenced another deal''s correction (direct insert)'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  -- a check for v1 cannot cover a hold declared for v2 (version mismatch), and a check of another deal cannot cover at all
  BEGIN UPDATE iit.audit_holds SET covering_check_id = chk1, covers_version_no = 2 WHERE id = h2; RAISE EXCEPTION 'R5x-b hold bound to a check of a different version'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e1', 1, 'draft', 'intake') ON CONFLICT DO NOTHING;
  UPDATE iit.deal_versions SET status='released', released_at=now(), released_by='00000000-0000-4000-8000-00000000000d', snapshot='{}', history_watermark=1 WHERE deal_id='00000000-0000-4000-8000-0000000000e1' AND version_no=1 AND status='draft';
  chk1 := iit.create_audit_attempt('00000000-0000-4000-8000-0000000000e1','00000000-0000-4000-8000-00000000000b');   -- a check on ANOTHER deal (e1), v1
  BEGIN UPDATE iit.audit_holds SET covering_check_id = chk1, covers_version_no = 1 WHERE id = h2; RAISE EXCEPTION 'R5x-b2 hold bound to another deal''s check'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  -- open a fresh bound hold and try to release it with a decision that belongs to ANOTHER check (chk1's old decisions don't exist; use dec of chk2 against a hold bound to chk3)
  h1 := iit.request_reaudit('00000000-0000-4000-8000-0000000000e3','cross-check test','b44-lead');
  BEGIN UPDATE iit.audit_holds SET released_at = now(), released_by_decision_id = dec WHERE id = h1; RAISE EXCEPTION 'R5x-c released with a decision from another check'; EXCEPTION WHEN foreign_key_violation THEN NULL; WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_RELEASE_INVALID%' THEN RAISE; END IF; END;
  chk2 := iit.current_attempt('00000000-0000-4000-8000-0000000000e3');
  dec := iit.record_decision(chk2,'changes_required','not yet','b44-aud');
  BEGIN UPDATE iit.audit_holds SET released_at = now(), released_by_decision_id = dec WHERE id = h1; RAISE EXCEPTION 'R5x-d released with a non-approved decision on the covering check'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_RELEASE_INVALID%' THEN RAISE; END IF; END;
  dec := iit.record_decision(chk2,'approved','now ok','b44-aud');
  IF (SELECT released_at FROM iit.audit_holds WHERE id=h1) IS NULL THEN RAISE EXCEPTION 'R5x-e covering approval did not release'; END IF;
  IF NOT (SELECT on_hold FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e3') THEN RAISE EXCEPTION 'R4l on_hold cache cleared while holds remain'; END IF;
  -- a hold bound to the approved check IS released: reaudit on v2 → bound to a new attempt → approve it
  h1 := iit.request_reaudit('00000000-0000-4000-8000-0000000000e3','double-check lien','b44-lead');
  chk2 := (SELECT id FROM iit.prequalification_checks WHERE deal_id='00000000-0000-4000-8000-0000000000e3' AND status='open');
  IF (SELECT covering_check_id FROM iit.audit_holds WHERE id=h1) <> chk2 THEN RAISE EXCEPTION 'R4m reaudit hold not bound'; END IF;
  dec := iit.record_decision(chk2,'approved','ok','b44-aud');
  IF (SELECT released_at FROM iit.audit_holds WHERE id=h1) IS NULL THEN RAISE EXCEPTION 'R4n covering hold not released by approval'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.audit_hold_events WHERE hold_id=h1 AND event='released' AND decision_id=dec) THEN RAISE EXCEPTION 'R4o no released event'; END IF;
  -- released_at immutable
  BEGIN UPDATE iit.audit_holds SET released_at = NULL, released_by_decision_id = NULL WHERE id=h1; RAISE EXCEPTION 'R4p release reverted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_RELEASE_IMMUTABLE%' THEN RAISE; END IF; END;
  -- cancel hold can never be released even by direct edit (CHECK)
  BEGIN UPDATE iit.audit_holds SET released_at = now(), released_by_decision_id = dec WHERE id=h2; RAISE EXCEPTION 'R4q cancel hold released directly'; EXCEPTION WHEN check_violation THEN NULL; WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HOLD_RELEASE_UNBOUND%' THEN RAISE; END IF; END;
END $$;

-- R5 report upload/access: path scoped to deal; replaces must be same deal; access needs a recorded file and a staff role
DO $$ DECLARE r record; p text; BEGIN
  SELECT * INTO r FROM iit.begin_report_upload('00000000-0000-4000-8000-0000000000e3','CARFAX','vehicle','00000000-0000-4000-8000-0000000000b2',NULL,'manual_upload',now(),NULL,'b44-de');
  IF r.object_path <> 'report-files/00000000-0000-4000-8000-0000000000e3/' || r.report_id::text THEN RAISE EXCEPTION 'R5a path %', r.object_path; END IF;
  BEGIN p := iit.authorize_report_access(r.report_id,'b44-aud'); RAISE EXCEPTION 'R5b access before file recorded'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REPORT_FILE_UNAVAILABLE%' THEN RAISE; END IF; END;
  PERFORM iit.finish_report_upload(r.report_id, 12345, 'abc', 'b44-de');
  BEGIN PERFORM iit.finish_report_upload(r.report_id, 1, 'zzz', 'b44-de'); RAISE EXCEPTION 'R5c file re-recorded'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REPORT_UNKNOWN_OR_ALREADY%' THEN RAISE; END IF; END;
  p := iit.authorize_report_access(r.report_id,'b44-aud'); IF p <> r.object_path THEN RAISE EXCEPTION 'R5d path mismatch'; END IF;
  BEGIN p := iit.authorize_report_access(r.report_id,'b44-admin'); RAISE EXCEPTION 'R5e admin-only actor got report access'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.begin_report_upload('00000000-0000-4000-8000-0000000000e2','CARFAX','vehicle','00000000-0000-4000-8000-0000000000b1',NULL,'manual_upload',now(),r.report_id,'b44-de'); RAISE EXCEPTION 'R5f replaces another deal''s report'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'REPLACES_OTHER_DEAL%' THEN RAISE; END IF; END;
END $$;

-- R6 grants: staff functions not executable by anon/authenticated/worker; helpers not by integration
DO $$ BEGIN
  IF has_function_privilege('anon','iit.record_decision(uuid,text,text,text)','EXECUTE') THEN RAISE EXCEPTION 'R6a'; END IF;
  IF has_function_privilege('tav_worker','iit.waive_report(uuid,text,text,text)','EXECUTE') THEN RAISE EXCEPTION 'R6b'; END IF;
  IF has_function_privilege('iit_integration','iit.open_hold(uuid,text,uuid,uuid,int,uuid)','EXECUTE') THEN RAISE EXCEPTION 'R6c integration can open holds directly'; END IF;
  IF has_function_privilege('iit_integration','iit.create_audit_attempt(uuid,uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'R6d'; END IF;
END $$;

-- R7 history coverage still complete after 002
DO $$ DECLARE r record; missing text := ''; BEGIN
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace s ON s.oid=c.relnamespace WHERE s.nspname='iit' AND c.relkind='r' LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c2 ON c2.oid=t.tgrelid JOIN pg_namespace s2 ON s2.oid=c2.relnamespace WHERE s2.nspname='iit' AND c2.relname=r.relname AND t.tgname IN ('zz_history','zz_append_only')) THEN missing := missing || r.relname || ' '; END IF; END LOOP;
  IF missing <> '' THEN RAISE EXCEPTION 'R7 uncovered: %', missing; END IF;
END $$;

SELECT 'ALL 002 TESTS PASS' AS result;
