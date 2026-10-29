-- 008_logistics_read_interface_test.sql — run as superuser after 001–008 (and their tests). Plain SQL asserts, no pgTAP.
-- L1 role/membership · L2 exact privilege matrix (T8) · L3 credential paths in-session (T1–T5, require_role) · L4 jti forms
-- (T15) · L5 correlation ids (T11) · L6 input validation and envelopes (T10, T12) · L7 contract: ordinality, duplicates,
-- linkage, liveness, VIN normalization (T10, Q2, Q3) · L8 audit split (T9) · L9 read-only (T14) · L10 batch budgets (T16) ·
-- L11 real authenticator session (T1–T7) · L12 base44 credential regression after the require_role change.
-- Fixtures use the 8008 UUID block. Logistics calls run as PostgREST runs them: SET ROLE iit_logistics_reader + claims.
\set ON_ERROR_STOP on
\set QUIET on

-- ===================================================================================================================
-- fixtures
-- ===================================================================================================================
INSERT INTO iit.vehicles(id, vin, year, make_text, model_text) VALUES
  ('00000000-0000-4000-8008-0000000000a1','L8VIN00000000000A1',2022,'Ram','1500'),
  ('00000000-0000-4000-8008-0000000000a2','L8VIN00000000000B2',2021,'Ford','Ranger'),
  ('00000000-0000-4000-8008-0000000000a4','L8VIN00000000000C3',2020,'Kia','Soul'),
  ('00000000-0000-4000-8008-0000000000a5','  l8vin00000000000d4 ',2019,'Mazda','3');           -- stored untrimmed/lowercase
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, dealer_sold_to, source_channel_id) VALUES
  ('00000000-0000-4000-8008-0000000000d1','00000000-0000-4000-8008-0000000000a1','manual_exception', 8801.08, 'L8 Dealer One', (SELECT id FROM iit.source_channels WHERE name = 'Brown Fig – Manheim')),
  ('00000000-0000-4000-8008-0000000000d2','00000000-0000-4000-8008-0000000000a2','manual_exception', 8802.08, NULL, NULL),
  ('00000000-0000-4000-8008-0000000000d3','00000000-0000-4000-8008-0000000000a2','manual_exception', 8803.08, NULL, NULL),   -- second live deal, same vehicle
  ('00000000-0000-4000-8008-0000000000d7','00000000-0000-4000-8008-0000000000a5','manual_exception', 8807.08, NULL, NULL);
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, cancelled_at, cancellation_reason) VALUES
  ('00000000-0000-4000-8008-0000000000d4','00000000-0000-4000-8008-0000000000a4','manual_exception', 8804.08, now(), 'L8 cancelled');
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, intake_status) VALUES
  ('00000000-0000-4000-8008-0000000000d5','00000000-0000-4000-8008-0000000000a4','manual_exception', 8805.08, 'voided');
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, final_closure_at) VALUES
  ('00000000-0000-4000-8008-0000000000d6','00000000-0000-4000-8008-0000000000a4','manual_exception', 8806.08, now());
INSERT INTO iit.source_records(legacy_iid, deal_id, kind, created_via, link_status, linked_at) VALUES ('L8-IID-1','00000000-0000-4000-8008-0000000000d1','initial','bridge','linked', now());
INSERT INTO iit.source_records(legacy_iid, deal_id, kind, created_via) VALUES ('L8-IID-2','00000000-0000-4000-8008-0000000000d2','initial','bridge');   -- unlinked, deal set
INSERT INTO iit.source_records(legacy_iid, kind, created_via, link_status) VALUES ('L8-IID-3','initial','bridge','conflict');
INSERT INTO iit.revoked_credentials(jti, reason) VALUES ('8a8a8a8a-0000-4000-8000-00000000dead', 'L8 revoked');
INSERT INTO iit.revoked_credentials(jti, reason) VALUES ('  8B8B8B8B-0000-4000-8000-00000000BEEF ', 'L8 revoked, entered uppercase and padded');

-- ===================================================================================================================
-- L1 the role: NOLOGIN NOINHERIT, unprivileged; authenticator holds it SET only; it is a member of nothing
-- ===================================================================================================================
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iit_logistics_reader' AND NOT rolcanlogin AND NOT rolinherit AND NOT rolsuper
                  AND NOT rolbypassrls AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication) THEN RAISE EXCEPTION 'L1a role attributes'; END IF;
  IF (SELECT count(*) FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
       WHERE r.rolname = 'iit_logistics_reader' AND m.rolname = 'authenticator') <> 1
     OR NOT EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
       WHERE r.rolname = 'iit_logistics_reader' AND m.rolname = 'authenticator' AND am.set_option AND NOT am.inherit_option AND NOT am.admin_option)
    THEN RAISE EXCEPTION 'L1b authenticator membership is not exactly SET only'; END IF;
  IF EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles m ON m.oid = am.member WHERE m.rolname = 'iit_logistics_reader') THEN RAISE EXCEPTION 'L1c member of a role'; END IF;
END $$;

