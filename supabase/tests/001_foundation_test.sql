-- 001_foundation_test.sql — runs on a fresh local Postgres after 001_foundation.sql. Plain SQL asserts (no pgTAP).
-- Each block: a named check that RAISEs on failure. Workflow + permission behaviour, not just DDL existence.
\set ON_ERROR_STOP on
\set QUIET on

-- ---- fixtures: an admin and a data-entry user via direct privileged writes (what a seed script would do) ----
INSERT INTO iit.users(id, display_name, email) VALUES
  ('00000000-0000-4000-8000-00000000000a','Admin A','admin@test'),
  ('00000000-0000-4000-8000-00000000000d','Data Entry D','de@test');
INSERT INTO iit.staff_identities(base44_user_id, user_id) VALUES ('b44-admin','00000000-0000-4000-8000-00000000000a'), ('b44-de','00000000-0000-4000-8000-00000000000d');
INSERT INTO iit.user_roles(user_id, role) VALUES ('00000000-0000-4000-8000-00000000000a','admin'), ('00000000-0000-4000-8000-00000000000d','data_entry');

-- T1 direct edits are recorded as actor_kind='direct' with changed_by NULL (§5.9.3, AC4)
DO $$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM iit.record_history WHERE table_name='users' AND actor_kind='direct' AND changed_by IS NULL;
  IF n <> 2 THEN RAISE EXCEPTION 'T1 expected 2 direct history rows for users, got %', n; END IF;
END $$;

-- T2 require_role: unknown actor, inactive actor, missing role all raise and write nothing
DO $$ BEGIN
  BEGIN PERFORM iit.require_role('nobody','admin'); RAISE EXCEPTION 'T2a should have raised'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
  BEGIN PERFORM iit.require_role('b44-de','admin'); RAISE EXCEPTION 'T2b should have raised'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  IF iit.require_role('b44-admin','admin') <> '00000000-0000-4000-8000-00000000000a' THEN RAISE EXCEPTION 'T2c wrong user'; END IF;
END $$;

-- T3 staff-facing function: creates user+identity, history rows carry actor_kind='user' and changed_by = the ADMIN's users.id (never the Base44 id)
SELECT iit.set_staff_identity('b44-new','New Person','new@test','b44-admin');
DO $$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM iit.record_history h JOIN iit.staff_identities si ON si.user_id = h.record_id
   WHERE si.base44_user_id='b44-new' AND h.table_name='users' AND h.actor_kind='user' AND h.changed_by='00000000-0000-4000-8000-00000000000a';
  IF n <> 1 THEN RAISE EXCEPTION 'T3 expected user-attributed history for the new user, got %', n; END IF;
END $$;

-- T4 actor context is restored after a staff function: a following direct write is 'direct' again (AC2/AC3)
UPDATE iit.users SET display_name='Admin A2' WHERE id='00000000-0000-4000-8000-00000000000a';
DO $$ DECLARE k text; BEGIN
  SELECT actor_kind INTO k FROM iit.record_history WHERE table_name='users' AND record_id='00000000-0000-4000-8000-00000000000a' ORDER BY id DESC LIMIT 1;
  IF k <> 'direct' THEN RAISE EXCEPTION 'T4 context leaked: last write attributed as %', k; END IF;
END $$;

-- T5 a rejected actor writes nothing and leaves no context (invariant 12b)
DO $$ DECLARE before_n int; after_n int; BEGIN
  SELECT count(*) INTO before_n FROM iit.record_history;
  BEGIN PERFORM iit.set_staff_identity('b44-x','X','x@test','b44-de'); RAISE EXCEPTION 'T5 should have raised'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  SELECT count(*) INTO after_n FROM iit.record_history;
  IF before_n <> after_n THEN RAISE EXCEPTION 'T5 rejected call wrote % history rows', after_n - before_n; END IF;
  IF coalesce(current_setting('app.actor_kind', true),'') <> '' THEN RAISE EXCEPTION 'T5 actor context leaked after rejection'; END IF;
END $$;

