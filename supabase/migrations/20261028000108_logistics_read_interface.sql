-- 008_logistics_read_interface.sql — the Logistics read interface (requirements v2.1 + owner amendment A1, docs/migrations/
-- 008-plan.md r4 decisions, owner implementation defaults of 29 Oct 2026 — docs/migrations/008.md). NOT applied.
--
-- Three VOLATILE audited wrappers, EXECUTE to the dedicated NOLOGIN role iit_logistics_reader only:
--   iit.logistics_resolve_31(text[], text), iit.logistics_deal_summaries(text[], text), iit.logistics_vin_candidates(text[], text)
-- Each: credential check (raises 28000) → correlation id (lowercase UUIDv4, else a server UUID) → input validation (returns a
-- fixed denied envelope and keeps its audit row) → STABLE read helper → one audit row → ok envelope. The only write is the
-- identifier-free audit row in iit.logistics_read_audit. No business row, link, identity, work item or history row is
-- created. Migration 007's iit.read_access_audit is not reused: it requires a staff actor and a target id, both of which this
-- integration contract must never store (008.md §3).

-- the PostgREST role for the Logistics credential. As in 001/006: the CREATEROLE executor keeps ADMIN only (no SET, no
-- INHERIT); that ADMIN authorizes the authenticator grant below, which iit_owner could not issue.
SET createrole_self_grant = '';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iit_logistics_reader') THEN CREATE ROLE iit_logistics_reader NOLOGIN NOINHERIT; END IF;
END $$;
RESET createrole_self_grant;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    EXECUTE 'GRANT iit_logistics_reader TO authenticator WITH ADMIN FALSE, INHERIT FALSE, SET TRUE';
  END IF;
END $$;

