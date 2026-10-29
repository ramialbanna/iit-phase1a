-- 007_staff_read_rpcs.sql — the read RPCs for the Phase 1 Base44 staff screens (owner decisions 29 Oct 2026,
-- docs/migrations/007-contract-worksheet.md), preceded by the V-2 correction
-- (docs/preflight/phase-c-post-application-verification-2026-10-28.md). NOT applied.
--
-- Ten functions join the iit_base44 manifest (27 → 37): get_my_profile, get_deal, list_work_items, list_audit_queue,
-- list_unknown_outcomes, get_unknown_outcome, get_dashboard_summary, list_staff, list_source_channels, search_deals.
-- Every one starts with the credential + staff checks of require_role (originating role, claims, jti, revocation, active
-- identity, staff role), returns a fixed jsonb envelope built from named keys only (never to_jsonb(row)), and exposes only
-- canonical IIT columns. Nothing here writes business data, creates a work item or changes a write function; the only
-- write is the read-access audit row of get_deal / get_unknown_outcome. No grant to iit_integration (owner B.5).

-- V-2. PostgreSQL's built-in PUBLIC EXECUTE on new functions is a global default; the per-schema form in 001/006
-- (`… IN SCHEMA iit REVOKE ALL ON FUNCTIONS FROM PUBLIC`) cannot remove it and creates no pg_default_acl row. Only the global
-- form below does, so it runs before any 007 function is created. It covers functions created by iit_owner in any schema;
-- every function still carries its own explicit REVOKE ALL … FROM PUBLIC, because functions created by other roles are not
-- covered. Issued as iit_owner: the executor holds iit_owner with SET only (001 §0c).
SET ROLE iit_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE iit_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. read-access audit (owner E): one identifier-minimized row per individual record access. Shared with later
--    get_report-style functions and suitable for 008. It never holds returned data, VINs, seller data, evidence text or
--    search terms. Append-only; no role but the owner holds any privilege on it.
--    Transaction semantics: the row is written in the calling transaction, so a raised exception (credential, role,
--    infrastructure) leaves no row — those failures are recorded at the calling server boundary. Outcomes that must be
--    durable (unknown record, record outside the caller's visibility) return an envelope instead of raising.
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.read_access_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  actor_user_id uuid NOT NULL REFERENCES iit.users(id),
  credential_jti text CHECK (credential_jti IS NULL OR pg_catalog.length(credential_jti) <= 64),   -- iit_base44 calls only
  origin_role text,
  rpc text NOT NULL CHECK (rpc ~ '^[a-z_]{1,63}$'),
  category text NOT NULL CHECK (category IN ('deal_detail','unknown_outcome_detail','report_detail')),
  target_type text NOT NULL CHECK (target_type IN ('deal','deal_version','gated_action','report')),
  target_id uuid NOT NULL,
  target_version int,
  outcome text NOT NULL CHECK (outcome IN ('granted','not_found','denied')),
  correlation_id uuid
);
SELECT iit.make_append_only('iit.read_access_audit');
REVOKE ALL ON TABLE iit.read_access_audit FROM PUBLIC;
REVOKE ALL ON SEQUENCE iit.read_access_audit_id_seq FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. internal helpers (no grant to anyone)
-- ---------------------------------------------------------------------------------------------------------------------
-- The caller's staff roles among p_candidates, through require_role itself, so every credential and identity check is the
-- one 006 enforces. Only ROLE_MISSING (42501) is caught — a credential or identity failure (28000) always propagates, unlike
-- authorize_report_access's catch-all. The '' sentinel forces one full check even when no candidate role is held.
CREATE FUNCTION iit._read_ctx(p_actor text, p_candidates text[], OUT user_id uuid, OUT roles text[])
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE r text; v uuid;
BEGIN
  roles := '{}';
  FOREACH r IN ARRAY p_candidates || ARRAY['']::text[] LOOP
    BEGIN
      v := iit.require_role(p_actor, r);
      IF r <> '' THEN roles := roles || r; END IF;
      user_id := v;
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE 'ROLE_MISSING:%' THEN RAISE; END IF;
    END;
  END LOOP;
  IF user_id IS NULL THEN       -- identity already proven active by require_role (it raises 28000 otherwise)
    SELECT si.user_id INTO user_id FROM iit.staff_identities si WHERE si.base44_user_id = p_actor AND si.active;
  END IF;
END $$;
REVOKE ALL ON FUNCTION iit._read_ctx(text,text[]) FROM PUBLIC;

CREATE FUNCTION iit._require_read(p_actor text, p_allowed text[], p_rpc text, OUT user_id uuid, OUT roles text[])
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  SELECT c.user_id, c.roles INTO user_id, roles FROM iit._read_ctx(p_actor, p_allowed) c;
  IF pg_catalog.cardinality(roles) = 0 THEN RAISE EXCEPTION 'ROLE_MISSING: %', p_rpc USING ERRCODE = '42501'; END IF;
END $$;
REVOKE ALL ON FUNCTION iit._require_read(text,text[],text) FROM PUBLIC;

CREATE FUNCTION iit._page_limit(p_limit int) RETURNS int LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_limit IS NULL THEN RETURN 50; END IF;                                          -- owner D.3: default 50
  IF p_limit < 1 OR p_limit > 100 THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_limit must be between 1 and 100' USING ERRCODE = '22023'; END IF;
  RETURN p_limit;                                                                     -- owner D.5: never silently clamped
END $$;
REVOKE ALL ON FUNCTION iit._page_limit(int) FROM PUBLIC;

