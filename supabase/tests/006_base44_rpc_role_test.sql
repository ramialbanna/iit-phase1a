-- 006_base44_rpc_role_test.sql — PostgREST is simulated the way it works: SET ROLE iit_base44 (membership via authenticator),
-- request.jwt.claims set to the credential's claims. Runs after 001–005 tests (fixtures: b44-admin a, b44-de d, deal d3 etc.).
\set ON_ERROR_STOP on
\set QUIET on

-- Z1 the role exists as specified; authenticator can assume it; it has schema usage and exactly the manifest
DO $$ DECLARE n int; BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='iit_base44' AND NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole AND NOT rolcreatedb) THEN RAISE EXCEPTION 'Z1a role attributes'; END IF;
  IF NOT pg_has_role('authenticator', 'iit_base44', 'MEMBER') THEN RAISE EXCEPTION 'Z1b authenticator cannot assume iit_base44'; END IF;
  IF NOT has_schema_privilege('iit_base44', 'iit', 'USAGE') THEN RAISE EXCEPTION 'Z1c no schema usage'; END IF;
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname='iit' AND has_function_privilege('iit_base44', p.oid, 'EXECUTE');
  IF n <> 27 THEN RAISE EXCEPTION 'Z1d manifest size: % executable functions, expected 27', n; END IF;
  -- no table or sequence privilege of any kind
  IF EXISTS (SELECT 1 FROM (SELECT c.oid FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace WHERE s.nspname='iit' AND c.relkind='r' OFFSET 0) c WHERE (has_table_privilege('iit_base44', c.oid, 'SELECT') OR has_table_privilege('iit_base44', c.oid, 'INSERT') OR has_table_privilege('iit_base44', c.oid, 'UPDATE') OR has_table_privilege('iit_base44', c.oid, 'DELETE'))) THEN RAISE EXCEPTION 'Z1e table privilege'; END IF;
  IF EXISTS (SELECT 1 FROM (SELECT c.oid FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace WHERE s.nspname='iit' AND c.relkind='S' OFFSET 0) q WHERE has_sequence_privilege('iit_base44', q.oid, 'USAGE')) THEN RAISE EXCEPTION 'Z1f sequence privilege'; END IF;
END $$;

-- Z2 as PostgREST would run it: an approved RPC succeeds and the actor/role checks inside still apply
SET ROLE iit_base44;
SELECT set_config('request.jwt.claims', '{"role":"iit_base44","iss":"supabase"}', true);
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
  -- and from this real session an approved RPC still works while a table read is still denied
  BEGIN PERFORM iit.create_manual_deal('manual_exception', 'WAUZZZ8V7JA000610', 'Brown Fig – ACV', 'b44-de'); EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Z6e approved RPC failed from the authenticator session: %', SQLERRM; END;
  BEGIN PERFORM 1 FROM iit.deals; RAISE EXCEPTION 'Z6f table read from the authenticator session'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END $$;
\c iit_local postgres
-- Z7 the 005 Worker functions remain tav_worker-only and the integration manifest is unchanged (006 touches no other grant)
DO $$ BEGIN
  IF NOT has_function_privilege('tav_worker', 'iit.authorize_and_consume(text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN RAISE EXCEPTION 'Z7a'; END IF;
  IF NOT has_function_privilege('iit_integration', 'iit.release_deal(uuid,text)', 'EXECUTE') THEN RAISE EXCEPTION 'Z7b'; END IF;
END $$;

SELECT 'ALL 006 TESTS PASS' AS result;
