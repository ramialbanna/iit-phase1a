-- 006_base44_rpc_role_test.sql — PostgREST is simulated the way it works: SET ROLE iit_base44 (membership via authenticator),
-- request.jwt.claims set to the credential's claims. Runs after 001–005 tests (fixtures: b44-admin a, b44-de d, deal d3 etc.).
\set ON_ERROR_STOP on
\set QUIET on

-- Z1 the role exists as specified; authenticator can assume it; it has schema usage and exactly the manifest
DO $$ DECLARE n int; BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='iit_base44' AND NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole AND NOT rolcreatedb) THEN RAISE EXCEPTION 'Z1a role attributes'; END IF;
  IF NOT pg_has_role('authenticator', 'iit_base44', 'MEMBER') THEN RAISE EXCEPTION 'Z1b authenticator cannot assume iit_base44'; END IF;
  -- Z1b2 exactly one grant, with exactly SET TRUE / INHERIT FALSE / ADMIN FALSE
  IF (SELECT count(*) FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member
       WHERE r.rolname='iit_base44' AND m.rolname='authenticator') <> 1
     OR NOT EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member
       WHERE r.rolname='iit_base44' AND m.rolname='authenticator' AND am.set_option AND NOT am.inherit_option AND NOT am.admin_option)
    THEN RAISE EXCEPTION 'Z1b2 authenticator membership in iit_base44 is not exactly SET TRUE, INHERIT FALSE, ADMIN FALSE'; END IF;
  IF NOT pg_has_role('authenticator', 'iit_base44', 'SET') OR pg_has_role('authenticator', 'iit_base44', 'USAGE')
    THEN RAISE EXCEPTION 'Z1b3 authenticator must be able to SET ROLE iit_base44 and must not inherit it'; END IF;
  IF NOT has_schema_privilege('iit_base44', 'iit', 'USAGE') THEN RAISE EXCEPTION 'Z1c no schema usage'; END IF;
  -- P2: the EXACT allowlist, not a count — every executable function is one of the 27 named signatures and all 27 are present
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname='iit' AND has_function_privilege('iit_base44', p.oid, 'EXECUTE');
  IF n <> 27 THEN RAISE EXCEPTION 'Z1d manifest size: % executable functions, expected 27', n; END IF;
  IF (SELECT string_agg(p.oid::regprocedure::text, E'\n' ORDER BY p.oid::regprocedure::text) FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname='iit' AND has_function_privilege('iit_base44', p.oid, 'EXECUTE'))
     <> (SELECT string_agg(x, E'\n' ORDER BY x) FROM unnest(ARRAY[
      'iit.amend_field(uuid,text,jsonb,text,text)', 'iit.amend_party(uuid,uuid,jsonb,text,text)', 'iit.authorize_report_access(uuid,text)',
      'iit.begin_report_upload(uuid,text,text,uuid,uuid,text,timestamp with time zone,uuid,text)', 'iit.cancel_deal(uuid,text,text)',
      'iit.correct_field(uuid,text,jsonb,text,text)', 'iit.correct_party(uuid,text,integer,jsonb,text,text)', 'iit.create_manual_deal(text,text,text,text)',
      'iit.deactivate_staff(text,text)', 'iit.finish_report_upload(uuid,bigint,text,text)', 'iit.rebind_hold(uuid,text,text)',
      'iit.record_decision(uuid,text,text,text)', 'iit.release_deal(uuid,text)', 'iit.request_reaudit(uuid,text,text)',
      'iit.resolve_flag(uuid,text,text,text)', 'iit.resolve_restart(uuid,text,text,text)', 'iit.resolve_unknown_outcome(uuid,text,jsonb,text,text)',
      'iit.resolve_work_item(uuid,text,text)', 'iit.revoke_waiver(uuid,text,text)', 'iit.set_consignment(uuid,uuid,numeric,text,text)',
      'iit.set_deal_fact(uuid,text,jsonb,text)', 'iit.set_seller_party(uuid,text,integer,jsonb,text)', 'iit.set_source_channel(uuid,text,text)',
      'iit.set_staff_identity(text,text,text,text)', 'iit.set_staff_role(uuid,text,boolean,text)', 'iit.validate_report(uuid,text,text,jsonb,text,text)',
      'iit.waive_report(uuid,text,text,text)']) x)
  THEN RAISE EXCEPTION 'Z1d2 manifest differs from the 27 named signatures'; END IF;
  -- no table or sequence privilege of any kind
  IF EXISTS (SELECT 1 FROM (SELECT c.oid FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace WHERE s.nspname='iit' AND c.relkind='r' OFFSET 0) c WHERE (has_table_privilege('iit_base44', c.oid, 'SELECT') OR has_table_privilege('iit_base44', c.oid, 'INSERT') OR has_table_privilege('iit_base44', c.oid, 'UPDATE') OR has_table_privilege('iit_base44', c.oid, 'DELETE'))) THEN RAISE EXCEPTION 'Z1e table privilege'; END IF;
  IF EXISTS (SELECT 1 FROM (SELECT c.oid FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace WHERE s.nspname='iit' AND c.relkind='S' OFFSET 0) q WHERE has_sequence_privilege('iit_base44', q.oid, 'USAGE')) THEN RAISE EXCEPTION 'Z1f sequence privilege'; END IF;