-- T6 a kind without a user id fails closed (§5.9.3 "raise")
DO $$ BEGIN
  PERFORM set_config('app.actor_kind','user',true); PERFORM set_config('app.actor_user_id','',true);
  BEGIN UPDATE iit.users SET display_name='bad' WHERE id='00000000-0000-4000-8000-00000000000d'; RAISE EXCEPTION 'T6 should have raised';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'history: actor kind%' THEN RAISE; END IF; END;
  PERFORM set_config('app.actor_kind','',true);
END $$;

-- T7 deactivated staff cannot act on the next call (re-read every call); deactivation is recorded with before/after and attribution (finding 3)
SELECT iit.deactivate_staff('b44-new','b44-admin');
DO $$ DECLARE h record; BEGIN
  BEGIN PERFORM iit.require_role('b44-new','data_entry'); RAISE EXCEPTION 'T7 should have raised'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
  SELECT * INTO h FROM iit.record_history WHERE table_name='staff_identities' AND record_key='b44-new' AND op='U' ORDER BY id DESC LIMIT 1;
  IF h IS NULL OR (h.before->>'active') <> 'true' OR (h.after->>'active') <> 'false' OR h.actor_kind <> 'user' OR h.changed_by <> '00000000-0000-4000-8000-00000000000a' THEN RAISE EXCEPTION 'T7b deactivation history missing or wrong: %', h; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.activity_events WHERE action='staff_deactivated' AND actor_id='00000000-0000-4000-8000-00000000000a') THEN RAISE EXCEPTION 'T7c no deactivation activity event'; END IF;
  -- identity creation was recorded too (op I, actor = admin)
  IF NOT EXISTS (SELECT 1 FROM iit.record_history WHERE table_name='staff_identities' AND record_key='b44-new' AND op='I' AND changed_by='00000000-0000-4000-8000-00000000000a') THEN RAISE EXCEPTION 'T7d identity creation not recorded'; END IF;
END $$;
-- T7e role revocation (a DELETE on user_roles) is recorded as op D with the before image, both via function and directly
SELECT iit.set_staff_role('00000000-0000-4000-8000-00000000000d', 'audit_lead', true, 'b44-admin');
SELECT iit.set_staff_role('00000000-0000-4000-8000-00000000000d', 'audit_lead', false, 'b44-admin');
DELETE FROM iit.user_roles WHERE user_id='00000000-0000-4000-8000-00000000000d' AND role='data_entry';
DO $$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM iit.record_history WHERE table_name='user_roles' AND record_key='00000000-0000-4000-8000-00000000000d|audit_lead' AND op='D' AND actor_kind='user' AND (before->>'role')='audit_lead';
  IF n <> 1 THEN RAISE EXCEPTION 'T7e function revocation not recorded (%)', n; END IF;
  SELECT count(*) INTO n FROM iit.record_history WHERE table_name='user_roles' AND record_key='00000000-0000-4000-8000-00000000000d|data_entry' AND op='D' AND actor_kind='direct';
  IF n <> 1 THEN RAISE EXCEPTION 'T7f direct revocation not recorded (%)', n; END IF;
END $$;
INSERT INTO iit.user_roles(user_id, role) VALUES ('00000000-0000-4000-8000-00000000000d','data_entry');

-- T8 append-only tables reject UPDATE and DELETE; current records reject DELETE
DO $$ BEGIN
  BEGIN UPDATE iit.record_history SET op='U' WHERE id=(SELECT min(id) FROM iit.record_history); RAISE EXCEPTION 'T8a should have raised'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN DELETE FROM iit.record_history WHERE id=(SELECT min(id) FROM iit.record_history); RAISE EXCEPTION 'T8b should have raised'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN DELETE FROM iit.users WHERE id='00000000-0000-4000-8000-00000000000d'; RAISE EXCEPTION 'T8c should have raised'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END $$;

-- T9 deals: VIN normalization + uniqueness; PR1/PR2 (NULL price → NULL balances; never 0); G8 consignment CHECK
INSERT INTO iit.vehicles(id, vin) VALUES ('00000000-0000-4000-8000-0000000000b1', ' 1hgcm82633a004352 ') ON CONFLICT DO NOTHING;
DO $$ DECLARE v text; BEGIN
  SELECT vin_normalized INTO v FROM iit.vehicles WHERE vin=' 1hgcm82633a004352 ';
  IF v <> '1HGCM82633A004352' THEN RAISE EXCEPTION 'T9a normalization: %', v; END IF;
  BEGIN INSERT INTO iit.vehicles(vin) VALUES ('1HGCM82633A004352'); RAISE EXCEPTION 'T9b duplicate VIN accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;
