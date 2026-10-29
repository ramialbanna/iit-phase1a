-- 007_staff_read_rpcs_test.sql — run as superuser after 001–007 (and their tests). Plain SQL asserts, no pgTAP.
-- V1–V4: the V-2 correction. R1–R12: the ten read RPCs, the read-access audit and the unchanged narrow door.
-- Fixtures use the 8007 UUID block so they never collide with the earlier suites' rows; assertions check named fixture rows
-- or properties that hold whatever earlier suites left behind.
\set ON_ERROR_STOP on
\set QUIET on

-- V1 the global default ACL for iit_owner functions: exactly one row, namespace 0 (global, not IN SCHEMA), object type f,
-- and its ACL is the owner's EXECUTE alone — no PUBLIC, no other grantee
DO $$ DECLARE n int; acl aclitem[]; BEGIN
  SELECT count(*) INTO n FROM pg_default_acl d WHERE d.defaclrole = 'iit_owner'::regrole AND d.defaclobjtype = 'f';
  IF n <> 1 THEN RAISE EXCEPTION 'V1a % function default-ACL rows for iit_owner, expected 1', n; END IF;
  SELECT d.defaclacl INTO acl FROM pg_default_acl d
   WHERE d.defaclrole = 'iit_owner'::regrole AND d.defaclobjtype = 'f' AND d.defaclnamespace = 0;
  IF acl IS NULL THEN RAISE EXCEPTION 'V1b no global (defaclnamespace = 0) function default ACL for iit_owner'; END IF;
  IF EXISTS (SELECT 1 FROM aclexplode(acl) a WHERE a.grantee = 0) THEN RAISE EXCEPTION 'V1c PUBLIC in the default ACL: %', acl; END IF;
  IF EXISTS (SELECT 1 FROM aclexplode(acl) a WHERE a.grantee <> 'iit_owner'::regrole OR a.privilege_type <> 'EXECUTE') OR
     NOT EXISTS (SELECT 1 FROM aclexplode(acl) a WHERE a.grantee = 'iit_owner'::regrole AND a.privilege_type = 'EXECUTE')
    THEN RAISE EXCEPTION 'V1d default ACL is not exactly iit_owner EXECUTE: %', acl; END IF;
  -- no other default-ACL row for any IIT role (the per-schema REVOKE forms in 001/006 never created one)
  SELECT count(*) INTO n FROM pg_default_acl d JOIN pg_roles r ON r.oid = d.defaclrole
   WHERE r.rolname IN ('iit_owner','iit_integration','tav_worker','iit_base44');
  IF n <> 1 THEN RAISE EXCEPTION 'V1e % default-ACL rows for IIT roles, expected 1', n; END IF;
END $$;

-- V2 a new function created by iit_owner in iit (no REVOKE of its own) is executable by its owner and by no one else,
-- checked both as catalog privilege and as an actual call; then an explicit GRANT reaches exactly its grantee.
-- Rolled back: the probe never persists.
BEGIN;
SET LOCAL ROLE iit_owner;
CREATE FUNCTION iit._v2_probe() RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = '' AS 'SELECT 1';
RESET ROLE;
DO $$ DECLARE r text; BEGIN
  IF (SELECT proacl FROM pg_proc WHERE oid = 'iit._v2_probe()'::regprocedure) IS NULL THEN RAISE EXCEPTION 'V2a proacl NULL (= PUBLIC EXECUTE)'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = 'iit._v2_probe()'::regprocedure AND a.grantee = 0)
    THEN RAISE EXCEPTION 'V2b PUBLIC holds EXECUTE on the probe'; END IF;
  IF NOT has_function_privilege('iit_owner', 'iit._v2_probe()', 'EXECUTE') THEN RAISE EXCEPTION 'V2c owner lost EXECUTE'; END IF;
  FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role','authenticator','iit_base44','iit_integration','tav_worker','deployer'] LOOP
    IF has_function_privilege(r, 'iit._v2_probe()', 'EXECUTE') THEN RAISE EXCEPTION 'V2d % can execute the probe', r; END IF;
  END LOOP;
  -- a role with USAGE on iit (and so able to resolve the name) is refused at call time
  FOREACH r IN ARRAY ARRAY['iit_base44','iit_integration','tav_worker','anon','authenticated','service_role'] LOOP
    EXECUTE format('SET LOCAL ROLE %I', r);
    BEGIN PERFORM iit._v2_probe(); RAISE EXCEPTION 'V2e % called the probe', r; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
    RESET ROLE;
  END LOOP;
END $$;
SET LOCAL ROLE iit_owner;
GRANT EXECUTE ON FUNCTION iit._v2_probe() TO iit_base44;
RESET ROLE;
DO $$ DECLARE r text; BEGIN
  IF NOT has_function_privilege('iit_base44', 'iit._v2_probe()', 'EXECUTE') THEN RAISE EXCEPTION 'V2f explicit grant ineffective'; END IF;
  FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role','authenticator','iit_integration','tav_worker','deployer'] LOOP
    IF has_function_privilege(r, 'iit._v2_probe()', 'EXECUTE') THEN RAISE EXCEPTION 'V2g grant to iit_base44 reached %', r; END IF;
  END LOOP;
  SET LOCAL ROLE iit_base44;
  IF iit._v2_probe() <> 1 THEN RAISE EXCEPTION 'V2h'; END IF;
  RESET ROLE;
END $$;
ROLLBACK;
DO $$ BEGIN
  IF to_regprocedure('iit._v2_probe()') IS NOT NULL THEN RAISE EXCEPTION 'V2i probe persisted'; END IF;
END $$;

-- V3 the same holds for a function created by iit_owner outside iit: the default is global, not tied to the schema
BEGIN;
CREATE SCHEMA v2_probe_schema AUTHORIZATION iit_owner;
SET LOCAL ROLE iit_owner;
CREATE FUNCTION v2_probe_schema.f() RETURNS int LANGUAGE sql AS 'SELECT 1';
RESET ROLE;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
              WHERE p.oid = 'v2_probe_schema.f()'::regprocedure AND a.grantee = 0) THEN RAISE EXCEPTION 'V3 PUBLIC EXECUTE outside iit'; END IF;
END $$;
ROLLBACK;

-- V4 permissions outside the 007 manifest unchanged. No iit function is executable by PUBLIC or the Supabase API roles;
-- iit_integration keeps exactly its 27; the Worker grants are untouched.
DO $$ DECLARE r text; n int; BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
              WHERE s.nspname = 'iit' AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0)))
    THEN RAISE EXCEPTION 'V4a an iit function is executable by PUBLIC'; END IF;
  FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role','authenticator'] LOOP
    SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
     WHERE s.nspname = 'iit' AND has_function_privilege(r, p.oid, 'EXECUTE');
    IF n <> 0 THEN RAISE EXCEPTION 'V4b % can execute % iit functions', r, n; END IF;
  END LOOP;
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'iit' AND has_function_privilege('iit_integration', p.oid, 'EXECUTE');
  IF n <> 27 THEN RAISE EXCEPTION 'V4c iit_integration can execute % iit functions, expected 27', n; END IF;
  IF EXISTS (SELECT 1 FROM unnest(ARRAY['iit.authorize_and_consume(text,text,text,text,text,text,text,text,timestamptz)',
                                        'iit.report_action_outcome(uuid,text,jsonb,text,text)', 'iit.expire_stale_attempts(timestamptz)',
                                        'iit.ingest_vauto_observation(text,text,jsonb,timestamptz)']) f
              WHERE has_function_privilege('iit_base44', f::regprocedure, 'EXECUTE')
                 OR has_function_privilege('iit_integration', f::regprocedure, 'EXECUTE')
                 OR NOT has_function_privilege('tav_worker', f::regprocedure, 'EXECUTE'))
    THEN RAISE EXCEPTION 'V4d Worker-function grants changed'; END IF;
END $$;

-- ===================================================================================================================
-- fixtures
-- ===================================================================================================================
INSERT INTO iit.users(id, display_name, email) VALUES
  ('00000000-0000-4000-8007-000000000001','T7 Data Entry','t7-de@example.test'),
  ('00000000-0000-4000-8007-000000000002','T7 Auditor','t7-aud@example.test'),
  ('00000000-0000-4000-8007-000000000003','T7 Lead','t7-lead@example.test'),
  ('00000000-0000-4000-8007-000000000004','T7 Admin','t7-adm@example.test'),
  ('00000000-0000-4000-8007-000000000005','T7 None','t7-none@example.test'),
  ('00000000-0000-4000-8007-000000000006','T7 Gone','t7-gone@example.test'),
  ('00000000-0000-4000-8007-000000000007','T7 Multi','t7-multi@example.test'),
  ('00000000-0000-4000-8007-000000000008','T7 Admin Entry','t7-admde@example.test');
INSERT INTO iit.staff_identities(base44_user_id, user_id) VALUES
  ('b44-7-de','00000000-0000-4000-8007-000000000001'), ('b44-7-aud','00000000-0000-4000-8007-000000000002'),
  ('b44-7-lead','00000000-0000-4000-8007-000000000003'), ('b44-7-adm','00000000-0000-4000-8007-000000000004'),
  ('b44-7-none','00000000-0000-4000-8007-000000000005'), ('b44-7-multi','00000000-0000-4000-8007-000000000007'),
  ('b44-7-admde','00000000-0000-4000-8007-000000000008');
INSERT INTO iit.staff_identities(base44_user_id, user_id, active, deactivated_at) VALUES ('b44-7-gone','00000000-0000-4000-8007-000000000006', false, now());
INSERT INTO iit.user_roles(user_id, role) VALUES
  ('00000000-0000-4000-8007-000000000001','data_entry'), ('00000000-0000-4000-8007-000000000002','auditor'),
  ('00000000-0000-4000-8007-000000000003','auditor'), ('00000000-0000-4000-8007-000000000003','audit_lead'),
  ('00000000-0000-4000-8007-000000000004','admin'), ('00000000-0000-4000-8007-000000000006','data_entry'),
  ('00000000-0000-4000-8007-000000000007','data_entry'), ('00000000-0000-4000-8007-000000000007','auditor'),
  ('00000000-0000-4000-8007-000000000008','admin'), ('00000000-0000-4000-8007-000000000008','data_entry');
INSERT INTO iit.source_channels(name, route, origin) VALUES ('TEST7 Audit','risk_audit','manual_exception');
INSERT INTO iit.source_channels(name, route, origin, active) VALUES ('TEST7 Off','skip_audit','manual_exception', false);
INSERT INTO iit.vehicles(id, vin, year, make_text, model_text) VALUES
  ('00000000-0000-4000-8007-0000000000a1','T7VIN00000000000A1',2021,'Chevrolet','Silverado'),
  ('00000000-0000-4000-8007-0000000000a2','T7VIN00000000000A2',2020,'Ford','F-150'),
  ('00000000-0000-4000-8007-0000000000a4','T7VIN00000000000A4',2019,'Toyota','Tacoma'),
  ('00000000-0000-4000-8007-0000000000a5','T7VIN00000000000A5',2018,'Honda','Civic'),
  ('00000000-0000-4000-8007-0000000000a6','T7VIN00000000000A6',2017,'Nissan','Altima');