-- ===================================================================================================================
-- L2 exact privilege matrix (T8)
-- ===================================================================================================================
DO $$ DECLARE pub text[] := ARRAY['iit.logistics_resolve_31(text[],text)','iit.logistics_deal_summaries(text[],text)','iit.logistics_vin_candidates(text[],text)'];
  helpers text[] := ARRAY['iit.require_logistics_reader()','iit._logistics_correlation(text)','iit._logistics_input_check(text[],integer,text)',
    'iit._logistics_audit(text,uuid,uuid,text,integer,integer,text,text)','iit._logistics_denied(text,uuid)','iit._logistics_resolve_31_rows(text[])',
    'iit._logistics_deal_summary_rows(uuid[])','iit._logistics_vin_candidate_rows(text[])'];
  others text[] := ARRAY['iit_base44','tav_worker','iit_integration','anon','authenticated','service_role','authenticator'];
  r text; f text; n int; BEGIN
  -- iit_logistics_reader executes exactly the three wrappers and nothing else in iit
  IF (SELECT array_agg(p.oid::regprocedure::text ORDER BY p.oid::regprocedure::text) FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
       WHERE s.nspname = 'iit' AND has_function_privilege('iit_logistics_reader', p.oid, 'EXECUTE'))
     IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(pub) x) THEN RAISE EXCEPTION 'L2a logistics manifest is not exactly the three wrappers'; END IF;
  -- nobody else executes them; nobody but the owner executes the helpers; no PUBLIC entry on any 008 function
  FOREACH f IN ARRAY pub || helpers LOOP
    FOREACH r IN ARRAY others LOOP
      IF has_function_privilege(r, f::regprocedure, 'EXECUTE') THEN RAISE EXCEPTION 'L2b % can execute %', r, f; END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE p.oid = f::regprocedure AND a.grantee = 0) THEN RAISE EXCEPTION 'L2c PUBLIC on %', f; END IF;
  END LOOP;
  FOREACH f IN ARRAY helpers LOOP
    IF has_function_privilege('iit_logistics_reader', f::regprocedure, 'EXECUTE') THEN RAISE EXCEPTION 'L2d logistics can execute helper %', f; END IF;
  END LOOP;
  -- shape: SECURITY DEFINER wrappers, VOLATILE, owned by iit_owner, search_path pinned
  IF EXISTS (SELECT 1 FROM unnest(pub) x JOIN pg_proc p ON p.oid = x::regprocedure
              WHERE NOT p.prosecdef OR p.provolatile <> 'v' OR p.proowner <> 'iit_owner'::regrole OR p.proconfig IS DISTINCT FROM ARRAY['search_path=""']) THEN RAISE EXCEPTION 'L2e wrapper shape'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(helpers) x JOIN pg_proc p ON p.oid = x::regprocedure WHERE p.proowner <> 'iit_owner'::regrole OR p.proconfig IS DISTINCT FROM ARRAY['search_path=""'])
    THEN RAISE EXCEPTION 'L2f helper shape'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(ARRAY['iit._logistics_resolve_31_rows(text[])','iit._logistics_deal_summary_rows(uuid[])','iit._logistics_vin_candidate_rows(text[])']) x
              JOIN pg_proc p ON p.oid = x::regprocedure WHERE p.provolatile <> 's') THEN RAISE EXCEPTION 'L2g read helpers must be STABLE'; END IF;
  -- no table or sequence privilege for the role anywhere in iit; schema usage only
  SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace WHERE s.nspname = 'iit' AND (
      (c.relkind IN ('r','p','v','m','f') AND has_table_privilege('iit_logistics_reader', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))
   OR (c.relkind = 'S' AND has_sequence_privilege('iit_logistics_reader', c.oid, 'USAGE,SELECT,UPDATE')));
  IF n <> 0 THEN RAISE EXCEPTION 'L2h logistics holds % relation privileges', n; END IF;
  IF NOT has_schema_privilege('iit_logistics_reader', 'iit', 'USAGE') OR has_schema_privilege('iit_logistics_reader', 'iit', 'CREATE') THEN RAISE EXCEPTION 'L2i schema'; END IF;
  -- the audit table: no privilege for any non-owner application role, iit_integration included (Q7); append-only
  FOREACH r IN ARRAY others || ARRAY['iit_logistics_reader','deployer'] LOOP
    IF has_table_privilege(r, 'iit.logistics_read_audit', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       OR has_sequence_privilege(r, 'iit.logistics_read_audit_id_seq', 'USAGE,SELECT,UPDATE') THEN RAISE EXCEPTION 'L2j % holds a privilege on logistics_read_audit', r; END IF;
  END LOOP;
  IF (SELECT array_agg(tgname::text) FROM pg_trigger WHERE tgrelid = 'iit.logistics_read_audit'::regclass AND NOT tgisinternal) IS DISTINCT FROM ARRAY['zz_append_only'] THEN RAISE EXCEPTION 'L2k audit triggers'; END IF;
  IF (SELECT array_agg(attname::text ORDER BY attnum) FROM pg_attribute WHERE attrelid = 'iit.logistics_read_audit'::regclass AND attnum > 0 AND NOT attisdropped)
     IS DISTINCT FROM ARRAY['id','at','function','credential_jti','correlation_id','correlation_source','input_count','invalid_count','outcome','error_code'] THEN RAISE EXCEPTION 'L2l audit columns'; END IF;
  -- existing manifests unchanged by 008
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'iit' AND has_function_privilege('iit_base44', p.oid, 'EXECUTE')) <> 37
     OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'iit' AND has_function_privilege('iit_integration', p.oid, 'EXECUTE')) <> 27
     OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'iit' AND has_function_privilege('tav_worker', p.oid, 'EXECUTE')) <> 4
    THEN RAISE EXCEPTION 'L2m an existing manifest changed'; END IF;
  -- require_role keeps its ACL (owner only) after CREATE OR REPLACE
  IF EXISTS (SELECT 1 FROM unnest(others || ARRAY['iit_logistics_reader']) x WHERE has_function_privilege(x, 'iit.require_role(text,text)', 'EXECUTE')) THEN RAISE EXCEPTION 'L2n require_role ACL'; END IF;
END $$;