INSERT INTO iit.deals(id, vehicle_id, origin, deposit_amount) SELECT '00000000-0000-4000-8000-0000000000e1', id, 'manual_consignment', 500 FROM iit.vehicles WHERE vin_normalized='1HGCM82633A004352';
DO $$ DECLARE b numeric; BEGIN
  SELECT balance INTO b FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e1';
  IF b IS NOT NULL THEN RAISE EXCEPTION 'T9c consignment balance must be NULL, got %', b; END IF;
  BEGIN UPDATE iit.deals SET purchase_price=100 WHERE id='00000000-0000-4000-8000-0000000000e1'; RAISE EXCEPTION 'T9d consignment price accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
INSERT INTO iit.deals(id, vehicle_id, origin, purchase_price, deposit_amount) SELECT '00000000-0000-4000-8000-0000000000e2', id, 'vauto_intake', 24850, 500 FROM iit.vehicles WHERE vin_normalized='1HGCM82633A004352';
DO $$ DECLARE b numeric; BEGIN
  SELECT balance INTO b FROM iit.deals WHERE id='00000000-0000-4000-8000-0000000000e2';
  IF b <> 24350 THEN RAISE EXCEPTION 'T9e balance expected 24350, got %', b; END IF;
END $$;

-- T10 deal_versions: one draft per deal; released rows immutable except → superseded; draft cannot be superseded directly
INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e2', 1, 'draft', 'intake');
DO $$ BEGIN
  BEGIN INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES ('00000000-0000-4000-8000-0000000000e2', 2, 'draft', 'resubmission'); RAISE EXCEPTION 'T10a second draft accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
  BEGIN UPDATE iit.deal_versions SET status='superseded' WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1; RAISE EXCEPTION 'T10b draft→superseded accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'VERSION_FLOW%' THEN RAISE; END IF; END;
END $$;
DO $$ BEGIN
  BEGIN UPDATE iit.deal_versions SET status='released', released_at=now(), released_by='00000000-0000-4000-8000-00000000000d', snapshot='{"purchase_price":1}'::jsonb, history_watermark=1
    WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1; RAISE EXCEPTION 'T10i non-empty snapshot accepted while its allowlist is undecided'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
UPDATE iit.deal_versions SET status='released', released_at=now(), released_by='00000000-0000-4000-8000-00000000000d', snapshot='{}'::jsonb, history_watermark=1
  WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1;
DO $$ BEGIN
  BEGIN UPDATE iit.deal_versions SET snapshot='{}'::jsonb, history_watermark=2 WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1; RAISE EXCEPTION 'T10c released watermark changed'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'VERSION_IMMUTABLE%' THEN RAISE; END IF; END;
  -- finding 2: reassignment or metadata edits alongside status='superseded' are rejected
  BEGIN UPDATE iit.deal_versions SET status='superseded', deal_id='00000000-0000-4000-8000-0000000000e1' WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1; RAISE EXCEPTION 'T10e reassignment to another deal accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'VERSION_IMMUTABLE%' THEN RAISE; END IF; END;
  BEGIN UPDATE iit.deal_versions SET status='superseded', version_no=7 WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1; RAISE EXCEPTION 'T10f version_no change accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'VERSION_IMMUTABLE%' THEN RAISE; END IF; END;
  BEGIN UPDATE iit.deal_versions SET status='superseded', opened_at=now()-interval '1 day' WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1; RAISE EXCEPTION 'T10g opened_at change accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'VERSION_IMMUTABLE%' THEN RAISE; END IF; END;
  BEGIN UPDATE iit.deal_versions SET status='superseded', released_by='00000000-0000-4000-8000-00000000000a' WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1; RAISE EXCEPTION 'T10h released_by change accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'VERSION_IMMUTABLE%' THEN RAISE; END IF; END;
  UPDATE iit.deal_versions SET status='superseded' WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1;
  BEGIN UPDATE iit.deal_versions SET status='released' WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND version_no=1; RAISE EXCEPTION 'T10d superseded changed'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'VERSION_IMMUTABLE%' THEN RAISE; END IF; END;