-- Cursors are opaque base64 JSON bound to one query shape (`q`); each key is type-checked here, so a forged or foreign
-- cursor is a parameter error (22023), never a cast failure or a different query. A cursor only positions within rows the
-- caller may already see.
CREATE FUNCTION iit._cursor_in(p_cursor text, p_query text, p_types text[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE j jsonb; kt text; k text; t text;
BEGIN
  IF p_cursor IS NULL THEN RETURN NULL; END IF;
  BEGIN
    IF pg_catalog.length(p_cursor) > 512 THEN RAISE EXCEPTION 'long'; END IF;
    j := pg_catalog.convert_from(pg_catalog.decode(p_cursor, 'base64'), 'UTF8')::jsonb;
    IF pg_catalog.jsonb_typeof(j) <> 'object' OR (j ->> 'q') IS DISTINCT FROM p_query THEN RAISE EXCEPTION 'shape'; END IF;
    FOREACH kt IN ARRAY p_types LOOP
      k := pg_catalog.split_part(kt, ':', 1); t := pg_catalog.split_part(kt, ':', 2);
      IF NOT (j ? k) THEN RAISE EXCEPTION 'key'; END IF;
      CASE t
        WHEN 'timestamptz' THEN PERFORM (j ->> k)::timestamptz;
        WHEN 'uuid'        THEN PERFORM (j ->> k)::uuid;
        WHEN 'bigint'      THEN PERFORM (j ->> k)::bigint;
        WHEN 'text'        THEN IF pg_catalog.jsonb_typeof(j -> k) <> 'string' THEN RAISE EXCEPTION 'type'; END IF;
      END CASE;
      IF t <> 'text' AND (j ->> k) IS NULL THEN RAISE EXCEPTION 'null'; END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'INVALID_PARAMETER: p_cursor' USING ERRCODE = '22023';
  END;
  RETURN j;
END $$;
REVOKE ALL ON FUNCTION iit._cursor_in(text,text,text[]) FROM PUBLIC;

CREATE FUNCTION iit._cursor_out(p_query text, p_keys jsonb) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT pg_catalog.translate(pg_catalog.encode(pg_catalog.convert_to((p_keys || pg_catalog.jsonb_build_object('q', p_query))::text, 'UTF8'), 'base64'), E'\n', '') $$;
REVOKE ALL ON FUNCTION iit._cursor_out(text,jsonb) FROM PUBLIC;

CREATE FUNCTION iit._list_envelope(p_items jsonb, p_next text, p_limit int) RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT pg_catalog.jsonb_build_object('status', 'ok', 'items', coalesce(p_items, '[]'::jsonb), 'next_cursor', p_next, 'limit', p_limit, 'as_of', pg_catalog.now()) $$;
REVOKE ALL ON FUNCTION iit._list_envelope(jsonb,text,int) FROM PUBLIC;

CREATE FUNCTION iit._not_found(p_record_type text) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT pg_catalog.jsonb_build_object('status', 'not_found', 'record_type', p_record_type) $$;
REVOKE ALL ON FUNCTION iit._not_found(text) FROM PUBLIC;

CREATE FUNCTION iit._jsonb_pick(p_obj jsonb, p_keys text[]) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_obj IS NULL OR pg_catalog.jsonb_typeof(p_obj) <> 'object' THEN NULL
              ELSE coalesce((SELECT pg_catalog.jsonb_object_agg(e.key, e.value) FROM pg_catalog.jsonb_each(p_obj) e WHERE e.key = ANY (p_keys)), '{}'::jsonb) END $$;
REVOKE ALL ON FUNCTION iit._jsonb_pick(jsonb,text[]) FROM PUBLIC;

-- Authoritative deal state token (owner F): a hash over every canonical row a deal screen displays or a state-dependent
-- write depends on. Any accepted change to the deal or its children changes it; it is computed, never stored, so a future
-- expected-state check in a write function can recompute exactly the same value under the Deal lock.
CREATE FUNCTION iit._deal_state_token(p_deal uuid) RETURNS text LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT 'v1:' || pg_catalog.md5(pg_catalog.jsonb_build_array(
    (SELECT pg_catalog.to_jsonb(d) FROM iit.deals d WHERE d.id = p_deal),
    (SELECT pg_catalog.to_jsonb(v) FROM iit.deals d JOIN iit.vehicles v ON v.id = d.vehicle_id WHERE d.id = p_deal),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(x.version_no, x.status, x.released_at) ORDER BY x.version_no) FROM iit.deal_versions x WHERE x.deal_id = p_deal),
    (SELECT pg_catalog.to_jsonb(t) FROM iit.deal_titles t WHERE t.deal_id = p_deal),
    (SELECT pg_catalog.to_jsonb(l) FROM iit.deal_liens l WHERE l.deal_id = p_deal),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(pg_catalog.to_jsonb(dp), pg_catalog.to_jsonb(sp)) ORDER BY dp.id) FROM iit.deal_parties dp JOIN iit.seller_parties sp ON sp.id = dp.party_id WHERE dp.deal_id = p_deal),
    (SELECT pg_catalog.to_jsonb(c) FROM iit.consignments c WHERE c.deal_id = p_deal),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(f.id, f.status, f.blocks_release) ORDER BY f.id) FROM iit.intake_flags f WHERE f.deal_id = p_deal),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(h.id, h.released_at, h.covering_check_id, h.covers_version_no) ORDER BY h.id) FROM iit.audit_holds h WHERE h.deal_id = p_deal),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(q.version_no, q.requirement_key, q.computed_at) ORDER BY q.version_no, q.requirement_key) FROM iit.deal_report_requirements q WHERE q.deal_id = p_deal),
    (SELECT max(rv.id) FROM iit.report_validations rv WHERE rv.deal_id = p_deal),
    (SELECT max(w.seq) FROM iit.report_waivers w WHERE w.deal_id = p_deal),
    (SELECT count(*) FROM iit.report_waiver_revocations r JOIN iit.report_waivers w ON w.id = r.waiver_id WHERE w.deal_id = p_deal),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(r.id, r.file_recorded_at) ORDER BY r.id) FROM iit.external_vehicle_reports r WHERE r.deal_id = p_deal),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(c.id, c.status) ORDER BY c.id) FROM iit.prequalification_checks c WHERE c.deal_id = p_deal),
    (SELECT max(a.seq) FROM iit.audit_decisions a JOIN iit.prequalification_checks c ON c.id = a.check_id WHERE c.deal_id = p_deal),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(w.id, w.status, w.assigned_role) ORDER BY w.id) FROM iit.work_items w WHERE w.deal_id = p_deal),
    (SELECT count(*) FROM iit.material_corrections m WHERE m.deal_id = p_deal),
    (SELECT max(a.id) FROM iit.deal_amendments a WHERE a.deal_id = p_deal),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(g.id, g.state, g.current_attempt_id) ORDER BY g.id) FROM iit.gated_actions g WHERE g.deal_id = p_deal)
  )::text) $$;
REVOKE ALL ON FUNCTION iit._deal_state_token(uuid) FROM PUBLIC;

CREATE FUNCTION iit._action_state_token(p_action uuid) RETURNS text LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT 'v1:' || pg_catalog.md5(pg_catalog.jsonb_build_array(
    (SELECT pg_catalog.to_jsonb(g) FROM iit.gated_actions g WHERE g.id = p_action),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(a) ORDER BY a.attempt_no) FROM iit.gated_action_attempts a WHERE a.action_id = p_action),
    (SELECT max(e.id) FROM iit.gated_action_events e WHERE e.action_id = p_action),
    (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(w.id, w.status) ORDER BY w.id) FROM iit.work_items w WHERE w.gated_action_id = p_action),
    (SELECT iit._deal_state_token(g.deal_id) FROM iit.gated_actions g WHERE g.id = p_action)
  )::text) $$;
REVOKE ALL ON FUNCTION iit._action_state_token(uuid) FROM PUBLIC;

-- read-access audit writer: jti only for calls that came through the PostgREST credential role; a correlation id only when
-- the request carries a well-formed X-Correlation-Id (PostgREST exposes request headers as request.headers)
CREATE FUNCTION iit._audit_read(p_actor uuid, p_rpc text, p_category text, p_target_type text, p_target uuid, p_version int, p_outcome text) RETURNS void
LANGUAGE plpgsql VOLATILE SET search_path = '' AS $$
DECLARE v_origin text; v_jti text; v_corr text;
BEGIN
  v_origin := nullif(pg_catalog.current_setting('role', true), 'none');
  IF v_origin = 'iit_base44' THEN v_jti := nullif(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb ->> 'jti'; END IF;
  BEGIN
    v_corr := nullif(pg_catalog.current_setting('request.headers', true), '')::jsonb ->> 'x-correlation-id';
  EXCEPTION WHEN OTHERS THEN v_corr := NULL;
  END;
  IF v_corr IS NOT NULL AND v_corr !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN v_corr := NULL; END IF;
  INSERT INTO iit.read_access_audit(actor_user_id, credential_jti, origin_role, rpc, category, target_type, target_id, target_version, outcome, correlation_id)
  VALUES (p_actor, v_jti, v_origin, p_rpc, p_category, p_target_type, p_target, p_version, p_outcome, v_corr::uuid);
END $$;
REVOKE ALL ON FUNCTION iit._audit_read(uuid,text,text,text,uuid,int,text) FROM PUBLIC;

-- Deal visibility (owner B.2/B.3): Data Entry sees every deal; auditors and audit leads see audit-review deals, i.e. deals
-- with at least one Risk Audit attempt. Admin alone sees none.
CREATE FUNCTION iit._deal_visible(p_deal uuid, p_roles text[]) RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM iit.deals d WHERE d.id = p_deal)
     AND ('data_entry' = ANY (p_roles)
          OR (p_roles && ARRAY['auditor','audit_lead'] AND EXISTS (SELECT 1 FROM iit.prequalification_checks c WHERE c.deal_id = p_deal))) $$;
REVOKE ALL ON FUNCTION iit._deal_visible(uuid,text[]) FROM PUBLIC;