-- D1/D2: Risk Audit deals (released below); D3: draft on D1's vehicle, never released (no attempt)
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, buyer_id, closer_id) VALUES
  ('00000000-0000-4000-8007-0000000000d1','00000000-0000-4000-8007-0000000000a1','manual_exception', 7771.07, '00000000-0000-4000-8007-000000000001','00000000-0000-4000-8007-000000000001'),
  ('00000000-0000-4000-8007-0000000000d2','00000000-0000-4000-8007-0000000000a2','manual_exception', 7772.07, '00000000-0000-4000-8007-000000000001','00000000-0000-4000-8007-000000000001'),
  ('00000000-0000-4000-8007-0000000000d3','00000000-0000-4000-8007-0000000000a1','manual_exception', 7773.07, '00000000-0000-4000-8007-000000000001','00000000-0000-4000-8007-000000000001');
-- D4: consignment missing its consignor; D5: complete consignment; D6: cancelled consignment (excluded from the queue)
INSERT INTO iit.deals(id, vehicle_id, origin, buyer_id, closer_id) VALUES
  ('00000000-0000-4000-8007-0000000000d4','00000000-0000-4000-8007-0000000000a4','manual_consignment','00000000-0000-4000-8007-000000000001','00000000-0000-4000-8007-000000000001'),
  ('00000000-0000-4000-8007-0000000000d5','00000000-0000-4000-8007-0000000000a5','manual_consignment','00000000-0000-4000-8007-000000000001','00000000-0000-4000-8007-000000000001');
INSERT INTO iit.deals(id, vehicle_id, origin, cancelled_at, cancellation_reason) VALUES
  ('00000000-0000-4000-8007-0000000000d6','00000000-0000-4000-8007-0000000000a6','manual_consignment', now(), 'T7 cancelled');
INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) SELECT d, 1, 'draft', 'intake' FROM unnest(ARRAY[
  '00000000-0000-4000-8007-0000000000d1','00000000-0000-4000-8007-0000000000d2','00000000-0000-4000-8007-0000000000d3',
  '00000000-0000-4000-8007-0000000000d4','00000000-0000-4000-8007-0000000000d5','00000000-0000-4000-8007-0000000000d6']::uuid[]) d;
INSERT INTO iit.seller_parties(id, party_type, first_name, last_name, phone, email, city, state) VALUES
  ('00000000-0000-4000-8007-0000000000b1','person','Sam','Sellerseven','(555) 777-0101','sam.seller7@example.test','Austin','TX'),
  ('00000000-0000-4000-8007-0000000000b5','person','Cora','Consignorseven','(555) 777-0505','cora7@example.test','Dallas','TX');
INSERT INTO iit.deal_parties(deal_id, party_id, role) VALUES
  ('00000000-0000-4000-8007-0000000000d1','00000000-0000-4000-8007-0000000000b1','owner'),
  ('00000000-0000-4000-8007-0000000000d3','00000000-0000-4000-8007-0000000000b1','owner');
INSERT INTO iit.consignments(deal_id, consignor_party_id, consignment_amount, notes) VALUES
  ('00000000-0000-4000-8007-0000000000d5','00000000-0000-4000-8007-0000000000b5', 1507, 'T7 consignment note');
SELECT iit.set_source_channel('00000000-0000-4000-8007-0000000000d1','TEST7 Audit','b44-7-de');
SELECT iit.set_source_channel('00000000-0000-4000-8007-0000000000d2','TEST7 Audit','b44-7-de');
SELECT iit.release_deal('00000000-0000-4000-8007-0000000000d1','b44-7-de');
SELECT iit.release_deal('00000000-0000-4000-8007-0000000000d2','b44-7-de');
SELECT iit.record_decision(iit.current_attempt('00000000-0000-4000-8007-0000000000d2'), 'escalated', 'T7 escalation comment', 'b44-7-aud');
INSERT INTO iit.work_items(id, kind, deal_id, assigned_role, opened_at) VALUES
  ('00000000-0000-4000-8007-0000000000c1','report_rejected','00000000-0000-4000-8007-0000000000d3','data_entry', now() - interval '3 hours'),
  ('00000000-0000-4000-8007-0000000000c2','restart_candidate','00000000-0000-4000-8007-0000000000d3','data_entry', now() - interval '2 hours'),
  ('00000000-0000-4000-8007-0000000000c3','reaudit_31_correction','00000000-0000-4000-8007-0000000000d1','auditor', now() - interval '1 hour'),
  ('00000000-0000-4000-8007-0000000000c4','legacy_match', NULL,'admin', now() - interval '1 hour');
INSERT INTO iit.work_items(id, kind, deal_id, assigned_role, status, closed_by, closed_at, outcome, detail) VALUES
  ('00000000-0000-4000-8007-0000000000c5','report_rejected','00000000-0000-4000-8007-0000000000d3','data_entry','closed','00000000-0000-4000-8007-000000000001', now(), 'T7 done', '{"secret":"T7-WI-DETAIL"}');
-- gate actions: f1 an unknown outcome with conflicting reports; f2 completed and never unknown (not exposed by get_unknown_outcome)
INSERT INTO iit.gated_actions(id, action_key, iid, deal_id, action, caller_integration, triggered_by_text, state, deal_version, authorized_at) VALUES
  ('00000000-0000-4000-8007-0000000000f1','k7-secret-key-1','T7-IID-1','00000000-0000-4000-8007-0000000000d1','package','appsheet:31','T7-TRIGGER-TEXT','denied',1, now()),
  ('00000000-0000-4000-8007-0000000000f2','k7-secret-key-2','T7-IID-1','00000000-0000-4000-8007-0000000000d1','package','appsheet:31',NULL,'denied',1, now());
INSERT INTO iit.gated_action_attempts(id, action_id, attempt_no, caller_integration, state, read_31_status) VALUES
  ('00000000-0000-4000-8007-0000000000e1','00000000-0000-4000-8007-0000000000f1',1,'appsheet:31','outcome_unknown','In-Progress'),
  ('00000000-0000-4000-8007-0000000000e2','00000000-0000-4000-8007-0000000000f2',1,'appsheet:31','completed','In-Progress');
UPDATE iit.gated_actions SET state = 'outcome_unknown', current_attempt_id = '00000000-0000-4000-8007-0000000000e1', outcome_evidence = '{"http_status":504,"note":"T7-SECRET-NOTE"}'
 WHERE id = '00000000-0000-4000-8007-0000000000f1';
UPDATE iit.gated_actions SET state = 'completed', current_attempt_id = '00000000-0000-4000-8007-0000000000e2' WHERE id = '00000000-0000-4000-8007-0000000000f2';
INSERT INTO iit.gated_action_events(action_id, event, detail) VALUES
  ('00000000-0000-4000-8007-0000000000f1','conflict','{"outcome":"completed","reason":"T7-EVENT-REASON"}');
INSERT INTO iit.work_items(id, kind, deal_id, gated_action_id, assigned_role, detail) VALUES
  ('00000000-0000-4000-8007-0000000000c6','gate_outcome_unknown','00000000-0000-4000-8007-0000000000d1','00000000-0000-4000-8007-0000000000f1','data_entry','{"action_key":"k7-secret-key-1"}');
-- 3.1 links: T7-IID-1 linked to D1; T7-IID-2 points at D3 but is NOT linked (must never resolve)
INSERT INTO iit.source_records(legacy_iid, deal_id, kind, created_via, link_status, linked_at) VALUES ('T7-IID-1','00000000-0000-4000-8007-0000000000d1','initial','bridge','linked', now());
INSERT INTO iit.source_records(legacy_iid, deal_id, kind, created_via) VALUES ('T7-IID-2','00000000-0000-4000-8007-0000000000d3','initial','bridge');
INSERT INTO iit.revoked_credentials(jti, reason) VALUES ('7a7a7a7a-0000-4000-8000-00000000dead', 'T7 revoked');

-- the call table: every RPC with the staff fixtures allowed to call it (owner B). %1$s = actor literal.
CREATE TEMP TABLE t7_calls(label text PRIMARY KEY, sql text NOT NULL, allowed text[] NOT NULL);
INSERT INTO t7_calls VALUES
 ('get_my_profile',         'SELECT iit.get_my_profile(%1$s)', ARRAY['de','aud','lead','adm','none','multi']),
 ('get_deal',               'SELECT iit.get_deal(''00000000-0000-4000-8007-0000000000d1'', NULL, %1$s)', ARRAY['de','aud','lead','multi']),
 ('list_work_items',        'SELECT iit.list_work_items(NULL, NULL, NULL, NULL, %1$s)', ARRAY['de','aud','lead','multi']),
 ('list_work_items_consign','SELECT iit.list_work_items(''consignment_setup'', NULL, NULL, NULL, %1$s)', ARRAY['de','multi']),
 ('list_audit_queue',       'SELECT iit.list_audit_queue(NULL, NULL, NULL, %1$s)', ARRAY['aud','lead','multi']),
 ('list_audit_queue_esc',   'SELECT iit.list_audit_queue(''escalated'', NULL, NULL, %1$s)', ARRAY['lead']),
 ('list_unknown_outcomes',  'SELECT iit.list_unknown_outcomes(NULL, NULL, %1$s)', ARRAY['de','multi']),
 ('get_unknown_outcome',    'SELECT iit.get_unknown_outcome(''00000000-0000-4000-8007-0000000000f1'', %1$s)', ARRAY['de','multi']),
 ('get_dashboard_summary',  'SELECT iit.get_dashboard_summary(%1$s)', ARRAY['de','aud','lead','multi']),
 ('list_staff_admin',       'SELECT iit.list_staff(''admin'', true, NULL, NULL, %1$s)', ARRAY['adm']),
 ('list_staff_selector',    'SELECT iit.list_staff(''auditor_selector'', false, NULL, NULL, %1$s)', ARRAY['aud','lead','multi']),
 ('list_source_channels',   'SELECT iit.list_source_channels(NULL, NULL, %1$s)', ARRAY['de','multi']),
 ('search_deals',           'SELECT iit.search_deals(''vin'', ''T7VIN00000000000A1'', NULL, NULL, %1$s)', ARRAY['de','aud','lead','multi']);
GRANT SELECT ON t7_calls TO iit_base44, anon, authenticated, service_role, tav_worker, iit_integration;