-- everything on iit objects is the owner's; 007's global default revoke already keeps new functions private, and every
-- function below still carries its own REVOKE ALL … FROM PUBLIC
SET ROLE iit_owner;

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. audit: one row per completed call (ok or denied). Never a VIN, deal id, 3.1 ID, row content or caller text: the jti is
--    the validated credential id, the correlation id is a validated UUIDv4 or a server UUID. Append-only; no privilege for
--    any role but the owner (iit_integration explicitly excluded, plan Q7). Retained indefinitely for Phase 1 (Q8).
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.logistics_read_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  function text NOT NULL CHECK (function IN ('logistics_resolve_31','logistics_deal_summaries','logistics_vin_candidates')),
  credential_jti uuid NOT NULL,
  correlation_id uuid NOT NULL,
  correlation_source text NOT NULL CHECK (correlation_source IN ('caller','server')),
  input_count int NOT NULL CHECK (input_count >= 0),
  invalid_count int NOT NULL DEFAULT 0 CHECK (invalid_count >= 0),          -- VIN positions answered as invalid (008.md D-8)
  outcome text NOT NULL CHECK (outcome IN ('ok','denied')),
  error_code text CHECK (error_code IN ('CORRELATION_MISSING','CORRELATION_INVALID','INPUT_EMPTY','INPUT_NULL_ELEMENT','INPUT_TOO_LARGE','INPUT_INVALID')),
  CHECK ((outcome = 'ok') = (error_code IS NULL)),
  CHECK (outcome = 'ok' OR invalid_count = 0),
  CHECK (correlation_source = 'caller' OR outcome = 'denied'),            -- a server id is only ever issued with a denial
  CHECK (invalid_count <= input_count)
);
SELECT iit.make_append_only('iit.logistics_read_audit');
REVOKE ALL ON TABLE iit.logistics_read_audit FROM PUBLIC;
REVOKE ALL ON SEQUENCE iit.logistics_read_audit_id_seq FROM PUBLIC;
REVOKE ALL ON TABLE iit.logistics_read_audit FROM iit_integration;      -- 001–005's blanket table grants never reach it (Q7)
REVOKE ALL ON SEQUENCE iit.logistics_read_audit_id_seq FROM iit_integration;

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. credential enforcement
-- ---------------------------------------------------------------------------------------------------------------------
-- The Logistics caller is an integration, not a staff actor, and has exactly one legitimate path: PostgREST's SET ROLE from
-- the Logistics credential. Every other originating role — owner SQL, postgres, service paths, the Base44 or Worker roles —
-- is refused. The jti is validated as text before any cast (canonical lowercase UUIDv4; the database checks form and
-- revocation only, it does not and cannot tell a random jti from a reused business UUID — plan §3.1) and compared to the
-- existing text revocation list in canonical form. Nothing from the claims is echoed in an error.
CREATE FUNCTION iit.require_logistics_reader() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE v_origin text; v_claims text; c jsonb; v_jti text;
BEGIN
  v_origin := nullif(pg_catalog.current_setting('role', true), 'none');
  IF v_origin IS DISTINCT FROM 'iit_logistics_reader' THEN RAISE EXCEPTION 'CREDENTIAL_WRONG_ORIGIN' USING ERRCODE = '28000'; END IF;
  v_claims := nullif(pg_catalog.current_setting('request.jwt.claims', true), '');
  IF v_claims IS NULL THEN RAISE EXCEPTION 'CREDENTIAL_NO_CLAIMS' USING ERRCODE = '28000'; END IF;
  BEGIN
    c := v_claims::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'CREDENTIAL_NO_CLAIMS' USING ERRCODE = '28000';
  END;
  IF pg_catalog.jsonb_typeof(c) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'CREDENTIAL_NO_CLAIMS' USING ERRCODE = '28000'; END IF;
  IF pg_catalog.jsonb_typeof(c -> 'role') IS DISTINCT FROM 'string' OR (c ->> 'role') <> 'iit_logistics_reader' THEN
    RAISE EXCEPTION 'CREDENTIAL_ROLE_MISMATCH' USING ERRCODE = '28000';
  END IF;
  IF NOT (c ? 'jti') OR pg_catalog.jsonb_typeof(c -> 'jti') = 'null' OR (c ->> 'jti') = '' THEN
    RAISE EXCEPTION 'CREDENTIAL_NO_JTI' USING ERRCODE = '28000';
  END IF;
  IF pg_catalog.jsonb_typeof(c -> 'jti') <> 'string' THEN RAISE EXCEPTION 'CREDENTIAL_INVALID_JTI' USING ERRCODE = '28000'; END IF;
  v_jti := c ->> 'jti';
  IF pg_catalog.length(v_jti) <> 36 OR v_jti !~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'CREDENTIAL_INVALID_JTI' USING ERRCODE = '28000';
  END IF;
  IF EXISTS (SELECT 1 FROM iit.revoked_credentials r WHERE pg_catalog.lower(pg_catalog.btrim(r.jti)) = v_jti) THEN
    RAISE EXCEPTION 'CREDENTIAL_REVOKED' USING ERRCODE = '28000';
  END IF;
  RETURN v_jti::uuid;
END $$;
REVOKE ALL ON FUNCTION iit.require_logistics_reader() FROM PUBLIC;

