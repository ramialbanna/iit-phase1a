-- 001_foundation.sql — schema `iit`, Phase 1a foundation slice.
-- Maps to Design v0.17: §1 principles, §2 authorization (require_role, grants), §4/§5.1–5.5 core tables,
-- §5.9 history model (actor context push/restore, record_history, append-only enforcement), §7 storage policy hooks.
-- EXCLUDED here (later migrations): §5.6 report pack, §5.7/5.7a Risk Audit + holds, §5.10 polling, §5.11 lienholder sync,
-- §6 gate (Worker contract). EXCLUDED by owner decision: §5.8 bridge objects — see docs/migrations/001.md §3.
-- Conventions: Postgres 15+; uuid keys; numeric(14,2) money; timestamptz; text + CHECK for statuses; every mutable
-- current-record table has the history trigger; every append-only table has reject_mutation.
-- Roles: this file CREATEs the NOLOGIN roles it needs if absent (iit_owner, iit_integration, tav_worker). The real Base44
-- integration role is granted membership of iit_integration once identified (P1) — docs/migrations/001.md D-2.


-- ---------------------------------------------------------------------------------------------------------------------
-- 0. roles and schema
-- ---------------------------------------------------------------------------------------------------------------------
-- The executor on Supabase is `postgres`: CREATEROLE, not superuser. Since PG16 such a creator is auto-granted ADMIN on each
-- role it creates (SET FALSE, INHERIT FALSE) plus whatever createrole_self_grant adds; pin that GUC empty so no SET or INHERIT
-- membership in iit_integration / tav_worker / iit_owner can come from the session's configuration.
SET createrole_self_grant = '';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iit_owner')       THEN CREATE ROLE iit_owner NOLOGIN; END IF;
  -- iit_integration: the role EXECUTE on staff-facing functions is granted to. Rev 4: NO BYPASSRLS — that attribute needs a
  -- superuser to create and Supabase's `postgres` is not one (001 would fail at application); RLS with no policies therefore
  -- denies this role's DIRECT table writes (deny by default, §2.2), which is the better property anyway. D-2 (measured 28 Oct):
  -- the Base44 integration executes SQL as the project's `postgres` role through the Management API — see docs/migrations/001.md.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iit_integration') THEN CREATE ROLE iit_integration NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tav_worker')      THEN CREATE ROLE tav_worker NOLOGIN; END IF;
END $$;
RESET createrole_self_grant;

-- CREATE SCHEMA ... AUTHORIZATION and every later SET ROLE iit_owner (here and in 002–006) need SET on iit_owner, which the
-- auto-grant withholds (first remote attempt: 42501 "must be able to SET ROLE"). SET only: INHERIT FALSE keeps iit_owner's
-- privileges unusable without an explicit SET ROLE; ADMIN FALSE adds no grant authority. Kept for the life of the schema:
-- 002–006 and any later migration switch to iit_owner the same way.
GRANT iit_owner TO CURRENT_USER WITH ADMIN FALSE, INHERIT FALSE, SET TRUE;
DO $$ BEGIN
  IF NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user)
     AND pg_catalog.pg_has_role(current_user, 'iit_owner', 'USAGE') THEN
    RAISE EXCEPTION '001: executor % inherits iit_owner privileges; only SET membership is allowed', current_user;
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS iit AUTHORIZATION iit_owner;

-- Schema grants and default privileges run as the owner: the executor holds no owner privileges (no INHERIT), so issued as
-- the executor they fail with 42501 on Supabase.
SET ROLE iit_owner;
SET search_path = pg_catalog;
REVOKE ALL ON SCHEMA iit FROM PUBLIC;
GRANT USAGE ON SCHEMA iit TO iit_integration, tav_worker;
-- Default privileges: nothing to PUBLIC/anon/authenticated. Table access for the integration is direct and privileged in
-- Supabase anyway (§2.5 risk 1); we grant it explicitly per table below so local tests mirror that.
ALTER DEFAULT PRIVILEGES FOR ROLE iit_owner IN SCHEMA iit REVOKE ALL ON FUNCTIONS FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. staff identity (§2.1, §4 P4): our own users / roles / user_roles / staff_identities / external_user_map
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text NOT NULL,
  email text UNIQUE,
  kind text NOT NULL DEFAULT 'staff' CHECK (kind IN ('staff','service')),   -- 'service' = the Worker's fixed user
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE iit.roles (
  name text PRIMARY KEY,
  description text NOT NULL
);
-- Role catalogue: 'data_entry' and 'audit_lead' are named in the design; the rest are proposed (docs/migrations/001.md D-1).
INSERT INTO iit.roles VALUES
  ('data_entry', 'Data Entry: intake review, release, corrections, work items'),
  ('audit_lead', 'Risk Audit lead: decisions, waivers, re-audit requests'),
  ('auditor',    'Risk Audit: decisions'),
  ('admin',      'Staff management');
CREATE TABLE iit.user_roles (
  user_id uuid NOT NULL REFERENCES iit.users(id),
  role text NOT NULL REFERENCES iit.roles(name),
  granted_by uuid REFERENCES iit.users(id),
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role)
);
CREATE TABLE iit.staff_identities (            -- Base44 user id → users.id; re-read on EVERY call (§2.1)
  base44_user_id text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES iit.users(id),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  deactivated_at timestamptz,
  CHECK ((active) = (deactivated_at IS NULL))
);
CREATE UNIQUE INDEX staff_identities_one_active_per_user ON iit.staff_identities (user_id) WHERE active;
CREATE TABLE iit.external_user_map (           -- vAuto username → users.id (informational attribution of vAuto personnel)
  system text NOT NULL CHECK (system IN ('vauto')),
  external_username text NOT NULL,
  user_id uuid NOT NULL REFERENCES iit.users(id),
  PRIMARY KEY (system, external_username)
);

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. actor context (§5.9.1): transaction-local settings app.actor_user_id / app.actor_kind / app.via_trigger
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TYPE iit.actor_ctx AS (actor_user_id text, actor_kind text, via_trigger text);