CREATE FUNCTION iit._vehicle_summary(p_deal uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT pg_catalog.jsonb_build_object('vin', v.vin, 'year', v.year, 'make_text', v.make_text, 'model_text', v.model_text)
    FROM iit.deals d JOIN iit.vehicles v ON v.id = d.vehicle_id WHERE d.id = p_deal $$;
REVOKE ALL ON FUNCTION iit._vehicle_summary(uuid) FROM PUBLIC;

CREATE FUNCTION iit._staff_ref(p_user uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_user IS NULL THEN NULL ELSE (SELECT pg_catalog.jsonb_build_object('id', u.id, 'display_name', u.display_name) FROM iit.users u WHERE u.id = p_user) END $$;
REVOKE ALL ON FUNCTION iit._staff_ref(uuid) FROM PUBLIC;

-- the release_deal preconditions (004), evaluated read-only. Advisory: release_deal recomputes the report requirements from
-- the current facts before its own check, and is the only authority.
CREATE FUNCTION iit._release_eligibility(p_deal uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE d record; v_draft int; v_missing text[]; b text[] := '{}';
BEGIN
  SELECT * INTO d FROM iit.deals WHERE id = p_deal;
  IF d.cancelled_at IS NOT NULL OR d.intake_status = 'voided' THEN b := b || 'deal_cancelled_or_voided'::text; END IF;
  v_draft := iit.open_draft_version(p_deal);
  IF v_draft IS NULL THEN b := b || 'no_open_draft'::text; END IF;
  v_missing := iit.missing_required_facts(p_deal);
  IF d.source_channel_id IS NULL AND NOT ('source_channel' = ANY (v_missing)) THEN v_missing := v_missing || 'source_channel'::text; END IF;
  IF pg_catalog.cardinality(v_missing) > 0 THEN b := b || 'missing_required_facts'::text; END IF;
  IF d.consumer_route IS NULL THEN b := b || 'consumer_route_not_set'::text; END IF;
  IF EXISTS (SELECT 1 FROM iit.intake_flags f WHERE f.deal_id = p_deal AND f.status = 'open' AND f.blocks_release) THEN b := b || 'open_blocking_flags'::text; END IF;
  IF v_draft IS NOT NULL AND NOT iit.requirements_all_satisfied(p_deal, v_draft) THEN b := b || 'unsatisfied_requirements'::text; END IF;
  RETURN pg_catalog.jsonb_build_object('eligible', pg_catalog.cardinality(b) = 0, 'blocking', pg_catalog.to_jsonb(b),
           'missing_required_facts', pg_catalog.to_jsonb(v_missing), 'authority', 'release_deal');
END $$;
REVOKE ALL ON FUNCTION iit._release_eligibility(uuid) FROM PUBLIC;

-- the record_decision preconditions (002) for an approval, evaluated read-only
CREATE FUNCTION iit._approval_eligibility(p_deal uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE c record; b text[] := '{}';
BEGIN
  SELECT * INTO c FROM iit.prequalification_checks WHERE id = iit.current_attempt(p_deal);
  IF c.id IS NULL THEN b := b || 'no_current_attempt'::text;
  ELSIF c.deal_version_no IS DISTINCT FROM iit.latest_released_version(p_deal) THEN b := b || 'attempt_not_for_latest_release'::text; END IF;
  IF iit.open_material_draft_exists(p_deal) THEN b := b || 'open_material_draft'::text; END IF;
  RETURN pg_catalog.jsonb_build_object('eligible', pg_catalog.cardinality(b) = 0, 'blocking', pg_catalog.to_jsonb(b),
           'open_hold_count', (SELECT count(*) FROM iit.audit_holds h WHERE h.deal_id = p_deal AND h.released_at IS NULL), 'authority', 'record_decision');
END $$;
REVOKE ALL ON FUNCTION iit._approval_eligibility(uuid) FROM PUBLIC;

-- live projection. p_de: Data Entry fields (seller contact, consignment notes); p_au: audit-review fields (decision comments,
-- approval eligibility). A caller holding several roles receives the union. Each collection is capped at 100 rows, newest or
-- oldest first as stated, and named in `truncated` when the cap is hit.
CREATE FUNCTION iit._deal_live(p_deal uuid, p_roles text[]) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE d record; v_de boolean; v_au boolean; v_req_version int; v_trunc text[] := '{}'; v_attempt uuid; r jsonb;
BEGIN
  v_de := 'data_entry' = ANY (p_roles); v_au := p_roles && ARRAY['auditor','audit_lead'];
  SELECT * INTO d FROM iit.deals WHERE id = p_deal;
  v_req_version := coalesce(iit.open_draft_version(p_deal), iit.latest_released_version(p_deal));
  v_attempt := iit.current_attempt(p_deal);
  IF (SELECT count(*) FROM iit.deal_parties WHERE deal_id = p_deal) > 100 THEN v_trunc := v_trunc || 'parties'::text; END IF;
  IF (SELECT count(*) FROM iit.intake_flags WHERE deal_id = p_deal AND status = 'open') > 100 THEN v_trunc := v_trunc || 'flags'::text; END IF;
  IF (SELECT count(*) FROM iit.audit_holds WHERE deal_id = p_deal AND released_at IS NULL) > 100 THEN v_trunc := v_trunc || 'holds'::text; END IF;
  IF (SELECT count(*) FROM iit.deal_report_requirements WHERE deal_id = p_deal AND version_no = v_req_version) > 100 THEN v_trunc := v_trunc || 'requirements'::text; END IF;
  IF (SELECT count(*) FROM iit.work_items WHERE deal_id = p_deal AND assigned_role = ANY (p_roles)) > 100 THEN v_trunc := v_trunc || 'work_items'::text; END IF;
  IF (SELECT count(*) FROM iit.material_corrections WHERE deal_id = p_deal) > 100 THEN v_trunc := v_trunc || 'material_corrections'::text; END IF;
  IF (SELECT count(*) FROM iit.deal_amendments WHERE deal_id = p_deal) > 100 THEN v_trunc := v_trunc || 'amendments'::text; END IF;
  IF (SELECT count(*) FROM iit.activity_events WHERE deal_id = p_deal) > 100 THEN v_trunc := v_trunc || 'activity'::text; END IF;
  IF (SELECT count(*) FROM iit.audit_decisions WHERE check_id = v_attempt) > 100 THEN v_trunc := v_trunc || 'decisions'::text; END IF;
  r := pg_catalog.jsonb_build_object(
    'deal', pg_catalog.jsonb_build_object('id', d.id, 'deal_number', d.deal_number, 'origin', d.origin, 'intake_status', d.intake_status,
              'audit_status', d.audit_status, 'on_hold', d.on_hold, 'gate_clear', d.gate_clear, 'consumer_route', d.consumer_route,
              'source_channel', (SELECT pg_catalog.jsonb_build_object('id', sc.id, 'name', sc.name, 'route', sc.route) FROM iit.source_channels sc WHERE sc.id = d.source_channel_id),
              'data_entry_due_at', d.data_entry_due_at, 'created_at', d.created_at, 'cancelled_at', d.cancelled_at,
              'cancellation_reason', d.cancellation_reason, 'restarted_from_deal_id', d.restarted_from_deal_id,
              'buyer', iit._staff_ref(d.buyer_id), 'closer', iit._staff_ref(d.closer_id),
              'dealer_sold_to', d.dealer_sold_to, 'dealer_auction_name', d.dealer_auction_name),
    'purchase', pg_catalog.jsonb_build_object('purchase_price', d.purchase_price, 'deposit_amount', d.deposit_amount, 'balance', d.balance, 'balance_owed', d.balance_owed),
    'vehicle', (SELECT pg_catalog.jsonb_build_object('vin', v.vin, 'year', v.year, 'make_text', v.make_text, 'model_text', v.model_text,
                  'series', v.series, 'exterior_color', v.exterior_color) FROM iit.vehicles v WHERE v.id = d.vehicle_id),
    'parties', coalesce((SELECT pg_catalog.jsonb_agg(p.j ORDER BY p.role, p.ordinal, p.id) FROM (
                 SELECT dp.role, dp.ordinal, dp.id, pg_catalog.jsonb_build_object('deal_party_id', dp.id, 'party_id', sp.id, 'role', dp.role, 'ordinal', dp.ordinal,
                          'party_type', sp.party_type, 'first_name', sp.first_name, 'last_name', sp.last_name,
                          'business_org', (SELECT pg_catalog.jsonb_build_object('id', o.id, 'name', o.name) FROM iit.organizations o WHERE o.id = sp.business_org_id),
                          'city', sp.city, 'state', sp.state)
                        || CASE WHEN v_de THEN pg_catalog.jsonb_build_object('phone', sp.phone, 'email', sp.email) ELSE '{}'::jsonb END AS j
                   FROM iit.deal_parties dp JOIN iit.seller_parties sp ON sp.id = dp.party_id WHERE dp.deal_id = p_deal
                  ORDER BY dp.role, dp.ordinal, dp.id LIMIT 100) p), '[]'::jsonb),
    'consignment', (SELECT pg_catalog.jsonb_build_object('consignor_party_id', c.consignor_party_id, 'consignment_amount', c.consignment_amount)
                           || CASE WHEN v_de THEN pg_catalog.jsonb_build_object('notes', c.notes) ELSE '{}'::jsonb END
                      FROM iit.consignments c WHERE c.deal_id = p_deal),
    'title', (SELECT pg_catalog.jsonb_build_object('custody', t.custody, 'title_state', t.title_state, 'title_number', t.title_number, 'title_miles', t.title_miles,
                'brand', t.brand, 'is_tribal', t.is_tribal, 'current_location', t.current_location, 'received_at', t.received_at) FROM iit.deal_titles t WHERE t.deal_id = p_deal),
    'lien', (SELECT pg_catalog.jsonb_build_object('position', l.position,
               'lienholder', (SELECT pg_catalog.jsonb_build_object('id', o.id, 'name', o.name) FROM iit.organizations o WHERE o.id = l.lienholder_org_id),
               'lienholder_name_raw', l.lienholder_name_raw, 'lienholder_phone', l.lienholder_phone, 'payoff_amount', l.payoff_amount,
               'payoff_good_through', l.payoff_good_through, 'per_diem', l.per_diem, 'source', l.source) FROM iit.deal_liens l WHERE l.deal_id = p_deal),
    'missing_required_facts', pg_catalog.to_jsonb(iit.missing_required_facts(p_deal)),
    'requirements', pg_catalog.jsonb_build_object('version_no', v_req_version, 'items', coalesce((SELECT pg_catalog.jsonb_agg(q.j ORDER BY q.k) FROM (
                 SELECT rq.requirement_key AS k, pg_catalog.jsonb_build_object('requirement_key', rq.requirement_key, 'report_type', rq.report_type,
                          'subject_type', rq.subject_type, 'freshness_baseline', rq.freshness_baseline,
                          'satisfied', iit.requirement_satisfied(p_deal, rq.version_no, rq.requirement_key)) AS j
                   FROM iit.deal_report_requirements rq WHERE rq.deal_id = p_deal AND rq.version_no = v_req_version
                  ORDER BY rq.requirement_key LIMIT 100) q), '[]'::jsonb)),
    'flags', coalesce((SELECT pg_catalog.jsonb_agg(f.j ORDER BY f.o, f.id) FROM (
                 SELECT fl.opened_at AS o, fl.id, pg_catalog.jsonb_build_object('id', fl.id, 'code', fl.code, 'blocks_release', fl.blocks_release, 'opened_at', fl.opened_at) AS j
                   FROM iit.intake_flags fl WHERE fl.deal_id = p_deal AND fl.status = 'open' ORDER BY fl.opened_at, fl.id LIMIT 100) f), '[]'::jsonb),
    'holds', coalesce((SELECT pg_catalog.jsonb_agg(h.j ORDER BY h.o, h.id) FROM (
                 SELECT ah.opened_at AS o, ah.id, pg_catalog.jsonb_build_object('id', ah.id, 'cause', ah.cause, 'opened_at', ah.opened_at,
                          'covers_version_no', ah.covers_version_no, 'covering_check_id', ah.covering_check_id) AS j
                   FROM iit.audit_holds ah WHERE ah.deal_id = p_deal AND ah.released_at IS NULL ORDER BY ah.opened_at, ah.id LIMIT 100) h), '[]'::jsonb),
    'work_items', coalesce((SELECT pg_catalog.jsonb_agg(w.j ORDER BY w.o, w.id) FROM (
                 SELECT wi.opened_at AS o, wi.id, pg_catalog.jsonb_build_object('id', wi.id, 'kind', wi.kind, 'assigned_role', wi.assigned_role, 'status', wi.status,
                          'due_at', wi.due_at, 'opened_at', wi.opened_at, 'closed_at', wi.closed_at, 'outcome', wi.outcome, 'gated_action_id', wi.gated_action_id) AS j
                   FROM iit.work_items wi WHERE wi.deal_id = p_deal AND wi.assigned_role = ANY (p_roles) ORDER BY wi.opened_at, wi.id LIMIT 100) w), '[]'::jsonb),
    'corrections', pg_catalog.jsonb_build_object(
       'material', coalesce((SELECT pg_catalog.jsonb_agg(m.j ORDER BY m.o, m.id) FROM (
                 SELECT mc.at AS o, mc.id, pg_catalog.jsonb_build_object('id', mc.id, 'from_version_no', mc.from_version_no, 'draft_version_no', mc.draft_version_no,
                          'fields', pg_catalog.to_jsonb(mc.fields), 'by', iit._staff_ref(mc.by), 'at', mc.at) AS j
                   FROM iit.material_corrections mc WHERE mc.deal_id = p_deal ORDER BY mc.at, mc.id LIMIT 100) m), '[]'::jsonb),
       'amendments', coalesce((SELECT pg_catalog.jsonb_agg(a.j ORDER BY a.id) FROM (
                 SELECT am.id, pg_catalog.jsonb_build_object('version_no', am.version_no, 'amendment_no', am.amendment_no, 'field', am.field,
                          'reason', am.reason, 'by', iit._staff_ref(am.by), 'at', am.at) AS j
                   FROM iit.deal_amendments am WHERE am.deal_id = p_deal ORDER BY am.id LIMIT 100) a), '[]'::jsonb)),
    'activity', coalesce((SELECT pg_catalog.jsonb_agg(e.j ORDER BY e.o DESC, e.id DESC) FROM (
                 SELECT ae.occurred_at AS o, ae.id, pg_catalog.jsonb_build_object('id', ae.id, 'occurred_at', ae.occurred_at, 'entity_type', ae.entity_type,
                          'action', ae.action, 'actor', iit._staff_ref(ae.actor_id), 'actor_kind', ae.actor_kind, 'source', ae.source) AS j
                   FROM iit.activity_events ae WHERE ae.deal_id = p_deal ORDER BY ae.occurred_at DESC, ae.id DESC LIMIT 100) e), '[]'::jsonb),
    'current_attempt', (SELECT pg_catalog.jsonb_build_object('check_id', c.id, 'deal_version_no', c.deal_version_no, 'status', c.status, 'opened_at', c.opened_at,
                   'reopened_from_check_id', c.reopened_from_check_id,
                   'decisions', coalesce((SELECT pg_catalog.jsonb_agg(x.j ORDER BY x.seq) FROM (
                        SELECT ad.seq, pg_catalog.jsonb_build_object('decision', ad.decision, 'decided_at', ad.decided_at, 'decided_by', iit._staff_ref(ad.decided_by))
                               || CASE WHEN v_au THEN pg_catalog.jsonb_build_object('comments', ad.comments) ELSE '{}'::jsonb END AS j
                          FROM iit.audit_decisions ad WHERE ad.check_id = c.id ORDER BY ad.seq LIMIT 100) x), '[]'::jsonb))
                  FROM iit.prequalification_checks c WHERE c.id = v_attempt),
    'version', pg_catalog.jsonb_build_object('current_version_no', d.current_version_no, 'latest_released_version_no', iit.latest_released_version(p_deal),
                 'open_draft_version_no', iit.open_draft_version(p_deal),
                 'draft_cause', (SELECT x.cause FROM iit.deal_versions x WHERE x.deal_id = p_deal AND x.status = 'draft')),
    'truncated', pg_catalog.to_jsonb(v_trunc));
  IF v_de THEN r := r || pg_catalog.jsonb_build_object('release_eligibility', iit._release_eligibility(p_deal)); END IF;
  IF v_au THEN r := r || pg_catalog.jsonb_build_object('approval_eligibility', iit._approval_eligibility(p_deal)); END IF;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION iit._deal_live(uuid,text[]) FROM PUBLIC;

-- frozen projection: the release snapshot of one version, re-projected through the same allowlist (seller contact only for
-- Data Entry), plus that version's requirement satisfaction as it stands now
CREATE FUNCTION iit._deal_frozen(p_deal uuid, p_version int, p_roles text[]) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE v record; s jsonb; v_de boolean; v_party_keys text[];
BEGIN
  v_de := 'data_entry' = ANY (p_roles);
  SELECT * INTO v FROM iit.deal_versions WHERE deal_id = p_deal AND version_no = p_version;
  s := v.snapshot;
  v_party_keys := ARRAY['id','party_type','first_name','last_name','business_org_id','city','state'] || CASE WHEN v_de THEN ARRAY['phone','email'] ELSE '{}'::text[] END;
  RETURN pg_catalog.jsonb_build_object(
    'version', pg_catalog.jsonb_build_object('version_no', v.version_no, 'status', v.status, 'cause', v.cause, 'opened_at', v.opened_at,
                 'released_at', v.released_at, 'released_by', iit._staff_ref(v.released_by)),
    'snapshot', pg_catalog.jsonb_build_object(
       'deal', iit._jsonb_pick(s -> 'deal', ARRAY['id','deal_number','origin','source_channel_id','consumer_route','purchase_price','deposit_amount','balance',
                                                  'balance_owed','buyer_id','closer_id','dealer_sold_to','dealer_auction_name','restarted_from_deal_id']),
       'vehicle', iit._jsonb_pick(s -> 'vehicle', ARRAY['vin','year','make_text','model_text','series','exterior_color']),
       'title', iit._jsonb_pick(s -> 'title', ARRAY['custody','title_state','title_number','title_miles','brand','is_tribal']),
       'lien', iit._jsonb_pick(s -> 'lien', ARRAY['position','lienholder_org_id','lienholder_name_raw','lienholder_phone','payoff_amount','payoff_good_through','per_diem']),
       'parties', coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('link', iit._jsonb_pick(e.value -> 'link', ARRAY['id','party_id','role','ordinal']),
                                   'party', iit._jsonb_pick(e.value -> 'party', v_party_keys)) ORDER BY e.ordinality)
                              FROM pg_catalog.jsonb_array_elements(CASE WHEN pg_catalog.jsonb_typeof(s -> 'parties') = 'array' THEN s -> 'parties' ELSE '[]'::jsonb END) WITH ORDINALITY e), '[]'::jsonb),
       'consignment', iit._jsonb_pick(s -> 'consignment', ARRAY['consignor_party_id','consignment_amount']),
       'requirements', coalesce((SELECT pg_catalog.jsonb_agg(iit._jsonb_pick(e.value, ARRAY['requirement_key','report_type','subject_type']) ORDER BY e.ordinality)
                              FROM pg_catalog.jsonb_array_elements(CASE WHEN pg_catalog.jsonb_typeof(s -> 'requirements') = 'array' THEN s -> 'requirements' ELSE '[]'::jsonb END) WITH ORDINALITY e), '[]'::jsonb)),
    'requirement_satisfaction', coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('requirement_key', rq.requirement_key,
                                   'satisfied', iit.requirement_satisfied(p_deal, rq.version_no, rq.requirement_key)) ORDER BY rq.requirement_key)
                              FROM iit.deal_report_requirements rq WHERE rq.deal_id = p_deal AND rq.version_no = p_version), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION iit._deal_frozen(uuid,int,text[]) FROM PUBLIC;