-- require_role (006) gains one refusal (requirements §4, plan §3.2): a Logistics credential can never act as a staff actor —
-- not from its own originating role (refused before any claim is read), and not when its claims appear under any other
-- origin. Every other line is unchanged from 006.
CREATE OR REPLACE FUNCTION iit.require_role(p_actor_base44_user_id text, p_required_role text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE v_user uuid; v_origin text; v_claims text; v_role text; v_jti text;
BEGIN
  -- Credential enforcement is keyed to the ORIGINATING role (the SET ROLE in force when the call began — the same signal
  -- record_history.origin_role records), never to what the claims say about themselves (Codex D-2 rev 2 P1):
  --   origin iit_base44  → claims must exist, claims.role must be iit_base44, jti must be present and unrevoked;
  --   origin iit_logistics_reader → refused: the Logistics credential has no staff path (008);
  --   origin anything else (owner SQL, Worker, local tests) with claims naming iit_base44 or iit_logistics_reader → identity
  --   mismatch, refused;
  --   origin anything else without such claims → unchanged claim-less behaviour.
  v_origin := nullif(pg_catalog.current_setting('role', true), 'none');
  IF v_origin = 'iit_logistics_reader' THEN RAISE EXCEPTION 'CREDENTIAL_WRONG_ORIGIN' USING ERRCODE = '28000'; END IF;
  v_claims := nullif(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_role := v_claims::jsonb ->> 'role'; v_jti := v_claims::jsonb ->> 'jti';
  IF v_origin = 'iit_base44' THEN
    IF v_claims IS NULL THEN RAISE EXCEPTION 'CREDENTIAL_NO_CLAIMS' USING ERRCODE = '28000'; END IF;
    IF v_role IS DISTINCT FROM 'iit_base44' THEN RAISE EXCEPTION 'CREDENTIAL_ROLE_MISMATCH' USING ERRCODE = '28000'; END IF;
    IF v_jti IS NULL OR v_jti = '' THEN RAISE EXCEPTION 'CREDENTIAL_NO_JTI' USING ERRCODE = '28000'; END IF;
    IF EXISTS (SELECT 1 FROM iit.revoked_credentials r WHERE r.jti = v_jti) THEN RAISE EXCEPTION 'CREDENTIAL_REVOKED' USING ERRCODE = '28000'; END IF;
  ELSIF v_role IN ('iit_base44', 'iit_logistics_reader') THEN
    RAISE EXCEPTION 'CREDENTIAL_ROLE_MISMATCH' USING ERRCODE = '28000';
  END IF;
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
REVOKE ALL ON FUNCTION iit.require_role(text,text) FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. internal helpers (owner-only)
-- ---------------------------------------------------------------------------------------------------------------------
-- correlation id (owner amendment A1): only a lowercase hyphenated UUIDv4 is accepted and stored as given; anything else gets
-- a server UUID and a denial code. The rejected value is never stored, logged or echoed.
CREATE FUNCTION iit._logistics_correlation(p text, OUT correlation_id uuid, OUT correlation_source text, OUT error_code text)
LANGUAGE plpgsql VOLATILE SET search_path = '' AS $$
BEGIN
  IF p IS NULL OR p = '' THEN
    correlation_id := pg_catalog.gen_random_uuid(); correlation_source := 'server'; error_code := 'CORRELATION_MISSING';
  ELSIF pg_catalog.length(p) <> 36 OR p !~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
    correlation_id := pg_catalog.gen_random_uuid(); correlation_source := 'server'; error_code := 'CORRELATION_INVALID';
  ELSE
    correlation_id := p::uuid; correlation_source := 'caller'; error_code := NULL;
  END IF;
END $$;
REVOKE ALL ON FUNCTION iit._logistics_correlation(text) FROM PUBLIC;

-- whole-call input checks, in a fixed order. The size limit is tested on cardinality() before any element is read
-- (requirements §3.3); then NULL elements; then per-kind form ('31': 1–64 characters after btrim, R1; 'deal': canonical
-- lowercase UUID text, F1). VINs have no whole-call form check: each position is answered valid or invalid (008.md D-8).
CREATE FUNCTION iit._logistics_input_check(p text[], p_max int, p_kind text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p IS NULL OR pg_catalog.cardinality(p) = 0 THEN RETURN 'INPUT_EMPTY'; END IF;
  IF pg_catalog.array_ndims(p) <> 1 THEN RETURN 'INPUT_INVALID'; END IF;
  IF pg_catalog.cardinality(p) > p_max THEN RETURN 'INPUT_TOO_LARGE'; END IF;
  IF pg_catalog.array_position(p, NULL) IS NOT NULL THEN RETURN 'INPUT_NULL_ELEMENT'; END IF;
  IF p_kind = '31' AND EXISTS (SELECT 1 FROM pg_catalog.unnest(p) x WHERE pg_catalog.btrim(x) = '' OR pg_catalog.length(pg_catalog.btrim(x)) > 64) THEN
    RETURN 'INPUT_INVALID';
  END IF;
  IF p_kind = 'deal' AND EXISTS (SELECT 1 FROM pg_catalog.unnest(p) x WHERE x !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
    RETURN 'INPUT_INVALID';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION iit._logistics_input_check(text[],int,text) FROM PUBLIC;

-- the only writer of the audit table
CREATE FUNCTION iit._logistics_audit(p_function text, p_jti uuid, p_correlation uuid, p_source text, p_input_count int, p_invalid_count int, p_outcome text, p_error_code text)
RETURNS void LANGUAGE sql VOLATILE SET search_path = '' AS $$
  INSERT INTO iit.logistics_read_audit(function, credential_jti, correlation_id, correlation_source, input_count, invalid_count, outcome, error_code)
  VALUES (p_function, p_jti, p_correlation, p_source, p_input_count, p_invalid_count, p_outcome, p_error_code) $$;
REVOKE ALL ON FUNCTION iit._logistics_audit(text,uuid,uuid,text,int,int,text,text) FROM PUBLIC;

CREATE FUNCTION iit._logistics_denied(p_error_code text, p_correlation uuid) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT pg_catalog.jsonb_build_object('status', 'denied', 'error_code', p_error_code, 'correlation_id', p_correlation) $$;
REVOKE ALL ON FUNCTION iit._logistics_denied(text,uuid) FROM PUBLIC;

-- read helpers: one row per input position (duplicates included, input order, 1-based ordinality), named keys only
-- 3.1 iD → deal. found only for a LINKED source record with a deal (008.md D-6); an unlinked or conflicting record answers
-- found = false with no deal_id, reporting its link/row status so Logistics can route it to its unresolved-link workflow.
CREATE FUNCTION iit._logistics_resolve_31_rows(p text[]) RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'ordinality', i.n, 'legacy_iid', pg_catalog.btrim(i.v),
           'found', coalesce(s.link_status = 'linked' AND s.deal_id IS NOT NULL, false),
           'deal_id', CASE WHEN s.link_status = 'linked' THEN s.deal_id END,
           'link_status', s.link_status, 'source_status', s.status, 'kind', s.kind) ORDER BY i.n), '[]'::jsonb)
    FROM pg_catalog.unnest(p) WITH ORDINALITY AS i(v, n)
    LEFT JOIN iit.source_records s ON s.legacy_iid = pg_catalog.btrim(i.v) $$;
REVOKE ALL ON FUNCTION iit._logistics_resolve_31_rows(text[]) FROM PUBLIC;

-- deal summaries. No parties, liens, titles, reports, audit detail, deposit or balance; no stock number (no canonical
-- deal/vehicle ↔ idms_stock link exists — plan Q1). Status fields let Logistics apply its own stricter holds (D-7).
CREATE FUNCTION iit._logistics_deal_summary_rows(p uuid[]) RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'ordinality', i.n, 'deal_id', i.v, 'found', d.id IS NOT NULL,
           'deal_number', d.deal_number, 'vin_normalized', v.vin_normalized, 'year', v.year, 'make_text', v.make_text, 'model_text', v.model_text,
           'purchase_price', d.purchase_price, 'dealer_sold_to', d.dealer_sold_to, 'source_channel_name', sc.name,
           'intake_status', d.intake_status, 'cancelled_at', d.cancelled_at, 'final_closure_at', d.final_closure_at, 'on_hold', d.on_hold) ORDER BY i.n), '[]'::jsonb)
    FROM pg_catalog.unnest(p) WITH ORDINALITY AS i(v, n)
    LEFT JOIN iit.deals d ON d.id = i.v
    LEFT JOIN iit.vehicles v ON v.id = d.vehicle_id
    LEFT JOIN iit.source_channels sc ON sc.id = d.source_channel_id $$;