CREATE FUNCTION iit.actor_push(p_user_id uuid, p_kind text) RETURNS iit.actor_ctx
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_prev iit.actor_ctx;
BEGIN
  IF p_kind NOT IN ('user','worker','system') THEN RAISE EXCEPTION 'actor_push: invalid kind %', p_kind; END IF;
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'actor_push: kind % requires a users.id', p_kind; END IF;
  v_prev := ROW(pg_catalog.current_setting('app.actor_user_id', true), pg_catalog.current_setting('app.actor_kind', true),
                pg_catalog.current_setting('app.via_trigger', true));
  PERFORM pg_catalog.set_config('app.actor_user_id', p_user_id::text, true);
  PERFORM pg_catalog.set_config('app.actor_kind', p_kind, true);
  RETURN v_prev;
END $$;

CREATE FUNCTION iit.actor_restore(p_prev iit.actor_ctx) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM pg_catalog.set_config('app.actor_user_id', coalesce(p_prev.actor_user_id, ''), true);
  PERFORM pg_catalog.set_config('app.actor_kind',    coalesce(p_prev.actor_kind, ''),    true);
  PERFORM pg_catalog.set_config('app.via_trigger',   coalesce(p_prev.via_trigger, ''),   true);
END $$;

-- require_role (§2.2): Base44 user id + required role → internal users.id, or raise. Writes nothing.
CREATE FUNCTION iit.require_role(p_actor_base44_user_id text, p_required_role text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE v_user uuid;
BEGIN
  IF p_actor_base44_user_id IS NULL OR p_actor_base44_user_id = '' THEN RAISE EXCEPTION 'ACTOR_REQUIRED' USING ERRCODE = '28000'; END IF;
  SELECT si.user_id INTO v_user
    FROM iit.staff_identities si JOIN iit.users u ON u.id = si.user_id
   WHERE si.base44_user_id = p_actor_base44_user_id AND si.active AND u.active;
  IF v_user IS NULL THEN RAISE EXCEPTION 'ACTOR_UNKNOWN_OR_INACTIVE' USING ERRCODE = '28000'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.user_roles ur WHERE ur.user_id = v_user AND ur.role = p_required_role) THEN
    RAISE EXCEPTION 'ROLE_MISSING: %', p_required_role USING ERRCODE = '42501';
  END IF;
  RETURN v_user;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. history model (§5.9): record_history (append-only), history trigger (SECURITY INVOKER), reject_mutation
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.record_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  table_name text NOT NULL,
  record_key text NOT NULL,                                 -- primary key value(s) as text ("a|b" for composite keys)
  record_id uuid NULL,                                      -- the uuid id when the table has one (convenience for joins)
  op text NOT NULL CHECK (op IN ('I','U','D')),
  before jsonb, after jsonb,                                -- to_jsonb(row): the tables hold only allowlisted columns (§7), so history does too
  CHECK ((op = 'I') = (before IS NULL)), CHECK ((op = 'D') = (after IS NULL)),
  changed_by uuid NULL REFERENCES iit.users(id),
  actor_kind text NOT NULL CHECK (actor_kind IN ('user','worker','system','direct')),
  via_trigger text NULL,
  exec_role text NOT NULL, origin_role text NULL, origin_jwt_role text NULL, origin_session_role text NOT NULL,
  at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CHECK ((actor_kind = 'direct') = (changed_by IS NULL))
);
CREATE INDEX record_history_record_idx ON iit.record_history (table_name, record_key, id);

-- SECURITY INVOKER on purpose (§5.9.2): current_user inside = the executing role (definer owner for function writes).
CREATE FUNCTION iit.history_trigger() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_kind text; v_user text; v_uid uuid; v_role text; v_jwt text; v_claims text; v_row jsonb; v_key text; v_rid uuid; i int;
BEGIN
  -- TG_ARGV[0] = comma-separated key column names (default 'id'); the key is read from the row image
  v_row := CASE TG_OP WHEN 'DELETE' THEN pg_catalog.to_jsonb(OLD) ELSE pg_catalog.to_jsonb(NEW) END;
  v_key := '';
  FOR i IN 1 .. pg_catalog.array_length(pg_catalog.string_to_array(coalesce(TG_ARGV[0], 'id'), ','), 1) LOOP
    v_key := v_key || CASE WHEN i > 1 THEN '|' ELSE '' END || coalesce(v_row ->> (pg_catalog.string_to_array(coalesce(TG_ARGV[0], 'id'), ','))[i], '');
  END LOOP;
  v_rid := CASE WHEN (v_row ? 'id') AND (v_row ->> 'id') ~ '^[0-9a-f-]{36}$' THEN (v_row ->> 'id')::uuid END;
  v_kind := nullif(pg_catalog.current_setting('app.actor_kind', true), '');
  v_user := nullif(pg_catalog.current_setting('app.actor_user_id', true), '');
  IF v_kind IS NULL THEN
    v_kind := 'direct'; v_uid := NULL;                                       -- no actor → direct (§5.9.3)
  ELSE
    IF v_user IS NULL THEN RAISE EXCEPTION 'history: actor kind % without a user id (programming error; write refused)', v_kind; END IF;
    v_uid := v_user::uuid;
    IF NOT EXISTS (SELECT 1 FROM iit.users WHERE id = v_uid) THEN RAISE EXCEPTION 'history: actor user % does not exist', v_uid; END IF;
  END IF;
  v_role := nullif(pg_catalog.current_setting('role', true), 'none');
  v_claims := pg_catalog.current_setting('request.jwt.claims', true);
  v_jwt := CASE WHEN v_claims IS NULL OR v_claims = '' THEN NULL ELSE (v_claims::jsonb ->> 'role') END;
  INSERT INTO iit.record_history(table_name, record_key, record_id, op, before, after, changed_by, actor_kind, via_trigger,
                                 exec_role, origin_role, origin_jwt_role, origin_session_role)
  VALUES (TG_TABLE_NAME, v_key, v_rid, CASE TG_OP WHEN 'INSERT' THEN 'I' WHEN 'UPDATE' THEN 'U' ELSE 'D' END,
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN pg_catalog.to_jsonb(OLD) END, CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN pg_catalog.to_jsonb(NEW) END,
          v_uid, v_kind, nullif(pg_catalog.current_setting('app.via_trigger', true), ''),
          current_user, v_role, v_jwt, session_user);
  RETURN COALESCE(NEW, OLD);