-- ===================================================================================================================
-- L3 credential paths (T1–T5 in-session; the real authenticator session repeats them in L11). Each failure raises 28000 with
-- only its code and leaves no audit row.
-- ===================================================================================================================
DO $$ DECLARE k record; m text; st text; n0 bigint; BEGIN
  SELECT count(*) INTO n0 FROM iit.logistics_read_audit;
  FOR k IN SELECT * FROM (VALUES (NULL::text, 'CREDENTIAL_NO_CLAIMS'), ('not json', 'CREDENTIAL_NO_CLAIMS'), ('[1]', 'CREDENTIAL_NO_CLAIMS'),
      ('{"role":"iit_base44","jti":"7e7e7e7e-0000-4000-8000-000000000001"}', 'CREDENTIAL_ROLE_MISMATCH'),
      ('{"jti":"7e7e7e7e-0000-4000-8000-000000000001"}', 'CREDENTIAL_ROLE_MISMATCH'),
      ('{"role":"iit_logistics_reader"}', 'CREDENTIAL_NO_JTI'), ('{"role":"iit_logistics_reader","jti":""}', 'CREDENTIAL_NO_JTI'),
      ('{"role":"iit_logistics_reader","jti":null}', 'CREDENTIAL_NO_JTI'),
      ('{"role":"iit_logistics_reader","jti":"8a8a8a8a-0000-4000-8000-00000000dead"}', 'CREDENTIAL_REVOKED'),
      ('{"role":"iit_logistics_reader","jti":"8b8b8b8b-0000-4000-8000-00000000beef"}', 'CREDENTIAL_REVOKED')) v(claims, expect) LOOP
    SET LOCAL ROLE iit_logistics_reader;
    PERFORM set_config('request.jwt.claims', coalesce(k.claims, ''), true);
    BEGIN PERFORM iit.logistics_resolve_31(ARRAY['L8-IID-1'], '7d7d7d7d-0000-4000-8000-000000000001'); RAISE EXCEPTION 'L3a accepted %', k.claims;
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT, st = RETURNED_SQLSTATE;
      IF st <> '28000' OR m <> k.expect THEN RAISE EXCEPTION 'L3b % expected % got % (%)', k.claims, k.expect, m, st; END IF; END;
    RESET ROLE;
  END LOOP;
  -- valid Logistics claims through any other originating role: the owner session reaches the body and is refused; the
  -- other roles have no EXECUTE at all (42501 before the body)
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000001"}', true);
  BEGIN PERFORM iit.logistics_vin_candidates(ARRAY['L8VIN00000000000A1'], '7d7d7d7d-0000-4000-8000-000000000001'); RAISE EXCEPTION 'L3c owner origin accepted';
  EXCEPTION WHEN SQLSTATE '28000' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'CREDENTIAL_WRONG_ORIGIN' THEN RAISE EXCEPTION 'L3d %', m; END IF; END;
  FOREACH m IN ARRAY ARRAY['iit_base44','authenticated','service_role','anon','tav_worker','iit_integration'] LOOP
    EXECUTE format('SET LOCAL ROLE %I', m);
    BEGIN PERFORM iit.logistics_deal_summaries(ARRAY['00000000-0000-4000-8008-0000000000d1'], '7d7d7d7d-0000-4000-8000-000000000001'); RAISE EXCEPTION 'L3e % called a logistics function', m;
    EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
    RESET ROLE;
  END LOOP;
  -- require_role refuses Logistics claims under any origin, so the token can never act as a staff actor
  BEGIN PERFORM iit.require_role('b44-de', 'data_entry'); RAISE EXCEPTION 'L3f require_role accepted logistics claims';
  EXCEPTION WHEN SQLSTATE '28000' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'CREDENTIAL_ROLE_MISMATCH' THEN RAISE EXCEPTION 'L3g %', m; END IF; END;
  SET LOCAL ROLE iit_integration;
  BEGIN PERFORM iit.release_deal('00000000-0000-4000-8008-0000000000d1', 'b44-de'); RAISE EXCEPTION 'L3h staff RPC under logistics claims';
  EXCEPTION WHEN SQLSTATE '28000' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'CREDENTIAL_ROLE_MISMATCH' THEN RAISE EXCEPTION 'L3i %', m; END IF; END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  IF (SELECT count(*) FROM iit.logistics_read_audit) <> n0 THEN RAISE EXCEPTION 'L3j a credential failure left an audit row'; END IF;
END $$;

-- ===================================================================================================================
-- L4 jti forms (T15): every malformed or non-v4 jti → CREDENTIAL_INVALID_JTI, message = code only, no audit row; a valid v4
-- jti is stored as that uuid
-- ===================================================================================================================
DO $$ DECLARE j text; m text; n0 bigint; a record; BEGIN
  SELECT count(*) INTO n0 FROM iit.logistics_read_audit;
  FOREACH j IN ARRAY ARRAY[
      to_jsonb('7e7e7e7e-0000-4000-8000-0000000000011'::text)::text, to_jsonb(repeat('a', 1024))::text, to_jsonb(repeat('b', 10240))::text,
      to_jsonb('not-a-uuid'::text)::text, to_jsonb('7e7e7e7e-0000-4000-8000-00000000000'::text)::text, to_jsonb('7e7e7e7e-0000-4000-8000-0000-00000001'::text)::text,
      to_jsonb('7E7E7E7E-0000-4000-8000-000000000001'::text)::text, to_jsonb('{7e7e7e7e-0000-4000-8000-000000000001}'::text)::text,
      to_jsonb('00000000-0000-0000-0000-000000000000'::text)::text, to_jsonb('7e7e7e7e-0000-1000-8000-000000000001'::text)::text,
      to_jsonb('7e7e7e7e-0000-7000-8000-000000000001'::text)::text, to_jsonb('7e7e7e7e-0000-4000-c000-000000000001'::text)::text,
      to_jsonb('L8VIN00000000000A1'::text)::text, to_jsonb('100045'::text)::text, to_jsonb('L8-IID-1'::text)::text, to_jsonb('ops@example.test'::text)::text,
      '12345', '{"x":1}', '["7e7e7e7e-0000-4000-8000-000000000001"]', 'true'] LOOP
    SET LOCAL ROLE iit_logistics_reader;
    PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":' || j || '}', true);
    BEGIN PERFORM iit.logistics_resolve_31(ARRAY['L8-IID-1'], '7d7d7d7d-0000-4000-8000-000000000001'); RAISE EXCEPTION 'L4a jti accepted: %', left(j, 60);
    EXCEPTION WHEN SQLSTATE '28000' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> 'CREDENTIAL_INVALID_JTI' THEN RAISE EXCEPTION 'L4b % → %', left(j, 60), m; END IF; END;
    RESET ROLE;
  END LOOP;
  IF (SELECT count(*) FROM iit.logistics_read_audit) <> n0 THEN RAISE EXCEPTION 'L4c an invalid jti left an audit row'; END IF;
  SET LOCAL ROLE iit_logistics_reader;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000002"}', true);
  PERFORM iit.logistics_resolve_31(ARRAY['L8-IID-1'], '7d7d7d7d-0000-4000-8000-000000000002');
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  SELECT * INTO a FROM iit.logistics_read_audit ORDER BY id DESC LIMIT 1;
  IF a.credential_jti <> '7e7e7e7e-0000-4000-8000-000000000002' OR a.correlation_id <> '7d7d7d7d-0000-4000-8000-000000000002' OR a.correlation_source <> 'caller' OR a.outcome <> 'ok'
    THEN RAISE EXCEPTION 'L4d valid jti/correlation not stored as given'; END IF;
END $$;

