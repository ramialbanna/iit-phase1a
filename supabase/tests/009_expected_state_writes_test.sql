-- 009_expected_state_writes_test.sql — run as superuser after 001–009 (and their tests). Plain SQL asserts, no pgTAP.
-- S1 manifests and removed signatures · S2 every state-dependent write through the gate (missing / malformed / stale token
-- refused with nothing changed; current token succeeds and moves the state) · S3 authorization precedes the state check ·
-- S4 credential path · S5 list_work_items tokens · S6 Worker, Logistics and read interfaces unchanged.
-- 009_concurrency_test.sh (run after this file) proves a concurrent state change cannot pass.
\set ON_ERROR_STOP on
\set QUIET on

-- ===================================================================================================================
-- fixtures (8009 block)
-- ===================================================================================================================
INSERT INTO iit.users(id, display_name, email) VALUES
  ('00000000-0000-4000-8009-000000000001','T9 Data Entry','t9-de@example.test'), ('00000000-0000-4000-8009-000000000002','T9 Auditor','t9-aud@example.test'),
  ('00000000-0000-4000-8009-000000000003','T9 Lead','t9-lead@example.test');
INSERT INTO iit.staff_identities(base44_user_id, user_id) VALUES ('b44-9-de','00000000-0000-4000-8009-000000000001'),
  ('b44-9-aud','00000000-0000-4000-8009-000000000002'), ('b44-9-lead','00000000-0000-4000-8009-000000000003');
INSERT INTO iit.user_roles(user_id, role) VALUES ('00000000-0000-4000-8009-000000000001','data_entry'), ('00000000-0000-4000-8009-000000000002','auditor'),
  ('00000000-0000-4000-8009-000000000003','audit_lead'), ('00000000-0000-4000-8009-000000000003','auditor');
INSERT INTO iit.source_channels(name, route, origin) VALUES ('TEST9 Audit','risk_audit','manual_exception');
INSERT INTO iit.vehicles(id, vin) VALUES ('00000000-0000-4000-8009-0000000000a1','N9VIN00000000000A1'), ('00000000-0000-4000-8009-0000000000a3','N9VIN00000000000C3'),
  ('00000000-0000-4000-8009-0000000000ab','N9VIN00000000000K1');
-- A: the main workflow deal; C: a consignment; K: release-ready deal for the concurrency script
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, buyer_id, closer_id) VALUES
  ('00000000-0000-4000-8009-0000000000d1','00000000-0000-4000-8009-0000000000a1','manual_exception', 9001, '00000000-0000-4000-8009-000000000001','00000000-0000-4000-8009-000000000001');
INSERT INTO iit.deals(id, vehicle_id, origin, buyer_id, closer_id) VALUES
  ('00000000-0000-4000-8009-0000000000c1','00000000-0000-4000-8009-0000000000a3','manual_consignment','00000000-0000-4000-8009-000000000001','00000000-0000-4000-8009-000000000001');
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, buyer_id, closer_id, source_channel_id, consumer_route) VALUES
  ('00000000-0000-4000-8009-0000000000cc','00000000-0000-4000-8009-0000000000ab','manual_exception', 9003, '00000000-0000-4000-8009-000000000001','00000000-0000-4000-8009-000000000001',
   (SELECT id FROM iit.source_channels WHERE name = 'TEST9 Audit'), 'risk_audit');
INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) SELECT d, 1, 'draft', 'intake'
  FROM unnest(ARRAY['00000000-0000-4000-8009-0000000000d1','00000000-0000-4000-8009-0000000000c1','00000000-0000-4000-8009-0000000000cc']::uuid[]) d;
INSERT INTO iit.seller_parties(id, party_type, first_name, last_name) VALUES ('00000000-0000-4000-8009-0000000000b3','person','Cleo','Consignine');
INSERT INTO iit.deal_parties(deal_id, party_id, role) VALUES ('00000000-0000-4000-8009-0000000000c1','00000000-0000-4000-8009-0000000000b3','owner');
INSERT INTO iit.intake_flags(id, deal_id, code) VALUES ('00000000-0000-4000-8009-0000000000f1','00000000-0000-4000-8009-0000000000d1','t9_flag');
INSERT INTO iit.work_items(id, kind, deal_id, assigned_role) VALUES
  ('00000000-0000-4000-8009-0000000000e1','report_rejected','00000000-0000-4000-8009-0000000000d1','data_entry'),
  ('00000000-0000-4000-8009-0000000000e2','restart_candidate','00000000-0000-4000-8009-0000000000d1','data_entry'),
  ('00000000-0000-4000-8009-0000000000e0','legacy_match', NULL,'data_entry');                                      -- an item with no deal