REVOKE ALL ON FUNCTION iit._logistics_deal_summary_rows(uuid[]) FROM PUBLIC;

-- VIN → candidate deals. IIT's normalization (upper(btrim()), as vehicles.vin_normalized); a position whose normalized VIN
-- is empty or longer than 32 characters (R1) is answered valid = false / INPUT_INVALID and not looked up — never guessed.
-- A deal is a live candidate unless IIT marks it cancelled, finally closed or voided (Q3). deal_id, deal_number and the
-- authoritative status are returned only when exactly one live candidate exists.
CREATE FUNCTION iit._logistics_vin_candidate_rows(p text[]) RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  WITH pos AS (
    SELECT i.n, pg_catalog.upper(pg_catalog.btrim(i.v)) AS vin FROM pg_catalog.unnest(p) WITH ORDINALITY AS i(v, n)),
  chk AS (
    SELECT pos.n, pos.vin, (pos.vin <> '' AND pg_catalog.length(pos.vin) <= 32) AS valid FROM pos),
  live AS (
    SELECT c.n, d.id, d.deal_number, d.intake_status, d.audit_status, d.on_hold
      FROM chk c JOIN iit.vehicles v ON v.vin_normalized = c.vin JOIN iit.deals d ON d.vehicle_id = v.id
     WHERE c.valid AND d.cancelled_at IS NULL AND d.final_closure_at IS NULL AND d.intake_status <> 'voided'),
  agg AS (
    SELECT c.n, c.vin, c.valid, count(l.id) AS cnt,
           CASE WHEN count(l.id) = 1 THEN pg_catalog.jsonb_build_object('deal_id', min(l.id::text)::uuid, 'deal_number', min(l.deal_number),
                    'intake_status', min(l.intake_status), 'audit_status', min(l.audit_status), 'on_hold', bool_or(l.on_hold)) END AS one
      FROM chk c LEFT JOIN live l ON l.n = c.n GROUP BY c.n, c.vin, c.valid)
  SELECT coalesce(pg_catalog.jsonb_agg(CASE WHEN a.valid THEN
             pg_catalog.jsonb_build_object('ordinality', a.n, 'vin_normalized', a.vin, 'valid', true, 'error_code', NULL::text,
               'found', a.cnt > 0, 'candidate_count', a.cnt,
               'deal_id', a.one -> 'deal_id', 'deal_number', a.one -> 'deal_number', 'intake_status', a.one -> 'intake_status',
               'audit_status', a.one -> 'audit_status', 'on_hold', a.one -> 'on_hold')
           ELSE
             pg_catalog.jsonb_build_object('ordinality', a.n, 'vin_normalized', NULL::text, 'valid', false, 'error_code', 'INPUT_INVALID',
               'found', false, 'candidate_count', NULL::text, 'deal_id', NULL::text, 'deal_number', NULL::text, 'intake_status', NULL::text,
               'audit_status', NULL::text, 'on_hold', NULL::text) END ORDER BY a.n), '[]'::jsonb)
    FROM agg a $$;