END $$;

CREATE FUNCTION iit.reject_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN RAISE EXCEPTION 'APPEND_ONLY: % on %.% is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME USING ERRCODE = '42501'; END $$;

CREATE FUNCTION iit.reject_delete() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN RAISE EXCEPTION 'NO_DELETE: current records in %.% are never deleted', TG_TABLE_SCHEMA, TG_TABLE_NAME USING ERRCODE = '42501'; END $$;

-- helper: attach the history model to a mutable current-record table (requires an `id uuid` column)
-- p_key_cols: primary-key column(s) recorded as record_key. p_allow_delete: current records are never deleted (default);
-- membership/reference rows that are legitimately removed (e.g. user_roles) record a 'D' history row instead.
CREATE FUNCTION iit.attach_history(p_table regclass, p_key_cols text DEFAULT 'id', p_allow_delete boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF p_allow_delete THEN
    EXECUTE pg_catalog.format('CREATE TRIGGER zz_history AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION iit.history_trigger(%L)', p_table, p_key_cols);
  ELSE
    EXECUTE pg_catalog.format('CREATE TRIGGER zz_history AFTER INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION iit.history_trigger(%L)', p_table, p_key_cols);
    EXECUTE pg_catalog.format('CREATE TRIGGER zz_no_delete BEFORE DELETE ON %s FOR EACH ROW EXECUTE FUNCTION iit.reject_delete()', p_table);
  END IF;
END $$;
CREATE FUNCTION iit.make_append_only(p_table regclass) RETURNS void LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  EXECUTE pg_catalog.format('CREATE TRIGGER zz_append_only BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION iit.reject_mutation()', p_table);
END $$;

SELECT iit.make_append_only('iit.record_history');
-- History coverage of §1 staff tables (Codex 001 finding 3): identities and role membership are security-relevant state.
SELECT iit.attach_history('iit.users');
SELECT iit.attach_history('iit.staff_identities', 'base44_user_id');
SELECT iit.attach_history('iit.user_roles', 'user_id,role', true);         -- revocation is a recorded DELETE
SELECT iit.attach_history('iit.external_user_map', 'system,external_username', true);
SELECT iit.attach_history('iit.roles', 'name');

-- §7 storage policy — FIELD-LEVEL allowlists, fail closed (Codex 001 finding 4).
-- iit.json_schemas holds one allowlist per stored JSON body. A schema is a JSON object: key → true (leaf allowed) or → a nested
-- schema object. A body matches only if every key at every level is present in the schema. An EMPTY schema admits only an empty
-- object: that is the fail-closed state for bodies whose allowlist is still undecided (D-7 nested vAuto fields; D-8 3.1 map).
CREATE TABLE iit.json_schemas (
  name text PRIMARY KEY, schema jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(schema) = 'object'),
  note text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now()
);
SELECT iit.attach_history('iit.json_schemas', 'name');
CREATE FUNCTION iit.json_matches_schema(p_body jsonb, p_schema jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE k text; v jsonb; sv jsonb;
BEGIN
  IF pg_catalog.jsonb_typeof(p_body) <> 'object' OR pg_catalog.jsonb_typeof(p_schema) <> 'object' THEN RETURN false; END IF;
  FOR k, v IN SELECT * FROM pg_catalog.jsonb_each(p_body) LOOP
    sv := p_schema -> k;
    IF sv IS NULL THEN RETURN false; END IF;                                   -- key not allowlisted
    IF pg_catalog.jsonb_typeof(sv) = 'object' THEN
      IF pg_catalog.jsonb_typeof(v) = 'object' THEN
        IF NOT iit.json_matches_schema(v, sv) THEN RETURN false; END IF;
      ELSIF pg_catalog.jsonb_typeof(v) = 'array' THEN                          -- array of objects: each element must match
        IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(v) e WHERE pg_catalog.jsonb_typeof(e) <> 'object' OR NOT iit.json_matches_schema(e, sv)) THEN RETURN false; END IF;
      ELSE RETURN false; END IF;                                               -- schema expects a structure, body has a scalar
    ELSIF sv = 'true'::jsonb THEN
      -- a leaf admits SCALARS only (string/number/boolean/null); objects and arrays need an explicit schema (Codex rev-2 finding 1)
      IF pg_catalog.jsonb_typeof(v) NOT IN ('string','number','boolean','null') THEN RETURN false; END IF;
    ELSE RETURN false; END IF;
  END LOOP;
  RETURN true;