INSERT INTO iit.gated_actions(id, action_key, iid, deal_id, action, caller_integration, state, deal_version, authorized_at) VALUES
  ('00000000-0000-4000-8009-0000000000a9','k9-action','T9-IID','00000000-0000-4000-8009-0000000000d1','package','appsheet:31','denied',1, now());
INSERT INTO iit.gated_action_attempts(id, action_id, attempt_no, caller_integration, state) VALUES
  ('00000000-0000-4000-8009-0000000000aa','00000000-0000-4000-8009-0000000000a9',1,'appsheet:31','outcome_unknown');
UPDATE iit.gated_actions SET state = 'outcome_unknown', current_attempt_id = '00000000-0000-4000-8009-0000000000aa' WHERE id = '00000000-0000-4000-8009-0000000000a9';

-- the gate: for one call template (%1$s = the token literal) and the SQL that computes the authoritative token, assert every
-- refusal, that a refusal changes nothing, then that the current token succeeds and moves the state. p_inner: for a call
-- whose business preconditions are deliberately unmet, the exact inner error proving the gate passed and delegated.
CREATE FUNCTION pg_temp.gate(p_label text, p_call text, p_token_sql text, p_inner text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE tok text; t2 text; snap0 text; snap1 text; m text; st text; d text; x text; BEGIN
  EXECUTE p_token_sql INTO tok;
  IF tok IS NULL OR tok !~ '^v1:[0-9a-f]{32}$' THEN RAISE EXCEPTION 'G0 % token %', p_label, tok; END IF;
  snap0 := tok || '|' || (SELECT coalesce(max(id), 0) FROM iit.record_history) || '|' || (SELECT count(*) FROM iit.activity_events)
           || '|' || (SELECT count(*) FROM iit.audit_decisions) || '|' || (SELECT count(*) FROM iit.read_access_audit);
  FOREACH x IN ARRAY ARRAY[NULL, ''] LOOP
    BEGIN EXECUTE format(p_call, quote_nullable(x)); RAISE EXCEPTION 'G1 % accepted a missing token', p_label;
    EXCEPTION WHEN SQLSTATE '22023' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'STATE_TOKEN_REQUIRED' THEN RAISE EXCEPTION 'G2 % %', p_label, m; END IF; END;
  END LOOP;
  FOREACH x IN ARRAY ARRAY['garbage', upper(tok), 'v1:' || repeat('a', 31), 'v2:' || repeat('a', 32), tok || ' ', 'v1:' || repeat('g', 32)] LOOP
    BEGIN EXECUTE format(p_call, quote_literal(x)); RAISE EXCEPTION 'G3 % accepted a malformed token %', p_label, x;
    EXCEPTION WHEN SQLSTATE '22023' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'STATE_TOKEN_INVALID' THEN RAISE EXCEPTION 'G4 % % → %', p_label, x, m; END IF; END;
  END LOOP;
  BEGIN EXECUTE format(p_call, quote_literal('v1:' || md5('stale ' || p_label))); RAISE EXCEPTION 'G5 % accepted a stale token', p_label;
  EXCEPTION WHEN SQLSTATE 'PT409' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL;
    IF m <> 'STALE_STATE' OR d <> 'current_state_token=' || tok THEN RAISE EXCEPTION 'G6 % stale → % / %', p_label, m, d; END IF; END;
  EXECUTE p_token_sql INTO t2;
  snap1 := t2 || '|' || (SELECT coalesce(max(id), 0) FROM iit.record_history) || '|' || (SELECT count(*) FROM iit.activity_events)
           || '|' || (SELECT count(*) FROM iit.audit_decisions) || '|' || (SELECT count(*) FROM iit.read_access_audit);
  IF snap1 <> snap0 THEN RAISE EXCEPTION 'G7 % a refusal changed state: % → %', p_label, snap0, snap1; END IF;
  IF p_inner IS NULL THEN
    EXECUTE format(p_call, quote_literal(tok));
    EXECUTE p_token_sql INTO t2;
    IF t2 = tok THEN RAISE EXCEPTION 'G8 % succeeded but the state token did not move', p_label; END IF;
  ELSE
    BEGIN EXECUTE format(p_call, quote_literal(tok)); RAISE EXCEPTION 'G9 % expected the inner error %', p_label, p_inner;
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m NOT LIKE p_inner || '%' THEN RAISE EXCEPTION 'G10 % → %', p_label, m; END IF; END;
  END IF;
END $$;

-- ===================================================================================================================
-- S1 manifests: the 22 replaced signatures are gone from the public surface; the new ones are the only grants; the unchecked
-- originals are owner-only; iit_base44 stays 37 and iit_integration 27; Worker and Logistics manifests unchanged
-- ===================================================================================================================
DO $$ DECLARE
  old text[] := ARRAY['iit.record_decision(uuid,text,text,text)','iit.request_reaudit(uuid,text,text)','iit.validate_report(uuid,text,text,jsonb,text,text)',
    'iit.waive_report(uuid,text,text,text)','iit.revoke_waiver(uuid,text,text)','iit.begin_report_upload(uuid,text,text,uuid,uuid,text,timestamp with time zone,uuid,text)',
    'iit.finish_report_upload(uuid,bigint,text,text)','iit.set_source_channel(uuid,text,text)','iit.release_deal(uuid,text)','iit.correct_field(uuid,text,jsonb,text,text)',
    'iit.amend_field(uuid,text,jsonb,text,text)','iit.rebind_hold(uuid,text,text)','iit.resolve_flag(uuid,text,text,text)','iit.resolve_work_item(uuid,text,text)',
    'iit.cancel_deal(uuid,text,text)','iit.set_seller_party(uuid,text,integer,jsonb,text)','iit.correct_party(uuid,text,integer,jsonb,text,text)',
    'iit.amend_party(uuid,uuid,jsonb,text,text)','iit.set_deal_fact(uuid,text,jsonb,text)','iit.resolve_restart(uuid,text,text,text)',
    'iit.resolve_unknown_outcome(uuid,text,jsonb,text,text)','iit.set_consignment(uuid,uuid,numeric,text,text)'];
  unchanged_staff text[] := ARRAY['iit.set_staff_identity(text,text,text,text)','iit.set_staff_role(uuid,text,boolean,text)','iit.deactivate_staff(text,text)',
    'iit.create_manual_deal(text,text,text,text)','iit.authorize_report_access(uuid,text)'];
  reads text[] := ARRAY['iit.get_my_profile(text)','iit.get_deal(uuid,integer,text)','iit.list_work_items(text,text,integer,text,text)','iit.list_audit_queue(text,integer,text,text)',
    'iit.list_unknown_outcomes(integer,text,text)','iit.get_unknown_outcome(uuid,text)','iit.get_dashboard_summary(text)','iit.list_staff(text,boolean,integer,text,text)',
    'iit.list_source_channels(integer,text,text)','iit.search_deals(text,text,integer,text,text)'];
  new text[]; o text; nm text; r text; base text[]; integ text[]; BEGIN
  SELECT array_agg(p.oid::regprocedure::text ORDER BY p.oid::regprocedure::text) INTO new FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname = 'iit' AND p.proname IN (SELECT split_part(substr(x, 5), '(', 1) FROM unnest(old) x) AND p.proname NOT LIKE '\_%';
  IF cardinality(new) <> 22 THEN RAISE EXCEPTION 'S1a % public functions with the 22 names, expected 22: %', cardinality(new), new; END IF;
  FOREACH o IN ARRAY old LOOP
    IF to_regprocedure(o) IS NOT NULL THEN RAISE EXCEPTION 'S1b old signature still public: %', o; END IF;
    nm := split_part(substr(o, 5), '(', 1);
    IF to_regprocedure('iit._' || nm || '_unchecked(' || split_part(o, '(', 2)) IS NULL THEN RAISE EXCEPTION 'S1c unchecked original missing for %', o; END IF;
    FOREACH r IN ARRAY ARRAY['iit_base44','iit_integration','tav_worker','iit_logistics_reader','anon','authenticated','service_role','authenticator'] LOOP
      IF has_function_privilege(r, ('iit._' || nm || '_unchecked(' || split_part(o, '(', 2))::regprocedure, 'EXECUTE') THEN RAISE EXCEPTION 'S1d % can execute the unchecked %', r, nm; END IF;
    END LOOP;
    -- each new signature is the old one with one extra text argument before the actor
    IF NOT EXISTS (SELECT 1 FROM unnest(new) n WHERE n = regexp_replace(o, ',text\)$', ',text,text)') OR n = regexp_replace(o, '\(uuid,text\)$', '(uuid,text,text)')) THEN
      RAISE EXCEPTION 'S1e no new signature for %', o; END IF;
  END LOOP;
  SELECT array_agg(p.oid::regprocedure::text ORDER BY p.oid::regprocedure::text) INTO base FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'iit' AND has_function_privilege('iit_base44', p.oid, 'EXECUTE');
  SELECT array_agg(p.oid::regprocedure::text ORDER BY p.oid::regprocedure::text) INTO integ FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'iit' AND has_function_privilege('iit_integration', p.oid, 'EXECUTE');
  IF base IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(new || unchanged_staff || reads) x) THEN RAISE EXCEPTION 'S1f iit_base44 manifest: %', base; END IF;
  IF integ IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(new || unchanged_staff) x) THEN RAISE EXCEPTION 'S1g iit_integration manifest: %', integ; END IF;
  IF cardinality(base) <> 37 OR cardinality(integ) <> 27 THEN RAISE EXCEPTION 'S1h manifest sizes % / %', cardinality(base), cardinality(integ); END IF;
  IF (SELECT array_agg(p.oid::regprocedure::text ORDER BY p.oid::regprocedure::text) FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'iit' AND has_function_privilege('tav_worker', p.oid, 'EXECUTE'))
     IS DISTINCT FROM ARRAY['iit.authorize_and_consume(text,text,text,text,text,text,text,text,timestamp with time zone)','iit.expire_stale_attempts(timestamp with time zone)',
                            'iit.ingest_vauto_observation(text,text,jsonb,timestamp with time zone)','iit.report_action_outcome(uuid,text,jsonb,text,text)'] THEN RAISE EXCEPTION 'S1i Worker manifest'; END IF;
  IF (SELECT array_agg(p.oid::regprocedure::text ORDER BY p.oid::regprocedure::text) FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'iit' AND has_function_privilege('iit_logistics_reader', p.oid, 'EXECUTE'))
     IS DISTINCT FROM ARRAY['iit.logistics_deal_summaries(text[],text)','iit.logistics_resolve_31(text[],text)','iit.logistics_vin_candidates(text[],text)'] THEN RAISE EXCEPTION 'S1j Logistics manifest'; END IF;
  -- every new wrapper: SECURITY DEFINER, owner iit_owner, search_path pinned, no PUBLIC; helpers owner-only
  IF EXISTS (SELECT 1 FROM unnest(new) n JOIN pg_proc p ON p.oid = n::regprocedure WHERE NOT p.prosecdef OR p.proowner <> 'iit_owner'::regrole OR p.proconfig IS DISTINCT FROM ARRAY['search_path=""']
              OR EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0)) THEN RAISE EXCEPTION 'S1k wrapper shape'; END IF;
  FOREACH r IN ARRAY ARRAY['iit_base44','iit_integration','tav_worker','iit_logistics_reader','anon','authenticated','service_role'] LOOP
    IF has_function_privilege(r, 'iit._state_token_form(text)', 'EXECUTE') OR has_function_privilege(r, 'iit._state_check(text,text)', 'EXECUTE')
       OR has_function_privilege(r, 'iit._work_item_state_token(uuid)', 'EXECUTE') THEN RAISE EXCEPTION 'S1l % can execute a 009 helper', r; END IF;
  END LOOP;