END $$;

-- T11 source_records: one initial row per deal; linked requires deal_id; reschedule needs replaces unless unlinked
INSERT INTO iit.source_records(deal_id, kind, created_via, link_status, linked_at) VALUES ('00000000-0000-4000-8000-0000000000e2','initial','cutover','linked',now());
DO $$ BEGIN
  BEGIN INSERT INTO iit.source_records(deal_id, kind, created_via) VALUES ('00000000-0000-4000-8000-0000000000e2','initial','cutover'); RAISE EXCEPTION 'T11a second initial row accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
  BEGIN INSERT INTO iit.source_records(kind, created_via, link_status, linked_at) VALUES ('reschedule','appsheet_reschedule','linked',now()); RAISE EXCEPTION 'T11b linked without deal accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;

-- T12 vauto_observations: field-level allowlist (finding 4), A→B→A history allowed, consecutive duplicate suppressed (finding 1)
DO $$ DECLARE r uuid; n int; BEGIN
  INSERT INTO iit.external_references(system, external_id) VALUES ('vauto_appraisal','A1') RETURNING id INTO r;
  INSERT INTO iit.vauto_observations(appraisal_ref_id, body, body_hash) VALUES (r, '{"vehicle":{"vin":"X","year":2019},"lien":{"owner":"Bank"}}', 'hA');
  BEGIN INSERT INTO iit.vauto_observations(appraisal_ref_id, body, body_hash) VALUES (r, '{"vehicle":{"vin":"X"},"raw":{}}', 'h2'); RAISE EXCEPTION 'T12a stray top-level key accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN INSERT INTO iit.vauto_observations(appraisal_ref_id, body, body_hash) VALUES (r, '{"vehicle":{"vin":"X","engine":"V6"}}', 'h3'); RAISE EXCEPTION 'T12b stray NESTED key accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN INSERT INTO iit.vauto_observations(appraisal_ref_id, body, body_hash) VALUES (r, '{"lien":{"accountNumber":"1"}}', 'h4'); RAISE EXCEPTION 'T12c accountNumber accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN INSERT INTO iit.vauto_observations(appraisal_ref_id, body, body_hash) VALUES (r, '{"customer":{"address":"1 st"}}', 'h5'); RAISE EXCEPTION 'T12d customer.address accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN INSERT INTO iit.vauto_observations(appraisal_ref_id, body, body_hash) VALUES (r, '{"vehicle":"not an object"}', 'h6'); RAISE EXCEPTION 'T12e scalar where structure expected accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
  -- consecutive duplicate (same hash as the latest) is suppressed
  BEGIN INSERT INTO iit.vauto_observations(appraisal_ref_id, body, body_hash) VALUES (r, '{"vehicle":{"vin":"X","year":2019},"lien":{"owner":"Bank"}}', 'hA'); RAISE EXCEPTION 'T12f consecutive duplicate accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
  -- A -> B -> A: the return to A is recorded
  INSERT INTO iit.vauto_observations(appraisal_ref_id, body, body_hash) VALUES (r, '{"vehicle":{"vin":"X","year":2020}}', 'hB');
  INSERT INTO iit.vauto_observations(appraisal_ref_id, body, body_hash) VALUES (r, '{"vehicle":{"vin":"X","year":2019},"lien":{"owner":"Bank"}}', 'hA');
  SELECT count(*) INTO n FROM iit.vauto_observations WHERE appraisal_ref_id = r; IF n <> 3 THEN RAISE EXCEPTION 'T12g expected 3 observations (A,B,A), got %', n; END IF;
  BEGIN UPDATE iit.vauto_observations SET body_hash='z' WHERE body_hash='hB'; RAISE EXCEPTION 'T12h observation mutated'; EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END $$;