-- the work-item kinds 005 allows (work_items_kind_check); 007_staff_read_rpcs_test asserts this list equals the constraint
CREATE FUNCTION iit._work_item_kinds() RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['legacy_match','link_conflict','restart_candidate','cancel_31_update','reaudit_31_correction','cutover_unresolved',
               'same_day_31_correction','lienholder_unmatched','report_rejected',
               'gate_unfinished_action','gate_outcome_unknown','gate_completed_after_hold','gate_conflicting_reports',
               'id_collision','delivery_failed_manual','vin_validation_rejected','duplicate_row']::text[] $$;
REVOKE ALL ON FUNCTION iit._work_item_kinds() FROM PUBLIC;

-- the derived consignment setup/review queue (owner Q1): every open manual-consignment deal, complete or not
CREATE FUNCTION iit._consignment_setup_deals() RETURNS SETOF uuid LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT d.id FROM iit.deals d
   WHERE d.origin = 'manual_consignment' AND d.intake_status IN ('new','in_review') AND d.cancelled_at IS NULL $$;
REVOKE ALL ON FUNCTION iit._consignment_setup_deals() FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. the ten read RPCs (iit_base44 manifest additions). No SQL DEFAULTs: callers pass every named parameter; NULL for
--    p_limit means 50, NULL for p_cursor means the first page.
-- ---------------------------------------------------------------------------------------------------------------------