END $$;
-- an old-signature call from the Base44 role finds no function at all (42883), so nothing can bypass the check
DO $$ BEGIN
  SET LOCAL ROLE iit_base44;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","jti":"tok-2"}', true);
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8009-0000000000d1', 'b44-9-de'); RAISE EXCEPTION 'S1m old release_deal callable';
  EXCEPTION WHEN SQLSTATE '42883' THEN NULL; END;
  BEGIN PERFORM iit.set_deal_fact('00000000-0000-4000-8009-0000000000d1', 'dealer_sold_to', '"x"', 'b44-9-de'); RAISE EXCEPTION 'S1n old set_deal_fact callable';
  EXCEPTION WHEN SQLSTATE '42883' THEN NULL; END;
  BEGIN PERFORM iit._release_deal_unchecked('00000000-0000-4000-8009-0000000000d1', 'b44-9-de'); RAISE EXCEPTION 'S1o unchecked callable';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  PERFORM set_config('request.jwt.claims', '', true);
  RESET ROLE;
END $$;

-- ===================================================================================================================
-- S2 every state-dependent write through the gate, in a realistic order on deal A, consignment C and gate action G
-- ===================================================================================================================
\set A '''00000000-0000-4000-8009-0000000000d1'''
\set TA 'SELECT iit._deal_state_token(''00000000-0000-4000-8009-0000000000d1'')'
SELECT pg_temp.gate('set_source_channel', $q$SELECT iit.set_source_channel('00000000-0000-4000-8009-0000000000d1', 'TEST9 Audit', %1$s, 'b44-9-de')$q$, :'TA');
SELECT pg_temp.gate('set_deal_fact',      $q$SELECT iit.set_deal_fact('00000000-0000-4000-8009-0000000000d1', 'dealer_sold_to', '"N9 Dealer"', %1$s, 'b44-9-de')$q$, :'TA');
SELECT pg_temp.gate('set_seller_party',   $q$SELECT iit.set_seller_party('00000000-0000-4000-8009-0000000000d1', 'owner', 1, '{"party_type":"person","first_name":"Nia","last_name":"Nine"}', %1$s, 'b44-9-de')$q$, :'TA');
INSERT INTO iit.deal_report_requirements(deal_id, version_no, requirement_key, report_type, subject_type, subject_vin, freshness_baseline)
  VALUES ('00000000-0000-4000-8009-0000000000d1', 1, 'CARFAX:N9VIN00000000000A1', 'CARFAX', 'vehicle', 'N9VIN00000000000A1', now() - interval '1 day');