END $$;

-- Z2 as PostgREST would run it: an approved RPC succeeds and the actor/role checks inside still apply
SET ROLE iit_base44;
SELECT set_config('request.jwt.claims', '{"role":"iit_base44","iss":"supabase","jti":"tok-1"}', false);   -- session-wide: outside a transaction a LOCAL setting vanishes at once
DO $$ DECLARE d uuid; BEGIN
  d := iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000600', 'Brown Fig – Manheim', 'b44-de');     -- approved, data_entry actor
  IF d IS NULL THEN RAISE EXCEPTION 'Z2a'; END IF;
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000601', 'Brown Fig – Manheim', 'b44-aud'); RAISE EXCEPTION 'Z2b role check skipped'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000602', 'Brown Fig – Manheim', 'nobody'); RAISE EXCEPTION 'Z2c unknown actor accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000603', 'Brown Fig – Manheim', ''); RAISE EXCEPTION 'Z2d empty actor accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
  PERFORM set_config('iit_test.deal', d::text, false);   -- checked after RESET ROLE: iit_base44 itself cannot read record_history (Z4)
END $$;
-- Z3 unapproved functions: helpers, hold machinery, Worker-only functions — denied
DO $$ BEGIN
  BEGIN PERFORM iit.open_hold('00000000-0000-4000-8000-0000000000e5', 'cancel', '00000000-0000-4000-8000-00000000000d'); RAISE EXCEPTION 'Z3a open_hold'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.authorize_and_consume('k','IID-300','package','appsheet:31',NULL,NULL,NULL,'In-Progress',now()); RAISE EXCEPTION 'Z3b worker authorize'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.report_action_outcome('00000000-0000-4000-8000-000000000000','completed','{}','appsheet:31',NULL); RAISE EXCEPTION 'Z3c worker report'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.expire_stale_attempts(now()); RAISE EXCEPTION 'Z3d worker expire'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.ingest_vauto_observation('x','', '{}'::jsonb, now()); RAISE EXCEPTION 'Z3e worker ingest'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.build_deal_snapshot('00000000-0000-4000-8000-0000000000e5', 1); RAISE EXCEPTION 'Z3f helper'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.actor_push('00000000-0000-4000-8000-00000000000d', 'user'); RAISE EXCEPTION 'Z3g actor_push'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM iit.require_role('b44-de', 'data_entry'); RAISE EXCEPTION 'Z3h require_role'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END $$;
-- Z4 direct table access: every verb denied on every iit table (privilege, before RLS even applies)
DO $$ DECLARE t record; BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='iit' LOOP
    BEGIN EXECUTE format('SELECT 1 FROM iit.%I LIMIT 1', t.tablename); RAISE EXCEPTION 'Z4 SELECT allowed on %', t.tablename; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  END LOOP;
  BEGIN INSERT INTO iit.intake_flags(deal_id, code) VALUES ('00000000-0000-4000-8000-0000000000e5', 'x'); RAISE EXCEPTION 'Z4b INSERT'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN UPDATE iit.deals SET dealer_sold_to = 'x' WHERE id = '00000000-0000-4000-8000-0000000000e5'; RAISE EXCEPTION 'Z4c UPDATE'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN DELETE FROM iit.intake_flags WHERE false; RAISE EXCEPTION 'Z4d DELETE'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN PERFORM nextval('iit.deal_number_seq'); RAISE EXCEPTION 'Z4e sequence'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN EXECUTE 'CREATE TABLE iit.z (x int)'; RAISE EXCEPTION 'Z4f DDL'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claims', '', false);