-- 3.1 identity: the caller's IIT staff identity and active roles. No role parameter; the roles come from user_roles.
CREATE FUNCTION iit.get_my_profile(p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE c record;
BEGIN
  SELECT * INTO c FROM iit._read_ctx(p_actor_base44_user_id, ARRAY(SELECT r.name FROM iit.roles r ORDER BY r.name));
  RETURN pg_catalog.jsonb_build_object('status', 'ok', 'record_type', 'staff_profile', 'data',
           pg_catalog.jsonb_build_object('user_id', c.user_id, 'display_name', (SELECT u.display_name FROM iit.users u WHERE u.id = c.user_id),
             'roles', pg_catalog.to_jsonb(c.roles)));
END $$;
REVOKE ALL ON FUNCTION iit.get_my_profile(text) FROM PUBLIC;

-- 3.2 deal detail: live (p_version NULL) or one frozen released/superseded version. Audited (owner E).
CREATE FUNCTION iit.get_deal(p_deal uuid, p_version int, p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path = '' AS $$
DECLARE c record; v_view text;
BEGIN
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, ARRAY['data_entry','auditor','audit_lead'], 'get_deal');
  IF p_deal IS NULL THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_deal' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM iit._audit_read(c.user_id, 'get_deal', 'deal_detail', 'deal', p_deal, p_version, 'not_found');
    RETURN iit._not_found('deal');
  END IF;
  IF NOT iit._deal_visible(p_deal, c.roles) THEN                  -- same envelope as an unknown id: existence is not disclosed
    PERFORM iit._audit_read(c.user_id, 'get_deal', 'deal_detail', 'deal', p_deal, p_version, 'denied');
    RETURN iit._not_found('deal');
  END IF;
  IF p_version IS NOT NULL AND NOT EXISTS (SELECT 1 FROM iit.deal_versions WHERE deal_id = p_deal AND version_no = p_version AND status IN ('released','superseded')) THEN
    PERFORM iit._audit_read(c.user_id, 'get_deal', 'deal_detail', 'deal_version', p_deal, p_version, 'not_found');
    RETURN iit._not_found('deal_version');
  END IF;
  v_view := CASE WHEN p_version IS NULL THEN 'live' ELSE 'frozen' END;
  PERFORM iit._audit_read(c.user_id, 'get_deal', 'deal_detail', CASE WHEN p_version IS NULL THEN 'deal' ELSE 'deal_version' END, p_deal, p_version, 'granted');
  RETURN pg_catalog.jsonb_build_object('status', 'ok', 'record_type', 'deal', 'view', v_view,
           'projections', pg_catalog.to_jsonb(ARRAY(SELECT x FROM pg_catalog.unnest(ARRAY[
                CASE WHEN 'data_entry' = ANY (c.roles) THEN 'data_entry' END,
                CASE WHEN c.roles && ARRAY['auditor','audit_lead'] THEN 'audit_review' END]) x WHERE x IS NOT NULL)),
           'data', CASE WHEN p_version IS NULL THEN iit._deal_live(p_deal, c.roles) ELSE iit._deal_frozen(p_deal, p_version, c.roles) END,
           'state_token', iit._deal_state_token(p_deal));
END $$;
REVOKE ALL ON FUNCTION iit.get_deal(uuid,int,text) FROM PUBLIC;

-- 3.3 work queue: stored work items assigned to any role the caller holds, or (p_kind = 'consignment_setup', Data Entry)
-- the derived consignment rows. p_status: 'open' (default) | 'closed'; derived rows are 'open' only.
CREATE FUNCTION iit.list_work_items(p_kind text, p_status text, p_limit int, p_cursor text, p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE c record; v_lim int; v_status text; q text; cur jsonb; v_items jsonb; v_n int; v_last record; v_next text;
BEGIN
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, ARRAY['admin','audit_lead','auditor','data_entry'], 'list_work_items');
  v_lim := iit._page_limit(p_limit);
  v_status := coalesce(p_status, 'open');
  IF v_status NOT IN ('open','closed') THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_status' USING ERRCODE = '22023'; END IF;
  IF p_kind = 'consignment_setup' THEN
    IF NOT ('data_entry' = ANY (c.roles)) THEN RAISE EXCEPTION 'ROLE_MISSING: list_work_items consignment_setup' USING ERRCODE = '42501'; END IF;
    IF v_status <> 'open' THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_status (consignment_setup rows are open only)' USING ERRCODE = '22023'; END IF;
    q := 'list_work_items|consignment_setup';
    cur := iit._cursor_in(p_cursor, q, ARRAY['n:bigint']);
    WITH page AS (
      SELECT d.id, d.deal_number, d.intake_status, row_number() OVER (ORDER BY d.deal_number) AS rn
        FROM iit.deals d WHERE d.id IN (SELECT iit._consignment_setup_deals())
         AND (cur IS NULL OR d.deal_number > (cur ->> 'n')::bigint)
       ORDER BY d.deal_number LIMIT v_lim + 1)
    SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('record_type', 'derived_deal', 'deal_id', p.id, 'deal_number', p.deal_number,
             'vehicle', iit._vehicle_summary(p.id),
             'consignor_present', EXISTS (SELECT 1 FROM iit.consignments k WHERE k.deal_id = p.id AND k.consignor_party_id IS NOT NULL),
             'consignment_amount', (SELECT k.consignment_amount FROM iit.consignments k WHERE k.deal_id = p.id),
             'missing_required_facts', pg_catalog.to_jsonb(iit.missing_required_facts(p.id)),
             'intake_status', p.intake_status, 'state_token', iit._deal_state_token(p.id)) ORDER BY p.rn) FILTER (WHERE p.rn <= v_lim),
           count(*)
      INTO v_items, v_n FROM page p;
    IF v_n > v_lim THEN
      v_next := iit._cursor_out(q, pg_catalog.jsonb_build_object('n', (v_items -> (v_lim - 1)) -> 'deal_number'));
    END IF;
    RETURN iit._list_envelope(v_items, v_next, v_lim);
  END IF;
  IF p_kind IS NOT NULL AND NOT (p_kind = ANY (iit._work_item_kinds())) THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_kind' USING ERRCODE = '22023'; END IF;
  q := 'list_work_items|' || v_status || '|' || coalesce(p_kind, '*');
  cur := iit._cursor_in(p_cursor, q, ARRAY['t:timestamptz','id:uuid']);
  WITH page AS (
    SELECT w.*, row_number() OVER (ORDER BY CASE WHEN v_status = 'open' THEN w.opened_at END, CASE WHEN v_status = 'open' THEN w.id END,
                                            CASE WHEN v_status = 'closed' THEN w.closed_at END DESC, CASE WHEN v_status = 'closed' THEN w.id END DESC) AS rn
      FROM iit.work_items w
     WHERE w.assigned_role = ANY (c.roles) AND w.status = v_status AND (p_kind IS NULL OR w.kind = p_kind)
       AND (cur IS NULL
            OR (v_status = 'open'   AND (w.opened_at, w.id) > ((cur ->> 't')::timestamptz, (cur ->> 'id')::uuid))
            OR (v_status = 'closed' AND (w.closed_at, w.id) < ((cur ->> 't')::timestamptz, (cur ->> 'id')::uuid)))
     ORDER BY CASE WHEN v_status = 'open' THEN w.opened_at END, CASE WHEN v_status = 'open' THEN w.id END,
              CASE WHEN v_status = 'closed' THEN w.closed_at END DESC, CASE WHEN v_status = 'closed' THEN w.id END DESC
     LIMIT v_lim + 1)
  SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('record_type', 'work_item', 'id', p.id, 'kind', p.kind, 'assigned_role', p.assigned_role,
           'status', p.status, 'due_at', p.due_at, 'overdue', p.status = 'open' AND p.due_at < pg_catalog.now(), 'opened_at', p.opened_at,
           'closed_at', p.closed_at, 'outcome', p.outcome, 'gated_action_id', p.gated_action_id,
           'deal', CASE WHEN p.deal_id IS NULL THEN NULL ELSE (SELECT pg_catalog.jsonb_build_object('id', d.id, 'deal_number', d.deal_number) || iit._vehicle_summary(d.id) FROM iit.deals d WHERE d.id = p.deal_id) END)
           ORDER BY p.rn) FILTER (WHERE p.rn <= v_lim),
         count(*)
    INTO v_items, v_n FROM page p;
  IF v_n > v_lim THEN
    v_next := iit._cursor_out(q, pg_catalog.jsonb_build_object(
                'id', (v_items -> (v_lim - 1)) ->> 'id',
                't', CASE WHEN v_status = 'open' THEN (v_items -> (v_lim - 1)) ->> 'opened_at' ELSE (v_items -> (v_lim - 1)) ->> 'closed_at' END));
  END IF;
  RETURN iit._list_envelope(v_items, v_next, v_lim);