SELECT pg_temp.gate('begin_report_upload', $q$SELECT * FROM iit.begin_report_upload('00000000-0000-4000-8009-0000000000d1', 'CARFAX', 'vehicle', '00000000-0000-4000-8009-0000000000a1', NULL, 'manual_upload', now(), NULL, %1$s, 'b44-9-de')$q$, :'TA');
SELECT id AS report FROM iit.external_vehicle_reports WHERE deal_id = '00000000-0000-4000-8009-0000000000d1' \gset
SELECT pg_temp.gate('finish_report_upload', format($q$SELECT iit.finish_report_upload(%L, 1024, 'ab12', %%1$s, 'b44-9-de')$q$, :'report'), :'TA');
SELECT pg_temp.gate('validate_report', format($q$SELECT iit.validate_report(%L, 'CARFAX:N9VIN00000000000A1', 'valid', '{}'::jsonb, NULL, %%1$s, 'b44-9-de')$q$, :'report'), :'TA');
SELECT pg_temp.gate('waive_report', $q$SELECT iit.waive_report('00000000-0000-4000-8009-0000000000d1', 'CARFAX:N9VIN00000000000A1', 'T9 waiver', %1$s, 'b44-9-lead')$q$, :'TA');
SELECT id AS waiver FROM iit.report_waivers WHERE deal_id = '00000000-0000-4000-8009-0000000000d1' \gset
SELECT pg_temp.gate('revoke_waiver', format($q$SELECT iit.revoke_waiver(%L, 'T9 revoke', %%1$s, 'b44-9-lead')$q$, :'waiver'), :'TA');
SELECT pg_temp.gate('resolve_flag', $q$SELECT iit.resolve_flag('00000000-0000-4000-8009-0000000000f1', 'resolved', 'T9 fixed', %1$s, 'b44-9-de')$q$, :'TA');
SELECT pg_temp.gate('resolve_work_item', $q$SELECT iit.resolve_work_item('00000000-0000-4000-8009-0000000000e1', 'T9 done', %1$s, 'b44-9-de')$q$, :'TA');
SELECT pg_temp.gate('resolve_work_item (no deal)', $q$SELECT iit.resolve_work_item('00000000-0000-4000-8009-0000000000e0', 'T9 done', %1$s, 'b44-9-de')$q$,
                    'SELECT iit._work_item_state_token(''00000000-0000-4000-8009-0000000000e0'')');