-- ===================================================================================================================
-- L5 correlation ids (T11, amendment A1): only lowercase UUIDv4 accepted; anything else → denied with a server UUID that is
-- returned and stored, and the rejected value appears in no audit column
-- ===================================================================================================================
DO $$ DECLARE c text; e jsonb; a record; codes text[] := '{}'; want text; BEGIN
  FOREACH c IN ARRAY ARRAY['', '7D7D7D7D-0000-4000-8000-000000000003', '{7d7d7d7d-0000-4000-8000-000000000003}', '7d7d7d7d-0000-1000-8000-000000000003',
      '00000000-0000-0000-0000-000000000000', 'L8VIN00000000000A1', '100045', 'L8-IID-1', 'ops@example.test', repeat('z', 64), repeat('q', 10240),
      '7d7d7d7d-0000-4000-8000-0000000000033', ' 7d7d7d7d-0000-4000-8000-000000000003'] LOOP
    SET LOCAL ROLE iit_logistics_reader;
    PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000003"}', true);
    e := iit.logistics_resolve_31(ARRAY['L8-IID-1'], c);
    RESET ROLE;
    SELECT * INTO a FROM iit.logistics_read_audit ORDER BY id DESC LIMIT 1;
    want := CASE WHEN c = '' THEN 'CORRELATION_MISSING' ELSE 'CORRELATION_INVALID' END;
    IF e ->> 'status' <> 'denied' OR (e ->> 'correlation_id') IS NULL OR (e ->> 'correlation_id')::uuid <> a.correlation_id OR a.correlation_source <> 'server'
       OR a.outcome <> 'denied' OR a.error_code <> want OR e ? 'rows'
       OR (e ->> 'correlation_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      THEN RAISE EXCEPTION 'L5a correlation % → %', left(c, 40), e; END IF;
    IF c <> '' AND (to_jsonb(a)::text LIKE '%' || left(c, 40) || '%' OR lower(to_jsonb(a)::text) LIKE '%' || lower(left(c, 40)) || '%') THEN RAISE EXCEPTION 'L5b rejected correlation value stored'; END IF;
  END LOOP;
  SET LOCAL ROLE iit_logistics_reader;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000003"}', true);
  e := iit.logistics_resolve_31(ARRAY['L8-IID-1'], NULL);
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  IF e ->> 'error_code' <> 'CORRELATION_MISSING' THEN RAISE EXCEPTION 'L5c NULL correlation'; END IF;
END $$;

-- ===================================================================================================================
-- L6 input validation (T10, T12): fixed codes in a fixed order, audited with bounded counts; exact envelope keys
-- ===================================================================================================================
DO $$ DECLARE t record; e jsonb; a record; ok_c text := '7d7d7d7d-0000-4000-8000-000000000004'; BEGIN
  FOR t IN SELECT * FROM (VALUES
      ('r31',  NULL::text[], 'INPUT_EMPTY', 0), ('r31', '{}'::text[], 'INPUT_EMPTY', 0), ('r31', ARRAY['L8-IID-1', NULL], 'INPUT_NULL_ELEMENT', 2),
      ('r31',  array_fill('x'::text, ARRAY[501]), 'INPUT_TOO_LARGE', 501), ('r31', array_fill(NULL::text, ARRAY[501]), 'INPUT_TOO_LARGE', 501),
      ('r31',  ARRAY['   '], 'INPUT_INVALID', 1), ('r31', ARRAY[repeat('i', 65)], 'INPUT_INVALID', 1), ('r31', ARRAY[['a','b'],['c','d']], 'INPUT_INVALID', 4),
      ('deal', NULL::text[], 'INPUT_EMPTY', 0), ('deal', ARRAY['not-a-uuid'], 'INPUT_INVALID', 1), ('deal', ARRAY['00000000-0000-4000-8008-0000000000D1'], 'INPUT_INVALID', 1),
      ('deal', ARRAY['{00000000-0000-4000-8008-0000000000d1}'], 'INPUT_INVALID', 1), ('deal', array_fill('00000000-0000-4000-8008-0000000000d1'::text, ARRAY[501]), 'INPUT_TOO_LARGE', 501),
      ('deal', ARRAY['00000000-0000-4000-8008-0000000000d1', NULL], 'INPUT_NULL_ELEMENT', 2),
      ('vin',  '{}'::text[], 'INPUT_EMPTY', 0), ('vin', array_fill('L8VIN00000000000A1'::text, ARRAY[51]), 'INPUT_TOO_LARGE', 51), ('vin', ARRAY[NULL::text], 'INPUT_NULL_ELEMENT', 1)
    ) v(fn, arr, code, cnt) LOOP
    SET LOCAL ROLE iit_logistics_reader;
    PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000004"}', true);
    e := CASE t.fn WHEN 'r31' THEN iit.logistics_resolve_31(t.arr, ok_c) WHEN 'deal' THEN iit.logistics_deal_summaries(t.arr, ok_c) ELSE iit.logistics_vin_candidates(t.arr, ok_c) END;
    RESET ROLE;
    SELECT * INTO a FROM iit.logistics_read_audit ORDER BY id DESC LIMIT 1;
    IF e <> jsonb_build_object('status', 'denied', 'error_code', t.code, 'correlation_id', ok_c) THEN RAISE EXCEPTION 'L6a % % → %', t.fn, t.code, e; END IF;
    IF a.outcome <> 'denied' OR a.error_code <> t.code OR a.input_count <> t.cnt OR a.correlation_source <> 'caller' OR a.invalid_count <> 0 THEN RAISE EXCEPTION 'L6b audit for % %: %', t.fn, t.code, to_jsonb(a); END IF;
  END LOOP;
  -- a correlation problem wins over an input problem (it is checked first)
  SET LOCAL ROLE iit_logistics_reader;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000004"}', true);
  e := iit.logistics_deal_summaries(NULL, 'bad');
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  IF e ->> 'error_code' <> 'CORRELATION_INVALID' THEN RAISE EXCEPTION 'L6c order'; END IF;
END $$;

-- ===================================================================================================================
-- L7 contract (T10, Q2, Q3, D-6, D-8): one row per position, duplicates kept, input order, exact keys
-- ===================================================================================================================
DO $$ DECLARE e jsonb; r jsonb; c text := '7d7d7d7d-0000-4000-8000-000000000005'; BEGIN
  SET LOCAL ROLE iit_logistics_reader;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000005"}', true);
  -- 3.1: linked → deal; unlinked (deal set) and conflict → found false, no deal; unknown → nulls; trimmed; duplicates; order
  e := iit.logistics_resolve_31(ARRAY['L8-IID-2', ' L8-IID-1 ', 'L8-NOPE', 'L8-IID-1', 'L8-IID-3'], c);
  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(e) k) <> ARRAY['correlation_id','error_code','rows','status'] OR e ->> 'status' <> 'ok' OR e -> 'error_code' <> 'null' THEN RAISE EXCEPTION 'L7a envelope %', e; END IF;
  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(e -> 'rows' -> 0) k) <> ARRAY['deal_id','found','kind','legacy_iid','link_status','ordinality','source_status'] THEN RAISE EXCEPTION 'L7b row keys'; END IF;
  IF (SELECT array_agg((x ->> 'ordinality')::int ORDER BY n) FROM jsonb_array_elements(e -> 'rows') WITH ORDINALITY q(x, n)) <> ARRAY[1,2,3,4,5] THEN RAISE EXCEPTION 'L7c ordinality'; END IF;
  IF e -> 'rows' -> 0 <> jsonb_build_object('ordinality', 1, 'legacy_iid', 'L8-IID-2', 'found', false, 'deal_id', NULL::text, 'link_status', 'unlinked', 'source_status', 'current', 'kind', 'initial')
    THEN RAISE EXCEPTION 'L7d unlinked must not resolve: %', e -> 'rows' -> 0; END IF;
  IF e -> 'rows' -> 1 <> jsonb_build_object('ordinality', 2, 'legacy_iid', 'L8-IID-1', 'found', true, 'deal_id', '00000000-0000-4000-8008-0000000000d1', 'link_status', 'linked', 'source_status', 'current', 'kind', 'initial')
     OR (e -> 'rows' -> 3) - 'ordinality' <> (e -> 'rows' -> 1) - 'ordinality' THEN RAISE EXCEPTION 'L7e linked / duplicate'; END IF;
  IF e -> 'rows' -> 2 <> jsonb_build_object('ordinality', 3, 'legacy_iid', 'L8-NOPE', 'found', false, 'deal_id', NULL::text, 'link_status', NULL::text, 'source_status', NULL::text, 'kind', NULL::text) THEN RAISE EXCEPTION 'L7f unknown'; END IF;
  IF (e -> 'rows' -> 4 ->> 'found')::boolean OR e -> 'rows' -> 4 ->> 'link_status' <> 'conflict' OR e -> 'rows' -> 4 -> 'deal_id' <> 'null' THEN RAISE EXCEPTION 'L7g conflict'; END IF;
  -- deal summaries: exact keys, values, not-found row, duplicates; nothing beyond the allowlist
  e := iit.logistics_deal_summaries(ARRAY['00000000-0000-4000-8008-0000000000d1', '00000000-0000-4000-8008-00000000ffff', '00000000-0000-4000-8008-0000000000d1', '00000000-0000-4000-8008-0000000000d4'], c);
  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(e -> 'rows' -> 0) k) <> ARRAY['cancelled_at','deal_id','deal_number','dealer_sold_to','final_closure_at','found','intake_status',
       'make_text','model_text','on_hold','ordinality','purchase_price','source_channel_name','vin_normalized','year'] THEN RAISE EXCEPTION 'L7h summary keys'; END IF;
  r := e -> 'rows' -> 0;
  IF NOT (r ->> 'found')::boolean OR r ->> 'vin_normalized' <> 'L8VIN00000000000A1' OR (r ->> 'purchase_price')::numeric <> 8801.08 OR r ->> 'dealer_sold_to' <> 'L8 Dealer One'
     OR r ->> 'source_channel_name' <> 'Brown Fig – Manheim' OR r ->> 'intake_status' <> 'new' OR (r ->> 'year')::int <> 2022 OR r ->> 'make_text' <> 'Ram' THEN RAISE EXCEPTION 'L7i summary values %', r; END IF;
  IF e -> 'rows' -> 1 <> (SELECT jsonb_object_agg(k, CASE k WHEN 'ordinality' THEN '2'::jsonb WHEN 'deal_id' THEN '"00000000-0000-4000-8008-00000000ffff"'::jsonb WHEN 'found' THEN 'false'::jsonb ELSE 'null'::jsonb END)
                          FROM jsonb_object_keys(e -> 'rows' -> 0) k) THEN RAISE EXCEPTION 'L7j not-found summary %', e -> 'rows' -> 1; END IF;
  IF (e -> 'rows' -> 2) - 'ordinality' <> r - 'ordinality' OR e -> 'rows' -> 3 ->> 'cancelled_at' IS NULL THEN RAISE EXCEPTION 'L7k duplicate / cancelled'; END IF;
  IF e::text ~* '"(stock_number|deposit_amount|balance|balance_owed|parties|lien|title|first_name|phone|email|valuation)"' THEN RAISE EXCEPTION 'L7l summary leaks a non-allowlisted field'; END IF;
  -- VIN candidates: one live → deal + status; two live → count 2, no deal; only cancelled/voided/closed → 0; normalization
  -- matches a lowercase, padded stored VIN; invalid positions answered INPUT_INVALID without stopping the call; bounds 1 and 32
  e := iit.logistics_vin_candidates(ARRAY[' l8vin00000000000a1 ', 'L8VIN00000000000B2', 'L8VIN00000000000C3', 'L8VIN00000000000D4', '   ', repeat('V', 33), 'L', repeat('V', 32), 'L8VIN00000000000A1'], c);
  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(e -> 'rows' -> 0) k) <> ARRAY['audit_status','candidate_count','deal_id','deal_number','error_code','found','intake_status',
       'on_hold','ordinality','valid','vin_normalized'] THEN RAISE EXCEPTION 'L7m vin keys'; END IF;
  r := e -> 'rows' -> 0;
  IF r ->> 'vin_normalized' <> 'L8VIN00000000000A1' OR NOT (r ->> 'found')::boolean OR (r ->> 'candidate_count')::int <> 1 OR r ->> 'deal_id' <> '00000000-0000-4000-8008-0000000000d1'
     OR r ->> 'intake_status' <> 'new' OR (r ->> 'on_hold')::boolean OR r ->> 'audit_status' <> 'not_required' OR NOT (r ->> 'valid')::boolean THEN RAISE EXCEPTION 'L7n one live %', r; END IF;
  r := e -> 'rows' -> 1;
  IF (r ->> 'candidate_count')::int <> 2 OR r -> 'deal_id' <> 'null' OR r -> 'deal_number' <> 'null' OR r -> 'intake_status' <> 'null' OR NOT (r ->> 'found')::boolean THEN RAISE EXCEPTION 'L7o two live %', r; END IF;
  r := e -> 'rows' -> 2;
  IF (r ->> 'candidate_count')::int <> 0 OR (r ->> 'found')::boolean OR r -> 'deal_id' <> 'null' THEN RAISE EXCEPTION 'L7p cancelled/voided/closed counted %', r; END IF;
  IF (e -> 'rows' -> 3 ->> 'candidate_count')::int <> 1 OR e -> 'rows' -> 3 ->> 'deal_id' <> '00000000-0000-4000-8008-0000000000d7' THEN RAISE EXCEPTION 'L7q normalized stored VIN'; END IF;
  FOR r IN SELECT x FROM jsonb_array_elements(e -> 'rows') x WHERE (x ->> 'ordinality')::int IN (5, 6) LOOP
    IF (r ->> 'valid')::boolean OR r ->> 'error_code' <> 'INPUT_INVALID' OR r -> 'vin_normalized' <> 'null' OR (r ->> 'found')::boolean OR r -> 'candidate_count' <> 'null' THEN RAISE EXCEPTION 'L7r invalid VIN %', r; END IF;
  END LOOP;
  IF NOT (e -> 'rows' -> 6 ->> 'valid')::boolean OR NOT (e -> 'rows' -> 7 ->> 'valid')::boolean OR (e -> 'rows' -> 8) - 'ordinality' - 'vin_normalized' <> (e -> 'rows' -> 0) - 'ordinality' - 'vin_normalized'
    THEN RAISE EXCEPTION 'L7s VIN bounds / duplicate'; END IF;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  IF (SELECT invalid_count || '/' || input_count || '/' || outcome FROM iit.logistics_read_audit ORDER BY id DESC LIMIT 1) <> '2/9/ok' THEN RAISE EXCEPTION 'L7t invalid_count'; END IF;
  -- the 500 / 50 limits themselves are accepted
  SET LOCAL ROLE iit_logistics_reader;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000005"}', true);
  IF jsonb_array_length(iit.logistics_resolve_31(array_fill('L8-IID-1'::text, ARRAY[500]), c) -> 'rows') <> 500
     OR jsonb_array_length(iit.logistics_deal_summaries(array_fill('00000000-0000-4000-8008-0000000000d1'::text, ARRAY[500]), c) -> 'rows') <> 500
     OR jsonb_array_length(iit.logistics_vin_candidates(array_fill('L8VIN00000000000A1'::text, ARRAY[50]), c) -> 'rows') <> 50 THEN RAISE EXCEPTION 'L7u limits'; END IF;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