-- Z2e the write is attributed to the function owner with the originating role recorded (§5.9.2 AC10)
DO $$ BEGIN
  IF (SELECT exec_role || '/' || origin_role || '/' || actor_kind FROM iit.record_history WHERE table_name='deals' AND record_id = current_setting('iit_test.deal')::uuid) <> 'iit_owner/iit_base44/user' THEN RAISE EXCEPTION 'Z2e attribution'; END IF;
END $$;

-- Z5 anon / authenticated / tav_worker stay denied on every staff function and every table
DO $$ DECLARE p record; r text; BEGIN
  FOREACH r IN ARRAY ARRAY['anon','authenticated','tav_worker'] LOOP
    FOR p IN SELECT pr.oid, pr.proname FROM pg_proc pr JOIN pg_namespace s ON s.oid = pr.pronamespace WHERE s.nspname='iit' AND has_function_privilege('iit_base44', pr.oid, 'EXECUTE') LOOP
      IF has_function_privilege(r, p.oid, 'EXECUTE') THEN RAISE EXCEPTION 'Z5 % can execute %', r, p.proname; END IF;
    END LOOP;
    IF has_schema_privilege(r, 'iit', 'USAGE') AND r <> 'tav_worker' THEN RAISE EXCEPTION 'Z5b % has schema usage', r; END IF;
  END LOOP;
  IF has_function_privilege('iit_base44', 'iit.authorize_and_consume(text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN RAISE EXCEPTION 'Z5c'; END IF;
END $$;
-- Z6 escalation from PostgREST's real session: login as `authenticator` (as Supabase's PostgREST does), assume iit_base44, and
-- try to become owner / worker / integration — SET ROLE is judged against the SESSION user's memberships, so all must fail.
\c iit_local authenticator
SET ROLE iit_base44;
DO $$ BEGIN
  BEGIN SET LOCAL ROLE iit_owner; RAISE EXCEPTION 'Z6a became owner'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN SET LOCAL ROLE tav_worker; RAISE EXCEPTION 'Z6b became worker'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN SET LOCAL ROLE iit_integration; RAISE EXCEPTION 'Z6c became integration'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN SET LOCAL ROLE postgres; RAISE EXCEPTION 'Z6d became postgres'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  -- and from this real session an approved RPC works WITH the credential's claims while a table read is still denied
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","iss":"supabase","jti":"tok-1"}', true);
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000610', 'Brown Fig – ACV', 'b44-de'); EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Z6e approved RPC failed from the authenticator session: %', SQLERRM; END;
  BEGIN PERFORM 1 FROM iit.deals; RAISE EXCEPTION 'Z6f table read from the authenticator session'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END $$;
-- Z9 enforcement is tied to the ORIGINATING role, not to what the claims say (Codex D-2 rev 2 P1)
DO $$ BEGIN
  -- Z9a originating role iit_base44 with NO claims at all → refused (this was the rev-2 bypass path)
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000630', 'Brown Fig – ACV', 'b44-de'); RAISE EXCEPTION 'Z9a claim-less call accepted from iit_base44'; EXCEPTION WHEN SQLSTATE '28000' THEN IF SQLERRM NOT LIKE 'CREDENTIAL_NO_CLAIMS%' THEN RAISE; END IF; END;
  -- Z9b originating role iit_base44 but the claims name another role → refused
  PERFORM set_config('request.jwt.claims', '{"role":"authenticated","iss":"supabase","jti":"tok-1"}', true);
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000631', 'Brown Fig – ACV', 'b44-de'); RAISE EXCEPTION 'Z9b foreign-role claims accepted from iit_base44'; EXCEPTION WHEN SQLSTATE '28000' THEN IF SQLERRM NOT LIKE 'CREDENTIAL_ROLE_MISMATCH%' THEN RAISE; END IF; END;
  -- Z9c claims without a role → refused the same way
  PERFORM set_config('request.jwt.claims', '{"iss":"supabase","jti":"tok-1"}', true);
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000632', 'Brown Fig – ACV', 'b44-de'); RAISE EXCEPTION 'Z9c role-less claims accepted from iit_base44'; EXCEPTION WHEN SQLSTATE '28000' THEN IF SQLERRM NOT LIKE 'CREDENTIAL_ROLE_MISMATCH%' THEN RAISE; END IF; END;
END $$;
\c iit_local postgres
-- Z9d claims say iit_base44 but the originating role is NOT iit_base44 (owner session, no SET ROLE) → identity mismatch
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","iss":"supabase","jti":"tok-1"}', true);
  BEGIN PERFORM iit.require_role('b44-de', 'data_entry'); RAISE EXCEPTION 'Z9d base44 claims accepted from the owner session'; EXCEPTION WHEN SQLSTATE '28000' THEN IF SQLERRM NOT LIKE 'CREDENTIAL_ROLE_MISMATCH%' THEN RAISE; END IF; END;
  PERFORM set_config('request.jwt.claims', '', true);