SELECT pg_temp.gate('resolve_restart', $q$SELECT iit.resolve_restart('00000000-0000-4000-8009-0000000000e2', 'no_restart', 'T9 no restart', %1$s, 'b44-9-de')$q$, :'TA');
SELECT pg_temp.gate('release_deal', $q$SELECT iit.release_deal('00000000-0000-4000-8009-0000000000d1', %1$s, 'b44-9-de')$q$, :'TA');
SELECT pg_temp.gate('record_decision', format($q$SELECT iit.record_decision(%L, 'pending', 'T9 note', %%1$s, 'b44-9-aud')$q$, iit.current_attempt('00000000-0000-4000-8009-0000000000d1')), :'TA');
SELECT pg_temp.gate('request_reaudit', $q$SELECT iit.request_reaudit('00000000-0000-4000-8009-0000000000d1', 'T9 reaudit', %1$s, 'b44-9-lead')$q$, :'TA');
SELECT pg_temp.gate('correct_field', $q$SELECT iit.correct_field('00000000-0000-4000-8009-0000000000d1', 'purchase_price', '9002', 'T9 price', %1$s, 'b44-9-de')$q$, :'TA');
SELECT pg_temp.gate('amend_field', $q$SELECT iit.amend_field('00000000-0000-4000-8009-0000000000d1', 'dealer_auction_name', '"N9 Auction"', 'T9 amend', %1$s, 'b44-9-de')$q$, :'TA');
SELECT pg_temp.gate('correct_party', $q$SELECT iit.correct_party('00000000-0000-4000-8009-0000000000d1', 'owner', 1, '{"last_name":"Ninth"}', 'T9 party', %1$s, 'b44-9-de')$q$, :'TA');
SELECT dp.party_id AS party FROM iit.deal_parties dp WHERE dp.deal_id = '00000000-0000-4000-8009-0000000000d1' AND dp.role = 'owner' \gset
SELECT pg_temp.gate('amend_party', format($q$SELECT iit.amend_party('00000000-0000-4000-8009-0000000000d1', %L, '{"phone":"(555) 999-0009"}', 'T9 phone', %%1$s, 'b44-9-de')$q$, :'party'), :'TA');
-- rebind_hold's business preconditions (a covering version superseded before approval) are 003's subject; here the gate must
-- pass and hand over to the unchanged function, which refuses on its own terms
SELECT id AS hold FROM iit.audit_holds WHERE deal_id = '00000000-0000-4000-8009-0000000000d1' AND released_at IS NULL ORDER BY opened_at, id LIMIT 1 \gset
SELECT pg_temp.gate('rebind_hold', format($q$SELECT iit.rebind_hold(%L, 'T9 rebind', %%1$s, 'b44-9-lead')$q$, :'hold'), :'TA', 'REBIND_REFUSED');
SELECT pg_temp.gate('resolve_unknown_outcome', $q$SELECT iit.resolve_unknown_outcome('00000000-0000-4000-8009-0000000000a9', 'failed_definitive', NULL, 'T9 resolved', %1$s, 'b44-9-de')$q$,
                    'SELECT iit._action_state_token(''00000000-0000-4000-8009-0000000000a9'')');
