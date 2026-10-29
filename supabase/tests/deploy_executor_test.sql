-- deploy_executor_test.sql — run_local.sh applies every migration to a fresh, test-free database as `deployer` (LOGIN, CREATEROLE, not
-- superuser — the shape of Supabase's `postgres`) and then runs this as superuser. Proves the executor holds iit_owner with SET
-- only, that nothing else was granted, and that the install left PUBLIC/anon/authenticated/service_role and D-36/D-40 untouched.
\set ON_ERROR_STOP on
\set QUIET on

-- X1 the executor is Supabase-shaped (guards the harness itself)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='deployer' AND rolcanlogin AND rolcreaterole AND NOT rolsuper AND NOT rolbypassrls) THEN RAISE EXCEPTION 'X1 deployer is not a non-superuser CREATEROLE login'; END IF;
END $$;

-- X2 deployer's iit_owner membership: one SET-only grant (ADMIN FALSE, INHERIT FALSE, SET TRUE) plus the PG16+ CREATEROLE
-- auto-grant from the bootstrap superuser (ADMIN TRUE, INHERIT FALSE, SET FALSE). No row of either kind inherits.
DO $$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member
   WHERE r.rolname='iit_owner' AND m.rolname='deployer';
  IF n <> 2 THEN RAISE EXCEPTION 'X2a deployer has % iit_owner grants, expected 2', n; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member JOIN pg_roles g ON g.oid=am.grantor
                  WHERE r.rolname='iit_owner' AND m.rolname='deployer' AND g.rolname='deployer' AND am.set_option AND NOT am.inherit_option AND NOT am.admin_option)
    THEN RAISE EXCEPTION 'X2b no SET TRUE / INHERIT FALSE / ADMIN FALSE grant'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member JOIN pg_roles g ON g.oid=am.grantor
                  WHERE r.rolname='iit_owner' AND m.rolname='deployer' AND g.rolsuper AND am.admin_option AND NOT am.inherit_option AND NOT am.set_option)
    THEN RAISE EXCEPTION 'X2c CREATEROLE auto-grant is not ADMIN-only'; END IF;
  IF EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member
              WHERE r.rolname='iit_owner' AND m.rolname='deployer' AND am.inherit_option) THEN RAISE EXCEPTION 'X2d an INHERIT grant exists'; END IF;
  IF NOT pg_has_role('deployer', 'iit_owner', 'SET') THEN RAISE EXCEPTION 'X2e deployer cannot SET ROLE iit_owner'; END IF;
  IF pg_has_role('deployer', 'iit_owner', 'USAGE') THEN RAISE EXCEPTION 'X2f deployer inherits iit_owner privileges'; END IF;
END $$;

-- X3 iit_owner (and every IIT role) stays NOLOGIN and unprivileged
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('iit_owner','iit_integration','tav_worker','iit_base44')
              AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)) THEN RAISE EXCEPTION 'X3 an IIT role can log in or is privileged'; END IF;
  IF (SELECT count(*) FROM pg_roles WHERE rolname IN ('iit_owner','iit_integration','tav_worker','iit_base44')) <> 4 THEN RAISE EXCEPTION 'X3b IIT roles missing'; END IF;
END $$;

-- X4 the complete membership graph of the IIT roles: deployer's CREATEROLE auto-grants (ADMIN only) on all four, deployer's
-- SET-only grant on iit_owner, authenticator's SET-only grant on iit_base44 (006). Nothing else — no IIT role is a member of
-- anything either.
DO $$ DECLARE extra text; BEGIN
  SELECT string_agg(format('%s<-%s(by %s a=%s i=%s s=%s)', r.rolname, m.rolname, g.rolname, am.admin_option, am.inherit_option, am.set_option), '; ') INTO extra
    FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member JOIN pg_roles g ON g.oid=am.grantor
   WHERE (r.rolname IN ('iit_owner','iit_integration','tav_worker','iit_base44') OR m.rolname IN ('iit_owner','iit_integration','tav_worker','iit_base44'))
     AND NOT (m.rolname='deployer' AND g.rolsuper AND am.admin_option AND NOT am.inherit_option AND NOT am.set_option)
     AND NOT (r.rolname='iit_owner' AND m.rolname='deployer' AND g.rolname='deployer' AND am.set_option AND NOT am.inherit_option AND NOT am.admin_option)
     AND NOT (r.rolname='iit_base44' AND m.rolname='authenticator' AND am.set_option AND NOT am.inherit_option AND NOT am.admin_option);
  IF extra IS NOT NULL THEN RAISE EXCEPTION 'X4 unexpected IIT role memberships: %', extra; END IF;