REVOKE ALL ON FUNCTION iit._logistics_vin_candidate_rows(text[]) FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. the three public wrappers (EXECUTE to iit_logistics_reader only)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION iit.logistics_resolve_31(p_legacy_iids text[], p_correlation_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path = '' AS $$
DECLARE v_jti uuid; k record; v_n int; v_code text; v_rows jsonb;
BEGIN
  v_jti := iit.require_logistics_reader();
  SELECT * INTO k FROM iit._logistics_correlation(p_correlation_id);
  v_n := coalesce(pg_catalog.cardinality(p_legacy_iids), 0);
  v_code := coalesce(k.error_code, iit._logistics_input_check(p_legacy_iids, 500, '31'));
  IF v_code IS NOT NULL THEN
    PERFORM iit._logistics_audit('logistics_resolve_31', v_jti, k.correlation_id, k.correlation_source, v_n, 0, 'denied', v_code);
    RETURN iit._logistics_denied(v_code, k.correlation_id);
  END IF;
  v_rows := iit._logistics_resolve_31_rows(p_legacy_iids);
  PERFORM iit._logistics_audit('logistics_resolve_31', v_jti, k.correlation_id, k.correlation_source, v_n, 0, 'ok', NULL::text);
  RETURN pg_catalog.jsonb_build_object('status', 'ok', 'error_code', NULL::text, 'correlation_id', k.correlation_id, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION iit.logistics_resolve_31(text[],text) FROM PUBLIC;

-- p_deal_ids is text[] (plan F1): a malformed id must reach the body to become an audited INPUT_INVALID denial
CREATE FUNCTION iit.logistics_deal_summaries(p_deal_ids text[], p_correlation_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path = '' AS $$
DECLARE v_jti uuid; k record; v_n int; v_code text; v_rows jsonb;
BEGIN
  v_jti := iit.require_logistics_reader();
  SELECT * INTO k FROM iit._logistics_correlation(p_correlation_id);
  v_n := coalesce(pg_catalog.cardinality(p_deal_ids), 0);
  v_code := coalesce(k.error_code, iit._logistics_input_check(p_deal_ids, 500, 'deal'));
  IF v_code IS NOT NULL THEN
    PERFORM iit._logistics_audit('logistics_deal_summaries', v_jti, k.correlation_id, k.correlation_source, v_n, 0, 'denied', v_code);
    RETURN iit._logistics_denied(v_code, k.correlation_id);
  END IF;
  v_rows := iit._logistics_deal_summary_rows(p_deal_ids::uuid[]);
  PERFORM iit._logistics_audit('logistics_deal_summaries', v_jti, k.correlation_id, k.correlation_source, v_n, 0, 'ok', NULL::text);
  RETURN pg_catalog.jsonb_build_object('status', 'ok', 'error_code', NULL::text, 'correlation_id', k.correlation_id, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION iit.logistics_deal_summaries(text[],text) FROM PUBLIC;

CREATE FUNCTION iit.logistics_vin_candidates(p_vins text[], p_correlation_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path = '' AS $$
DECLARE v_jti uuid; k record; v_n int; v_code text; v_rows jsonb; v_invalid int;
BEGIN
  v_jti := iit.require_logistics_reader();
  SELECT * INTO k FROM iit._logistics_correlation(p_correlation_id);
  v_n := coalesce(pg_catalog.cardinality(p_vins), 0);
  v_code := coalesce(k.error_code, iit._logistics_input_check(p_vins, 50, 'vin'));
  IF v_code IS NOT NULL THEN
    PERFORM iit._logistics_audit('logistics_vin_candidates', v_jti, k.correlation_id, k.correlation_source, v_n, 0, 'denied', v_code);
    RETURN iit._logistics_denied(v_code, k.correlation_id);
  END IF;
  v_rows := iit._logistics_vin_candidate_rows(p_vins);
  SELECT count(*) INTO v_invalid FROM pg_catalog.jsonb_array_elements(v_rows) e WHERE NOT (e ->> 'valid')::boolean;
  PERFORM iit._logistics_audit('logistics_vin_candidates', v_jti, k.correlation_id, k.correlation_source, v_n, v_invalid, 'ok', NULL::text);
  RETURN pg_catalog.jsonb_build_object('status', 'ok', 'error_code', NULL::text, 'correlation_id', k.correlation_id, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION iit.logistics_vin_candidates(text[],text) FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5. grants: schema usage and EXECUTE on exactly the three wrappers. No table, sequence, helper, staff, integration or
--    Worker privilege; the explicit revokes record that intent.
-- ---------------------------------------------------------------------------------------------------------------------
GRANT USAGE ON SCHEMA iit TO iit_logistics_reader;
GRANT EXECUTE ON FUNCTION iit.logistics_resolve_31(text[],text), iit.logistics_deal_summaries(text[],text), iit.logistics_vin_candidates(text[],text)
  TO iit_logistics_reader;
REVOKE ALL ON ALL TABLES IN SCHEMA iit FROM iit_logistics_reader;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA iit FROM iit_logistics_reader;
RESET ROLE;
