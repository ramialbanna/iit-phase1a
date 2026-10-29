-- 009_expected_state_writes.sql — the stale-write gate (owner decision F; docs/migrations/007-stale-write-gap-report.md).
-- Every state-dependent public write now requires p_expected_state: the authoritative state token the caller last read
-- (get_deal.state_token, list_work_items / consignment rows' state_token, get_unknown_outcome.state_token). NOT applied.
--
-- Shape of each of the 22 changes (docs/migrations/009.md §2): the deployed function keeps its exact body and is renamed
-- iit._<name>_unchecked (owner-only); a new public iit.<name>(…, p_expected_state text, p_actor_base44_user_id text):
--   1. runs the credential, identity and staff-role check (require_role, unchanged) — nothing about state is disclosed first;
--   2. refuses a missing token (STATE_TOKEN_REQUIRED) or a malformed one (STATE_TOKEN_INVALID), SQLSTATE 22023;
--   3. takes the row locks in the established order (Deal first; appraisal → Deal → item for restarts; Deal → action for
--      gate outcomes), recomputes the token under them and refuses a mismatch with STALE_STATE (SQLSTATE PT409, which
--      PostgREST returns as HTTP 409; DETAIL carries the current token);
--   4. only then delegates to the unchanged function, which repeats its own checks, actor push/restore, history and audit.
-- A refusal raises before the unchanged function runs, so it mutates nothing and writes no history, activity or audit row.
-- The superseded signatures cease to exist as public functions (renamed and revoked), so no caller can bypass the check.
--
-- Not changed (state-independent, docs/migrations/009.md §1): set_staff_identity, set_staff_role, deactivate_staff (absolute
-- admin commands), create_manual_deal (creation), authorize_report_access (read). The Worker functions, the 008 Logistics
-- interface, require_role and every 007 read are unchanged; list_work_items gains a per-row state_token (signature unchanged).
--
-- Signatures (old → new):
--   iit.record_decision(uuid,text,text,text)                       → iit.record_decision(uuid,text,text,text,text)
--   iit.request_reaudit(uuid,text,text)                            → iit.request_reaudit(uuid,text,text,text)
--   iit.validate_report(uuid,text,text,jsonb,text,text)            → iit.validate_report(uuid,text,text,jsonb,text,text,text)
--   iit.waive_report(uuid,text,text,text)                          → iit.waive_report(uuid,text,text,text,text)
--   iit.revoke_waiver(uuid,text,text)                              → iit.revoke_waiver(uuid,text,text,text)
--   iit.begin_report_upload(uuid,text,text,uuid,uuid,text,timestamptz,uuid,text) → iit.begin_report_upload(uuid,text,text,uuid,uuid,text,timestamptz,uuid,text,text)
--   iit.finish_report_upload(uuid,bigint,text,text)                → iit.finish_report_upload(uuid,bigint,text,text,text)
--   iit.set_source_channel(uuid,text,text)                         → iit.set_source_channel(uuid,text,text,text)
--   iit.release_deal(uuid,text)                                    → iit.release_deal(uuid,text,text)
--   iit.correct_field(uuid,text,jsonb,text,text)                   → iit.correct_field(uuid,text,jsonb,text,text,text)
--   iit.amend_field(uuid,text,jsonb,text,text)                     → iit.amend_field(uuid,text,jsonb,text,text,text)
--   iit.rebind_hold(uuid,text,text)                                → iit.rebind_hold(uuid,text,text,text)
--   iit.resolve_flag(uuid,text,text,text)                          → iit.resolve_flag(uuid,text,text,text,text)
--   iit.resolve_work_item(uuid,text,text)                          → iit.resolve_work_item(uuid,text,text,text)
--   iit.cancel_deal(uuid,text,text)                                → iit.cancel_deal(uuid,text,text,text)
--   iit.set_seller_party(uuid,text,int,jsonb,text)                 → iit.set_seller_party(uuid,text,int,jsonb,text,text)
--   iit.correct_party(uuid,text,int,jsonb,text,text)               → iit.correct_party(uuid,text,int,jsonb,text,text,text)
--   iit.amend_party(uuid,uuid,jsonb,text,text)                     → iit.amend_party(uuid,uuid,jsonb,text,text,text)
--   iit.set_deal_fact(uuid,text,jsonb,text)                        → iit.set_deal_fact(uuid,text,jsonb,text,text)
--   iit.resolve_restart(uuid,text,text,text)                       → iit.resolve_restart(uuid,text,text,text,text)
--   iit.resolve_unknown_outcome(uuid,text,jsonb,text,text)         → iit.resolve_unknown_outcome(uuid,text,jsonb,text,text,text)
--   iit.set_consignment(uuid,uuid,numeric,text,text)               → iit.set_consignment(uuid,uuid,numeric,text,text,text)

SET ROLE iit_owner;

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. helpers (owner-only)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION iit._state_token_form(p text) RETURNS void LANGUAGE plpgsql VOLATILE SET search_path = '' AS $$
BEGIN
  IF p IS NULL OR p = '' THEN RAISE EXCEPTION 'STATE_TOKEN_REQUIRED' USING ERRCODE = '22023'; END IF;
  IF p !~ '^v1:[0-9a-f]{32}$' THEN RAISE EXCEPTION 'STATE_TOKEN_INVALID' USING ERRCODE = '22023'; END IF;
END $$;
REVOKE ALL ON FUNCTION iit._state_token_form(text) FROM PUBLIC;

-- called only under the row locks; the current token is returned so the caller can reload without another round trip
CREATE FUNCTION iit._state_check(p_expected text, p_current text) RETURNS void LANGUAGE plpgsql VOLATILE SET search_path = '' AS $$
BEGIN
  IF p_expected IS DISTINCT FROM p_current THEN
    RAISE EXCEPTION 'STALE_STATE' USING ERRCODE = 'PT409', DETAIL = 'current_state_token=' || coalesce(p_current, '');
  END IF;
END $$;
REVOKE ALL ON FUNCTION iit._state_check(text,text) FROM PUBLIC;

-- token of a work item that belongs to no deal (admin/legacy kinds); a deal's items are covered by the deal token
CREATE FUNCTION iit._work_item_state_token(p_item uuid) RETURNS text LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT 'v1:' || pg_catalog.md5(pg_catalog.jsonb_build_array(pg_catalog.to_jsonb(w))::text) FROM iit.work_items w WHERE w.id = p_item $$;
REVOKE ALL ON FUNCTION iit._work_item_state_token(uuid) FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. list_work_items (007) returns each row's state token: the deal token, or the item's own when it has no deal
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iit.list_work_items(p_kind text, p_status text, p_limit int, p_cursor text, p_actor_base44_user_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE c record; v_lim int; v_status text; q text; cur jsonb; v_items jsonb; v_n int; v_last record; v_next text;
BEGIN
  SELECT * INTO c FROM iit._require_read(p_actor_base44_user_id, ARRAY['audit_lead','auditor','data_entry'], 'list_work_items');
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
           'state_token', CASE WHEN p.deal_id IS NULL THEN iit._work_item_state_token(p.id) ELSE iit._deal_state_token(p.deal_id) END,
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

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. the 22 state-dependent writes
-- ---------------------------------------------------------------------------------------------------------------------
ALTER FUNCTION iit.record_decision(uuid,text,text,text) RENAME TO _record_decision_unchecked;
REVOKE ALL ON FUNCTION iit._record_decision_unchecked(uuid,text,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.record_decision(p_check_id uuid, p_decision text, p_comments text, p_expected_state text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_deal uuid;
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'auditor');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  SELECT deal_id INTO v_deal FROM iit.prequalification_checks WHERE id = p_check_id;         -- a prequalification_checks row never changes deal
  IF v_deal IS NOT NULL THEN
    PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(v_deal));
  END IF;                                                              -- unknown prequalification_checks row: the function raises its own error
  RETURN iit._record_decision_unchecked(p_check_id, p_decision, p_comments, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.record_decision(uuid,text,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.request_reaudit(uuid,text,text) RENAME TO _request_reaudit_unchecked;
REVOKE ALL ON FUNCTION iit._request_reaudit_unchecked(uuid,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.request_reaudit(p_deal uuid, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'audit_lead');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._request_reaudit_unchecked(p_deal, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.request_reaudit(uuid,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.validate_report(uuid,text,text,jsonb,text,text) RENAME TO _validate_report_unchecked;
REVOKE ALL ON FUNCTION iit._validate_report_unchecked(uuid,text,text,jsonb,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.validate_report(p_report uuid, p_requirement_key text, p_outcome text, p_checks jsonb, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_deal uuid;
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  SELECT deal_id INTO v_deal FROM iit.external_vehicle_reports WHERE id = p_report;         -- a external_vehicle_reports row never changes deal
  IF v_deal IS NOT NULL THEN
    PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(v_deal));
  END IF;                                                              -- unknown external_vehicle_reports row: the function raises its own error
  RETURN iit._validate_report_unchecked(p_report, p_requirement_key, p_outcome, p_checks, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.validate_report(uuid,text,text,jsonb,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.waive_report(uuid,text,text,text) RENAME TO _waive_report_unchecked;
REVOKE ALL ON FUNCTION iit._waive_report_unchecked(uuid,text,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.waive_report(p_deal uuid, p_requirement_key text, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'audit_lead');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._waive_report_unchecked(p_deal, p_requirement_key, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.waive_report(uuid,text,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.revoke_waiver(uuid,text,text) RENAME TO _revoke_waiver_unchecked;
REVOKE ALL ON FUNCTION iit._revoke_waiver_unchecked(uuid,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.revoke_waiver(p_waiver uuid, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_deal uuid;
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'audit_lead');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  SELECT deal_id INTO v_deal FROM iit.report_waivers WHERE id = p_waiver;         -- a report_waivers row never changes deal
  IF v_deal IS NOT NULL THEN
    PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(v_deal));
  END IF;                                                              -- unknown report_waivers row: the function raises its own error
  RETURN iit._revoke_waiver_unchecked(p_waiver, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.revoke_waiver(uuid,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.begin_report_upload(uuid,text,text,uuid,uuid,text,timestamptz,uuid,text) RENAME TO _begin_report_upload_unchecked;
REVOKE ALL ON FUNCTION iit._begin_report_upload_unchecked(uuid,text,text,uuid,uuid,text,timestamptz,uuid,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.begin_report_upload(p_deal uuid, p_report_type text, p_subject_type text, p_vehicle uuid, p_subject_org uuid, p_acquisition text, p_pulled_at timestamptz, p_replaces uuid, p_expected_state text, p_actor_base44_user_id text) RETURNS TABLE (report_id uuid, object_path text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN QUERY SELECT * FROM iit._begin_report_upload_unchecked(p_deal, p_report_type, p_subject_type, p_vehicle, p_subject_org, p_acquisition, p_pulled_at, p_replaces, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.begin_report_upload(uuid,text,text,uuid,uuid,text,timestamptz,uuid,text,text) FROM PUBLIC;

ALTER FUNCTION iit.finish_report_upload(uuid,bigint,text,text) RENAME TO _finish_report_upload_unchecked;
REVOKE ALL ON FUNCTION iit._finish_report_upload_unchecked(uuid,bigint,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.finish_report_upload(p_report uuid, p_bytes bigint, p_sha256 text, p_expected_state text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_deal uuid;
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  SELECT deal_id INTO v_deal FROM iit.external_vehicle_reports WHERE id = p_report;         -- a external_vehicle_reports row never changes deal
  IF v_deal IS NOT NULL THEN
    PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(v_deal));
  END IF;                                                              -- unknown external_vehicle_reports row: the function raises its own error
  PERFORM iit._finish_report_upload_unchecked(p_report, p_bytes, p_sha256, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.finish_report_upload(uuid,bigint,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.set_source_channel(uuid,text,text) RENAME TO _set_source_channel_unchecked;
REVOKE ALL ON FUNCTION iit._set_source_channel_unchecked(uuid,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.set_source_channel(p_deal uuid, p_channel_name text, p_expected_state text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  PERFORM iit._set_source_channel_unchecked(p_deal, p_channel_name, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.set_source_channel(uuid,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.release_deal(uuid,text) RENAME TO _release_deal_unchecked;
REVOKE ALL ON FUNCTION iit._release_deal_unchecked(uuid,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.release_deal(p_deal uuid, p_expected_state text, p_actor_base44_user_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._release_deal_unchecked(p_deal, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.release_deal(uuid,text,text) FROM PUBLIC;

ALTER FUNCTION iit.correct_field(uuid,text,jsonb,text,text) RENAME TO _correct_field_unchecked;
REVOKE ALL ON FUNCTION iit._correct_field_unchecked(uuid,text,jsonb,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.correct_field(p_deal uuid, p_field text, p_value jsonb, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._correct_field_unchecked(p_deal, p_field, p_value, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.correct_field(uuid,text,jsonb,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.amend_field(uuid,text,jsonb,text,text) RENAME TO _amend_field_unchecked;
REVOKE ALL ON FUNCTION iit._amend_field_unchecked(uuid,text,jsonb,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.amend_field(p_deal uuid, p_field text, p_value jsonb, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._amend_field_unchecked(p_deal, p_field, p_value, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.amend_field(uuid,text,jsonb,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.rebind_hold(uuid,text,text) RENAME TO _rebind_hold_unchecked;
REVOKE ALL ON FUNCTION iit._rebind_hold_unchecked(uuid,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.rebind_hold(p_hold uuid, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_deal uuid;
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'audit_lead');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  SELECT deal_id INTO v_deal FROM iit.audit_holds WHERE id = p_hold;         -- a audit_holds row never changes deal
  IF v_deal IS NOT NULL THEN
    PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(v_deal));
  END IF;                                                              -- unknown audit_holds row: the function raises its own error
  RETURN iit._rebind_hold_unchecked(p_hold, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.rebind_hold(uuid,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.resolve_flag(uuid,text,text,text) RENAME TO _resolve_flag_unchecked;
REVOKE ALL ON FUNCTION iit._resolve_flag_unchecked(uuid,text,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.resolve_flag(p_flag uuid, p_status text, p_resolution text, p_expected_state text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_deal uuid;
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  SELECT deal_id INTO v_deal FROM iit.intake_flags WHERE id = p_flag;         -- a intake_flags row never changes deal
  IF v_deal IS NOT NULL THEN
    PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(v_deal));
  END IF;                                                              -- unknown intake_flags row: the function raises its own error
  PERFORM iit._resolve_flag_unchecked(p_flag, p_status, p_resolution, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.resolve_flag(uuid,text,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.resolve_work_item(uuid,text,text) RENAME TO _resolve_work_item_unchecked;
REVOKE ALL ON FUNCTION iit._resolve_work_item_unchecked(uuid,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.resolve_work_item(p_item uuid, p_outcome text, p_expected_state text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w record;
BEGIN
  PERFORM iit._read_ctx(p_actor_base44_user_id, '{}');                  -- credential and identity first; the role is the item's, checked under the lock
  PERFORM iit._state_token_form(p_expected_state);
  SELECT deal_id INTO w FROM iit.work_items WHERE id = p_item;
  IF FOUND THEN
    IF w.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = w.deal_id FOR UPDATE; END IF;   -- Deal, then item (003 lock order)
    SELECT * INTO w FROM iit.work_items WHERE id = p_item FOR UPDATE;
    PERFORM iit.require_role(p_actor_base44_user_id, w.assigned_role);
    PERFORM iit._state_check(p_expected_state,
      CASE WHEN w.deal_id IS NULL THEN iit._work_item_state_token(p_item) ELSE iit._deal_state_token(w.deal_id) END);
  END IF;                                                              -- unknown item: the function raises its own error
  PERFORM iit._resolve_work_item_unchecked(p_item, p_outcome, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.resolve_work_item(uuid,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.cancel_deal(uuid,text,text) RENAME TO _cancel_deal_unchecked;
REVOKE ALL ON FUNCTION iit._cancel_deal_unchecked(uuid,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.cancel_deal(p_deal uuid, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._cancel_deal_unchecked(p_deal, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.cancel_deal(uuid,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.set_seller_party(uuid,text,int,jsonb,text) RENAME TO _set_seller_party_unchecked;
REVOKE ALL ON FUNCTION iit._set_seller_party_unchecked(uuid,text,int,jsonb,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.set_seller_party(p_deal uuid, p_role text, p_ordinal int, p_party jsonb, p_expected_state text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._set_seller_party_unchecked(p_deal, p_role, p_ordinal, p_party, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.set_seller_party(uuid,text,int,jsonb,text,text) FROM PUBLIC;

ALTER FUNCTION iit.correct_party(uuid,text,int,jsonb,text,text) RENAME TO _correct_party_unchecked;
REVOKE ALL ON FUNCTION iit._correct_party_unchecked(uuid,text,int,jsonb,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.correct_party(p_deal uuid, p_role text, p_ordinal int, p_party jsonb, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._correct_party_unchecked(p_deal, p_role, p_ordinal, p_party, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.correct_party(uuid,text,int,jsonb,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.amend_party(uuid,uuid,jsonb,text,text) RENAME TO _amend_party_unchecked;
REVOKE ALL ON FUNCTION iit._amend_party_unchecked(uuid,uuid,jsonb,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.amend_party(p_deal uuid, p_party_id uuid, p_party jsonb, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._amend_party_unchecked(p_deal, p_party_id, p_party, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.amend_party(uuid,uuid,jsonb,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.set_deal_fact(uuid,text,jsonb,text) RENAME TO _set_deal_fact_unchecked;
REVOKE ALL ON FUNCTION iit._set_deal_fact_unchecked(uuid,text,jsonb,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.set_deal_fact(p_deal uuid, p_field text, p_value jsonb, p_expected_state text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  PERFORM iit._set_deal_fact_unchecked(p_deal, p_field, p_value, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.set_deal_fact(uuid,text,jsonb,text,text) FROM PUBLIC;

ALTER FUNCTION iit.resolve_restart(uuid,text,text,text) RENAME TO _resolve_restart_unchecked;
REVOKE ALL ON FUNCTION iit._resolve_restart_unchecked(uuid,text,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.resolve_restart(p_item uuid, p_decision text, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE w record;
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');
  PERFORM iit._state_token_form(p_expected_state);
  SELECT deal_id, appraisal_ref_id INTO w FROM iit.work_items WHERE id = p_item;
  IF FOUND THEN                                                        -- 004 lock order: appraisal identity → Deal → item
    IF w.appraisal_ref_id IS NOT NULL THEN PERFORM 1 FROM iit.external_references WHERE id = w.appraisal_ref_id FOR UPDATE; END IF;
    IF w.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = w.deal_id FOR UPDATE; END IF;
    PERFORM 1 FROM iit.work_items WHERE id = p_item FOR UPDATE;
    PERFORM iit._state_check(p_expected_state,
      CASE WHEN w.deal_id IS NULL THEN iit._work_item_state_token(p_item) ELSE iit._deal_state_token(w.deal_id) END);
  END IF;
  RETURN iit._resolve_restart_unchecked(p_item, p_decision, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.resolve_restart(uuid,text,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.resolve_unknown_outcome(uuid,text,jsonb,text,text) RENAME TO _resolve_unknown_outcome_unchecked;
REVOKE ALL ON FUNCTION iit._resolve_unknown_outcome_unchecked(uuid,text,jsonb,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.resolve_unknown_outcome(p_action_id uuid, p_resolution text, p_evidence jsonb, p_reason text, p_expected_state text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE g record;
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');
  PERFORM iit._state_token_form(p_expected_state);
  SELECT deal_id INTO g FROM iit.gated_actions WHERE id = p_action_id;
  IF FOUND THEN                                                        -- 005 order: Deal → action (Deal taken FOR UPDATE here)
    IF g.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = g.deal_id FOR UPDATE; END IF;
    PERFORM 1 FROM iit.gated_actions WHERE id = p_action_id FOR UPDATE;
    PERFORM iit._state_check(p_expected_state, iit._action_state_token(p_action_id));   -- covers the Deal token too
  END IF;
  PERFORM iit._resolve_unknown_outcome_unchecked(p_action_id, p_resolution, p_evidence, p_reason, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.resolve_unknown_outcome(uuid,text,jsonb,text,text,text) FROM PUBLIC;

ALTER FUNCTION iit.set_consignment(uuid,uuid,numeric,text,text) RENAME TO _set_consignment_unchecked;
REVOKE ALL ON FUNCTION iit._set_consignment_unchecked(uuid,uuid,numeric,text,text) FROM PUBLIC, iit_base44, iit_integration;
CREATE FUNCTION iit.set_consignment(p_deal uuid, p_consignor_party_id uuid, p_amount numeric, p_notes text, p_expected_state text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry');            -- credential, identity, staff role: before any state is consulted
  PERFORM iit._state_token_form(p_expected_state);
  IF EXISTS (SELECT 1 FROM iit.deals WHERE id = p_deal) THEN
    PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;               -- the Deal lock every writer takes first
    PERFORM iit._state_check(p_expected_state, iit._deal_state_token(p_deal));
  END IF;                                                              -- unknown deal: the function raises its own error
  RETURN iit._set_consignment_unchecked(p_deal, p_consignor_party_id, p_amount, p_notes, p_actor_base44_user_id);
END $$;
REVOKE ALL ON FUNCTION iit.set_consignment(uuid,uuid,numeric,text,text,text) FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. grants: the new signatures replace the old ones in both staff manifests (iit_base44 stays 37, iit_integration 27)
-- ---------------------------------------------------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION
  iit.record_decision(uuid,text,text,text,text),
  iit.request_reaudit(uuid,text,text,text),
  iit.validate_report(uuid,text,text,jsonb,text,text,text),
  iit.waive_report(uuid,text,text,text,text),
  iit.revoke_waiver(uuid,text,text,text),
  iit.begin_report_upload(uuid,text,text,uuid,uuid,text,timestamptz,uuid,text,text),
  iit.finish_report_upload(uuid,bigint,text,text,text),
  iit.set_source_channel(uuid,text,text,text),
  iit.release_deal(uuid,text,text),
  iit.correct_field(uuid,text,jsonb,text,text,text),
  iit.amend_field(uuid,text,jsonb,text,text,text),
  iit.rebind_hold(uuid,text,text,text),
  iit.resolve_flag(uuid,text,text,text,text),
  iit.resolve_work_item(uuid,text,text,text),
  iit.cancel_deal(uuid,text,text,text),
  iit.set_seller_party(uuid,text,int,jsonb,text,text),
  iit.correct_party(uuid,text,int,jsonb,text,text,text),
  iit.amend_party(uuid,uuid,jsonb,text,text,text),
  iit.set_deal_fact(uuid,text,jsonb,text,text),
  iit.resolve_restart(uuid,text,text,text,text),
  iit.resolve_unknown_outcome(uuid,text,jsonb,text,text,text),
  iit.set_consignment(uuid,uuid,numeric,text,text,text)
TO iit_base44, iit_integration;
RESET ROLE;