-- ===================================================================================================================
-- R1 manifest: iit_base44 executes exactly the 27 (= iit_integration's, proven by 006 Z1d2) plus the ten 007 signatures
-- ===================================================================================================================
DO $$ DECLARE new10 text[] := ARRAY['iit.get_my_profile(text)','iit.get_deal(uuid,integer,text)','iit.list_work_items(text,text,integer,text,text)',
    'iit.list_audit_queue(text,integer,text,text)','iit.list_unknown_outcomes(integer,text,text)','iit.get_unknown_outcome(uuid,text)',
    'iit.get_dashboard_summary(text)','iit.list_staff(text,boolean,integer,text,text)','iit.list_source_channels(integer,text,text)',
    'iit.search_deals(text,text,integer,text,text)'];
  b44 text[]; integ text[]; r text; f text; BEGIN
  SELECT array_agg(p.oid::regprocedure::text ORDER BY 1) INTO b44 FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname='iit' AND has_function_privilege('iit_base44', p.oid, 'EXECUTE');
  SELECT array_agg(p.oid::regprocedure::text ORDER BY 1) INTO integ FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname='iit' AND has_function_privilege('iit_integration', p.oid, 'EXECUTE');
  IF cardinality(b44) <> 37 THEN RAISE EXCEPTION 'R1a iit_base44 executes % functions, expected 37', cardinality(b44); END IF;
  IF NOT (b44 @> integ AND b44 @> new10 AND (integ || new10) @> b44 AND cardinality(integ) = 27) THEN RAISE EXCEPTION 'R1b manifest is not the 27 + the ten: %', b44; END IF;
  IF integ && new10 THEN RAISE EXCEPTION 'R1c a read RPC was granted to iit_integration'; END IF;
  FOREACH r IN ARRAY ARRAY['tav_worker','anon','authenticated','service_role','authenticator','iit_integration'] LOOP
    FOREACH f IN ARRAY new10 LOOP
      IF has_function_privilege(r, f::regprocedure, 'EXECUTE') THEN RAISE EXCEPTION 'R1d % can execute %', r, f; END IF;
    END LOOP;
  END LOOP;
  -- the 007 helpers are executable by no one but the owner
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace, unnest(ARRAY['iit_base44','iit_integration','tav_worker','anon','authenticated','service_role','authenticator']) rr(rname)
              WHERE s.nspname='iit' AND p.proname IN ('_read_ctx','_require_read','_page_limit','_cursor_in','_cursor_out','_list_envelope','_not_found','_jsonb_pick',
                    '_deal_state_token','_action_state_token','_audit_read','_deal_visible','_vehicle_summary','_staff_ref','_release_eligibility','_approval_eligibility',
                    '_deal_live','_deal_frozen','_work_item_kinds','_consignment_setup_deals')
                AND has_function_privilege(rr.rname, p.oid, 'EXECUTE')) THEN RAISE EXCEPTION 'R1e a 007 helper is executable by a non-owner role'; END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname='iit' AND p.proname LIKE '\_%' AND p.proname IN ('_read_ctx','_require_read','_page_limit','_cursor_in','_cursor_out','_list_envelope','_not_found','_jsonb_pick',
        '_deal_state_token','_action_state_token','_audit_read','_deal_visible','_vehicle_summary','_staff_ref','_release_eligibility','_approval_eligibility',
        '_deal_live','_deal_frozen','_work_item_kinds','_consignment_setup_deals')) <> 20 THEN RAISE EXCEPTION 'R1f helper inventory'; END IF;
  -- every new RPC: SECURITY DEFINER, search_path pinned empty, owned by iit_owner
  IF EXISTS (SELECT 1 FROM unnest(new10) nf(sig) JOIN pg_proc p ON p.oid = nf.sig::regprocedure
              WHERE NOT p.prosecdef OR p.proowner <> 'iit_owner'::regrole OR p.proconfig IS DISTINCT FROM ARRAY['search_path=""']) THEN RAISE EXCEPTION 'R1g function shape'; END IF;
  -- the hard-coded work-item kinds equal the 005 CHECK constraint
  IF (SELECT array_agg(k ORDER BY k) FROM unnest(iit._work_item_kinds()) k) IS DISTINCT FROM
     (SELECT array_agg(m[1] ORDER BY m[1]) FROM regexp_matches((SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'work_items_kind_check'), '''([a-z0-9_]+)''', 'g') m)
    THEN RAISE EXCEPTION 'R1h _work_item_kinds differs from work_items_kind_check'; END IF;
END $$;