END $$;
-- helper: is record column <name> SQL NULL? (to_jsonb cannot tell SQL NULL from JSON null; jsonb_populate/`$1.col` can)
CREATE FUNCTION iit._column_is_sql_null(p_row anyelement, p_col text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v boolean;
BEGIN
  EXECUTE pg_catalog.format('SELECT ($1).%I IS NULL', p_col) INTO v USING p_row;
  RETURN v;
END $$;
-- generic BEFORE trigger: iit.enforce_json(<column>, <schema name>) — raises STORAGE_POLICY on any non-allowlisted key
CREATE FUNCTION iit.enforce_json() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_body jsonb; v_schema jsonb;
BEGIN
  v_body := pg_catalog.to_jsonb(NEW) -> TG_ARGV[0];
  -- to_jsonb(NEW) renders a SQL NULL column as JSON null, so re-check the column itself: SQL NULL is allowed where the table allows
  -- it (e.g. a draft snapshot); a stored JSON 'null' is NOT an object and is rejected (Codex rev-2 finding 2).
  IF v_body IS NULL THEN RETURN NEW; END IF;
  IF v_body = 'null'::jsonb THEN
    IF (pg_catalog.to_jsonb(NEW) ? TG_ARGV[0]) AND iit._column_is_sql_null(NEW, TG_ARGV[0]) THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'STORAGE_POLICY: %.% is JSON null; a body must be an object', TG_TABLE_NAME, TG_ARGV[0] USING ERRCODE = '23514';
  END IF;
  IF pg_catalog.jsonb_typeof(v_body) <> 'object' THEN
    RAISE EXCEPTION 'STORAGE_POLICY: %.% must be a JSON object (got %)', TG_TABLE_NAME, TG_ARGV[0], pg_catalog.jsonb_typeof(v_body) USING ERRCODE = '23514';
  END IF;
  SELECT schema INTO v_schema FROM iit.json_schemas WHERE name = TG_ARGV[1];
  IF v_schema IS NULL THEN RAISE EXCEPTION 'STORAGE_POLICY: no allowlist % for %.%', TG_ARGV[1], TG_TABLE_NAME, TG_ARGV[0] USING ERRCODE = '23514'; END IF;
  IF NOT iit.json_matches_schema(v_body, v_schema) THEN
    RAISE EXCEPTION 'STORAGE_POLICY: %.% contains a key outside allowlist %', TG_TABLE_NAME, TG_ARGV[0], TG_ARGV[1] USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
-- vAuto observation allowlist: the fields the design NAMES in §7 ("vehicle, appraisal value, personnel, customer name/phone/
-- email/postal code/city/state, title region/name, tag, lien owner/phone/payoff/payoff date/per diem, condition, timestamps,
-- sanitized notes"). Field names below are the design's words; the Worker's sanitizer must map vAuto's names onto exactly these,
-- and anything not listed is REJECTED. Extending the list is a reviewed change to this table (D-7).
INSERT INTO iit.json_schemas(name, schema, note) VALUES
 ('vauto_observation', '{
   "vehicle":   {"vin":true,"year":true,"make":true,"model":true,"series":true,"trim":true,"exterior_color":true,"mileage":true},
   "appraisal": {"value":true,"status":true,"is_completed":true},
   "personnel": {"appraiser":true,"buyer":true,"closer":true},
   "customer":  {"first_name":true,"last_name":true,"phone":true,"email":true,"postal_code":true,"city":true,"state":true},
   "title":     {"region":true,"name":true},
   "tag":       {"value":true},
   "lien":      {"owner":true,"phone":true,"payoff":true,"payoff_date":true,"per_diem":true},
   "condition": {"summary":true},
   "timestamps":{"created":true,"last_modified":true,"completed":true},
   "notes_sanitized": {"labels": {"label":true,"value":true}}
 }', '§7 vAuto observations; nested names per the design text, to be confirmed against the Appraisal API (D-7)'),
 ('source_observation_31', '{}', 'FAIL CLOSED until the 3.1 field map (groups A–E) is in the repo (D-8): no key is allowed yet'),
 ('deal_version_snapshot', '{}', 'FAIL CLOSED until release_deal defines the allowlisted snapshot columns (later slice)'),
 ('activity_event_detail', '{"role":true}', 'activity_events.before/after: only keys written by functions in this slice');

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. reference data: organizations, source channels, required facts, material fields, settings, shift calendar
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL, name_normalized text GENERATED ALWAYS AS (pg_catalog.lower(pg_catalog.btrim(name))) STORED,
  phone text, city text, state text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE iit.organization_roles (          -- §4: lienholder / business_seller only (no legal-entity role, v0.9)
  org_id uuid NOT NULL REFERENCES iit.organizations(id),
  role text NOT NULL CHECK (role IN ('lienholder','business_seller')),
  PRIMARY KEY (org_id, role)
);
SELECT iit.attach_history('iit.organizations');
SELECT iit.attach_history('iit.organization_roles', 'org_id,role', true);

CREATE TABLE iit.source_channels (             -- §5.2 G9 seeds; route is reference data (D12)
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,                   -- vAuto Source value or manual channel name
  route text NOT NULL CHECK (route IN ('risk_audit','skip_audit','hold_in_data_entry')),
  origin text NOT NULL CHECK (origin IN ('vauto_intake','manual_consignment','manual_exception')),
  active boolean NOT NULL DEFAULT true
);
INSERT INTO iit.source_channels(name, route, origin) VALUES
  ('Consignment',          'skip_audit', 'manual_consignment'),
  ('Brown Fig – Manheim',  'skip_audit', 'manual_exception'),
  ('Brown Fig – OpenLane', 'skip_audit', 'manual_exception'),
  ('Brown Fig – ACV',      'skip_audit', 'manual_exception');
-- vAuto Source values and their routes are NOT seeded: they are the owner's list (docs/migrations/001.md D-4).
SELECT iit.attach_history('iit.source_channels');

CREATE TABLE iit.required_fact_rules (         -- §5.7 G13: which intake facts are required at release, by origin
  origin text NOT NULL CHECK (origin IN ('vauto_intake','manual_consignment','manual_exception')),
  fact text NOT NULL CHECK (fact IN ('vin','purchase_price','purchase_price_empty','deposit_stated','title_custody','lien_position',
                                     'seller_party','seller_phone','buyer','closer','source_channel','consignor')),
  required boolean NOT NULL,
  PRIMARY KEY (origin, fact)
);
INSERT INTO iit.required_fact_rules VALUES
  ('vauto_intake','vin',true),('vauto_intake','purchase_price',true),('vauto_intake','deposit_stated',true),
  ('vauto_intake','title_custody',true),('vauto_intake','lien_position',true),('vauto_intake','seller_party',true),
  ('vauto_intake','seller_phone',true),('vauto_intake','buyer',true),('vauto_intake','closer',true),('vauto_intake','source_channel',true),
  ('manual_consignment','vin',true),('manual_consignment','source_channel',true),('manual_consignment','consignor',true),
  ('manual_consignment','buyer',true),('manual_consignment','closer',true),('manual_consignment','purchase_price_empty',true),
  ('manual_consignment','seller_phone',false),('manual_consignment','lien_position',false),('manual_consignment','title_custody',false),
  ('manual_exception','vin',true),('manual_exception','source_channel',true),('manual_exception','purchase_price',true),
  ('manual_exception','buyer',true),('manual_exception','closer',true),
  ('manual_exception','seller_phone',false),('manual_exception','lien_position',false),('manual_exception','title_custody',false);

CREATE TABLE iit.material_fields (             -- §5.5 D21: which fields are material (open a draft + hold)
  field text PRIMARY KEY,
  note text NOT NULL
);
INSERT INTO iit.material_fields VALUES
  ('purchase_price','D21 price'),('vin','D21 VIN'),('seller_parties','D21 owner/sellers'),
  ('lien_position','D21 lien position'),('lienholder','D21 lienholder'),('title_state','D21 title state'),('is_tribal','D21 tribal flag');
-- R2 (Source/channel change after release as material) is a PROPOSAL, not seeded — docs/migrations/001.md D-5.
SELECT iit.attach_history('iit.required_fact_rules', 'origin,fact', true);
SELECT iit.attach_history('iit.material_fields', 'field', true);

CREATE TABLE iit.system_settings (
  key text PRIMARY KEY, value jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO iit.system_settings VALUES ('legacy_31_consignment_total_price', '"1.99"'::jsonb, now());
SELECT iit.attach_history('iit.system_settings', 'key');

CREATE TABLE iit.shift_calendar (              -- T50: staffed working hours (dated); content to be supplied by the owner (D-6)
  day date NOT NULL, start_at timestamptz NOT NULL, end_at timestamptz NOT NULL,
  PRIMARY KEY (day, start_at), CHECK (end_at > start_at)
);
SELECT iit.attach_history('iit.shift_calendar', 'day,start_at', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- 5. vehicles (§5.1)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.vehicles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vin text NOT NULL,
  vin_normalized text GENERATED ALWAYS AS (pg_catalog.upper(pg_catalog.btrim(vin))) STORED,
  year int, make_text text, model_text text, series text, exterior_color text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX vehicles_vin_normalized_uq ON iit.vehicles (vin_normalized);
SELECT iit.attach_history('iit.vehicles');

-- ---------------------------------------------------------------------------------------------------------------------
-- 6. deals (§5.2) and deal_versions (§5.5, v0.3 DDL), amendments, material corrections (§5.7a — the table only)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE SEQUENCE iit.deal_number_seq;           -- U6: own sequence, independent of the 3.1 iD
CREATE TABLE iit.deals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_number bigint NOT NULL UNIQUE DEFAULT nextval('iit.deal_number_seq'),
  vehicle_id uuid NOT NULL REFERENCES iit.vehicles(id),
  origin text NOT NULL CHECK (origin IN ('vauto_intake','manual_consignment','manual_exception')),
  source_channel_id uuid REFERENCES iit.source_channels(id),            -- the confirmed Source (D12); NULL until set
  consumer_route text CHECK (consumer_route IN ('risk_audit','skip_audit','hold_in_data_entry')),
  purchase_price numeric(14,2),                                          -- PR1: nullable, no default; NULL = not applicable
  deposit_amount numeric(14,2) CHECK (deposit_amount IS NULL OR deposit_amount >= 0),   -- 0 allowed; NULL = not provided
  balance numeric(14,2) GENERATED ALWAYS AS (purchase_price - coalesce(deposit_amount, 0)) STORED,       -- PR2: NULL price → NULL
  balance_owed numeric(14,2) GENERATED ALWAYS AS (purchase_price - coalesce(deposit_amount, 0)) STORED,
  buyer_id uuid REFERENCES iit.users(id),                                 -- Sourcing Specialist (T42)
  closer_id uuid REFERENCES iit.users(id),                                -- Acquisition Closer (T42)
  dealer_sold_to text, dealer_auction_name text,                         -- Data Entry (Q4)
  consignment_id uuid,                                                   -- FK added after consignments (below)
  intake_status text NOT NULL DEFAULT 'new' CHECK (intake_status IN ('new','in_review','released','voided')),
  current_version_no int NOT NULL DEFAULT 1,                             -- cache
  audit_status text NOT NULL DEFAULT 'not_required'
    CHECK (audit_status IN ('not_required','pending','approved','changes_required','escalated','cancelled')),  -- cache (§5.7)
  on_hold boolean NOT NULL DEFAULT false,                                -- cache (§5.7a)
  gate_clear boolean NOT NULL DEFAULT false,                             -- cache (§6)
  restarted_from_deal_id uuid REFERENCES iit.deals(id),
  cancelled_at timestamptz, cancellation_reason text,
  final_closure_at timestamptz,                                          -- T52 retention start
  data_entry_due_at timestamptz,                                         -- T50, from shift_calendar
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (restarted_from_deal_id IS NULL OR restarted_from_deal_id <> id),
  CHECK ((cancelled_at IS NULL) = (cancellation_reason IS NULL)),
  CHECK (origin <> 'manual_consignment' OR purchase_price IS NULL)       -- G8: consignments carry no price (release re-checks)
);
SELECT iit.attach_history('iit.deals');

CREATE TABLE iit.deal_versions (               -- v0.3 DDL, unchanged in v0.17
  deal_id uuid NOT NULL REFERENCES iit.deals(id),
  version_no int NOT NULL,
  status text NOT NULL CHECK (status IN ('draft','released','superseded')),
  cause text NOT NULL CHECK (cause IN ('intake','material_correction','resubmission')),
  opened_at timestamptz NOT NULL DEFAULT now(),
  released_by uuid REFERENCES iit.users(id), released_at timestamptz,
  snapshot jsonb,                              -- set once at release (allowlisted, §7); NULL while draft
  history_watermark bigint,                    -- max record_history id covered by the snapshot
  PRIMARY KEY (deal_id, version_no),
  CHECK ((status = 'draft') = (released_at IS NULL)),
  CHECK ((status = 'draft') = (snapshot IS NULL))
);
CREATE UNIQUE INDEX one_draft_per_deal ON iit.deal_versions (deal_id) WHERE status = 'draft';
-- a released version is immutable except draft→released (freeze) and released→superseded
CREATE FUNCTION iit.deal_versions_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF OLD.status = 'superseded' THEN RAISE EXCEPTION 'VERSION_IMMUTABLE: superseded version % of deal % cannot change', OLD.version_no, OLD.deal_id; END IF;
  IF OLD.status = 'released' THEN
    -- the COMPLETE row except status must be unchanged (Codex 001 finding 2): no reassignment of deal_id/version_no, no metadata edits
    IF NOT (NEW.status = 'superseded' AND (pg_catalog.to_jsonb(NEW) - 'status') = (pg_catalog.to_jsonb(OLD) - 'status')) THEN
      RAISE EXCEPTION 'VERSION_IMMUTABLE: released version % of deal % may only change status to superseded', OLD.version_no, OLD.deal_id;
    END IF;
  END IF;
  IF OLD.status = 'draft' AND NEW.status = 'superseded' THEN RAISE EXCEPTION 'VERSION_FLOW: a draft cannot be superseded directly'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER deal_versions_guard BEFORE UPDATE ON iit.deal_versions FOR EACH ROW EXECUTE FUNCTION iit.deal_versions_guard();
CREATE TRIGGER deal_versions_snapshot_policy BEFORE INSERT OR UPDATE ON iit.deal_versions FOR EACH ROW EXECUTE FUNCTION iit.enforce_json('snapshot', 'deal_version_snapshot');
SELECT iit.attach_history('iit.deal_versions', 'deal_id,version_no');   -- composite key; versions are never deleted

CREATE TABLE iit.deal_amendments (             -- §5.5 administrative corrections, append-only
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  deal_id uuid NOT NULL REFERENCES iit.deals(id), version_no int NOT NULL, amendment_no int NOT NULL,
  field text NOT NULL, before jsonb, after jsonb,
  by uuid NOT NULL REFERENCES iit.users(id), reason text NOT NULL, at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (deal_id, version_no, amendment_no),
  FOREIGN KEY (deal_id, version_no) REFERENCES iit.deal_versions(deal_id, version_no)
);
SELECT iit.make_append_only('iit.deal_amendments');

CREATE TABLE iit.material_corrections (        -- §5.7a (table only; the hold machinery arrives with the Risk Audit migration)
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES iit.deals(id),
  from_version_no int NOT NULL, draft_version_no int NOT NULL,
  fields text[] NOT NULL, history_ids bigint[] NOT NULL,
  by uuid NOT NULL REFERENCES iit.users(id), at timestamptz NOT NULL DEFAULT now(),
  CHECK (draft_version_no > from_version_no)
);
SELECT iit.make_append_only('iit.material_corrections');

-- ---------------------------------------------------------------------------------------------------------------------
-- 7. appraisal identity (§5.3) and vAuto observations (immutable, allowlisted — §7)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.external_references (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  system text NOT NULL CHECK (system IN ('vauto_appraisal','vauto_entity','idms_stock','manheim_account','appsheet_31')),
  external_id text NOT NULL,
  account_context text NOT NULL DEFAULT '',
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (system, external_id, account_context)
);
SELECT iit.attach_history('iit.external_references');
CREATE TABLE iit.appraisal_episodes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  appraisal_ref_id uuid NOT NULL REFERENCES iit.external_references(id),
  deal_id uuid NOT NULL REFERENCES iit.deals(id),
  episode_no int NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(), started_by uuid REFERENCES iit.users(id),
  start_basis text NOT NULL CHECK (start_basis IN ('first_completion','data_entry_restart')),
  ended_at timestamptz, end_reason text CHECK (end_reason IN ('cancelled','voided')),
  UNIQUE (appraisal_ref_id, episode_no),
  CHECK ((ended_at IS NULL) = (end_reason IS NULL))
);
CREATE UNIQUE INDEX one_open_episode ON iit.appraisal_episodes (appraisal_ref_id) WHERE ended_at IS NULL;
SELECT iit.attach_history('iit.appraisal_episodes');

CREATE TABLE iit.vauto_observations (          -- append-only evidence of every read whose content changed
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  appraisal_ref_id uuid NOT NULL REFERENCES iit.external_references(id),
  is_completed boolean, last_modified timestamptz, created_at_vauto timestamptz,
  body jsonb NOT NULL,                         -- allowlisted per iit.json_schemas 'vauto_observation' (trigger below)
  body_hash text NOT NULL,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  seq bigint GENERATED ALWAYS AS IDENTITY,     -- insertion order (fetched_at can tie inside one transaction)
  CHECK (NOT (body #> '{lien}' ? 'accountNumber')),       -- belt-and-braces for the two design-named prohibitions
  CHECK (NOT (body #> '{customer}' ? 'address'))
);
SELECT iit.make_append_only('iit.vauto_observations');
CREATE TRIGGER vauto_observations_policy BEFORE INSERT ON iit.vauto_observations FOR EACH ROW EXECUTE FUNCTION iit.enforce_json('body', 'vauto_observation');
-- A new observation is stored only when content changed vs the LATEST observation of that appraisal (design §5.3 "only when
-- payload_hash changes"). A later return to earlier content (A→B→A) IS recorded — lifetime uniqueness was wrong (Codex 001 finding 1).
CREATE FUNCTION iit.vauto_observations_dedupe() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_last text;
BEGIN
  SELECT body_hash INTO v_last FROM iit.vauto_observations WHERE appraisal_ref_id = NEW.appraisal_ref_id ORDER BY seq DESC LIMIT 1;
  IF v_last = NEW.body_hash THEN RAISE EXCEPTION 'UNCHANGED_OBSERVATION: latest observation for % already has hash %', NEW.appraisal_ref_id, NEW.body_hash USING ERRCODE = '23505'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER vauto_observations_dedupe BEFORE INSERT ON iit.vauto_observations FOR EACH ROW EXECUTE FUNCTION iit.vauto_observations_dedupe();

-- ---------------------------------------------------------------------------------------------------------------------
-- 8. source records (§5.4): 3.1 rows the tool knows about, and their immutable read-backs
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.source_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legacy_iid text UNIQUE,                      -- 3.1 iD; NULL until known
  deal_id uuid REFERENCES iit.deals(id),       -- NULL only while link_status = 'unlinked'
  kind text NOT NULL CHECK (kind IN ('initial','reschedule','cutover_legacy')),
  replaces_source_record_id uuid REFERENCES iit.source_records(id),
  created_via text NOT NULL CHECK (created_via IN ('bridge','appsheet_reschedule','manual_fallback','cutover')),
  link_status text NOT NULL DEFAULT 'unlinked' CHECK (link_status IN ('unlinked','linked','conflict')),
  status text NOT NULL DEFAULT 'current' CHECK (status IN ('current','rescheduled','cancelled','duplicate')),   -- G3
  linked_at timestamptz, linked_by uuid REFERENCES iit.users(id),
  appsheet_link_confirmed_at timestamptz,
  current_observation_id uuid,                 -- FK added below
  first_seen_at timestamptz NOT NULL DEFAULT now(), last_seen_at timestamptz,
  CHECK (link_status <> 'linked' OR deal_id IS NOT NULL),
  CHECK (kind <> 'reschedule' OR replaces_source_record_id IS NOT NULL OR link_status <> 'linked'),
  CHECK ((link_status = 'linked') = (linked_at IS NOT NULL))
);
CREATE UNIQUE INDEX one_initial_row_per_deal ON iit.source_records (deal_id) WHERE kind = 'initial';
SELECT iit.attach_history('iit.source_records');
-- NOTE (§5.4): the reschedule link function (seller-set match, G7) is a WORKFLOW function and arrives with the intake
-- migration; created_via = 'bridge' is a vocabulary value only — nothing in this repo creates such rows (bridge deferred).

CREATE TABLE iit.source_observations (         -- one row per 3.1 read-back, allowlisted field-map columns only (§7 groups A–E)
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_record_id uuid NOT NULL REFERENCES iit.source_records(id),
  body jsonb NOT NULL, body_hash text NOT NULL,
  observed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, source_record_id)                -- lets source_records reference "this observation OF this record"
);
SELECT iit.make_append_only('iit.source_observations');
-- body allowlist: 'source_observation_31' is EMPTY until the 3.1 field map is in the repo → every non-empty body is rejected (D-8)
CREATE TRIGGER source_observations_policy BEFORE INSERT ON iit.source_observations FOR EACH ROW EXECUTE FUNCTION iit.enforce_json('body', 'source_observation_31');
-- current_observation_id must belong to THIS source record (Codex 001 finding 5)
ALTER TABLE iit.source_records ADD CONSTRAINT source_records_current_obs_fk
  FOREIGN KEY (current_observation_id, id) REFERENCES iit.source_observations(id, source_record_id);

-- ---------------------------------------------------------------------------------------------------------------------
-- 9. seller, title, lien, consignments, valuations (§5.5 v0.1 + v0.17 refinements)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.seller_parties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  party_type text NOT NULL CHECK (party_type IN ('person','business')),
  first_name text, last_name text,
  business_org_id uuid REFERENCES iit.organizations(id),
  phone text, phone_normalized text GENERATED ALWAYS AS (pg_catalog.regexp_replace(coalesce(phone,''), '[^0-9]', '', 'g')) STORED,
  email text, city text, state text,           -- no street address (D14)
  user_id uuid REFERENCES iit.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((party_type = 'business') = (business_org_id IS NOT NULL))
);
SELECT iit.attach_history('iit.seller_parties');
CREATE TABLE iit.deal_parties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES iit.deals(id),
  party_id uuid NOT NULL REFERENCES iit.seller_parties(id),
  role text NOT NULL CHECK (role IN ('owner','co_owner','business_seller','authorized_signer','title_owner')),
  ordinal int NOT NULL DEFAULT 1,
  UNIQUE (deal_id, role, ordinal)
);
SELECT iit.attach_history('iit.deal_parties');
CREATE TABLE iit.deal_titles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL UNIQUE REFERENCES iit.deals(id),
  custody text CHECK (custody IN ('in_hand','held_lien','no_title','floored')),
  title_state text CHECK (title_state ~ '^[A-Z]{2}$'),
  title_number text, title_miles int, brand text,
  is_tribal boolean NOT NULL DEFAULT false,
  current_location text, received_at timestamptz
);
SELECT iit.attach_history('iit.deal_titles');
CREATE TABLE iit.deal_liens (                  -- no account-number column, by design
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL UNIQUE REFERENCES iit.deals(id),
  position text CHECK (position IN ('none','lien','unknown')),
  lienholder_org_id uuid REFERENCES iit.organizations(id),
  lienholder_name_raw text, lienholder_phone text,
  payoff_amount numeric(14,2), payoff_good_through date, per_diem numeric(14,2),
  source text CHECK (source IN ('vauto','data_entry','parser'))
);
SELECT iit.attach_history('iit.deal_liens');
CREATE TABLE iit.consignments (                -- PR3: consignor amount never feeds purchase_price
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL UNIQUE REFERENCES iit.deals(id),
  consignor_party_id uuid NOT NULL REFERENCES iit.seller_parties(id),
  consignment_amount numeric(14,2),
  notes text,
  UNIQUE (id, deal_id)                         -- lets deals reference "this consignment OF this deal"
);
SELECT iit.attach_history('iit.consignments');
-- deals.consignment_id must be a consignment of THIS deal (Codex 001 finding 6)
ALTER TABLE iit.deals ADD CONSTRAINT deals_consignment_fk FOREIGN KEY (consignment_id, id) REFERENCES iit.consignments(id, deal_id);
CREATE TABLE iit.valuations (                  -- append-only
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_id uuid NOT NULL REFERENCES iit.vehicles(id), deal_id uuid REFERENCES iit.deals(id),
  source text NOT NULL CHECK (source IN ('mmr','vauto')), value numeric(14,2) NOT NULL, miles int,
  as_of timestamptz NOT NULL, recorded_at timestamptz NOT NULL DEFAULT now()
);
SELECT iit.make_append_only('iit.valuations');

-- ---------------------------------------------------------------------------------------------------------------------
-- 10. flags, work items, activity (§5.6 v0.1 vocabulary + v0.17 additions)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.intake_flags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES iit.deals(id),
  code text NOT NULL, detail text,
  blocks_release boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','accepted')),
  opened_at timestamptz NOT NULL DEFAULT now(),
  resolved_by uuid REFERENCES iit.users(id), resolution text, resolved_at timestamptz,
  CHECK ((status = 'open') = (resolved_at IS NULL))
);
SELECT iit.attach_history('iit.intake_flags');

CREATE TABLE iit.work_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN (
    'legacy_match','link_conflict','restart_candidate','cancel_31_update','reaudit_31_correction','cutover_unresolved',
    'same_day_31_correction','lienholder_unmatched','report_rejected',
    -- bridge-related kinds are listed for vocabulary completeness ONLY; nothing in this repo creates them (bridge deferred):
    'id_collision','delivery_failed_manual','vin_validation_rejected','duplicate_row')),
  deal_id uuid REFERENCES iit.deals(id),
  appraisal_ref_id uuid REFERENCES iit.external_references(id),
  source_record_id uuid REFERENCES iit.source_records(id),
  assigned_role text NOT NULL REFERENCES iit.roles(name),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  due_at timestamptz, detail jsonb,
  opened_at timestamptz NOT NULL DEFAULT now(),
  closed_by uuid REFERENCES iit.users(id), closed_at timestamptz, outcome text,
  CHECK ((status = 'open') = (closed_at IS NULL))
);
CREATE UNIQUE INDEX one_open_restart_task_per_appraisal ON iit.work_items (appraisal_ref_id, kind) WHERE status = 'open' AND appraisal_ref_id IS NOT NULL;
SELECT iit.attach_history('iit.work_items');