SELECT pg_temp.gate('set_consignment', $q$SELECT iit.set_consignment('00000000-0000-4000-8009-0000000000c1', '00000000-0000-4000-8009-0000000000b3', 150, 'T9 consignment', %1$s, 'b44-9-de')$q$,
                    'SELECT iit._deal_state_token(''00000000-0000-4000-8009-0000000000c1'')');
SELECT pg_temp.gate('cancel_deal', $q$SELECT iit.cancel_deal('00000000-0000-4000-8009-0000000000d1', 'T9 cancel', %1$s, 'b44-9-de')$q$, :'TA');
-- the successful calls really happened (spot checks of each family's effect)
DO $$ BEGIN
  IF (SELECT cancelled_at IS NULL OR purchase_price <> 9002 OR dealer_sold_to <> 'N9 Dealer' FROM iit.deals WHERE id = '00000000-0000-4000-8009-0000000000d1') THEN RAISE EXCEPTION 'S2a deal effects'; END IF;
  IF iit.latest_released_version('00000000-0000-4000-8009-0000000000d1') IS NULL THEN RAISE EXCEPTION 'S2b release'; END IF;
  IF (SELECT status FROM iit.intake_flags WHERE id = '00000000-0000-4000-8009-0000000000f1') <> 'resolved'
     OR (SELECT count(*) FROM iit.work_items WHERE id IN ('00000000-0000-4000-8009-0000000000e0','00000000-0000-4000-8009-0000000000e1','00000000-0000-4000-8009-0000000000e2') AND status = 'closed') <> 3
    THEN RAISE EXCEPTION 'S2c flag / items'; END IF;
  IF (SELECT state FROM iit.gated_actions WHERE id = '00000000-0000-4000-8009-0000000000a9') <> 'failed_definitive' THEN RAISE EXCEPTION 'S2d gate outcome'; END IF;
  IF (SELECT consignment_amount FROM iit.consignments WHERE deal_id = '00000000-0000-4000-8009-0000000000c1') <> 150 THEN RAISE EXCEPTION 'S2e consignment'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.report_waiver_revocations r JOIN iit.report_waivers w ON w.id = r.waiver_id WHERE w.deal_id = '00000000-0000-4000-8009-0000000000d1') THEN RAISE EXCEPTION 'S2f waiver revoked'; END IF;
  -- history and actor attribution still come from the unchanged functions: the release was recorded as the staff user
  IF NOT EXISTS (SELECT 1 FROM iit.record_history WHERE table_name = 'deal_versions' AND record_key LIKE '00000000-0000-4000-8009-0000000000d1|%'
                  AND changed_by = '00000000-0000-4000-8009-000000000001' AND actor_kind = 'user') THEN RAISE EXCEPTION 'S2g history attribution'; END IF;
END $$;