END $$;

-- X5 PUBLIC, anon, authenticated and service_role have no privilege on schema iit or on anything in it
DO $$ DECLARE bad text; BEGIN
  SELECT string_agg(x, '; ') INTO bad FROM (
    SELECT 'schema iit -> ' || coalesce(g.rolname, 'PUBLIC') || ' ' || a.privilege_type AS x
      FROM pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a LEFT JOIN pg_roles g ON g.oid = a.grantee
     WHERE n.nspname='iit' AND (a.grantee = 0 OR g.rolname IN ('anon','authenticated','service_role'))
    UNION ALL
    SELECT c.oid::regclass::text || ' -> ' || coalesce(g.rolname, 'PUBLIC') || ' ' || a.privilege_type
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace, aclexplode(coalesce(c.relacl, acldefault(CASE WHEN c.relkind='S' THEN 's' ELSE 'r' END::"char", c.relowner))) a LEFT JOIN pg_roles g ON g.oid = a.grantee
     WHERE n.nspname='iit' AND c.relkind IN ('r','p','v','m','S','f') AND (a.grantee = 0 OR g.rolname IN ('anon','authenticated','service_role'))
    UNION ALL
    SELECT p.oid::regprocedure::text || ' -> ' || coalesce(g.rolname, 'PUBLIC') || ' ' || a.privilege_type
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a LEFT JOIN pg_roles g ON g.oid = a.grantee
     WHERE n.nspname='iit' AND (a.grantee = 0 OR g.rolname IN ('anon','authenticated','service_role'))
    UNION ALL
    SELECT 'default ACL -> ' || coalesce(g.rolname, 'PUBLIC') || ' ' || a.privilege_type
      FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace, aclexplode(d.defaclacl) a LEFT JOIN pg_roles g ON g.oid = a.grantee
     -- global rows (defaclnamespace = 0, V-2 / 007) included: they govern iit objects too
     WHERE (n.nspname='iit' OR d.defaclnamespace = 0) AND (a.grantee = 0 OR g.rolname IN ('anon','authenticated','service_role'))
  ) s;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'X5 public/API roles hold iit privileges: %', bad; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole))
    THEN RAISE EXCEPTION 'X5b API role attributes changed'; END IF;
END $$;

-- X6 D-36 and D-40 are created empty: no target is proven idempotent and no integration/action pair is allowlisted
DO $$ BEGIN
  IF (SELECT count(*) FROM iit.gate_idempotent_targets) <> 0 THEN RAISE EXCEPTION 'X6a D-36 gate_idempotent_targets is populated'; END IF;
  IF (SELECT count(*) FROM iit.gate_integration_actions) <> 0 THEN RAISE EXCEPTION 'X6b D-40 gate_integration_actions is populated'; END IF;
END $$;

-- X7 nothing the install created reads or names the spike schema (the name is assembled so this file does not contain it)
DO $$ DECLARE spike text := 's2' || 'test'; BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = spike) THEN RAISE EXCEPTION 'X7a the spike schema exists in the test database'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='iit' AND p.prosrc ILIKE '%' || spike || '%')
    THEN RAISE EXCEPTION 'X7b an iit function body names the spike schema'; END IF;
END $$;

-- X8 as the executor itself: no owner privileges before SET ROLE; explicit SET ROLE iit_owner works; RESET drops them again
\connect - deployer
\set ON_ERROR_STOP on
DO $$ BEGIN
  BEGIN PERFORM 1 FROM iit.users LIMIT 1; RAISE EXCEPTION 'X8a deployer read iit.users without SET ROLE';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SET ROLE iit_owner;
DO $$ BEGIN
  IF current_user <> 'iit_owner' THEN RAISE EXCEPTION 'X8b SET ROLE did not take effect'; END IF;
  PERFORM 1 FROM iit.users LIMIT 1;
END $$;
RESET ROLE;
DO $$ BEGIN
  IF current_user <> 'deployer' THEN RAISE EXCEPTION 'X8c RESET ROLE did not return to deployer'; END IF;
  BEGIN PERFORM 1 FROM iit.users LIMIT 1; RAISE EXCEPTION 'X8d deployer kept owner privileges after RESET ROLE';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;

SELECT 'ALL EXECUTOR TESTS PASS' AS result;