END $$;
REVOKE ALL ON FUNCTION iit.list_work_items(text,text,int,text,text) FROM PUBLIC;

-- 3.4 Risk Audit queue: current open attempts for auditors and audit leads; escalated attempts (current attempt whose latest
-- decision is 'escalated') for audit leads only. No assignment exists in IIT, so every permitted caller sees every row.
-- p_queue: NULL (everything the caller may see) | 'open' | 'escalated'.
CREATE FUNCTION iit.list_audit_queue(p_queue text, p_limit int, p_cursor text, p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE c record; v_lim int; v_lead boolean; v_open boolean; v_esc boolean; q text; cur jsonb; v_items jsonb; v_n int; v_next text;
BEGIN
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, ARRAY['audit_lead','auditor'], 'list_audit_queue');
  v_lim := iit._page_limit(p_limit);
  v_lead := 'audit_lead' = ANY (c.roles);
  IF p_queue IS NOT NULL AND p_queue NOT IN ('open','escalated') THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_queue' USING ERRCODE = '22023'; END IF;
  IF p_queue = 'escalated' AND NOT v_lead THEN RAISE EXCEPTION 'ROLE_MISSING: list_audit_queue escalated' USING ERRCODE = '42501'; END IF;
  v_open := p_queue IS NULL OR p_queue = 'open';
  v_esc := v_lead AND (p_queue IS NULL OR p_queue = 'escalated');
  q := 'list_audit_queue|' || coalesce(p_queue, '*') || '|' || v_lead::text;
  cur := iit._cursor_in(p_cursor, q, ARRAY['t:timestamptz','id:uuid']);
  WITH base AS (
    SELECT k.*, (SELECT ad.decision FROM iit.audit_decisions ad WHERE ad.check_id = k.id ORDER BY ad.seq DESC LIMIT 1) AS last_decision,
           (SELECT ad.decided_at FROM iit.audit_decisions ad WHERE ad.check_id = k.id ORDER BY ad.seq DESC LIMIT 1) AS last_decided_at
      FROM iit.prequalification_checks k WHERE k.status <> 'superseded'),
  page AS (
    SELECT b.*, CASE WHEN b.status = 'open' THEN 'open' ELSE 'escalated' END AS queue_reason,
           row_number() OVER (ORDER BY b.opened_at, b.id) AS rn
      FROM base b
     WHERE ((v_open AND b.status = 'open') OR (v_esc AND b.status = 'decided' AND b.last_decision = 'escalated'))
       AND (cur IS NULL OR (b.opened_at, b.id) > ((cur ->> 't')::timestamptz, (cur ->> 'id')::uuid))
     ORDER BY b.opened_at, b.id LIMIT v_lim + 1)
  SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('record_type', 'audit_attempt', 'check_id', p.id, 'queue_reason', p.queue_reason,
           'deal', (SELECT pg_catalog.jsonb_build_object('id', d.id, 'deal_number', d.deal_number, 'on_hold', d.on_hold) || iit._vehicle_summary(d.id) FROM iit.deals d WHERE d.id = p.deal_id),
           'deal_version_no', p.deal_version_no, 'opened_at', p.opened_at, 'reopened_from_check_id', p.reopened_from_check_id,
           'latest_decision', CASE WHEN p.last_decision IS NULL THEN NULL ELSE pg_catalog.jsonb_build_object('decision', p.last_decision, 'decided_at', p.last_decided_at) END,
           'open_hold_count', (SELECT count(*) FROM iit.audit_holds h WHERE h.deal_id = p.deal_id AND h.released_at IS NULL),
           'material_draft_open', iit.open_material_draft_exists(p.deal_id),
           'requirements_all_satisfied', iit.requirements_all_satisfied(p.deal_id, p.deal_version_no)) ORDER BY p.rn) FILTER (WHERE p.rn <= v_lim),
         count(*)
    INTO v_items, v_n FROM page p;
  IF v_n > v_lim THEN
    v_next := iit._cursor_out(q, pg_catalog.jsonb_build_object('t', (v_items -> (v_lim - 1)) ->> 'opened_at', 'id', (v_items -> (v_lim - 1)) ->> 'check_id'));
  END IF;
  RETURN iit._list_envelope(v_items, v_next, v_lim);
END $$;
REVOKE ALL ON FUNCTION iit.list_audit_queue(text,int,text,text) FROM PUBLIC;

-- 3.5 gate actions awaiting explicit manual resolution (state outcome_unknown), oldest first. Data Entry only
-- (resolve_unknown_outcome's role). No action key, no evidence, no triggering text.
CREATE FUNCTION iit.list_unknown_outcomes(p_limit int, p_cursor text, p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE c record; v_lim int; q text := 'list_unknown_outcomes'; cur jsonb; v_items jsonb; v_n int; v_next text;
BEGIN
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, ARRAY['data_entry'], 'list_unknown_outcomes');
  v_lim := iit._page_limit(p_limit);
  cur := iit._cursor_in(p_cursor, q, ARRAY['t:timestamptz','id:uuid']);
  WITH page AS (
    SELECT g.*, row_number() OVER (ORDER BY g.created_at, g.id) AS rn FROM iit.gated_actions g
     WHERE g.state = 'outcome_unknown' AND (cur IS NULL OR (g.created_at, g.id) > ((cur ->> 't')::timestamptz, (cur ->> 'id')::uuid))
     ORDER BY g.created_at, g.id LIMIT v_lim + 1)
  SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('record_type', 'gated_action', 'id', p.id, 'source_31_id', p.iid,
           'deal', CASE WHEN p.deal_id IS NULL THEN NULL ELSE (SELECT pg_catalog.jsonb_build_object('id', d.id, 'deal_number', d.deal_number) FROM iit.deals d WHERE d.id = p.deal_id) END,
           'action', p.action, 'caller_integration', p.caller_integration, 'state', p.state, 'authorized_at', p.authorized_at,
           'deal_version', p.deal_version, 'created_at', p.created_at,
           'has_conflicting_reports', EXISTS (SELECT 1 FROM iit.gated_action_events e WHERE e.action_id = p.id AND e.event = 'conflict'),
           'open_work_item_id', (SELECT w.id FROM iit.work_items w WHERE w.gated_action_id = p.id AND w.status = 'open' ORDER BY w.opened_at, w.id LIMIT 1))
           ORDER BY p.rn) FILTER (WHERE p.rn <= v_lim),
         count(*)
    INTO v_items, v_n FROM page p;
  IF v_n > v_lim THEN
    v_next := iit._cursor_out(q, pg_catalog.jsonb_build_object('t', (v_items -> (v_lim - 1)) ->> 'created_at', 'id', (v_items -> (v_lim - 1)) ->> 'id'));
  END IF;
  RETURN iit._list_envelope(v_items, v_next, v_lim);
END $$;
REVOKE ALL ON FUNCTION iit.list_unknown_outcomes(int,text,text) FROM PUBLIC;