END $$;

-- ===================================================================================================================
-- L8 audit split (T9): every completed call → exactly one row; an exception after the insert → none (rolled back); no audit
-- row anywhere carries an input identifier or caller text
-- ===================================================================================================================
DO $$ DECLARE n0 bigint; e jsonb; BEGIN
  SELECT count(*) INTO n0 FROM iit.logistics_read_audit;
  SET LOCAL ROLE iit_logistics_reader;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000006"}', true);
  e := iit.logistics_resolve_31(ARRAY['L8-IID-1'], '7d7d7d7d-0000-4000-8000-000000000006');
  e := iit.logistics_deal_summaries(ARRAY['bad'], '7d7d7d7d-0000-4000-8000-000000000006');
  e := iit.logistics_vin_candidates(ARRAY['L8VIN00000000000A1'], 'bad');
  BEGIN
    e := iit.logistics_vin_candidates(ARRAY['L8VIN00000000000A1'], '7d7d7d7d-0000-4000-8000-000000000006');
    RAISE EXCEPTION 'simulated failure after the audit insert';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'simulated failure after the audit insert' THEN RAISE; END IF;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  IF (SELECT count(*) FROM iit.logistics_read_audit) - n0 <> 3 THEN RAISE EXCEPTION 'L8a % rows, expected 3 (the rolled-back call leaves none)', (SELECT count(*) FROM iit.logistics_read_audit) - n0; END IF;
  IF EXISTS (SELECT 1 FROM iit.logistics_read_audit a WHERE to_jsonb(a)::text ~* '(L8VIN|L8-IID|L8-NOPE|8008-0000000000d|8008-00000000ffff|not-a-uuid|ops@example|100045|zzzz|qqqq)')
    THEN RAISE EXCEPTION 'L8b an audit row carries an input identifier or caller text'; END IF;
  BEGIN UPDATE iit.logistics_read_audit SET outcome = 'ok' WHERE false OR true; RAISE EXCEPTION 'L8c audit updatable'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'L8c%' THEN RAISE; END IF; END;
  BEGIN DELETE FROM iit.logistics_read_audit; RAISE EXCEPTION 'L8d audit deletable'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'L8d%' THEN RAISE; END IF; END;
  IF EXISTS (SELECT 1 FROM iit.record_history WHERE table_name = 'logistics_read_audit') THEN RAISE EXCEPTION 'L8e audit rows went through history'; END IF;