CREATE TABLE iit.activity_events (             -- append-only (v0.1 §5.11); actor_kind vocabulary aligned with record_history
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  deal_id uuid, entity_type text NOT NULL, entity_id uuid,
  action text NOT NULL, before jsonb, after jsonb,
  actor_id uuid REFERENCES iit.users(id), actor_kind text NOT NULL CHECK (actor_kind IN ('user','worker','system','direct')),
  source text NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((actor_kind = 'direct') = (actor_id IS NULL))
);
CREATE INDEX activity_deal_idx ON iit.activity_events (deal_id, occurred_at);
SELECT iit.make_append_only('iit.activity_events');
CREATE TRIGGER activity_before_policy BEFORE INSERT ON iit.activity_events FOR EACH ROW EXECUTE FUNCTION iit.enforce_json('before', 'activity_event_detail');
CREATE TRIGGER activity_after_policy  BEFORE INSERT ON iit.activity_events FOR EACH ROW EXECUTE FUNCTION iit.enforce_json('after',  'activity_event_detail');

-- ---------------------------------------------------------------------------------------------------------------------
-- 11. staff management functions (§2.2): the only staff-facing entry points in this slice
-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION iit.set_staff_identity(p_base44_user_id text, p_display_name text, p_email text, p_actor_base44_user_id text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; v_user uuid;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'admin');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT user_id INTO v_user FROM iit.staff_identities WHERE base44_user_id = p_base44_user_id;
  IF v_user IS NULL THEN
    INSERT INTO iit.users(display_name, email) VALUES (p_display_name, p_email) RETURNING id INTO v_user;
    INSERT INTO iit.staff_identities(base44_user_id, user_id) VALUES (p_base44_user_id, v_user);
  ELSE
    UPDATE iit.users SET display_name = p_display_name, email = p_email WHERE id = v_user;
    UPDATE iit.staff_identities SET active = true, deactivated_at = NULL WHERE base44_user_id = p_base44_user_id AND NOT active;
  END IF;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_user;