-- T12x source_observations: fail closed while the 3.1 map is undecided (finding 4); current_observation must belong to the record (finding 5)
DO $$ DECLARE s1 uuid; s2 uuid; o1 uuid; BEGIN
  SELECT id INTO s1 FROM iit.source_records WHERE deal_id='00000000-0000-4000-8000-0000000000e2' AND kind='initial';
  INSERT INTO iit.source_records(kind, created_via) VALUES ('cutover_legacy','cutover') RETURNING id INTO s2;
  BEGIN INSERT INTO iit.source_observations(source_record_id, body, body_hash) VALUES (s1, '{"Deal Status":"In-Progress"}', 'o1'); RAISE EXCEPTION 'T12x-a non-empty 3.1 body accepted while allowlist is empty'; EXCEPTION WHEN check_violation THEN NULL; END;
  INSERT INTO iit.source_observations(source_record_id, body, body_hash) VALUES (s2, '{}', 'o-empty') RETURNING id INTO o1;
  BEGIN UPDATE iit.source_records SET current_observation_id = o1 WHERE id = s1; RAISE EXCEPTION 'T12x-b observation of another record accepted as current'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  UPDATE iit.source_records SET current_observation_id = o1 WHERE id = s2;   -- own observation: accepted
END $$;

-- T12y deals.consignment_id must be this deal's consignment (finding 6)
DO $$ DECLARE p uuid; c1 uuid; BEGIN
  INSERT INTO iit.seller_parties(party_type, first_name, last_name, phone) VALUES ('person','Con','Signor','(555) 010-0000') RETURNING id INTO p;
  INSERT INTO iit.consignments(deal_id, consignor_party_id, consignment_amount) VALUES ('00000000-0000-4000-8000-0000000000e1', p, 12000) RETURNING id INTO c1;
  BEGIN UPDATE iit.deals SET consignment_id = c1 WHERE id='00000000-0000-4000-8000-0000000000e2'; RAISE EXCEPTION 'T12y-a another deal''s consignment accepted'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  UPDATE iit.deals SET consignment_id = c1 WHERE id='00000000-0000-4000-8000-0000000000e1';   -- own consignment: accepted
END $$;

-- T13 appraisal_episodes: one open episode per reference
DO $$ DECLARE r uuid; BEGIN
  SELECT id INTO r FROM iit.external_references WHERE external_id='A1';
  INSERT INTO iit.appraisal_episodes(appraisal_ref_id, deal_id, episode_no, start_basis) VALUES (r,'00000000-0000-4000-8000-0000000000e2',1,'first_completion');
  BEGIN INSERT INTO iit.appraisal_episodes(appraisal_ref_id, deal_id, episode_no, start_basis) VALUES (r,'00000000-0000-4000-8000-0000000000e1',2,'data_entry_restart'); RAISE EXCEPTION 'T13 second open episode accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;

-- T14 work_items: one open restart task per appraisal
DO $$ DECLARE r uuid; BEGIN
  SELECT id INTO r FROM iit.external_references WHERE external_id='A1';
  INSERT INTO iit.work_items(kind, appraisal_ref_id, assigned_role) VALUES ('restart_candidate', r, 'data_entry');
  BEGIN INSERT INTO iit.work_items(kind, appraisal_ref_id, assigned_role) VALUES ('restart_candidate', r, 'data_entry'); RAISE EXCEPTION 'T14 duplicate open restart task accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;

-- T15 grants (invariant 12a): anon/authenticated/PUBLIC cannot execute staff functions; iit_integration can; tav_worker cannot
DO $$ BEGIN
  IF has_function_privilege('anon', 'iit.set_staff_identity(text,text,text,text)', 'EXECUTE') THEN RAISE EXCEPTION 'T15a anon can execute'; END IF;
  IF has_function_privilege('authenticated', 'iit.set_staff_identity(text,text,text,text)', 'EXECUTE') THEN RAISE EXCEPTION 'T15b authenticated can execute'; END IF;
  IF NOT has_function_privilege('iit_integration', 'iit.set_staff_identity(text,text,text,text)', 'EXECUTE') THEN RAISE EXCEPTION 'T15c integration cannot execute'; END IF;
  IF has_function_privilege('tav_worker', 'iit.set_staff_identity(text,text,text,text)', 'EXECUTE') THEN RAISE EXCEPTION 'T15d worker can execute staff function'; END IF;
  IF has_function_privilege('iit_integration', 'iit.require_role(text,text)', 'EXECUTE') THEN RAISE EXCEPTION 'T15e integration can call require_role directly'; END IF;
  IF has_schema_privilege('anon', 'iit', 'USAGE') THEN RAISE EXCEPTION 'T15f anon has schema usage'; END IF;