-- ===================================================================================================================
-- S3 authorization precedes the state check: a caller without the role, or unknown, learns nothing about state — a wrong
-- role with a stale token still gets ROLE_MISSING, an unknown actor gets 28000, and nothing changes
-- ===================================================================================================================
DO $$ DECLARE m text; t0 text := iit._deal_state_token('00000000-0000-4000-8009-0000000000c1'); BEGIN
  BEGIN PERFORM iit.set_consignment('00000000-0000-4000-8009-0000000000c1', '00000000-0000-4000-8009-0000000000b3', 1, 'x', 'v1:' || md5('stale'), 'b44-9-aud'); RAISE EXCEPTION 'S3a';
  EXCEPTION WHEN SQLSTATE '42501' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'ROLE_MISSING: data_entry' THEN RAISE EXCEPTION 'S3b %', m; END IF; END;
  BEGIN PERFORM iit.set_consignment('00000000-0000-4000-8009-0000000000c1', '00000000-0000-4000-8009-0000000000b3', 1, 'x', NULL, 'b44-9-aud'); RAISE EXCEPTION 'S3c';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.set_consignment('00000000-0000-4000-8009-0000000000c1', '00000000-0000-4000-8009-0000000000b3', 1, 'x', t0, 'b44-nobody'); RAISE EXCEPTION 'S3d';
  EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
  BEGIN PERFORM iit.record_decision(gen_random_uuid(), 'pending', 'x', 'v1:' || md5('stale'), 'b44-9-de'); RAISE EXCEPTION 'S3e';
  EXCEPTION WHEN SQLSTATE '42501' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'ROLE_MISSING: auditor' THEN RAISE EXCEPTION 'S3f %', m; END IF; END;
  -- an unknown target with a well-formed token reaches the unchanged function's own error
  BEGIN PERFORM iit.release_deal(gen_random_uuid(), 'v1:' || md5('x'), 'b44-9-de'); RAISE EXCEPTION 'S3g';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m NOT LIKE 'DEAL_UNKNOWN%' THEN RAISE EXCEPTION 'S3h %', m; END IF; END;
  IF iit._deal_state_token('00000000-0000-4000-8009-0000000000c1') <> t0 THEN RAISE EXCEPTION 'S3i state changed'; END IF;
END $$;

-- ===================================================================================================================
-- S4 the PostgREST credential path through a new signature: revoked / missing claims refused before any state check; a valid
-- credential with the current token succeeds and is attributed as before
-- ===================================================================================================================
DO $$ DECLARE m text; tok text := iit._deal_state_token('00000000-0000-4000-8009-0000000000c1'); BEGIN
  SET LOCAL ROLE iit_base44;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","jti":"tok-1"}', true);                -- revoked by 006's tests
  BEGIN PERFORM iit.set_deal_fact('00000000-0000-4000-8009-0000000000c1', 'dealer_sold_to', '"x"', tok, 'b44-9-de'); RAISE EXCEPTION 'S4a';
  EXCEPTION WHEN SQLSTATE '28000' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'CREDENTIAL_REVOKED' THEN RAISE EXCEPTION 'S4b %', m; END IF; END;
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN PERFORM iit.set_deal_fact('00000000-0000-4000-8009-0000000000c1', 'dealer_sold_to', '"x"', 'garbage', 'b44-9-de'); RAISE EXCEPTION 'S4c';
  EXCEPTION WHEN SQLSTATE '28000' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'CREDENTIAL_NO_CLAIMS' THEN RAISE EXCEPTION 'S4d %', m; END IF; END;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","jti":"tok-2"}', true);
  PERFORM iit.set_deal_fact('00000000-0000-4000-8009-0000000000c1', 'dealer_sold_to', '"N9 via credential"', tok, 'b44-9-de');
  PERFORM set_config('request.jwt.claims', '', true);
  RESET ROLE;
  IF (SELECT dealer_sold_to FROM iit.deals WHERE id = '00000000-0000-4000-8009-0000000000c1') <> 'N9 via credential' THEN RAISE EXCEPTION 'S4e'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.record_history WHERE table_name = 'deals' AND record_id = '00000000-0000-4000-8009-0000000000c1' AND origin_role = 'iit_base44'
                  AND exec_role = 'iit_owner' AND changed_by = '00000000-0000-4000-8009-000000000001') THEN RAISE EXCEPTION 'S4f attribution through the credential'; END IF;
END $$;

-- ===================================================================================================================
-- S5 list_work_items rows carry the token the writes check
-- ===================================================================================================================
INSERT INTO iit.work_items(id, kind, deal_id, assigned_role) VALUES ('00000000-0000-4000-8009-0000000000e5','report_rejected','00000000-0000-4000-8009-0000000000c1','data_entry'),
  ('00000000-0000-4000-8009-0000000000e6','legacy_match', NULL,'data_entry');