END $$;

-- ===================================================================================================================
-- L9 read-only (T14): a full battery of calls changes no business row and no history; D-36/D-40 untouched
-- ===================================================================================================================
DO $$ DECLARE before jsonb; after jsonb; e jsonb; BEGIN
  SELECT jsonb_build_object('hist', (SELECT count(*) || ':' || coalesce(max(id), 0) FROM iit.record_history), 'deals', (SELECT count(*) FROM iit.deals),
           'vehicles', (SELECT count(*) FROM iit.vehicles), 'source_records', (SELECT md5(string_agg(to_jsonb(s)::text, ',' ORDER BY s.id)) FROM iit.source_records s),
           'work_items', (SELECT count(*) FROM iit.work_items), 'activity', (SELECT count(*) FROM iit.activity_events), 'users', (SELECT count(*) FROM iit.users),
           'd36', (SELECT count(*) FROM iit.gate_idempotent_targets), 'd40', (SELECT count(*) FROM iit.gate_integration_actions), 'read_access', (SELECT count(*) FROM iit.read_access_audit)) INTO before;
  SET LOCAL ROLE iit_logistics_reader;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000007"}', true);
  e := iit.logistics_resolve_31(ARRAY['L8-IID-1', 'L8-IID-2', 'L8-NOPE'], '7d7d7d7d-0000-4000-8000-000000000007');
  e := iit.logistics_deal_summaries(ARRAY['00000000-0000-4000-8008-0000000000d1'], '7d7d7d7d-0000-4000-8000-000000000007');
  e := iit.logistics_vin_candidates(ARRAY['L8VIN00000000000A1', 'NOVIN'], '7d7d7d7d-0000-4000-8000-000000000007');
  e := iit.logistics_vin_candidates(NULL, NULL);
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  SELECT jsonb_build_object('hist', (SELECT count(*) || ':' || coalesce(max(id), 0) FROM iit.record_history), 'deals', (SELECT count(*) FROM iit.deals),
           'vehicles', (SELECT count(*) FROM iit.vehicles), 'source_records', (SELECT md5(string_agg(to_jsonb(s)::text, ',' ORDER BY s.id)) FROM iit.source_records s),
           'work_items', (SELECT count(*) FROM iit.work_items), 'activity', (SELECT count(*) FROM iit.activity_events), 'users', (SELECT count(*) FROM iit.users),
           'd36', (SELECT count(*) FROM iit.gate_idempotent_targets), 'd40', (SELECT count(*) FROM iit.gate_integration_actions), 'read_access', (SELECT count(*) FROM iit.read_access_audit)) INTO after;
  IF before <> after THEN RAISE EXCEPTION 'L9 a logistics call changed IIT data: % → %', before, after; END IF;