-- 3.6 one gate action for manual resolution: an action that is, or was, an unknown outcome (state outcome_unknown, or a
-- 'resolved' event). Evidence is the 005 allowlist minus its free-text `note`; events carry allowlisted detail keys only.
-- Audited (owner E).
CREATE FUNCTION iit.get_unknown_outcome(p_action uuid, p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path = '' AS $$
DECLARE c record; g record;
BEGIN
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, ARRAY['data_entry'], 'get_unknown_outcome');
  IF p_action IS NULL THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_action' USING ERRCODE = '22023'; END IF;
  SELECT * INTO g FROM iit.gated_actions WHERE id = p_action;
  IF g.id IS NULL OR NOT (g.state = 'outcome_unknown' OR EXISTS (SELECT 1 FROM iit.gated_action_events e WHERE e.action_id = g.id AND e.event = 'resolved')) THEN
    PERFORM iit._audit_read(c.user_id, 'get_unknown_outcome', 'unknown_outcome_detail', 'gated_action', p_action, NULL,
                            CASE WHEN g.id IS NULL THEN 'not_found' ELSE 'denied' END);
    RETURN iit._not_found('gated_action');
  END IF;
  PERFORM iit._audit_read(c.user_id, 'get_unknown_outcome', 'unknown_outcome_detail', 'gated_action', p_action, NULL, 'granted');
  RETURN pg_catalog.jsonb_build_object('status', 'ok', 'record_type', 'gated_action', 'data', pg_catalog.jsonb_build_object(
    'action', pg_catalog.jsonb_build_object('id', g.id, 'source_31_id', g.iid, 'action', g.action, 'caller_integration', g.caller_integration,
                'state', g.state, 'authorized_at', g.authorized_at, 'deal_version', g.deal_version, 'outcome_reported_at', g.outcome_reported_at,
                'completed_after_hold', g.completed_after_hold, 'created_at', g.created_at),
    'evidence', iit._jsonb_pick(g.outcome_evidence, ARRAY['provider_message_id','package_id','trip_id','target','http_status']),
    'attempts', coalesce((SELECT pg_catalog.jsonb_agg(a.j ORDER BY a.n) FROM (
                  SELECT at.attempt_no AS n, pg_catalog.jsonb_build_object('attempt_no', at.attempt_no, 'state', at.state, 'granted_at', at.granted_at,
                           'reported_at', at.reported_at, 'supplied_row_status', at.supplied_row_status, 'read_31_status', at.read_31_status, 'read_31_at', at.read_31_at) AS j
                    FROM iit.gated_action_attempts at WHERE at.action_id = g.id ORDER BY at.attempt_no LIMIT 100) a), '[]'::jsonb),
    'timeline', coalesce((SELECT pg_catalog.jsonb_agg(t.j ORDER BY t.at, t.id) FROM (
                  SELECT e.at, e.id, pg_catalog.jsonb_build_object('event', e.event, 'at', e.at,
                           'attempt_no', (SELECT at.attempt_no FROM iit.gated_action_attempts at WHERE at.id = e.attempt_id),
                           'detail', iit._jsonb_pick(e.detail, ARRAY['outcome','status_mismatch','resolution','replay','attempt_no','hold_id'])) AS j
                    FROM iit.gated_action_events e WHERE e.action_id = g.id ORDER BY e.at, e.id LIMIT 100) t), '[]'::jsonb),
    'deal', CASE WHEN g.deal_id IS NULL THEN NULL ELSE (SELECT pg_catalog.jsonb_build_object('id', d.id, 'deal_number', d.deal_number, 'on_hold', d.on_hold,
                'vehicle', iit._vehicle_summary(d.id),
                'open_holds', coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', h.id, 'cause', h.cause, 'opened_at', h.opened_at) ORDER BY h.opened_at, h.id)
                                          FROM iit.audit_holds h WHERE h.deal_id = d.id AND h.released_at IS NULL), '[]'::jsonb))
              FROM iit.deals d WHERE d.id = g.deal_id) END,
    'work_items', coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', w.id, 'kind', w.kind, 'assigned_role', w.assigned_role, 'status', w.status,
                    'opened_at', w.opened_at, 'closed_at', w.closed_at) ORDER BY w.opened_at, w.id)
                  FROM iit.work_items w WHERE w.gated_action_id = g.id), '[]'::jsonb)),
    'state_token', iit._action_state_token(g.id));
END $$;
REVOKE ALL ON FUNCTION iit.get_unknown_outcome(uuid,text) FROM PUBLIC;

-- 3.7 dashboard counts: only the sections for roles the caller holds, counts only (no ids, VINs or names). Admin alone: refused.
CREATE FUNCTION iit.get_dashboard_summary(p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE c record; r jsonb := '{}'::jsonb;
BEGIN
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, ARRAY['audit_lead','auditor','data_entry'], 'get_dashboard_summary');
  IF 'data_entry' = ANY (c.roles) THEN
    r := r || pg_catalog.jsonb_build_object('data_entry', (
      WITH open_deals AS (SELECT d.* FROM iit.deals d WHERE d.intake_status IN ('new','in_review') AND d.cancelled_at IS NULL)
      SELECT pg_catalog.jsonb_build_object(
        'new_intake',             (SELECT count(*) FROM open_deals WHERE intake_status = 'new'),
        'in_review',              (SELECT count(*) FROM open_deals WHERE intake_status = 'in_review'),
        'missing_required_facts', (SELECT count(*) FROM open_deals o WHERE pg_catalog.cardinality(iit.missing_required_facts(o.id)) > 0),
        'open_blocking_flags',    (SELECT count(DISTINCT f.deal_id) FROM iit.intake_flags f JOIN open_deals o ON o.id = f.deal_id WHERE f.status = 'open' AND f.blocks_release),
        'overdue_data_entry',     (SELECT count(*) FROM open_deals WHERE data_entry_due_at < pg_catalog.now()),
        'unknown_outcomes',       (SELECT count(*) FROM iit.gated_actions g WHERE g.state = 'outcome_unknown'),
        'consignment_setup',      (SELECT count(*) FROM iit._consignment_setup_deals()),
        'deals_on_hold',          (SELECT count(DISTINCT h.deal_id) FROM iit.audit_holds h WHERE h.released_at IS NULL),
        'restart_candidates',     (SELECT count(*) FROM iit.work_items w WHERE w.kind = 'restart_candidate' AND w.status = 'open'),
        'open_work_items',        (SELECT count(*) FROM iit.work_items w WHERE w.assigned_role = 'data_entry' AND w.status = 'open'))));
  END IF;
  IF c.roles && ARRAY['auditor','audit_lead'] THEN
    r := r || pg_catalog.jsonb_build_object('risk_audit', (
      WITH open_checks AS (SELECT k.* FROM iit.prequalification_checks k WHERE k.status = 'open')
      SELECT pg_catalog.jsonb_build_object(
        'awaiting_decision',  (SELECT count(*) FROM open_checks),
        'blocked_by_holds',   (SELECT count(*) FROM open_checks k WHERE iit.deal_has_open_hold(k.deal_id)),
        'missing_evidence',   (SELECT count(*) FROM open_checks k WHERE NOT iit.requirements_all_satisfied(k.deal_id, k.deal_version_no)),
        'material_drafts_open', (SELECT count(*) FROM iit.prequalification_checks k WHERE k.status <> 'superseded' AND iit.open_material_draft_exists(k.deal_id)))
      || CASE WHEN 'audit_lead' = ANY (c.roles) THEN pg_catalog.jsonb_build_object('escalated',
           (SELECT count(*) FROM iit.prequalification_checks k WHERE k.status = 'decided'
               AND (SELECT ad.decision FROM iit.audit_decisions ad WHERE ad.check_id = k.id ORDER BY ad.seq DESC LIMIT 1) = 'escalated'))
         ELSE '{}'::jsonb END));
  END IF;
  RETURN pg_catalog.jsonb_build_object('status', 'ok', 'record_type', 'dashboard_summary', 'data', r, 'as_of', pg_catalog.now());
END $$;
REVOKE ALL ON FUNCTION iit.get_dashboard_summary(text) FROM PUBLIC;