-- R2 the read-access audit table: no privilege for any role but its owner, append-only even for the superuser, and only the
-- identifier-minimized columns (owner E)
DO $$ DECLARE r text; BEGIN
  FOREACH r IN ARRAY ARRAY['iit_base44','iit_integration','tav_worker','anon','authenticated','service_role','authenticator','deployer'] LOOP
    IF has_table_privilege(r, 'iit.read_access_audit', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       OR has_sequence_privilege(r, 'iit.read_access_audit_id_seq', 'USAGE,SELECT,UPDATE') THEN RAISE EXCEPTION 'R2a % holds a privilege on read_access_audit', r; END IF;
  END LOOP;
  IF (SELECT array_agg(attname::text ORDER BY attnum) FROM pg_attribute WHERE attrelid = 'iit.read_access_audit'::regclass AND attnum > 0 AND NOT attisdropped)
     IS DISTINCT FROM ARRAY['id','at','actor_user_id','credential_jti','origin_role','rpc','category','target_type','target_id','target_version','outcome','correlation_id']
    THEN RAISE EXCEPTION 'R2b read_access_audit columns changed'; END IF;
  PERFORM iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-de');
  BEGIN UPDATE iit.read_access_audit SET outcome = 'denied' WHERE rpc = 'get_deal'; RAISE EXCEPTION 'R2c audit row updated'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'R2c%' THEN RAISE; END IF; END;
  BEGIN DELETE FROM iit.read_access_audit; RAISE EXCEPTION 'R2d audit row deleted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'R2d%' THEN RAISE; END IF; END;
END $$;

-- R3 role matrix (claim-less owner session): every RPC succeeds for exactly its allowed staff and is refused with
-- ROLE_MISSING (42501) for every other staff fixture; inactive and unknown identities are refused with 28000 everywhere
DO $$ DECLARE c record; a text; actors text[] := ARRAY['de','aud','lead','adm','none','multi']; m text; BEGIN
  FOR c IN SELECT * FROM t7_calls ORDER BY label LOOP
    FOREACH a IN ARRAY actors LOOP
      IF a = ANY (c.allowed) THEN
        EXECUTE format(c.sql, quote_literal('b44-7-' || a));
      ELSE
        BEGIN EXECUTE format(c.sql, quote_literal('b44-7-' || a)); RAISE EXCEPTION 'R3a % allowed for %', c.label, a;
        EXCEPTION WHEN SQLSTATE '42501' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT;
          IF m NOT LIKE 'ROLE_MISSING:%' THEN RAISE EXCEPTION 'R3b % for %: %', c.label, a, m; END IF; END;
      END IF;
    END LOOP;
    FOREACH a IN ARRAY ARRAY['b44-7-gone','b44-7-nobody'] LOOP
      BEGIN EXECUTE format(c.sql, quote_literal(a)); RAISE EXCEPTION 'R3c % allowed for %', c.label, a;
      EXCEPTION WHEN SQLSTATE '28000' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT;
        IF m <> 'ACTOR_UNKNOWN_OR_INACTIVE' THEN RAISE EXCEPTION 'R3d % for %: %', c.label, a, m; END IF; END;
    END LOOP;
    BEGIN EXECUTE format(c.sql, 'NULL'); RAISE EXCEPTION 'R3e % without actor', c.label;
    EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
  END LOOP;
END $$;

-- R4 credential path, as PostgREST runs it (SET ROLE iit_base44 + request.jwt.claims): every RPC fails closed with the
-- ACTUAL credential error — not masked as a role error — for no claims, a foreign role claim, a missing jti and a revoked
-- jti; with a valid credential each succeeds for its allowed staff. Claims naming iit_base44 from another session role are
-- refused as a mismatch. No audit row survives any of the failures.
DO $$ DECLARE c record; k record; m text; st text; n0 bigint; BEGIN
  SELECT count(*) INTO n0 FROM iit.read_access_audit;
  FOR k IN SELECT * FROM (VALUES (NULL::text, 'CREDENTIAL_NO_CLAIMS'),
                                 ('{"role":"authenticated","jti":"7b7b7b7b-0000-4000-8000-000000000001"}', 'CREDENTIAL_ROLE_MISMATCH'),
                                 ('{"role":"iit_base44"}', 'CREDENTIAL_NO_JTI'),
                                 ('{"role":"iit_base44","jti":"7a7a7a7a-0000-4000-8000-00000000dead"}', 'CREDENTIAL_REVOKED')) v(claims, expect) LOOP
    FOR c IN SELECT * FROM t7_calls ORDER BY label LOOP
      SET LOCAL ROLE iit_base44;
      PERFORM set_config('request.jwt.claims', coalesce(k.claims, ''), true);
      BEGIN EXECUTE format(c.sql, quote_literal('b44-7-' || c.allowed[1])); RAISE EXCEPTION 'R4a % with %', c.label, k.expect;
      EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT, st = RETURNED_SQLSTATE;
        IF st <> '28000' OR m <> k.expect THEN RAISE EXCEPTION 'R4b % expected % (28000), got % (%)', c.label, k.expect, m, st; END IF; END;
      RESET ROLE;
    END LOOP;
  END LOOP;
  FOR c IN SELECT * FROM t7_calls ORDER BY label LOOP
    SET LOCAL ROLE iit_base44;
    PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","jti":"7c7c7c7c-0000-4000-8000-000000000001"}', true);
    EXECUTE format(c.sql, quote_literal('b44-7-' || c.allowed[1]));
    RESET ROLE;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","jti":"7c7c7c7c-0000-4000-8000-000000000001"}', true);
  BEGIN PERFORM iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-de'); RAISE EXCEPTION 'R4c owner session with iit_base44 claims';
  EXCEPTION WHEN SQLSTATE '28000' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'CREDENTIAL_ROLE_MISMATCH' THEN RAISE EXCEPTION 'R4d %', m; END IF; END;
  PERFORM set_config('request.jwt.claims', '', true);
  -- the successful pass above audited get_deal and get_unknown_outcome once each; the failures left nothing
  IF (SELECT count(*) FROM iit.read_access_audit) - n0 <> 2 THEN RAISE EXCEPTION 'R4e % audit rows, expected 2 (failures must leave none)', (SELECT count(*) FROM iit.read_access_audit) - n0; END IF;
END $$;

-- R5 roles outside the door: anon, authenticated, service_role, tav_worker, iit_integration cannot call any read RPC, even with
-- iit_base44 claims; direct table and sequence access stays denied for iit_base44 on every iit table, including the audit table
DO $$ DECLARE c record; r text; t record; BEGIN
  FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role','tav_worker','iit_integration'] LOOP
    FOR c IN SELECT * FROM t7_calls ORDER BY label LOOP
      EXECUTE format('SET LOCAL ROLE %I', r);
      PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","jti":"7c7c7c7c-0000-4000-8000-000000000001"}', true);
      BEGIN EXECUTE format(c.sql, quote_literal('b44-7-de')); RAISE EXCEPTION 'R5a % called %', r, c.label; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
      RESET ROLE;
    END LOOP;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
  SET LOCAL ROLE iit_base44;
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'iit' LOOP
    BEGIN EXECUTE format('SELECT 1 FROM iit.%I LIMIT 1', t.tablename); RAISE EXCEPTION 'R5b SELECT allowed on %', t.tablename; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  END LOOP;
  BEGIN INSERT INTO iit.read_access_audit(actor_user_id, rpc, category, target_type, target_id, outcome)
        VALUES ('00000000-0000-4000-8007-000000000001','get_deal','deal_detail','deal','00000000-0000-4000-8007-0000000000d1','granted'); RAISE EXCEPTION 'R5c audit INSERT';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM nextval('iit.read_access_audit_id_seq'); RAISE EXCEPTION 'R5d sequence'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit._deal_live('00000000-0000-4000-8007-0000000000d1', ARRAY['data_entry']); RAISE EXCEPTION 'R5e helper'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.require_role('b44-7-de', 'data_entry'); RAISE EXCEPTION 'R5f require_role'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.expire_stale_attempts(now()); RAISE EXCEPTION 'R5g worker function'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  RESET ROLE;
END $$;

-- R6 not-found and non-disclosure: unauthorized callers get the same role error for existing and unknown ids; authorized
-- callers get a fixed not-found envelope; a record outside the caller's visibility is indistinguishable from an unknown one
DO $$ DECLARE m1 text; m2 text; nf jsonb := '{"status":"not_found","record_type":"deal"}'; BEGIN
  BEGIN PERFORM iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-adm'); EXCEPTION WHEN SQLSTATE '42501' THEN GET STACKED DIAGNOSTICS m1 = MESSAGE_TEXT; END;
  BEGIN PERFORM iit.get_deal('00000000-0000-4000-8007-00000000ffff', NULL, 'b44-7-adm'); EXCEPTION WHEN SQLSTATE '42501' THEN GET STACKED DIAGNOSTICS m2 = MESSAGE_TEXT; END;
  IF m1 IS NULL OR m1 IS DISTINCT FROM m2 THEN RAISE EXCEPTION 'R6a existing vs unknown differ for an unauthorized caller: % / %', m1, m2; END IF;
  BEGIN PERFORM iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f1', 'b44-7-aud'); EXCEPTION WHEN SQLSTATE '42501' THEN GET STACKED DIAGNOSTICS m1 = MESSAGE_TEXT; END;
  BEGIN PERFORM iit.get_unknown_outcome('00000000-0000-4000-8007-00000000ffff', 'b44-7-aud'); EXCEPTION WHEN SQLSTATE '42501' THEN GET STACKED DIAGNOSTICS m2 = MESSAGE_TEXT; END;
  IF m1 IS DISTINCT FROM m2 THEN RAISE EXCEPTION 'R6b'; END IF;
  IF iit.get_deal('00000000-0000-4000-8007-00000000ffff', NULL, 'b44-7-de') <> nf THEN RAISE EXCEPTION 'R6c not-found envelope'; END IF;
  -- D3 has no audit attempt: invisible to auditors, and indistinguishable from an unknown id
  IF iit.get_deal('00000000-0000-4000-8007-0000000000d3', NULL, 'b44-7-aud') <> nf OR iit.get_deal('00000000-0000-4000-8007-00000000ffff', NULL, 'b44-7-aud') <> nf
    THEN RAISE EXCEPTION 'R6d audit-review visibility'; END IF;
  IF iit.get_deal('00000000-0000-4000-8007-0000000000d3', NULL, 'b44-7-de') ->> 'status' <> 'ok' THEN RAISE EXCEPTION 'R6e data entry sees every deal'; END IF;
  IF iit.get_deal('00000000-0000-4000-8007-0000000000d1', 99, 'b44-7-de') <> '{"status":"not_found","record_type":"deal_version"}'
     OR iit.get_deal('00000000-0000-4000-8007-0000000000d3', 1, 'b44-7-de') <> '{"status":"not_found","record_type":"deal_version"}'   -- a draft has no frozen view
    THEN RAISE EXCEPTION 'R6f version not found'; END IF;
  -- a gate action that was never an unknown outcome is not exposed, and looks like an unknown id
  IF iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f2', 'b44-7-de') <> iit.get_unknown_outcome('00000000-0000-4000-8007-00000000ffff', 'b44-7-de')
     OR iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f2', 'b44-7-de') ->> 'status' <> 'not_found' THEN RAISE EXCEPTION 'R6g gate action disclosure'; END IF;
  -- search hides what get_deal would hide
  IF jsonb_array_length(iit.search_deals('iit_id', '00000000-0000-4000-8007-0000000000d3', NULL, NULL, 'b44-7-aud') -> 'items') <> 0 THEN RAISE EXCEPTION 'R6h auditor found D3'; END IF;
  IF jsonb_array_length(iit.search_deals('iit_id', '00000000-0000-4000-8007-0000000000d3', NULL, NULL, 'b44-7-de') -> 'items') <> 1 THEN RAISE EXCEPTION 'R6i'; END IF;
  IF jsonb_array_length(iit.list_unknown_outcomes(NULL, NULL, 'b44-7-de') -> 'items') < 1 THEN RAISE EXCEPTION 'R6j'; END IF;
END $$;

-- R7 paging contract: default 50, 1..100 accepted, anything else (and any forged or foreign cursor) refused with 22023;
-- walking every list one row at a time returns exactly the single-page result, in the declared order, with no duplicates
DO $$ DECLARE t text; bad int; tmpl text; j jsonb; cur text; walked jsonb; whole jsonb; page jsonb; i int; key text; BEGIN
  FOREACH bad IN ARRAY ARRAY[0, -1, 101, 1000] LOOP
    BEGIN PERFORM iit.list_work_items(NULL, NULL, bad, NULL, 'b44-7-de'); RAISE EXCEPTION 'R7a limit % accepted', bad; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
    BEGIN PERFORM iit.list_staff('admin', true, bad, NULL, 'b44-7-adm'); RAISE EXCEPTION 'R7a2 limit % accepted', bad; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  END LOOP;
  IF (iit.list_work_items(NULL, NULL, NULL, NULL, 'b44-7-de') ->> 'limit')::int <> 50 OR (iit.list_audit_queue(NULL, 100, NULL, 'b44-7-lead') ->> 'limit')::int <> 100 THEN RAISE EXCEPTION 'R7b limits'; END IF;
  FOREACH t IN ARRAY ARRAY['not base64!', encode(convert_to('{"q":"list_work_items|open|*","t":"not a time","id":"00000000-0000-4000-8007-000000000001"}', 'UTF8'), 'base64'),
                           encode(convert_to('{"q":"list_audit_queue|*|false","t":"2026-01-01T00:00:00Z","id":"00000000-0000-4000-8007-000000000001"}', 'UTF8'), 'base64'),
                           encode(convert_to('[1,2]', 'UTF8'), 'base64'), repeat('A', 600)] LOOP
    BEGIN PERFORM iit.list_work_items(NULL, NULL, 1, t, 'b44-7-de'); RAISE EXCEPTION 'R7c cursor accepted: %', t; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  END LOOP;
  FOR tmpl, key IN SELECT * FROM (VALUES
      ('SELECT iit.list_work_items(NULL, ''open'', $L, $C, ''b44-7-multi'')', 'id'),
      ('SELECT iit.list_work_items(NULL, ''closed'', $L, $C, ''b44-7-multi'')', 'id'),
      ('SELECT iit.list_work_items(''consignment_setup'', NULL, $L, $C, ''b44-7-de'')', 'deal_id'),
      ('SELECT iit.list_audit_queue(NULL, $L, $C, ''b44-7-lead'')', 'check_id'),
      ('SELECT iit.list_unknown_outcomes($L, $C, ''b44-7-de'')', 'id'),
      ('SELECT iit.list_staff(''admin'', true, $L, $C, ''b44-7-adm'')', 'user_id'),
      ('SELECT iit.list_staff(''auditor_selector'', false, $L, $C, ''b44-7-aud'')', 'user_id'),
      ('SELECT iit.list_source_channels($L, $C, ''b44-7-de'')', 'id'),
      ('SELECT iit.search_deals(''vin'', '' t7vin00000000000a1 '', $L, $C, ''b44-7-de'')', 'deal_id')) v(tmpl, key) LOOP
    EXECUTE replace(replace(tmpl, '$L', '100'), '$C', 'NULL') INTO whole;
    IF whole ->> 'next_cursor' IS NOT NULL THEN RAISE EXCEPTION 'R7d fixture list exceeds 100: %', tmpl; END IF;
    walked := '[]'; cur := NULL; i := 0;
    LOOP
      EXECUTE replace(replace(tmpl, '$L', '1'), '$C', quote_nullable(cur)) INTO page;
      walked := walked || (page -> 'items'); cur := page ->> 'next_cursor'; i := i + 1;
      EXIT WHEN cur IS NULL OR i > 200;
    END LOOP;
    IF walked <> (whole -> 'items') THEN RAISE EXCEPTION 'R7e paging by 1 differs from one page for %', tmpl; END IF;
    IF (SELECT count(DISTINCT e ->> key) FROM jsonb_array_elements(walked) e) <> jsonb_array_length(walked) THEN RAISE EXCEPTION 'R7f duplicates in %', tmpl; END IF;
    EXECUTE replace(replace(tmpl, '$L', '100'), '$C', 'NULL') INTO j;
    IF (j -> 'items') <> (whole -> 'items') THEN RAISE EXCEPTION 'R7g not deterministic: %', tmpl; END IF;
  END LOOP;
  -- declared orders: open work items by (opened_at, id); audit queue by (opened_at, check_id); consignment rows by deal_number
  whole := iit.list_work_items(NULL, 'open', 100, NULL, 'b44-7-multi') -> 'items';
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(whole) WITH ORDINALITY a(e, n) JOIN jsonb_array_elements(whole) WITH ORDINALITY b(e, n) ON b.n = a.n + 1
              WHERE ((a.e ->> 'opened_at')::timestamptz, (a.e ->> 'id')::uuid) > ((b.e ->> 'opened_at')::timestamptz, (b.e ->> 'id')::uuid)) THEN RAISE EXCEPTION 'R7h work item order'; END IF;
  whole := iit.list_work_items('consignment_setup', NULL, 100, NULL, 'b44-7-de') -> 'items';
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(whole) WITH ORDINALITY a(e, n) JOIN jsonb_array_elements(whole) WITH ORDINALITY b(e, n) ON b.n = a.n + 1
              WHERE (a.e ->> 'deal_number')::bigint >= (b.e ->> 'deal_number')::bigint) THEN RAISE EXCEPTION 'R7i consignment order'; END IF;
  -- a cursor from one query is refused by another
  cur := iit.list_work_items(NULL, 'open', 1, NULL, 'b44-7-multi') ->> 'next_cursor';
  BEGIN PERFORM iit.list_work_items(NULL, 'closed', 1, cur, 'b44-7-multi'); RAISE EXCEPTION 'R7j foreign cursor accepted'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN PERFORM iit.list_audit_queue(NULL, 1, cur, 'b44-7-lead'); RAISE EXCEPTION 'R7k foreign cursor accepted'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