DO $$ DECLARE items jsonb; BEGIN
  items := iit.list_work_items(NULL, NULL, 100, NULL, 'b44-9-de') -> 'items';
  IF (SELECT e ->> 'state_token' FROM jsonb_array_elements(items) e WHERE e ->> 'id' = '00000000-0000-4000-8009-0000000000e5') <> iit._deal_state_token('00000000-0000-4000-8009-0000000000c1')
     OR (SELECT e ->> 'state_token' FROM jsonb_array_elements(items) e WHERE e ->> 'id' = '00000000-0000-4000-8009-0000000000e6') <> iit._work_item_state_token('00000000-0000-4000-8009-0000000000e6')
    THEN RAISE EXCEPTION 'S5a list_work_items tokens'; END IF;
  PERFORM iit.resolve_work_item('00000000-0000-4000-8009-0000000000e5', 'via list token',
            (SELECT e ->> 'state_token' FROM jsonb_array_elements(items) e WHERE e ->> 'id' = '00000000-0000-4000-8009-0000000000e5'), 'b44-9-de');
  PERFORM iit.resolve_work_item('00000000-0000-4000-8009-0000000000e6', 'via list token',
            (SELECT e ->> 'state_token' FROM jsonb_array_elements(items) e WHERE e ->> 'id' = '00000000-0000-4000-8009-0000000000e6'), 'b44-9-de');
END $$;

-- ===================================================================================================================
-- S6 interfaces 009 must not change: require_role keeps its 008 body; the Logistics wrappers still answer; reads unchanged
-- ===================================================================================================================
DO $$ DECLARE e jsonb; BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'iit.require_role(text,text)'::regprocedure) <> 'fcdd9a0bc7c722a247bbc070d462afe1' THEN RAISE EXCEPTION 'S6a require_role changed'; END IF;
  SET LOCAL ROLE iit_logistics_reader;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000909"}', true);
  e := iit.logistics_deal_summaries(ARRAY['00000000-0000-4000-8009-0000000000d1'], '7d7d7d7d-0000-4000-8000-000000000909');
  PERFORM set_config('request.jwt.claims', '', true);
  RESET ROLE;
  IF e #>> '{rows,0,found}' <> 'true' THEN RAISE EXCEPTION 'S6b logistics interface: %', e; END IF;
  IF iit.get_deal('00000000-0000-4000-8009-0000000000d1', NULL, 'b44-9-de') ->> 'state_token' <> iit._deal_state_token('00000000-0000-4000-8009-0000000000d1') THEN RAISE EXCEPTION 'S6c get_deal token'; END IF;
END $$;

-- S7 the gate-outcome write checks the ACTION token, which also covers attempts and events the deal token does not: a new
-- event after the operator read the outcome must make that read stale
INSERT INTO iit.gated_actions(id, action_key, iid, deal_id, action, caller_integration, state, deal_version, authorized_at) VALUES
  ('00000000-0000-4000-8009-0000000000b9','k9-action-2','T9-IID-2','00000000-0000-4000-8009-0000000000c1','package','appsheet:31','denied',1, now());
INSERT INTO iit.gated_action_attempts(id, action_id, attempt_no, caller_integration, state) VALUES
  ('00000000-0000-4000-8009-0000000000ba','00000000-0000-4000-8009-0000000000b9',1,'appsheet:31','outcome_unknown');
UPDATE iit.gated_actions SET state = 'outcome_unknown', current_attempt_id = '00000000-0000-4000-8009-0000000000ba' WHERE id = '00000000-0000-4000-8009-0000000000b9';
DO $$ DECLARE t text := iit._action_state_token('00000000-0000-4000-8009-0000000000b9'); dt text := iit._deal_state_token('00000000-0000-4000-8009-0000000000c1'); m text; BEGIN
  INSERT INTO iit.gated_action_events(action_id, event, detail) VALUES ('00000000-0000-4000-8009-0000000000b9', 'late_report', '{"outcome":"completed"}');
  IF iit._deal_state_token('00000000-0000-4000-8009-0000000000c1') <> dt THEN RAISE EXCEPTION 'S7a premise: the event should not move the deal token'; END IF;
  BEGIN PERFORM iit.resolve_unknown_outcome('00000000-0000-4000-8009-0000000000b9', 'completed', '{}', 'T9', t, 'b44-9-de'); RAISE EXCEPTION 'S7b stale action read accepted';
  EXCEPTION WHEN SQLSTATE 'PT409' THEN NULL; END;
  IF (SELECT state FROM iit.gated_actions WHERE id = '00000000-0000-4000-8009-0000000000b9') <> 'outcome_unknown' THEN RAISE EXCEPTION 'S7c mutated'; END IF;
END $$;

SELECT 'ALL 009 TESTS PASS' AS result;