-- 3.8 staff: p_purpose 'admin' (admin; active and, on request, inactive staff, with email and roles) | 'auditor_selector'
-- (auditor or audit lead; active staff holding the auditor role, name only — no email). Service users never appear.
CREATE FUNCTION iit.list_staff(p_purpose text, p_include_inactive boolean, p_limit int, p_cursor text, p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE c record; v_lim int; q text; cur jsonb; v_items jsonb; v_n int; v_next text; v_admin boolean;
BEGIN
  IF p_purpose IS NULL OR p_purpose NOT IN ('admin','auditor_selector') THEN
    PERFORM iit._read_ctx(p_actor_base44_user_id, '{}');          -- credential and identity first, then the parameter error
    RAISE EXCEPTION 'INVALID_PARAMETER: p_purpose' USING ERRCODE = '22023';
  END IF;
  v_admin := p_purpose = 'admin';
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, CASE WHEN v_admin THEN ARRAY['admin'] ELSE ARRAY['audit_lead','auditor'] END, 'list_staff ' || p_purpose);
  IF NOT v_admin AND coalesce(p_include_inactive, false) THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_include_inactive (admin only)' USING ERRCODE = '22023'; END IF;
  v_lim := iit._page_limit(p_limit);
  q := 'list_staff|' || p_purpose || '|' || coalesce(p_include_inactive, false)::text;
  cur := iit._cursor_in(p_cursor, q, ARRAY['name:text','id:uuid']);
  WITH page AS (
    SELECT u.id, u.display_name, u.email, u.created_at, si.base44_user_id, si.deactivated_at, (si.active AND u.active) AS active,
           row_number() OVER (ORDER BY u.display_name, u.id) AS rn
      FROM iit.staff_identities si JOIN iit.users u ON u.id = si.user_id
     WHERE u.kind = 'staff'
       AND (CASE WHEN v_admin THEN (coalesce(p_include_inactive, false) OR (si.active AND u.active))
                 ELSE si.active AND u.active AND EXISTS (SELECT 1 FROM iit.user_roles ur WHERE ur.user_id = u.id AND ur.role = 'auditor') END)
       AND (cur IS NULL OR (u.display_name, u.id) > ((cur ->> 'name'), (cur ->> 'id')::uuid))
     ORDER BY u.display_name, u.id LIMIT v_lim + 1)
  SELECT pg_catalog.jsonb_agg(CASE WHEN v_admin THEN
             pg_catalog.jsonb_build_object('record_type', 'staff', 'user_id', p.id, 'base44_user_id', p.base44_user_id, 'display_name', p.display_name,
               'email', p.email, 'active', p.active, 'created_at', p.created_at, 'deactivated_at', p.deactivated_at,
               'roles', pg_catalog.to_jsonb(ARRAY(SELECT ur.role FROM iit.user_roles ur WHERE ur.user_id = p.id ORDER BY ur.role)))
           ELSE pg_catalog.jsonb_build_object('record_type', 'staff_option', 'user_id', p.id, 'display_name', p.display_name) END ORDER BY p.rn) FILTER (WHERE p.rn <= v_lim),
         count(*)
    INTO v_items, v_n FROM page p;
  IF v_n > v_lim THEN
    v_next := iit._cursor_out(q, pg_catalog.jsonb_build_object('name', (v_items -> (v_lim - 1)) ->> 'display_name', 'id', (v_items -> (v_lim - 1)) ->> 'user_id'));
  END IF;
  RETURN iit._list_envelope(v_items, v_next, v_lim);
END $$;
REVOKE ALL ON FUNCTION iit.list_staff(text,boolean,int,text,text) FROM PUBLIC;

-- 3.9 active source channels for the fixed selectors (create_manual_deal, set_source_channel). Data Entry.
CREATE FUNCTION iit.list_source_channels(p_limit int, p_cursor text, p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE c record; v_lim int; q text := 'list_source_channels'; cur jsonb; v_items jsonb; v_n int; v_next text;
BEGIN
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, ARRAY['data_entry'], 'list_source_channels');
  v_lim := iit._page_limit(p_limit);
  cur := iit._cursor_in(p_cursor, q, ARRAY['name:text','id:uuid']);
  WITH page AS (
    SELECT sc.*, row_number() OVER (ORDER BY sc.name, sc.id) AS rn FROM iit.source_channels sc
     WHERE sc.active AND (cur IS NULL OR (sc.name, sc.id) > ((cur ->> 'name'), (cur ->> 'id')::uuid))
     ORDER BY sc.name, sc.id LIMIT v_lim + 1)
  SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('record_type', 'source_channel', 'id', p.id, 'name', p.name, 'route', p.route, 'origin', p.origin)
           ORDER BY p.rn) FILTER (WHERE p.rn <= v_lim),
         count(*)
    INTO v_items, v_n FROM page p;
  IF v_n > v_lim THEN
    v_next := iit._cursor_out(q, pg_catalog.jsonb_build_object('name', (v_items -> (v_lim - 1)) ->> 'name', 'id', (v_items -> (v_lim - 1)) ->> 'id'));
  END IF;
  RETURN iit._list_envelope(v_items, v_next, v_lim);
END $$;
REVOKE ALL ON FUNCTION iit.list_source_channels(int,text,text) FROM PUBLIC;

-- 3.10 exact lookup (owner Q2): p_type 'iit_id' (deals.id) | 'deal_number' | 'vin' (normalized) | 'source_31_id' (a linked
-- source_records.legacy_iid; no VIN fallback). No substring search, no seller/dealer/consignor names, no prices. Results are
-- limited to deals the caller may open with get_deal.
CREATE FUNCTION iit.search_deals(p_type text, p_value text, p_limit int, p_cursor text, p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE c record; v_lim int; v text; v_uuid uuid; v_num bigint; q text; cur jsonb; v_items jsonb; v_n int; v_next text; v_label text;
BEGIN
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, ARRAY['audit_lead','auditor','data_entry'], 'search_deals');
  v_lim := iit._page_limit(p_limit);
  IF p_type IS NULL OR p_type NOT IN ('iit_id','deal_number','vin','source_31_id') THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_type' USING ERRCODE = '22023'; END IF;
  v := pg_catalog.btrim(p_value);
  IF v IS NULL OR v = '' OR pg_catalog.length(v) > 64 THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_value' USING ERRCODE = '22023'; END IF;
  IF p_type = 'iit_id' THEN
    IF v !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_value (iit_id is a UUID)' USING ERRCODE = '22023'; END IF;
    v_uuid := v::uuid;
  ELSIF p_type = 'deal_number' THEN
    IF v !~ '^[0-9]{1,18}$' THEN RAISE EXCEPTION 'INVALID_PARAMETER: p_value (deal_number is digits)' USING ERRCODE = '22023'; END IF;
    v_num := v::bigint;
  ELSIF p_type = 'vin' THEN
    v := pg_catalog.upper(v);
  END IF;
  v_label := CASE p_type WHEN 'iit_id' THEN 'IIT ID' WHEN 'deal_number' THEN 'Deal number' WHEN 'vin' THEN 'VIN' ELSE '3.1 ID' END;
  q := 'search_deals|' || p_type || '|' || pg_catalog.md5(v);
  cur := iit._cursor_in(p_cursor, q, ARRAY['n:bigint']);
  WITH hits AS (
    SELECT d.id FROM iit.deals d WHERE p_type = 'iit_id' AND d.id = v_uuid
    UNION SELECT d.id FROM iit.deals d WHERE p_type = 'deal_number' AND d.deal_number = v_num
    UNION SELECT d.id FROM iit.deals d JOIN iit.vehicles vh ON vh.id = d.vehicle_id WHERE p_type = 'vin' AND vh.vin_normalized = v
    UNION SELECT s.deal_id FROM iit.source_records s WHERE p_type = 'source_31_id' AND s.legacy_iid = v AND s.link_status = 'linked' AND s.deal_id IS NOT NULL),
  page AS (
    SELECT d.id, d.deal_number, d.intake_status, d.audit_status, row_number() OVER (ORDER BY d.deal_number) AS rn
      FROM iit.deals d WHERE d.id IN (SELECT h.id FROM hits h) AND iit._deal_visible(d.id, c.roles)
       AND (cur IS NULL OR d.deal_number > (cur ->> 'n')::bigint)
     ORDER BY d.deal_number LIMIT v_lim + 1)
  SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('record_type', 'deal_match', 'deal_id', p.id, 'deal_number', p.deal_number,
           'matched_on', p_type, 'match_label', v_label, 'vehicle', iit._vehicle_summary(p.id),
           'intake_status', p.intake_status, 'audit_status', p.audit_status) ORDER BY p.rn) FILTER (WHERE p.rn <= v_lim),
         count(*)
    INTO v_items, v_n FROM page p;
  IF v_n > v_lim THEN
    v_next := iit._cursor_out(q, pg_catalog.jsonb_build_object('n', (v_items -> (v_lim - 1)) -> 'deal_number'));
  END IF;
  RETURN iit._list_envelope(v_items, v_next, v_lim);
END $$;
REVOKE ALL ON FUNCTION iit.search_deals(text,text,int,text,text) FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. grants: the ten read RPCs to the PostgREST credential role only (manifest 27 → 37). Helpers, the audit table and its
--    sequence get nothing.
-- ---------------------------------------------------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION
  iit.get_my_profile(text), iit.get_deal(uuid,int,text), iit.list_work_items(text,text,int,text,text),
  iit.list_audit_queue(text,int,text,text), iit.list_unknown_outcomes(int,text,text), iit.get_unknown_outcome(uuid,text),
  iit.get_dashboard_summary(text), iit.list_staff(text,boolean,int,text,text), iit.list_source_channels(int,text,text),
  iit.search_deals(text,text,int,text,text)
TO iit_base44;
RESET ROLE;