END $$;
-- Z9e same claims under another originating role that can reach a staff function (iit_integration) → identity mismatch
SET ROLE iit_integration;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","iss":"supabase","jti":"tok-1"}', true);
  BEGIN PERFORM iit.set_consignment(gen_random_uuid(), NULL, NULL, NULL, 'b44-de'); RAISE EXCEPTION 'Z9e base44 claims accepted under iit_integration'; EXCEPTION WHEN SQLSTATE '28000' THEN IF SQLERRM NOT LIKE 'CREDENTIAL_ROLE_MISMATCH%' THEN RAISE; END IF; END;
  PERFORM set_config('request.jwt.claims', '', true);
END $$;
RESET ROLE;
\c iit_local postgres
-- Z8 genuine credential revocation (P1): a token without jti is refused; a revoked jti is refused immediately and stays refused;
-- another token (new jti) keeps working; no RPC can un-revoke (table has no DELETE, no grants to iit_base44)
INSERT INTO iit.revoked_credentials(jti, reason) VALUES ('tok-1', 'laptop stolen 2026-10-28');
\c iit_local authenticator
SET ROLE iit_base44;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","iss":"supabase","jti":"tok-1"}', true);
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000620', 'Brown Fig – ACV', 'b44-de'); RAISE EXCEPTION 'Z8a revoked token accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN IF SQLERRM NOT LIKE 'CREDENTIAL_REVOKED%' THEN RAISE; END IF; END;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","iss":"supabase"}', true);
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000621', 'Brown Fig – ACV', 'b44-de'); RAISE EXCEPTION 'Z8b token without jti accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN IF SQLERRM NOT LIKE 'CREDENTIAL_NO_JTI%' THEN RAISE; END IF; END;
  PERFORM set_config('request.jwt.claims', '{"role":"iit_base44","iss":"supabase","jti":"tok-2"}', true);
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000622', 'Brown Fig – ACV', 'b44-de'); EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Z8c replacement token refused: %', SQLERRM; END;
  BEGIN DELETE FROM iit.revoked_credentials WHERE jti = 'tok-1'; RAISE EXCEPTION 'Z8d un-revoked'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN INSERT INTO iit.revoked_credentials(jti, reason) VALUES ('x', 'x'); RAISE EXCEPTION 'Z8e credential role can write the revocation list'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END $$;
\c iit_local postgres
DO $$ BEGIN
  BEGIN DELETE FROM iit.revoked_credentials WHERE jti = 'tok-1'; RAISE EXCEPTION 'Z8f revocation deletable even by the owner'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  -- the non-PostgREST path (no claims: Worker, local tests, owner SQL) is unchanged
  IF iit.require_role('b44-de', 'data_entry') IS NULL THEN RAISE EXCEPTION 'Z8g'; END IF;
END $$;

-- Z7 the 005 Worker functions remain tav_worker-only and the integration manifest is unchanged (006 touches no other grant)
DO $$ BEGIN
  IF NOT has_function_privilege('tav_worker', 'iit.authorize_and_consume(text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN RAISE EXCEPTION 'Z7a'; END IF;
  IF NOT has_function_privilege('iit_integration', 'iit.release_deal(uuid,text)', 'EXECUTE') THEN RAISE EXCEPTION 'Z7b'; END IF;
END $$;

SELECT 'ALL 006 TESTS PASS' AS result;