END $$;

-- ===================================================================================================================
-- L10 batch budgets (T16, R2): the largest permitted batches, all found and duplicates-heavy, stay within 1 MB and 2 s locally
-- (seeded in a rolled-back transaction)
-- ===================================================================================================================
BEGIN;
INSERT INTO iit.vehicles(id, vin, year, make_text, model_text)
  SELECT ('00000000-0000-4000-8a08-' || lpad(to_hex(g), 12, '0'))::uuid, 'L8BUDGET' || lpad(g::text, 10, '0'), 2020, 'Budgetmake', 'Budgetmodel' FROM generate_series(1, 500) g;
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, dealer_sold_to, source_channel_id)
  SELECT ('00000000-0000-4000-8b08-' || lpad(to_hex(g), 12, '0'))::uuid, ('00000000-0000-4000-8a08-' || lpad(to_hex(g), 12, '0'))::uuid, 'manual_exception', 99999.99,
         repeat('D', 40), (SELECT id FROM iit.source_channels WHERE name = 'Brown Fig – Manheim') FROM generate_series(1, 500) g;
INSERT INTO iit.source_records(legacy_iid, deal_id, kind, created_via, link_status, linked_at)
  SELECT 'L8BUDGET-' || lpad(g::text, 54, '0'), ('00000000-0000-4000-8b08-' || lpad(to_hex(g), 12, '0'))::uuid, 'initial', 'bridge', 'linked', now() FROM generate_series(1, 500) g;
DO $$ DECLARE t0 timestamptz; ms numeric; e jsonb; sz int; lbl text; arr text[]; BEGIN
  SET LOCAL ROLE iit_logistics_reader;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000008"}', true);
  FOREACH lbl IN ARRAY ARRAY['r31','r31dup','deal','dealdup','vin','vindup'] LOOP
    arr := CASE lbl
      WHEN 'r31'     THEN ARRAY(SELECT 'L8BUDGET-' || lpad(g::text, 54, '0') FROM generate_series(1, 500) g)
      WHEN 'r31dup'  THEN array_fill(('L8BUDGET-' || lpad('1', 54, '0'))::text, ARRAY[500])
      WHEN 'deal'    THEN ARRAY(SELECT '00000000-0000-4000-8b08-' || lpad(to_hex(g), 12, '0') FROM generate_series(1, 500) g)
      WHEN 'dealdup' THEN array_fill('00000000-0000-4000-8b08-000000000001'::text, ARRAY[500])
      WHEN 'vin'     THEN ARRAY(SELECT 'L8BUDGET' || lpad(g::text, 10, '0') FROM generate_series(1, 50) g)
      ELSE array_fill('L8BUDGET0000000001'::text, ARRAY[50]) END;
    t0 := clock_timestamp();
    e := CASE WHEN lbl LIKE 'r31%' THEN iit.logistics_resolve_31(arr, '7d7d7d7d-0000-4000-8000-000000000008')
              WHEN lbl LIKE 'deal%' THEN iit.logistics_deal_summaries(arr, '7d7d7d7d-0000-4000-8000-000000000008')
              ELSE iit.logistics_vin_candidates(arr, '7d7d7d7d-0000-4000-8000-000000000008') END;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000; sz := octet_length(e::text);
    IF e ->> 'status' <> 'ok' OR EXISTS (SELECT 1 FROM jsonb_array_elements(e -> 'rows') x WHERE NOT (x ->> 'found')::boolean) THEN RAISE EXCEPTION 'L10a % not all found', lbl; END IF;
    IF sz > 1000000 OR ms > 2000 THEN RAISE EXCEPTION 'L10b % exceeds budget: % bytes, % ms', lbl, sz, round(ms); END IF;
    RAISE NOTICE 'L10 % rows=% bytes=% ms=%', lbl, jsonb_array_length(e -> 'rows'), sz, round(ms, 1);
  END LOOP;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
END $$;
ROLLBACK;