END $$;

-- R8 sensitive-data exclusion (owner C): auditors never receive seller phone/email (live or frozen); nothing returns valuations,
-- raw observations, history before/after, gate action keys, triggering text, free-text evidence or event reasons, work-item
-- detail, report object paths; lists, search and aggregates carry no personal or financial detail
DO $$ DECLARE de jsonb; au jsonb; t text; BEGIN
  de := iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-de');
  au := iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-aud');
  IF de::text NOT LIKE '%(555) 777-0101%' OR de::text NOT LIKE '%sam.seller7@example.test%' THEN RAISE EXCEPTION 'R8a data entry lacks seller contact'; END IF;
  IF au::text LIKE '%777-0101%' OR au::text LIKE '%sam.seller7%' OR au::text LIKE '%"phone"%' OR au::text LIKE '%"email"%' THEN RAISE EXCEPTION 'R8b auditor received seller contact'; END IF;
  IF (au #>> '{data,parties,0,last_name}') <> 'Sellerseven' OR (au #>> '{data,purchase,purchase_price}')::numeric <> 7771.07 THEN RAISE EXCEPTION 'R8c audit facts missing'; END IF;
  IF iit.get_deal('00000000-0000-4000-8007-0000000000d1', 1, 'b44-7-aud')::text LIKE '%777-0101%' THEN RAISE EXCEPTION 'R8d frozen auditor view has seller phone'; END IF;
  IF iit.get_deal('00000000-0000-4000-8007-0000000000d1', 1, 'b44-7-de')::text NOT LIKE '%777-0101%' THEN RAISE EXCEPTION 'R8e frozen data entry view'; END IF;
  FOREACH t IN ARRAY ARRAY['"valuations"','"value"','"body"','"before"','"after"','"history_ids"','"detail"','"object_path"','"action_key"','"snapshot_raw"',
                           '"triggered_by_text"','"outcome_evidence"','k7-secret-key','T7-TRIGGER-TEXT','T7-WI-DETAIL','"phone_normalized"','"user_id"'] LOOP
    IF de::text LIKE '%' || t || '%' OR au::text LIKE '%' || t || '%' THEN RAISE EXCEPTION 'R8f get_deal exposes %', t; END IF;
  END LOOP;
  t := iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f1', 'b44-7-de')::text;
  IF t LIKE '%T7-SECRET-NOTE%' OR t LIKE '%k7-secret-key%' OR t LIKE '%T7-TRIGGER-TEXT%' OR t LIKE '%T7-EVENT-REASON%' OR t LIKE '%"note"%' THEN RAISE EXCEPTION 'R8g unknown outcome exposes restricted text'; END IF;
  IF t NOT LIKE '%"http_status": 504%' OR t NOT LIKE '%"event": "conflict"%' OR t NOT LIKE '%00000000-0000-4000-8007-0000000000c6%' THEN RAISE EXCEPTION 'R8h unknown outcome lacks evidence/timeline/work item: %', t; END IF;
  t := iit.list_unknown_outcomes(100, NULL, 'b44-7-de')::text;
  IF t LIKE '%k7-secret-key%' OR t LIKE '%T7-SECRET-NOTE%' OR t LIKE '%T7-TRIGGER%' THEN RAISE EXCEPTION 'R8i list exposes restricted text'; END IF;
  t := iit.search_deals('vin', 'T7VIN00000000000A1', NULL, NULL, 'b44-7-de')::text || iit.list_work_items(NULL, NULL, 100, NULL, 'b44-7-multi')::text
       || iit.list_work_items(NULL, 'closed', 100, NULL, 'b44-7-de')::text || iit.list_audit_queue(NULL, 100, NULL, 'b44-7-lead')::text;
  IF t LIKE '%Sellerseven%' OR t LIKE '%777-0101%' OR t LIKE '%7771.07%' OR t LIKE '%7773.07%' OR t LIKE '%T7-WI-DETAIL%' OR t LIKE '%"detail"%' OR t LIKE '%T7 escalation comment%'
    THEN RAISE EXCEPTION 'R8j a list or search exposes personal, financial or restricted data'; END IF;
  t := iit.get_dashboard_summary('b44-7-multi')::text;
  IF t ~* '[0-9a-f]{8}-[0-9a-f]{4}-' OR t LIKE '%T7VIN%' OR t LIKE '%T7 %' THEN RAISE EXCEPTION 'R8k dashboard exposes identifiers: %', t; END IF;
  IF iit.list_staff('auditor_selector', false, 100, NULL, 'b44-7-aud')::text LIKE '%"email"%' THEN RAISE EXCEPTION 'R8l selector exposes email'; END IF;
  IF iit.list_staff('admin', false, 100, NULL, 'b44-7-adm')::text NOT LIKE '%t7-de@example.test%' THEN RAISE EXCEPTION 'R8m admin list lacks email'; END IF;
  -- audit decision comments: audit roles only
  IF iit.get_deal('00000000-0000-4000-8007-0000000000d2', NULL, 'b44-7-de')::text LIKE '%T7 escalation comment%' THEN RAISE EXCEPTION 'R8n data entry sees decision comments'; END IF;
  IF iit.get_deal('00000000-0000-4000-8007-0000000000d2', NULL, 'b44-7-lead')::text NOT LIKE '%T7 escalation comment%' THEN RAISE EXCEPTION 'R8o lead lacks decision comments'; END IF;
END $$;

-- R9 read-access audit (owner E): one minimized row per get_deal / get_unknown_outcome call — granted, not_found or denied —
-- with the jti and a well-formed correlation id when the call came through the credential; nothing for lists, search,
-- reference data, aggregates or the profile; nothing survives a rolled-back caller transaction
DO $$ DECLARE n0 bigint; a record; BEGIN
  SELECT max(id) INTO n0 FROM iit.read_access_audit;
  PERFORM iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-de');
  PERFORM iit.get_deal('00000000-0000-4000-8007-00000000ffff', NULL, 'b44-7-de');
  PERFORM iit.get_deal('00000000-0000-4000-8007-0000000000d3', NULL, 'b44-7-aud');
  PERFORM iit.get_deal('00000000-0000-4000-8007-0000000000d1', 1, 'b44-7-aud');
  PERFORM iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f1', 'b44-7-de');
  PERFORM iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f2', 'b44-7-de');
  PERFORM iit.list_work_items(NULL, NULL, NULL, NULL, 'b44-7-de'); PERFORM iit.search_deals('vin', 'T7VIN00000000000A1', NULL, NULL, 'b44-7-de');
  PERFORM iit.get_dashboard_summary('b44-7-de'); PERFORM iit.list_source_channels(NULL, NULL, 'b44-7-de'); PERFORM iit.get_my_profile('b44-7-de');
  PERFORM iit.list_unknown_outcomes(NULL, NULL, 'b44-7-de'); PERFORM iit.list_audit_queue(NULL, NULL, NULL, 'b44-7-aud');
  IF (SELECT array_agg(rpc || ':' || target_type || ':' || outcome || ':' || coalesce(target_version::text, '-') ORDER BY id) FROM iit.read_access_audit WHERE id > n0)
     IS DISTINCT FROM ARRAY['get_deal:deal:granted:-','get_deal:deal:not_found:-','get_deal:deal:denied:-','get_deal:deal_version:granted:1',
                            'get_unknown_outcome:gated_action:granted:-','get_unknown_outcome:gated_action:denied:-']
    THEN RAISE EXCEPTION 'R9a audit rows: %', (SELECT array_agg(rpc || ':' || target_type || ':' || outcome ORDER BY id) FROM iit.read_access_audit WHERE id > n0); END IF;
  SELECT * INTO a FROM iit.read_access_audit WHERE id > n0 ORDER BY id LIMIT 1;
  IF a.actor_user_id <> '00000000-0000-4000-8007-000000000001' OR a.target_id <> '00000000-0000-4000-8007-0000000000d1' OR a.category <> 'deal_detail'
     OR a.credential_jti IS NOT NULL OR a.correlation_id IS NOT NULL THEN RAISE EXCEPTION 'R9b row content'; END IF;
  -- through the credential: jti recorded; correlation id only when well-formed
  SELECT max(id) INTO n0 FROM iit.read_access_audit;
  SET LOCAL ROLE iit_base44;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","jti":"7c7c7c7c-0000-4000-8000-000000000001"}', true);
  PERFORM set_config('request.headers', '{"x-correlation-id":"7d7d7d7d-0000-4000-8000-000000000001"}', true);
  PERFORM iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-de');
  PERFORM set_config('request.headers', '{"x-correlation-id":"not-a-uuid; drop"}', true);
  PERFORM iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f1', 'b44-7-de');
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.headers', '', true);
  IF (SELECT array_agg(coalesce(credential_jti, '-') || '|' || coalesce(correlation_id::text, '-') || '|' || coalesce(origin_role, '-') ORDER BY id) FROM iit.read_access_audit WHERE id > n0)
     IS DISTINCT FROM ARRAY['7c7c7c7c-0000-4000-8000-000000000001|7d7d7d7d-0000-4000-8000-000000000001|iit_base44','7c7c7c7c-0000-4000-8000-000000000001|-|iit_base44']
    THEN RAISE EXCEPTION 'R9c credential rows'; END IF;
END $$;
-- a caller transaction that rolls back takes its audit row with it (documented limitation; the server boundary records it)
CREATE TEMP TABLE t7_mark AS SELECT max(id) AS id FROM iit.read_access_audit;
BEGIN;
SELECT iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-de') IS NOT NULL AS read_inside_tx;
ROLLBACK;
DO $$ BEGIN
  IF (SELECT max(id) FROM iit.read_access_audit) IS DISTINCT FROM (SELECT id FROM t7_mark) THEN RAISE EXCEPTION 'R9d audit row survived a rollback'; END IF;
END $$;

-- R10 function behaviour against canonical sources
DO $$ DECLARE j jsonb; items jsonb; tok1 text; tok2 text; BEGIN
  -- profile: roles from user_roles, sorted; staff without roles get an empty list
  j := iit.get_my_profile('b44-7-multi');
  IF j #> '{data,roles}' <> '["auditor","data_entry"]' OR j #>> '{data,user_id}' <> '00000000-0000-4000-8007-000000000007' OR j #>> '{data,display_name}' <> 'T7 Multi' THEN RAISE EXCEPTION 'R10a profile %', j; END IF;
  IF iit.get_my_profile('b44-7-none') #> '{data,roles}' <> '[]' THEN RAISE EXCEPTION 'R10b no-role profile'; END IF;
  -- derived consignment rows: every open consignment (D4 missing consignor, D5 complete), never the cancelled D6 or a non-consignment
  items := iit.list_work_items('consignment_setup', NULL, 100, NULL, 'b44-7-de') -> 'items';
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(items) e WHERE e ->> 'record_type' <> 'derived_deal' OR e ? 'id') THEN RAISE EXCEPTION 'R10c derived rows must be derived_deal with deal_id only'; END IF;
  SELECT e INTO j FROM jsonb_array_elements(items) e WHERE e ->> 'deal_id' = '00000000-0000-4000-8007-0000000000d4';
  IF j IS NULL OR (j ->> 'consignor_present')::boolean OR j -> 'missing_required_facts' <> to_jsonb(iit.missing_required_facts('00000000-0000-4000-8007-0000000000d4'))
     OR NOT (j -> 'missing_required_facts') ? 'consignor' OR j ->> 'intake_status' <> 'new' OR j ->> 'state_token' <> iit._deal_state_token('00000000-0000-4000-8007-0000000000d4')
     OR j #>> '{vehicle,vin}' <> 'T7VIN00000000000A4' THEN RAISE EXCEPTION 'R10d D4 row %', j; END IF;
  SELECT e INTO j FROM jsonb_array_elements(items) e WHERE e ->> 'deal_id' = '00000000-0000-4000-8007-0000000000d5';
  IF j IS NULL OR NOT (j ->> 'consignor_present')::boolean OR (j ->> 'consignment_amount')::numeric <> 1507 THEN RAISE EXCEPTION 'R10e D5 row %', j; END IF;
  IF items::text LIKE '%0000000000d6%' OR items::text LIKE '%0000000000d1%' OR items::text LIKE '%T7 consignment note%' THEN RAISE EXCEPTION 'R10f consignment queue scope'; END IF;
  BEGIN PERFORM iit.list_work_items('consignment_setup', 'closed', NULL, NULL, 'b44-7-de'); RAISE EXCEPTION 'R10g'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  -- stored work items: visible by assigned role only; kind and status filters; unknown kind refused
  items := iit.list_work_items(NULL, NULL, 100, NULL, 'b44-7-de') -> 'items';
  IF NOT (items::text LIKE '%0000000000c1%' AND items::text LIKE '%0000000000c2%' AND items::text LIKE '%0000000000c6%') OR items::text LIKE '%0000000000c3%' OR items::text LIKE '%0000000000c4%' OR items::text LIKE '%0000000000c5%'
    THEN RAISE EXCEPTION 'R10h data entry items'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(items) e WHERE e ->> 'record_type' <> 'work_item' OR e ->> 'assigned_role' <> 'data_entry') THEN RAISE EXCEPTION 'R10i'; END IF;
  items := iit.list_work_items(NULL, NULL, 100, NULL, 'b44-7-aud') -> 'items';
  IF items::text NOT LIKE '%0000000000c3%' OR items::text LIKE '%0000000000c1%' OR items::text LIKE '%0000000000c4%' THEN RAISE EXCEPTION 'R10j auditor items'; END IF;
  items := iit.list_work_items('restart_candidate', NULL, 100, NULL, 'b44-7-de') -> 'items';
  IF items::text NOT LIKE '%0000000000c2%' OR items::text LIKE '%0000000000c1%' THEN RAISE EXCEPTION 'R10l kind filter'; END IF;
  IF (iit.list_work_items(NULL, 'closed', 100, NULL, 'b44-7-de') -> 'items')::text NOT LIKE '%0000000000c5%' THEN RAISE EXCEPTION 'R10m closed'; END IF;
  BEGIN PERFORM iit.list_work_items('consignment', NULL, NULL, NULL, 'b44-7-de'); RAISE EXCEPTION 'R10n'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN PERFORM iit.list_work_items(NULL, 'blocked', NULL, NULL, 'b44-7-de'); RAISE EXCEPTION 'R10o'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  -- audit queue: auditors see open ordinary attempts; audit leads also see the escalated one
  items := iit.list_audit_queue(NULL, 100, NULL, 'b44-7-aud') -> 'items';
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(items) e WHERE e #>> '{deal,id}' = '00000000-0000-4000-8007-0000000000d1' AND e ->> 'queue_reason' = 'open')
     OR items::text LIKE '%0000000000d2%' THEN RAISE EXCEPTION 'R10p auditor queue'; END IF;
  items := iit.list_audit_queue(NULL, 100, NULL, 'b44-7-lead') -> 'items';
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(items) e WHERE e #>> '{deal,id}' = '00000000-0000-4000-8007-0000000000d2' AND e ->> 'queue_reason' = 'escalated' AND e #>> '{latest_decision,decision}' = 'escalated')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(items) e WHERE e #>> '{deal,id}' = '00000000-0000-4000-8007-0000000000d1') THEN RAISE EXCEPTION 'R10q lead queue'; END IF;
  IF (iit.list_audit_queue('escalated', 100, NULL, 'b44-7-lead') -> 'items')::text LIKE '%0000000000d1%' THEN RAISE EXCEPTION 'R10r escalated filter'; END IF;
  -- dashboard: sections only for held roles; escalations only for leads
  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(iit.get_dashboard_summary('b44-7-de') -> 'data') k) <> ARRAY['data_entry']
     OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(iit.get_dashboard_summary('b44-7-multi') -> 'data') k) <> ARRAY['data_entry','risk_audit']
     OR iit.get_dashboard_summary('b44-7-aud') #> '{data,risk_audit}' ? 'escalated' OR NOT iit.get_dashboard_summary('b44-7-lead') #> '{data,risk_audit}' ? 'escalated'
     OR (iit.get_dashboard_summary('b44-7-lead') #>> '{data,risk_audit,escalated}')::int < 1 OR (iit.get_dashboard_summary('b44-7-de') #>> '{data,data_entry,consignment_setup}')::int < 2
    THEN RAISE EXCEPTION 'R10s dashboard'; END IF;
  -- staff: admin sees inactive only on request; the selector lists active auditors by name only
  IF (iit.list_staff('admin', true, 100, NULL, 'b44-7-adm') -> 'items')::text NOT LIKE '%T7 Gone%' OR (iit.list_staff('admin', false, 100, NULL, 'b44-7-adm') -> 'items')::text LIKE '%T7 Gone%' THEN RAISE EXCEPTION 'R10t admin inactive'; END IF;
  items := iit.list_staff('auditor_selector', false, 100, NULL, 'b44-7-aud') -> 'items';
  IF NOT (items::text LIKE '%T7 Auditor%' AND items::text LIKE '%T7 Lead%' AND items::text LIKE '%T7 Multi%') OR items::text LIKE '%T7 Data Entry%' OR items::text LIKE '%T7 Admin%' THEN RAISE EXCEPTION 'R10u selector'; END IF;
  BEGIN PERFORM iit.list_staff('auditor_selector', true, NULL, NULL, 'b44-7-aud'); RAISE EXCEPTION 'R10v'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN PERFORM iit.list_staff('everyone', false, NULL, NULL, 'b44-7-adm'); RAISE EXCEPTION 'R10w'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  -- source channels: active only
  items := iit.list_source_channels(100, NULL, 'b44-7-de') -> 'items';
  IF items::text NOT LIKE '%TEST7 Audit%' OR items::text LIKE '%TEST7 Off%' THEN RAISE EXCEPTION 'R10x channels'; END IF;
  -- search: the four exact lookups; unlinked 3.1 IDs never resolve; malformed values and unknown types refused
  IF iit.search_deals('iit_id', '00000000-0000-4000-8007-0000000000D1', NULL, NULL, 'b44-7-de') #>> '{items,0,deal_id}' <> '00000000-0000-4000-8007-0000000000d1' THEN RAISE EXCEPTION 'R10y iit_id'; END IF;
  IF iit.search_deals('deal_number', (SELECT ' ' || deal_number || ' ' FROM iit.deals WHERE id = '00000000-0000-4000-8007-0000000000d1'), NULL, NULL, 'b44-7-de') #>> '{items,0,deal_id}' <> '00000000-0000-4000-8007-0000000000d1' THEN RAISE EXCEPTION 'R10z deal_number'; END IF;
  items := iit.search_deals('vin', ' t7vin00000000000a1 ', NULL, NULL, 'b44-7-de') -> 'items';
  IF jsonb_array_length(items) <> 2 THEN RAISE EXCEPTION 'R10aa vin (two deals share the vehicle) %', items; END IF;
  IF jsonb_array_length(iit.search_deals('vin', 'T7VIN00000000000A1', NULL, NULL, 'b44-7-aud') -> 'items') <> 1 THEN RAISE EXCEPTION 'R10ab auditor vin'; END IF;
  j := iit.search_deals('source_31_id', ' T7-IID-1 ', NULL, NULL, 'b44-7-de');
  IF j #>> '{items,0,deal_id}' <> '00000000-0000-4000-8007-0000000000d1' OR j #>> '{items,0,match_label}' <> '3.1 ID' OR j #>> '{items,0,matched_on}' <> 'source_31_id'
     OR (j #>> '{items,0,deal_number}') IS NULL THEN RAISE EXCEPTION 'R10ac source_31_id %', j; END IF;
  IF jsonb_array_length(iit.search_deals('source_31_id', 'T7-IID-2', NULL, NULL, 'b44-7-de') -> 'items') <> 0 THEN RAISE EXCEPTION 'R10ad unlinked 3.1 ID resolved'; END IF;
  IF jsonb_array_length(iit.search_deals('source_31_id', 'T7VIN00000000000A1', NULL, NULL, 'b44-7-de') -> 'items') <> 0 THEN RAISE EXCEPTION 'R10ae VIN fallback'; END IF;
  BEGIN PERFORM iit.search_deals('iit_id', 'IIT-1001', NULL, NULL, 'b44-7-de'); RAISE EXCEPTION 'R10af'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN PERFORM iit.search_deals('deal_number', '12a', NULL, NULL, 'b44-7-de'); RAISE EXCEPTION 'R10ag'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN PERFORM iit.search_deals('stock_number', '123', NULL, NULL, 'b44-7-de'); RAISE EXCEPTION 'R10ah stock search'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN PERFORM iit.search_deals('vin', '   ', NULL, NULL, 'b44-7-de'); RAISE EXCEPTION 'R10ai'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN PERFORM iit.search_deals('vin', repeat('A', 65), NULL, NULL, 'b44-7-de'); RAISE EXCEPTION 'R10aj'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  -- get_deal: projections, eligibility, live vs frozen, and the state token tracks every accepted change
  j := iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-multi');
  IF j -> 'projections' <> '["data_entry","audit_review"]' OR j ->> 'view' <> 'live' OR NOT (j -> 'data') ? 'release_eligibility' OR NOT (j -> 'data') ? 'approval_eligibility' THEN RAISE EXCEPTION 'R10ak multi projection'; END IF;
  IF (iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-de') -> 'data') ? 'approval_eligibility' OR (iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-aud') -> 'data') ? 'release_eligibility' THEN RAISE EXCEPTION 'R10al projection split'; END IF;
  IF (j #>> '{data,approval_eligibility,eligible}')::boolean IS DISTINCT FROM true OR j #>> '{data,current_attempt,status}' <> 'open' OR (j #>> '{data,version,latest_released_version_no}')::int <> 1 THEN RAISE EXCEPTION 'R10am audit eligibility %', j -> 'data'; END IF;
  IF (j #>> '{data,release_eligibility,eligible}')::boolean OR NOT (j #> '{data,release_eligibility,blocking}') ? 'no_open_draft' THEN RAISE EXCEPTION 'R10an release eligibility'; END IF;
  IF NOT ((iit.get_deal('00000000-0000-4000-8007-0000000000d4', NULL, 'b44-7-de') #> '{data,release_eligibility,blocking}') ? 'missing_required_facts') THEN RAISE EXCEPTION 'R10ao'; END IF;
  IF (j #> '{data,work_items}')::text NOT LIKE '%0000000000c3%' OR (iit.get_deal('00000000-0000-4000-8007-0000000000d1', NULL, 'b44-7-de') #> '{data,work_items}')::text LIKE '%0000000000c3%' THEN RAISE EXCEPTION 'R10ap work items by role'; END IF;
  IF jsonb_array_length(j #> '{data,activity}') < 1 OR j #>> '{data,activity,0,action}' IS NULL THEN RAISE EXCEPTION 'R10aq activity'; END IF;
  j := iit.get_deal('00000000-0000-4000-8007-0000000000d1', 1, 'b44-7-aud');
  IF j ->> 'view' <> 'frozen' OR j #>> '{data,version,status}' <> 'released' OR (j #>> '{data,snapshot,deal,purchase_price}')::numeric <> 7771.07 OR j #>> '{data,snapshot,parties,0,party,last_name}' <> 'Sellerseven' THEN RAISE EXCEPTION 'R10ar frozen %', j; END IF;
  tok1 := iit.get_deal('00000000-0000-4000-8007-0000000000d3', NULL, 'b44-7-de') ->> 'state_token';
  IF tok1 IS DISTINCT FROM (iit.get_deal('00000000-0000-4000-8007-0000000000d3', NULL, 'b44-7-de') ->> 'state_token') OR tok1 NOT LIKE 'v1:%' THEN RAISE EXCEPTION 'R10as token unstable'; END IF;
  INSERT INTO iit.deal_titles(deal_id, custody) VALUES ('00000000-0000-4000-8007-0000000000d3', 'in_hand');
  tok2 := iit.get_deal('00000000-0000-4000-8007-0000000000d3', NULL, 'b44-7-de') ->> 'state_token';
  IF tok2 = tok1 THEN RAISE EXCEPTION 'R10at token did not change on a child-row write'; END IF;
  UPDATE iit.work_items SET status = 'closed', closed_at = now(), outcome = 'x' WHERE id = '00000000-0000-4000-8007-0000000000c1';
  IF iit.get_deal('00000000-0000-4000-8007-0000000000d3', NULL, 'b44-7-de') ->> 'state_token' = tok2 THEN RAISE EXCEPTION 'R10au token did not change on a work item'; END IF;
  -- unknown outcome detail: the action's state token tracks its events
  tok1 := iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f1', 'b44-7-de') ->> 'state_token';
  INSERT INTO iit.gated_action_events(action_id, event, detail) VALUES ('00000000-0000-4000-8007-0000000000f1', 'late_report', '{"outcome":"completed"}');
  IF iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f1', 'b44-7-de') ->> 'state_token' = tok1 THEN RAISE EXCEPTION 'R10av action token'; END IF;
END $$;

-- R11 the only rows 007 writes are read-audit rows: no read RPC touched business data or the D-36/D-40 allowlists here
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM iit.record_history WHERE table_name = 'read_access_audit') THEN RAISE EXCEPTION 'R11a audit rows went through history'; END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'iit.read_access_audit'::regclass AND NOT tgisinternal AND tgname <> 'zz_append_only') THEN RAISE EXCEPTION 'R11b unexpected trigger'; END IF;
END $$;

-- R12 admin has no operational visibility (owner B.1; Codex PR #15 P1): an admin-only caller is refused by list_work_items
-- before any work item, deal or parameter is looked at — the same refusal whether matching admin-assigned rows exist (c4,
-- legacy_match) or not, for every filter, and carrying no identifier; an admin who also holds data_entry sees Data Entry items
-- only, never admin-assigned ones; admin alone is refused by every operational read
DO $$ DECLARE m text; ms text[] := '{}'; args text; BEGIN
  IF NOT EXISTS (SELECT 1 FROM iit.work_items WHERE id = '00000000-0000-4000-8007-0000000000c4' AND assigned_role = 'admin' AND status = 'open') THEN RAISE EXCEPTION 'R12a fixture'; END IF;
  IF EXISTS (SELECT 1 FROM iit.work_items WHERE kind = 'duplicate_row' AND assigned_role = 'admin') THEN RAISE EXCEPTION 'R12b fixture'; END IF;
  FOREACH args IN ARRAY ARRAY['NULL, NULL, NULL, NULL', '''legacy_match'', NULL, 100, NULL', '''duplicate_row'', NULL, NULL, NULL', '''consignment_setup'', NULL, NULL, NULL',
                              'NULL, ''closed'', NULL, NULL', '''no_such_kind'', ''bogus'', 1000, ''forged-cursor'''] LOOP
    BEGIN EXECUTE format('SELECT iit.list_work_items(%s, %L)', args, 'b44-7-adm'); RAISE EXCEPTION 'R12c admin listed work items (%)', args;
    EXCEPTION WHEN SQLSTATE '42501' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; ms := ms || m; END;
  END LOOP;
  IF (SELECT count(DISTINCT x) FROM unnest(ms) x) <> 1 OR ms[1] <> 'ROLE_MISSING: list_work_items' THEN RAISE EXCEPTION 'R12d refusals differ or carry data: %', ms; END IF;
  IF array_to_string(ms, ' ') ~* '[0-9a-f]{8}-[0-9a-f]{4}-|T7VIN|legacy_match' THEN RAISE EXCEPTION 'R12e refusal carries an identifier'; END IF;
  -- admin + data_entry: Data Entry rows only; the admin-assigned item never appears, in any filter or status
  IF (iit.list_work_items(NULL, NULL, 100, NULL, 'b44-7-admde') -> 'items')::text NOT LIKE '%0000000000c2%'
     OR (iit.list_work_items(NULL, NULL, 100, NULL, 'b44-7-admde') || iit.list_work_items('legacy_match', NULL, 100, NULL, 'b44-7-admde')
         || iit.list_work_items(NULL, 'closed', 100, NULL, 'b44-7-admde'))::text LIKE '%0000000000c4%'
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(iit.list_work_items(NULL, NULL, 100, NULL, 'b44-7-admde') -> 'items') e WHERE e ->> 'assigned_role' <> 'data_entry')
    THEN RAISE EXCEPTION 'R12f admin role contributed visibility'; END IF;
  -- admin alone: refused by every operational read (deal, queues, search, dashboard, unknown outcomes, channels)
  FOREACH args IN ARRAY ARRAY['SELECT iit.get_deal(''00000000-0000-4000-8007-0000000000d1'', NULL, %L)', 'SELECT iit.list_audit_queue(NULL, NULL, NULL, %L)',
                              'SELECT iit.search_deals(''vin'', ''T7VIN00000000000A1'', NULL, NULL, %L)', 'SELECT iit.get_dashboard_summary(%L)',
                              'SELECT iit.list_unknown_outcomes(NULL, NULL, %L)', 'SELECT iit.get_unknown_outcome(''00000000-0000-4000-8007-0000000000f1'', %L)',
                              'SELECT iit.list_source_channels(NULL, NULL, %L)', 'SELECT iit.list_staff(''auditor_selector'', false, NULL, NULL, %L)'] LOOP
    BEGIN EXECUTE format(args, 'b44-7-adm'); RAISE EXCEPTION 'R12g admin allowed: %', args; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  END LOOP;
  IF iit.list_staff('admin', true, 100, NULL, 'b44-7-adm') ->> 'status' <> 'ok' THEN RAISE EXCEPTION 'R12h admin staff list'; END IF;
END $$;

-- R13 state token coverage (Codex PR #15 P2), in a rolled-back transaction: repeated reads, read-audit rows and changes to
-- other deals leave a deal's token unchanged; one representative accepted change in each covered category — made alone, so
-- that a category missing from the token fails here — changes it. %1$s = D3, %2$s = D1 (attempts, decisions, gate actions),
-- %3$s = D5 (consignment).
BEGIN;
CREATE TEMP TABLE t7_token_cases(n int PRIMARY KEY, label text NOT NULL, deal text NOT NULL, stmt text NOT NULL);
INSERT INTO t7_token_cases VALUES
 ( 1,'deal row',           'd3', 'UPDATE iit.deals SET dealer_auction_name = ''T7 auction'' WHERE id = %1$L'),
 ( 2,'vehicle',            'd3', 'UPDATE iit.vehicles SET exterior_color = ''T7 red'' WHERE id = ''00000000-0000-4000-8007-0000000000a1'''),
 ( 3,'deal channel link',  'd3', 'UPDATE iit.deals SET source_channel_id = (SELECT id FROM iit.source_channels WHERE name = ''TEST7 Audit'') WHERE id = %1$L'),
 ( 4,'source channel row', 'd3', 'UPDATE iit.source_channels SET route = ''hold_in_data_entry'' WHERE name = ''TEST7 Audit'''),
 ( 5,'required-fact rules','d3', 'UPDATE iit.required_fact_rules SET required = NOT required WHERE origin = ''manual_exception'' AND fact = ''closer'''),
 ( 6,'version row',        'd3', 'UPDATE iit.deal_versions SET opened_at = opened_at - interval ''1 minute'' WHERE deal_id = %1$L AND version_no = 1'),
 ( 7,'title',              'd3', 'UPDATE iit.deal_titles SET title_number = ''T7TN'' WHERE deal_id = %1$L'),
 ( 8,'lien insert',        'd3', 'INSERT INTO iit.deal_liens(deal_id, position) VALUES (%1$L, ''none'')'),
 ( 9,'lien field',         'd3', 'UPDATE iit.deal_liens SET per_diem = 7.07 WHERE deal_id = %1$L'),
 (10,'lienholder link',    'd3', 'INSERT INTO iit.organizations(id, name) VALUES (''00000000-0000-4000-8007-0000000000e8'', ''T7 Bank''); UPDATE iit.deal_liens SET lienholder_org_id = ''00000000-0000-4000-8007-0000000000e8'' WHERE deal_id = %1$L'),
 (11,'organization name',  'd3', 'UPDATE iit.organizations SET name = ''T7 Bank Renamed'' WHERE id = ''00000000-0000-4000-8007-0000000000e8'''),
 (12,'seller party',       'd3', 'UPDATE iit.seller_parties SET city = ''Waco'' WHERE id = ''00000000-0000-4000-8007-0000000000b1'''),
 (13,'party link',         'd3', 'UPDATE iit.deal_parties SET ordinal = 2 WHERE deal_id = %1$L'),
 (14,'consignment',        'd5', 'UPDATE iit.consignments SET notes = ''T7 note changed'' WHERE deal_id = %3$L'),
 (15,'flag insert',        'd3', 'INSERT INTO iit.intake_flags(id, deal_id, code) VALUES (''00000000-0000-4000-8007-0000000000e9'', %1$L, ''t7_flag'')'),
 (16,'flag field',         'd3', 'UPDATE iit.intake_flags SET detail = ''changed'' WHERE id = ''00000000-0000-4000-8007-0000000000e9'''),
 (17,'flag status',        'd3', 'UPDATE iit.intake_flags SET status = ''resolved'', resolved_at = now(), resolution = ''x'' WHERE id = ''00000000-0000-4000-8007-0000000000e9'''),
 (18,'hold insert',        'd3', 'INSERT INTO iit.audit_holds(id, deal_id, cause, opened_by) VALUES (''00000000-0000-4000-8007-0000000000ea'', %1$L, ''reaudit_request'', ''00000000-0000-4000-8007-000000000001'')'),
 (19,'hold field',         'd3', 'UPDATE iit.audit_holds SET covers_version_no = 1 WHERE id = ''00000000-0000-4000-8007-0000000000ea'''),
 (20,'requirement insert', 'd3', 'INSERT INTO iit.deal_report_requirements(deal_id, version_no, requirement_key, report_type, subject_type, subject_vin, freshness_baseline) VALUES (%1$L, 1, ''CARFAX:T7VIN00000000000A1'', ''CARFAX'', ''vehicle'', ''T7VIN00000000000A1'', now() - interval ''1 day'')'),
 (21,'requirement field',  'd3', 'UPDATE iit.deal_report_requirements SET freshness_baseline = now() - interval ''2 days'' WHERE deal_id = %1$L'),
 (22,'report insert',      'd3', 'INSERT INTO iit.external_vehicle_reports(id, deal_id, subject_type, vehicle_id, report_type, acquisition, pulled_at) VALUES (''00000000-0000-4000-8007-0000000000eb'', %1$L, ''vehicle'', ''00000000-0000-4000-8007-0000000000a1'', ''CARFAX'', ''manual_upload'', now())'),
 (23,'report file',        'd3', 'UPDATE iit.external_vehicle_reports SET file_recorded_at = now(), file_bytes = 7, file_sha256 = ''ab'' WHERE id = ''00000000-0000-4000-8007-0000000000eb'''),
 (24,'validation',         'd3', 'INSERT INTO iit.report_validations(report_id, requirement_key, deal_id, version_no, outcome, checks, validated_by) VALUES (''00000000-0000-4000-8007-0000000000eb'', ''CARFAX:T7VIN00000000000A1'', %1$L, 1, ''valid'', ''{}'', ''00000000-0000-4000-8007-000000000001'')'),
 (25,'waiver',             'd3', 'INSERT INTO iit.report_waivers(id, deal_id, version_no, requirement_key, waived_by, reason) VALUES (''00000000-0000-4000-8007-0000000000ec'', %1$L, 1, ''CARFAX:T7VIN00000000000A1'', ''00000000-0000-4000-8007-000000000003'', ''T7 waiver'')'),
 (26,'waiver revocation',  'd3', 'INSERT INTO iit.report_waiver_revocations(waiver_id, revoked_by, reason) VALUES (''00000000-0000-4000-8007-0000000000ec'', ''00000000-0000-4000-8007-000000000003'', ''T7 revoked'')'),
 (27,'work item field',    'd3', 'UPDATE iit.work_items SET due_at = now() + interval ''1 day'' WHERE id = ''00000000-0000-4000-8007-0000000000c2'''),
 (28,'material correction','d3', 'INSERT INTO iit.material_corrections(deal_id, from_version_no, draft_version_no, fields, history_ids, by) VALUES (%1$L, 1, 2, ARRAY[''title_number''], ARRAY[1]::bigint[], ''00000000-0000-4000-8007-000000000001'')'),
 (29,'amendment',          'd3', 'INSERT INTO iit.deal_amendments(deal_id, version_no, amendment_no, field, after, by, reason) VALUES (%1$L, 1, 77, ''dealer_sold_to'', ''"x"'', ''00000000-0000-4000-8007-000000000001'', ''T7 amend'')'),
 (30,'activity append',    'd3', 'INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, actor_id, actor_kind, source) VALUES (%1$L, ''deal'', %1$L, ''t7_event'', ''00000000-0000-4000-8007-000000000001'', ''user'', ''t7'')'),
 (31,'staff display name', 'd3', 'UPDATE iit.users SET display_name = ''T7 Data Entry Renamed'' WHERE id = ''00000000-0000-4000-8007-000000000001'''),
 (32,'attempt row',        'd1', 'UPDATE iit.prequalification_checks SET opened_by = ''00000000-0000-4000-8007-000000000002'' WHERE id = iit.current_attempt(%2$L)'),
 (33,'decision append',    'd1', 'INSERT INTO iit.audit_decisions(check_id, decision, decided_by, comments) VALUES (iit.current_attempt(%2$L), ''pending'', ''00000000-0000-4000-8007-000000000001'', ''T7 note'')'),
 (34,'gate action row',    'd1', 'UPDATE iit.gated_actions SET outcome_reported_at = now() WHERE id = ''00000000-0000-4000-8007-0000000000f2''');
DO $$ DECLARE c record; d3 uuid := '00000000-0000-4000-8007-0000000000d3'; d1 uuid := '00000000-0000-4000-8007-0000000000d1'; d5 uuid := '00000000-0000-4000-8007-0000000000d5';
  t0 text; t text; tgt uuid; at0 text; BEGIN
  -- stable under repeated reads, read-audit rows (get_deal writes one each call) and changes to another deal
  t0 := iit._deal_state_token(d3);
  IF iit.get_deal(d3, NULL, 'b44-7-de') ->> 'state_token' <> t0 OR iit.get_deal(d3, NULL, 'b44-7-de') ->> 'state_token' <> t0 THEN RAISE EXCEPTION 'R13a repeated reads changed the token'; END IF;
  INSERT INTO iit.read_access_audit(actor_user_id, rpc, category, target_type, target_id, outcome) VALUES ('00000000-0000-4000-8007-000000000001', 'get_deal', 'deal_detail', 'deal', d3, 'granted');
  UPDATE iit.deals SET dealer_sold_to = 'T7 elsewhere' WHERE id = '00000000-0000-4000-8007-0000000000d4';
  IF iit._deal_state_token(d3) <> t0 OR iit.get_deal(d3, NULL, 'b44-7-de') ->> 'state_token' <> t0 THEN RAISE EXCEPTION 'R13b read audit or another deal changed the token'; END IF;
  -- every covered category, one change at a time
  FOR c IN SELECT * FROM t7_token_cases ORDER BY n LOOP
    tgt := CASE c.deal WHEN 'd3' THEN d3 WHEN 'd1' THEN d1 ELSE d5 END;
    t := iit._deal_state_token(tgt);
    EXECUTE format(c.stmt, d3, d1, d5);
    IF iit._deal_state_token(tgt) = t THEN RAISE EXCEPTION 'R13c token unchanged after: % (%)', c.label, c.n; END IF;
  END LOOP;
  -- get_deal returns the helper's token; the unknown-outcome token follows its work items and its deal
  IF iit.get_deal(d3, NULL, 'b44-7-de') ->> 'state_token' <> iit._deal_state_token(d3) THEN RAISE EXCEPTION 'R13d'; END IF;
  at0 := iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f1', 'b44-7-de') ->> 'state_token';
  IF iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f1', 'b44-7-de') ->> 'state_token' <> at0 THEN RAISE EXCEPTION 'R13e action token unstable'; END IF;
  -- a gate work item without a deal: only the action token's own work-item category can see it
  INSERT INTO iit.work_items(id, kind, gated_action_id, assigned_role) VALUES ('00000000-0000-4000-8007-0000000000ed', 'gate_conflicting_reports', '00000000-0000-4000-8007-0000000000f1', 'data_entry');
  IF iit.get_unknown_outcome('00000000-0000-4000-8007-0000000000f1', 'b44-7-de') ->> 'state_token' = at0 THEN RAISE EXCEPTION 'R13f action token missed a linked work item'; END IF;
  at0 := iit._action_state_token('00000000-0000-4000-8007-0000000000f1');
  UPDATE iit.work_items SET due_at = now() + interval '2 days' WHERE id = '00000000-0000-4000-8007-0000000000ed';
  IF iit._action_state_token('00000000-0000-4000-8007-0000000000f1') = at0 THEN RAISE EXCEPTION 'R13f2 action token missed a work item field'; END IF;
  at0 := iit._action_state_token('00000000-0000-4000-8007-0000000000f1');
  UPDATE iit.deals SET dealer_sold_to = 'T7 changed' WHERE id = d1;
  IF iit._action_state_token('00000000-0000-4000-8007-0000000000f1') = at0 THEN RAISE EXCEPTION 'R13g action token missed its deal'; END IF;
END $$;
ROLLBACK;

SELECT 'ALL 007 TESTS PASS' AS result;