END $$;

CREATE FUNCTION iit.set_staff_role(p_user_id uuid, p_role text, p_grant boolean, p_actor_base44_user_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'admin');
  v_prev := iit.actor_push(v_actor, 'user');
  IF p_grant THEN
    INSERT INTO iit.user_roles(user_id, role, granted_by) VALUES (p_user_id, p_role, v_actor) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM iit.user_roles WHERE user_id = p_user_id AND role = p_role;
  END IF;
  INSERT INTO iit.activity_events(entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES ('user', p_user_id, CASE WHEN p_grant THEN 'role_granted' ELSE 'role_revoked' END, pg_catalog.jsonb_build_object('role', p_role), v_actor, 'user', 'admin_ui');
  PERFORM iit.actor_restore(v_prev);
END $$;

CREATE FUNCTION iit.deactivate_staff(p_base44_user_id text, p_actor_base44_user_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'admin');
  v_prev := iit.actor_push(v_actor, 'user');
  UPDATE iit.staff_identities SET active = false, deactivated_at = now() WHERE base44_user_id = p_base44_user_id AND active;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'STAFF_NOT_ACTIVE: %', p_base44_user_id; END IF;
  INSERT INTO iit.activity_events(entity_type, entity_id, action, actor_id, actor_kind, source)
    SELECT 'user', user_id, 'staff_deactivated', v_actor, 'user', 'admin_ui' FROM iit.staff_identities WHERE base44_user_id = p_base44_user_id;
  PERFORM iit.actor_restore(v_prev);
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 12. grants (§2.2): staff-facing functions → iit_integration only; helpers → none; tables → integration (direct, privileged)
-- ---------------------------------------------------------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA iit FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iit.set_staff_identity(text,text,text,text), iit.set_staff_role(uuid,text,boolean,text), iit.deactivate_staff(text,text) TO iit_integration;
-- iit.require_role / actor_push / actor_restore / triggers: executable by the owner only (called inside definer functions).
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA iit TO iit_integration;   -- mirrors the integration's privileged access (§2.5)
GRANT USAGE ON ALL SEQUENCES IN SCHEMA iit TO iit_integration;
-- tav_worker: nothing in this slice (worker functions arrive with the gate migration).
-- RLS enabled with no policies: anon/authenticated are denied by default (§2.2).
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'iit' AND c.relkind = 'r' LOOP
    EXECUTE pg_catalog.format('ALTER TABLE iit.%I ENABLE ROW LEVEL SECURITY', r.relname);
  END LOOP; END $$;

RESET ROLE;