-- ===================================================================================================================
-- L11 from a real authenticator login (as Supabase's PostgREST connects): assume the role, cannot escalate, calls work only
-- with valid claims, and nothing else in iit is reachable (T1–T7)
-- ===================================================================================================================
\c iit_local authenticator
SET ROLE iit_logistics_reader;
DO $$ DECLARE f record; m text; st text; e jsonb; BEGIN
  BEGIN SET LOCAL ROLE iit_owner; RAISE EXCEPTION 'L11a became owner'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  -- SET ROLE is judged against the session user (authenticator), which legitimately holds both PostgREST roles; the JWT picks
  -- one and an RPC caller has no SQL session. What must hold: no path to the owner, Worker, integration or postgres roles.
  BEGIN SET LOCAL ROLE tav_worker; RAISE EXCEPTION 'L11b became worker'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN SET LOCAL ROLE iit_integration; RAISE EXCEPTION 'L11b2 became integration'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN SET LOCAL ROLE postgres; RAISE EXCEPTION 'L11b3 became postgres'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  -- T1–T4 from this session
  FOREACH m IN ARRAY ARRAY['', '{"role":"authenticated","jti":"7e7e7e7e-0000-4000-8000-000000000009"}', '{"role":"iit_logistics_reader"}',
                           '{"role":"iit_logistics_reader","jti":"8a8a8a8a-0000-4000-8000-00000000dead"}'] LOOP
    PERFORM set_config('request.jwt.claims', m, true);
    BEGIN PERFORM iit.logistics_resolve_31(ARRAY['L8-IID-1'], '7d7d7d7d-0000-4000-8000-000000000009'); RAISE EXCEPTION 'L11c accepted %', m;
    EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-000000000009"}', true);
  e := iit.logistics_resolve_31(ARRAY['L8-IID-1'], '7d7d7d7d-0000-4000-8000-000000000009');
  IF e #>> '{rows,0,deal_id}' <> '00000000-0000-4000-8008-0000000000d1' THEN RAISE EXCEPTION 'L11d valid call from the authenticator session failed: %', e; END IF;
  -- T7: every other iit function — 37 staff RPCs, require_role, Worker functions, every helper — is refused before its body
  FOR f IN SELECT p.oid::regprocedure AS sig, format('SELECT %s(%s)', p.oid::regproc::text,
              coalesce((SELECT string_agg('NULL::' || format_type(t, NULL), ', ' ORDER BY o) FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY u(t, o)), '')) AS call
             FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
            WHERE s.nspname = 'iit' AND p.prokind = 'f' AND p.prorettype <> 'trigger'::regtype
              AND p.proname NOT IN ('logistics_resolve_31','logistics_deal_summaries','logistics_vin_candidates')
              -- polymorphic signatures cannot be called with typed NULLs; L2a covers them by catalog
              AND NOT EXISTS (SELECT 1 FROM unnest(p.proargtypes::oid[]) t JOIN pg_type ty ON ty.oid = t WHERE ty.typtype = 'p') LOOP
    BEGIN EXECUTE f.call; RAISE EXCEPTION 'L11e logistics credential executed %', f.sig;
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT, st = RETURNED_SQLSTATE;
      IF st <> '42501' OR m NOT LIKE 'permission denied for function%' THEN RAISE EXCEPTION 'L11f % → % %', f.sig, st, m; END IF; END;
  END LOOP;
  BEGIN PERFORM 1 FROM iit.deals; RAISE EXCEPTION 'L11g table read'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM 1 FROM iit.logistics_read_audit; RAISE EXCEPTION 'L11h audit read'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN INSERT INTO iit.logistics_read_audit(function, credential_jti, correlation_id, correlation_source, input_count, outcome)
        VALUES ('logistics_resolve_31', gen_random_uuid(), gen_random_uuid(), 'caller', 1, 'ok'); RAISE EXCEPTION 'L11i audit forged'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  PERFORM set_config('request.jwt.claims', '', true);
END $$;
RESET ROLE;
-- T6: a Base44 credential cannot call a logistics function, with its own claims or with Logistics claims coerced in
SET ROLE iit_base44;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","jti":"tok-2"}', true);
  BEGIN PERFORM iit.logistics_resolve_31(ARRAY['L8-IID-1'], '7d7d7d7d-0000-4000-8000-00000000000a'); RAISE EXCEPTION 'L11j base44 called logistics'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-00000000000a"}', true);
  BEGIN PERFORM iit.logistics_vin_candidates(ARRAY['L8VIN00000000000A1'], '7d7d7d7d-0000-4000-8000-00000000000a'); RAISE EXCEPTION 'L11k coerced claims'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  -- and the coerced Logistics claims cannot pass require_role on a staff RPC from the Base44 role
  BEGIN PERFORM iit.get_my_profile('b44-de'); RAISE EXCEPTION 'L11l staff RPC under logistics claims'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
  PERFORM set_config('request.jwt.claims', '', true);
END $$;
RESET ROLE;
\c iit_local postgres

-- ===================================================================================================================
-- L12 the Base44 credential path through the replaced require_role is unchanged (006 Z8/Z9 semantics)
-- ===================================================================================================================
DO $$ DECLARE k record; m text; BEGIN
  FOR k IN SELECT * FROM (VALUES (NULL::text, 'CREDENTIAL_NO_CLAIMS'), ('{"role":"authenticated","jti":"tok-9"}', 'CREDENTIAL_ROLE_MISMATCH'),
      ('{"role":"iit_logistics_reader","jti":"7e7e7e7e-0000-4000-8000-00000000000b"}', 'CREDENTIAL_ROLE_MISMATCH'),
      ('{"role":"iit_base44"}', 'CREDENTIAL_NO_JTI'), ('{"role":"iit_base44","jti":"tok-1"}', 'CREDENTIAL_REVOKED')) v(claims, expect) LOOP
    SET LOCAL ROLE iit_base44;
    PERFORM set_config('request.jwt.claims', coalesce(k.claims, ''), true);
    BEGIN PERFORM iit.get_my_profile('b44-de'); RAISE EXCEPTION 'L12a accepted %', k.claims;
    EXCEPTION WHEN SQLSTATE '28000' THEN GET STACKED DIAGNOSTICS m = MESSAGE_TEXT; IF m <> k.expect THEN RAISE EXCEPTION 'L12b % → % (expected %)', k.claims, m, k.expect; END IF; END;
    RESET ROLE;
  END LOOP;
  SET LOCAL ROLE iit_base44;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","jti":"tok-2"}', true);
  IF iit.get_my_profile('b44-de') ->> 'status' <> 'ok' THEN RAISE EXCEPTION 'L12c valid base44 credential refused'; END IF;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  -- the claim-less path (Worker, owner SQL, local tests) is unchanged
  IF iit.require_role('b44-de', 'data_entry') IS NULL THEN RAISE EXCEPTION 'L12d claim-less path'; END IF;
END $$;

SELECT 'ALL 008 TESTS PASS' AS result;