END $$;

-- T16 role capture (AC10): a function write under SET ROLE iit_integration records exec_role = owner, origin_role = integration
SET ROLE iit_integration;
SELECT iit.set_staff_role('00000000-0000-4000-8000-00000000000d', 'auditor', true, 'b44-admin');
RESET ROLE;
DO $$ DECLARE r record; BEGIN
  SELECT exec_role, origin_role INTO r FROM iit.record_history WHERE table_name='users' ORDER BY id DESC LIMIT 1;
  -- set_staff_role writes activity_events (append-only, no history) — check the activity row's attribution instead
  IF NOT EXISTS (SELECT 1 FROM iit.activity_events WHERE action='role_granted' AND actor_kind='user' AND actor_id='00000000-0000-4000-8000-00000000000a') THEN RAISE EXCEPTION 'T16a activity attribution'; END IF;
END $$;
SET ROLE iit_integration;
UPDATE iit.users SET display_name='Direct by integration' WHERE id='00000000-0000-4000-8000-00000000000d';
RESET ROLE;
DO $$ DECLARE r record; BEGIN
  SELECT exec_role, origin_role, actor_kind INTO r FROM iit.record_history WHERE table_name='users' AND record_id='00000000-0000-4000-8000-00000000000d' ORDER BY id DESC LIMIT 1;
  IF r.exec_role <> 'iit_integration' OR r.origin_role <> 'iit_integration' OR r.actor_kind <> 'direct' THEN RAISE EXCEPTION 'T16b direct edit capture: %', r; END IF;
END $$;
SET ROLE iit_integration;
SELECT iit.set_staff_identity('b44-de','Data Entry D','de@test','b44-admin');
RESET ROLE;
DO $$ DECLARE r record; BEGIN
  SELECT exec_role, origin_role, actor_kind INTO r FROM iit.record_history WHERE table_name='users' AND record_id='00000000-0000-4000-8000-00000000000d' ORDER BY id DESC LIMIT 1;
  IF r.exec_role <> 'iit_owner' OR r.origin_role <> 'iit_integration' OR r.actor_kind <> 'user' THEN RAISE EXCEPTION 'T16c function-write capture: %', r; END IF;
END $$;

-- T17 RLS is enabled on every table in iit with no policies
DO $$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace s ON s.oid=c.relnamespace WHERE s.nspname='iit' AND c.relkind='r' AND NOT c.relrowsecurity;
  IF n <> 0 THEN RAISE EXCEPTION 'T17 % tables without RLS', n; END IF;
  SELECT count(*) INTO n FROM pg_policies WHERE schemaname='iit'; IF n <> 0 THEN RAISE EXCEPTION 'T17b unexpected policies'; END IF;
END $$;

-- T18 history coverage inventory (finding 3): every table in iit has either the history trigger or append-only enforcement
DO $$ DECLARE r record; missing text := ''; BEGIN
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace s ON s.oid=c.relnamespace WHERE s.nspname='iit' AND c.relkind='r' LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c2 ON c2.oid=t.tgrelid JOIN pg_namespace s2 ON s2.oid=c2.relnamespace WHERE s2.nspname='iit' AND c2.relname=r.relname AND t.tgname IN ('zz_history','zz_append_only')) THEN
      missing := missing || r.relname || ' '; END IF; END LOOP;
  IF missing <> '' THEN RAISE EXCEPTION 'T18 tables without history/append-only coverage: %', missing; END IF;
END $$;

-- T19 activity_events detail allowlist: a key outside the schema is rejected
DO $$ BEGIN
  BEGIN INSERT INTO iit.activity_events(entity_type, action, after, actor_kind, source) VALUES ('x','y','{"secret":"s"}','direct','t'); RAISE EXCEPTION 'T19 stray activity detail key accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;

SELECT 'ALL 001 TESTS PASS' AS result;
