-- 004_intake.sql — intake and the two owner decisions of 26 Oct 2026: D-20 (deposit after release is administrative) and
-- D-25a (skip-audit material-correction holds are released by the release of the corrected version). Adds: the Worker service
-- user (001 D-10), vAuto intake (§5.3 rules: first completion → Deal + episode; open episode → change flags; ended episode →
-- restart task only on a real transition), manual Deal creation, draft editing, seller parties (pre-release set, post-release
-- material correction / administrative amendment), restart decisions (§5.3).
-- Depends on 001–003. EXCLUDED and named: reschedule linking (§5.4) — needs 3.1 read-backs, whose allowlist is empty until the
-- field map exists (001 D-8), so no function is provided; §5.10 polling (the Worker's discovery loop calls ingest per
-- observation); §5.11 lienholder sync; §6 gate; §5.8 bridge; data_entry_due_at (D-6, calendar empty).
BEGIN;
SET ROLE iit_owner;
SET search_path = pg_catalog;

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. reference data: Worker service user (D-10), activity keys
-- ---------------------------------------------------------------------------------------------------------------------
INSERT INTO iit.users(id, display_name, email, kind) VALUES ('00000000-0000-4000-8000-00000000f00d', 'TAV Intake Worker', NULL, 'service');
CREATE FUNCTION iit.worker_user() RETURNS uuid LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT '00000000-0000-4000-8000-00000000f00d'::uuid $$;
UPDATE iit.json_schemas SET schema = schema || '{"deal_id":true,"episode_no":true,"observation_id":true,"party_role":true,"party_id":true,"restarted_from_deal_id":true,"origin":true}'::jsonb,
  updated_at = now(), note = note || '; 004: deal_id, episode_no, observation_id, party_role, party_id, restarted_from_deal_id, origin'
WHERE name = 'activity_event_detail';

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. D-25a — release-based hold release on the skip-audit route (reviewed change to 002's audit_holds constraints)
-- ---------------------------------------------------------------------------------------------------------------------
ALTER TABLE iit.audit_holds ADD COLUMN released_by_version_no int;
-- replace 002's "released ⇔ decision" CHECK with "released ⇔ exactly one of (decision, version)"
DO $$ DECLARE c text; BEGIN
  SELECT conname INTO c FROM pg_catalog.pg_constraint WHERE conrelid = 'iit.audit_holds'::regclass AND contype = 'c'
   AND pg_catalog.pg_get_constraintdef(oid) = 'CHECK (((released_at IS NULL) = (released_by_decision_id IS NULL)))';
  IF c IS NULL THEN RAISE EXCEPTION '004: the 002 release CHECK on audit_holds was not found'; END IF;
  EXECUTE pg_catalog.format('ALTER TABLE iit.audit_holds DROP CONSTRAINT %I', c);
END $$;
ALTER TABLE iit.audit_holds
  ADD CONSTRAINT audit_holds_release_ref_check CHECK ((released_at IS NULL) = (released_by_decision_id IS NULL AND released_by_version_no IS NULL)),
  ADD CONSTRAINT audit_holds_release_one_path_check CHECK (released_by_decision_id IS NULL OR released_by_version_no IS NULL),
  ADD CONSTRAINT audit_holds_release_version_fk FOREIGN KEY (deal_id, released_by_version_no) REFERENCES iit.deal_versions(deal_id, version_no);
-- guard: the version path is allowed only for a material_correction hold, on a Deal whose route is skip_audit, citing EXACTLY
-- the hold's covering version, and only when that version is released. Release immutability now covers both reference columns.
CREATE OR REPLACE FUNCTION iit.audit_holds_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_route text; v_vstatus text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.released_at IS NOT NULL OR NEW.released_by_decision_id IS NOT NULL OR NEW.released_by_version_no IS NOT NULL THEN RAISE EXCEPTION 'HOLD_INSERT_RELEASED: holds cannot be inserted already released'; END IF;
    RETURN NEW;
  END IF;
  IF OLD.released_at IS NOT NULL AND (NEW.released_at IS DISTINCT FROM OLD.released_at OR NEW.released_by_decision_id IS DISTINCT FROM OLD.released_by_decision_id OR NEW.released_by_version_no IS DISTINCT FROM OLD.released_by_version_no) THEN
    RAISE EXCEPTION 'HOLD_RELEASE_IMMUTABLE: hold % was already released', OLD.id; END IF;
  IF NEW.deal_id <> OLD.deal_id OR NEW.cause <> OLD.cause OR NEW.correction_id IS DISTINCT FROM OLD.correction_id OR NEW.opened_at <> OLD.opened_at OR NEW.opened_by <> OLD.opened_by THEN
    RAISE EXCEPTION 'HOLD_IMMUTABLE: identity fields of hold % cannot change', OLD.id; END IF;
  IF NEW.released_by_decision_id IS NOT NULL AND OLD.released_by_decision_id IS NULL THEN
    IF NEW.covering_check_id IS NULL THEN RAISE EXCEPTION 'HOLD_RELEASE_UNBOUND: hold % has no covering check', OLD.id; END IF;
    IF NOT EXISTS (SELECT 1 FROM iit.audit_decisions d WHERE d.id = NEW.released_by_decision_id AND d.check_id = NEW.covering_check_id AND d.decision = 'approved') THEN
      RAISE EXCEPTION 'HOLD_RELEASE_INVALID: decision % is not an approved decision on covering check %', NEW.released_by_decision_id, NEW.covering_check_id; END IF;
  END IF;
  IF NEW.released_by_version_no IS NOT NULL AND OLD.released_by_version_no IS NULL THEN                      -- D-25a path
    IF NEW.cause <> 'material_correction' THEN RAISE EXCEPTION 'HOLD_RELEASE_BY_VERSION: only material_correction holds release by version (hold % is %)', OLD.id, NEW.cause; END IF;
    SELECT consumer_route INTO v_route FROM iit.deals WHERE id = NEW.deal_id;
    IF v_route IS DISTINCT FROM 'skip_audit' THEN RAISE EXCEPTION 'HOLD_RELEASE_BY_VERSION: deal % is on route %, not skip_audit', NEW.deal_id, coalesce(v_route, 'NULL'); END IF;
    IF NEW.released_by_version_no IS DISTINCT FROM NEW.covers_version_no THEN RAISE EXCEPTION 'HOLD_RELEASE_BY_VERSION: v% is not the covering version v% of hold %', NEW.released_by_version_no, NEW.covers_version_no, OLD.id; END IF;
    SELECT status INTO v_vstatus FROM iit.deal_versions WHERE deal_id = NEW.deal_id AND version_no = NEW.released_by_version_no;
    IF v_vstatus IS DISTINCT FROM 'released' THEN RAISE EXCEPTION 'HOLD_RELEASE_BY_VERSION: v% of deal % is %', NEW.released_by_version_no, NEW.deal_id, coalesce(v_vstatus, 'missing'); END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. D-20 — deposit_amount is an administrative field after release (replaces 003's _apply_field; only the new branch differs)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iit._apply_field(p_deal uuid, p_field text, p_value jsonb, OUT table_name text, OUT record_id uuid, OUT before jsonb, OUT after jsonb)
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_vehicle uuid; v_text text; v_cnt int;
BEGIN
  v_text := CASE WHEN p_value IS NULL OR p_value = 'null'::jsonb THEN NULL ELSE p_value #>> '{}' END;
  SELECT vehicle_id INTO v_vehicle FROM iit.deals WHERE id = p_deal;
  CASE p_field
    WHEN 'purchase_price' THEN
      table_name := 'deals'; record_id := p_deal;
      SELECT pg_catalog.to_jsonb(purchase_price) INTO before FROM iit.deals WHERE id = p_deal;
      UPDATE iit.deals SET purchase_price = v_text::numeric WHERE id = p_deal RETURNING pg_catalog.to_jsonb(purchase_price) INTO after;
    WHEN 'deposit_amount' THEN                 -- D-20 (Rami, 26 Oct): administrative after release
      table_name := 'deals'; record_id := p_deal;
      SELECT pg_catalog.to_jsonb(deposit_amount) INTO before FROM iit.deals WHERE id = p_deal;
      UPDATE iit.deals SET deposit_amount = v_text::numeric WHERE id = p_deal RETURNING pg_catalog.to_jsonb(deposit_amount) INTO after;
    WHEN 'dealer_sold_to' THEN
      table_name := 'deals'; record_id := p_deal;
      SELECT pg_catalog.to_jsonb(dealer_sold_to) INTO before FROM iit.deals WHERE id = p_deal;
      UPDATE iit.deals SET dealer_sold_to = v_text WHERE id = p_deal RETURNING pg_catalog.to_jsonb(dealer_sold_to) INTO after;
    WHEN 'dealer_auction_name' THEN
      table_name := 'deals'; record_id := p_deal;
      SELECT pg_catalog.to_jsonb(dealer_auction_name) INTO before FROM iit.deals WHERE id = p_deal;
      UPDATE iit.deals SET dealer_auction_name = v_text WHERE id = p_deal RETURNING pg_catalog.to_jsonb(dealer_auction_name) INTO after;
    WHEN 'buyer_id' THEN
      table_name := 'deals'; record_id := p_deal;
      SELECT pg_catalog.to_jsonb(buyer_id) INTO before FROM iit.deals WHERE id = p_deal;
      UPDATE iit.deals SET buyer_id = v_text::uuid WHERE id = p_deal RETURNING pg_catalog.to_jsonb(buyer_id) INTO after;
    WHEN 'closer_id' THEN
      table_name := 'deals'; record_id := p_deal;
      SELECT pg_catalog.to_jsonb(closer_id) INTO before FROM iit.deals WHERE id = p_deal;
      UPDATE iit.deals SET closer_id = v_text::uuid WHERE id = p_deal RETURNING pg_catalog.to_jsonb(closer_id) INTO after;
    WHEN 'vin' THEN
      -- a Vehicle is one record per VIN (T1). Correcting the VIN of a vehicle that other live Deals also reference would change
      -- their VIN too; that is refused here (VIN_SHARED, D-22). A VIN already owned by another vehicle is refused (VIN_EXISTS).
      table_name := 'vehicles'; record_id := v_vehicle;
      SELECT count(*) INTO v_cnt FROM iit.deals x WHERE x.vehicle_id = v_vehicle AND x.id <> p_deal AND x.cancelled_at IS NULL;
      IF v_cnt > 0 THEN RAISE EXCEPTION 'VIN_SHARED: vehicle % is referenced by % other live deal(s); VIN correction refused', v_vehicle, v_cnt; END IF;
      IF v_text IS NULL OR pg_catalog.btrim(v_text) = '' THEN RAISE EXCEPTION 'FIELD_VALUE: vin cannot be empty'; END IF;
      IF EXISTS (SELECT 1 FROM iit.vehicles x WHERE x.vin_normalized = pg_catalog.upper(pg_catalog.btrim(v_text)) AND x.id <> v_vehicle) THEN
        RAISE EXCEPTION 'VIN_EXISTS: another vehicle already has VIN %', pg_catalog.upper(pg_catalog.btrim(v_text)) USING ERRCODE = '23505'; END IF;
      SELECT pg_catalog.to_jsonb(vin) INTO before FROM iit.vehicles WHERE id = v_vehicle;
      UPDATE iit.vehicles SET vin = v_text WHERE id = v_vehicle RETURNING pg_catalog.to_jsonb(vin) INTO after;
    WHEN 'year', 'make_text', 'model_text', 'series', 'exterior_color' THEN
      table_name := 'vehicles'; record_id := v_vehicle;
      EXECUTE pg_catalog.format('SELECT pg_catalog.to_jsonb(%I) FROM iit.vehicles WHERE id = $1', p_field) INTO before USING v_vehicle;
      IF p_field = 'year' THEN UPDATE iit.vehicles SET year = v_text::int WHERE id = v_vehicle;
      ELSE EXECUTE pg_catalog.format('UPDATE iit.vehicles SET %I = $1 WHERE id = $2', p_field) USING v_text, v_vehicle; END IF;
      EXECUTE pg_catalog.format('SELECT pg_catalog.to_jsonb(%I) FROM iit.vehicles WHERE id = $1', p_field) INTO after USING v_vehicle;
    WHEN 'title_state', 'is_tribal', 'custody', 'title_number', 'title_miles', 'brand' THEN
      table_name := 'deal_titles';
      INSERT INTO iit.deal_titles(deal_id) VALUES (p_deal) ON CONFLICT (deal_id) DO NOTHING;   -- the Deal's single title row
      SELECT id INTO record_id FROM iit.deal_titles WHERE deal_id = p_deal;
      EXECUTE pg_catalog.format('SELECT pg_catalog.to_jsonb(%I) FROM iit.deal_titles WHERE id = $1', p_field) INTO before USING record_id;
      CASE p_field
        WHEN 'is_tribal'   THEN UPDATE iit.deal_titles SET is_tribal = coalesce(v_text::boolean, false) WHERE id = record_id;
        WHEN 'title_miles' THEN UPDATE iit.deal_titles SET title_miles = v_text::int WHERE id = record_id;
        ELSE EXECUTE pg_catalog.format('UPDATE iit.deal_titles SET %I = $1 WHERE id = $2', p_field) USING v_text, record_id;
      END CASE;
      EXECUTE pg_catalog.format('SELECT pg_catalog.to_jsonb(%I) FROM iit.deal_titles WHERE id = $1', p_field) INTO after USING record_id;
    WHEN 'lien_position', 'lienholder', 'lienholder_name_raw', 'lienholder_phone', 'payoff_amount', 'payoff_good_through', 'per_diem' THEN
      table_name := 'deal_liens';
      INSERT INTO iit.deal_liens(deal_id) VALUES (p_deal) ON CONFLICT (deal_id) DO NOTHING;
      SELECT id INTO record_id FROM iit.deal_liens WHERE deal_id = p_deal;
      CASE p_field
        WHEN 'lien_position' THEN
          SELECT pg_catalog.to_jsonb(position) INTO before FROM iit.deal_liens WHERE id = record_id;
          UPDATE iit.deal_liens SET position = v_text WHERE id = record_id RETURNING pg_catalog.to_jsonb(position) INTO after;
        WHEN 'lienholder' THEN
          SELECT pg_catalog.to_jsonb(lienholder_org_id) INTO before FROM iit.deal_liens WHERE id = record_id;
          UPDATE iit.deal_liens SET lienholder_org_id = v_text::uuid WHERE id = record_id RETURNING pg_catalog.to_jsonb(lienholder_org_id) INTO after;
        WHEN 'payoff_amount', 'per_diem' THEN
          EXECUTE pg_catalog.format('SELECT pg_catalog.to_jsonb(%I) FROM iit.deal_liens WHERE id = $1', p_field) INTO before USING record_id;
          EXECUTE pg_catalog.format('UPDATE iit.deal_liens SET %I = $1::numeric WHERE id = $2', p_field) USING v_text, record_id;
          EXECUTE pg_catalog.format('SELECT pg_catalog.to_jsonb(%I) FROM iit.deal_liens WHERE id = $1', p_field) INTO after USING record_id;
        WHEN 'payoff_good_through' THEN
          SELECT pg_catalog.to_jsonb(payoff_good_through) INTO before FROM iit.deal_liens WHERE id = record_id;
          UPDATE iit.deal_liens SET payoff_good_through = v_text::date WHERE id = record_id RETURNING pg_catalog.to_jsonb(payoff_good_through) INTO after;
        ELSE
          EXECUTE pg_catalog.format('SELECT pg_catalog.to_jsonb(%I) FROM iit.deal_liens WHERE id = $1', p_field) INTO before USING record_id;
          EXECUTE pg_catalog.format('UPDATE iit.deal_liens SET %I = $1 WHERE id = $2', p_field) USING v_text, record_id;
          EXECUTE pg_catalog.format('SELECT pg_catalog.to_jsonb(%I) FROM iit.deal_liens WHERE id = $1', p_field) INTO after USING record_id;
      END CASE;
    ELSE
      RAISE EXCEPTION 'FIELD_UNSUPPORTED: % is not an editable field (seller parties: set_seller_party / correct_party / amend_party)', p_field;
  END CASE;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. material-correction machinery shared by correct_field (003) and correct_party (004): begin → caller applies → finish
-- ---------------------------------------------------------------------------------------------------------------------
-- begin: validates the Deal (caller holds the lock), opens draft N+1 if no material draft is open, returns the bookkeeping
CREATE FUNCTION iit._begin_material_correction(p_deal uuid, OUT rel int, OUT draft int, OUT new_draft boolean, OUT mark bigint)
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_cause text;
BEGIN
  rel := iit.latest_released_version(p_deal);
  IF rel IS NULL THEN RAISE EXCEPTION 'NOT_RELEASED: deal % has no released version; edit the draft through the intake functions', p_deal; END IF;
  draft := iit.open_draft_version(p_deal); new_draft := false;
  IF draft IS NOT NULL THEN
    SELECT cause INTO v_cause FROM iit.deal_versions WHERE deal_id = p_deal AND version_no = draft;
    IF v_cause <> 'material_correction' THEN RAISE EXCEPTION 'DRAFT_OPEN_NON_MATERIAL: deal % has an open % draft v%', p_deal, v_cause, draft; END IF;
  ELSE
    draft := rel + 1; new_draft := true;
    INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES (p_deal, draft, 'draft', 'material_correction');
  END IF;
  SELECT coalesce(max(id), 0) INTO mark FROM iit.record_history;
END $$;
-- finish: exact history ids supplied by the caller; recompute requirements; carry over only when the draft was opened now;
-- material_corrections row; hold covering the draft (002 open_hold); activity
CREATE FUNCTION iit._finish_material_correction(p_deal uuid, p_actor uuid, p_field text, p_history_ids bigint[], p_rel int, p_draft int, p_new_draft boolean, p_reason text) RETURNS uuid
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_corr uuid; v_hold uuid;
BEGIN
  IF p_history_ids IS NULL OR pg_catalog.cardinality(p_history_ids) = 0 THEN RAISE EXCEPTION 'HISTORY_MISSING: no history row recorded for %', p_field; END IF;
  PERFORM iit.compute_requirements(p_deal, p_draft);
  IF p_new_draft THEN PERFORM iit.carry_over_validations(p_deal, p_rel, p_draft, p_actor); END IF;
  INSERT INTO iit.material_corrections(deal_id, from_version_no, draft_version_no, fields, history_ids, by)
    VALUES (p_deal, p_rel, p_draft, ARRAY[p_field], p_history_ids, p_actor) RETURNING id INTO v_corr;
  v_hold := iit.open_hold(p_deal, 'material_correction', p_actor, v_corr, p_draft);
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, before, after, actor_id, actor_kind, source)
    VALUES (p_deal, 'material_correction', v_corr, 'field_corrected', pg_catalog.jsonb_build_object('field', p_field, 'from_version_no', p_rel),
            pg_catalog.jsonb_build_object('field', p_field, 'version_no', p_draft, 'reason', p_reason), p_actor, 'user', 'data_entry_ui');
  RETURN v_corr;
END $$;
-- correct_field (003) re-expressed on the shared machinery; behaviour unchanged (003 tests W4/W5/W7/W8 still pass)
CREATE OR REPLACE FUNCTION iit.correct_field(p_deal uuid, p_field text, p_value jsonb, p_reason text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; b record; w record; v_ids bigint[]; v_corr uuid;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF d.cancelled_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_CANCELLED: %', p_deal; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.material_fields WHERE field = p_field) THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'NOT_MATERIAL: % is not a material field (use amend_field)', p_field; END IF;
  IF p_field = 'seller_parties' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'CORRECTION_UNSUPPORTED: seller-party corrections go through correct_party'; END IF;
  IF p_reason IS NULL OR pg_catalog.btrim(p_reason) = '' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  BEGIN
    SELECT * INTO b FROM iit._begin_material_correction(p_deal);
    SELECT * INTO w FROM iit._apply_field(p_deal, p_field, p_value);
    IF w.before IS NOT DISTINCT FROM w.after THEN RAISE EXCEPTION 'NO_CHANGE: % already has that value', p_field; END IF;
    SELECT pg_catalog.array_agg(id ORDER BY id) INTO v_ids FROM iit.record_history WHERE id > b.mark AND table_name = w.table_name AND record_id = w.record_id;
    v_corr := iit._finish_material_correction(p_deal, v_actor, p_field, v_ids, b.rel, b.draft, b.new_draft, p_reason);
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_corr;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5. seller parties: validation, pre-release set, post-release material correction, administrative amendment
-- ---------------------------------------------------------------------------------------------------------------------
-- allowed keys of a party patch; identity keys are material (D21 owner/sellers), contact keys are administrative
CREATE FUNCTION iit._party_patch_check(p_party jsonb, OUT identity_keys text[], OUT contact_keys text[]) LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE k text;
BEGIN
  IF p_party IS NULL OR pg_catalog.jsonb_typeof(p_party) <> 'object' THEN RAISE EXCEPTION 'PARTY_PATCH: a JSON object is required'; END IF;
  identity_keys := '{}'; contact_keys := '{}';
  FOR k IN SELECT * FROM pg_catalog.jsonb_object_keys(p_party) LOOP
    IF k IN ('party_type','first_name','last_name','business_org_id') THEN identity_keys := identity_keys || k;
    ELSIF k IN ('phone','email','city','state') THEN contact_keys := contact_keys || k;
    ELSE RAISE EXCEPTION 'PARTY_PATCH: key % is not allowed (no street address — D14)', k; END IF;
  END LOOP;
END $$;
-- applies a patch to a seller_parties row (keys already validated); returns the row id
CREATE FUNCTION iit._apply_party_patch(p_party_id uuid, p_party jsonb) RETURNS uuid LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  UPDATE iit.seller_parties SET
    party_type      = CASE WHEN p_party ? 'party_type'      THEN p_party ->> 'party_type'              ELSE party_type END,
    first_name      = CASE WHEN p_party ? 'first_name'      THEN p_party ->> 'first_name'              ELSE first_name END,
    last_name       = CASE WHEN p_party ? 'last_name'       THEN p_party ->> 'last_name'               ELSE last_name END,
    business_org_id = CASE WHEN p_party ? 'business_org_id' THEN (p_party ->> 'business_org_id')::uuid ELSE business_org_id END,
    phone           = CASE WHEN p_party ? 'phone'           THEN p_party ->> 'phone'                   ELSE phone END,
    email           = CASE WHEN p_party ? 'email'           THEN p_party ->> 'email'                   ELSE email END,
    city            = CASE WHEN p_party ? 'city'            THEN p_party ->> 'city'                    ELSE city END,
    state           = CASE WHEN p_party ? 'state'           THEN p_party ->> 'state'                   ELSE state END
  WHERE id = p_party_id;
  RETURN p_party_id;
END $$;
-- set_seller_party (data_entry): PRE-RELEASE only — creates or replaces the party at (deal, role, ordinal) on the draft.
-- Once a version is released, identity changes go through correct_party and contact changes through amend_party.
CREATE FUNCTION iit.set_seller_party(p_deal uuid, p_role text, p_ordinal int, p_party jsonb, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; v_party uuid; v_link uuid; k record;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF d.cancelled_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_CANCELLED: %', p_deal; END IF;
  IF iit.latest_released_version(p_deal) IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'RELEASED_USE_CORRECTIONS: deal % is released; use correct_party / amend_party', p_deal; END IF;
  BEGIN
    SELECT * INTO k FROM iit._party_patch_check(p_party);
    IF NOT (p_party ? 'party_type') THEN RAISE EXCEPTION 'PARTY_PATCH: party_type is required'; END IF;
    SELECT party_id INTO v_party FROM iit.deal_parties WHERE deal_id = p_deal AND role = p_role AND ordinal = coalesce(p_ordinal, 1);
    IF v_party IS NULL THEN
      INSERT INTO iit.seller_parties(party_type) VALUES (p_party ->> 'party_type') RETURNING id INTO v_party;
      PERFORM iit._apply_party_patch(v_party, p_party);
      INSERT INTO iit.deal_parties(deal_id, party_id, role, ordinal) VALUES (p_deal, v_party, p_role, coalesce(p_ordinal, 1)) RETURNING id INTO v_link;
    ELSE
      PERFORM iit._apply_party_patch(v_party, p_party);
    END IF;
    IF iit.open_draft_version(p_deal) IS NOT NULL THEN PERFORM iit.compute_requirements(p_deal, iit.open_draft_version(p_deal)); END IF;   -- business seller changes the OPENCORPORATES key
    INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
      VALUES (p_deal, 'seller_party', v_party, 'party_set', pg_catalog.jsonb_build_object('party_role', p_role, 'party_id', v_party), v_actor, 'user', 'data_entry_ui');
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_party;
END $$;
-- correct_party (data_entry, §5.5 material: owner/sellers): post-release identity change (or a new party) → draft N+1 + hold.
-- A patch with contact keys only is refused (use amend_party). Contact keys may ride along with identity keys.
CREATE FUNCTION iit.correct_party(p_deal uuid, p_role text, p_ordinal int, p_party jsonb, p_reason text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; b record; k record; v_party uuid; v_link uuid; v_ids bigint[]; v_corr uuid; v_before jsonb; v_after jsonb;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF d.cancelled_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_CANCELLED: %', p_deal; END IF;
  IF p_reason IS NULL OR pg_catalog.btrim(p_reason) = '' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  BEGIN
    SELECT * INTO k FROM iit._party_patch_check(p_party);
    IF pg_catalog.cardinality(k.identity_keys) = 0 THEN RAISE EXCEPTION 'NOT_MATERIAL: the patch changes contact fields only (use amend_party)'; END IF;
    SELECT * INTO b FROM iit._begin_material_correction(p_deal);
    SELECT party_id INTO v_party FROM iit.deal_parties WHERE deal_id = p_deal AND role = p_role AND ordinal = coalesce(p_ordinal, 1);
    IF v_party IS NULL THEN
      IF NOT (p_party ? 'party_type') THEN RAISE EXCEPTION 'PARTY_PATCH: party_type is required for a new party'; END IF;
      INSERT INTO iit.seller_parties(party_type) VALUES (p_party ->> 'party_type') RETURNING id INTO v_party;
      PERFORM iit._apply_party_patch(v_party, p_party);
      INSERT INTO iit.deal_parties(deal_id, party_id, role, ordinal) VALUES (p_deal, v_party, p_role, coalesce(p_ordinal, 1)) RETURNING id INTO v_link;
    ELSE
      SELECT pg_catalog.to_jsonb(sp) INTO v_before FROM iit.seller_parties sp WHERE id = v_party;
      PERFORM iit._apply_party_patch(v_party, p_party);
      SELECT pg_catalog.to_jsonb(sp) INTO v_after FROM iit.seller_parties sp WHERE id = v_party;
      IF v_before = v_after THEN RAISE EXCEPTION 'NO_CHANGE: party already has those values'; END IF;
    END IF;
    SELECT pg_catalog.array_agg(id ORDER BY id) INTO v_ids FROM iit.record_history
     WHERE id > b.mark AND ((table_name = 'seller_parties' AND record_id = v_party) OR (table_name = 'deal_parties' AND record_id = v_link));
    v_corr := iit._finish_material_correction(p_deal, v_actor, 'seller_parties', v_ids, b.rel, b.draft, b.new_draft, p_reason);
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_corr;
END $$;
-- amend_party (data_entry): post-release CONTACT change on one of the Deal's parties; amendment on the latest released version.
CREATE FUNCTION iit.amend_party(p_deal uuid, p_party_id uuid, p_party jsonb, p_reason text, p_actor_base44_user_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; k record; v_rel int; v_no int; v_before jsonb; v_after jsonb; v_role text;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF d.cancelled_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_CANCELLED: %', p_deal; END IF;
  IF p_reason IS NULL OR pg_catalog.btrim(p_reason) = '' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  BEGIN
    SELECT * INTO k FROM iit._party_patch_check(p_party);
    IF pg_catalog.cardinality(k.identity_keys) > 0 THEN RAISE EXCEPTION 'MATERIAL_FIELD: % are identity fields (use correct_party)', pg_catalog.array_to_string(k.identity_keys, ','); END IF;
    IF pg_catalog.cardinality(k.contact_keys) = 0 THEN RAISE EXCEPTION 'PARTY_PATCH: nothing to amend'; END IF;
    v_rel := iit.latest_released_version(p_deal);
    IF v_rel IS NULL THEN RAISE EXCEPTION 'NOT_RELEASED: deal % has no released version; use set_seller_party', p_deal; END IF;
    SELECT role INTO v_role FROM iit.deal_parties WHERE deal_id = p_deal AND party_id = p_party_id ORDER BY ordinal LIMIT 1;
    IF v_role IS NULL THEN RAISE EXCEPTION 'PARTY_NOT_ON_DEAL: party % is not a party of deal %', p_party_id, p_deal; END IF;
    SELECT pg_catalog.jsonb_build_object('phone', phone, 'email', email, 'city', city, 'state', state) INTO v_before FROM iit.seller_parties WHERE id = p_party_id;
    PERFORM iit._apply_party_patch(p_party_id, p_party);
    SELECT pg_catalog.jsonb_build_object('phone', phone, 'email', email, 'city', city, 'state', state) INTO v_after FROM iit.seller_parties WHERE id = p_party_id;
    IF v_before = v_after THEN RAISE EXCEPTION 'NO_CHANGE: party already has those values'; END IF;
    SELECT coalesce(max(amendment_no), 0) + 1 INTO v_no FROM iit.deal_amendments WHERE deal_id = p_deal AND version_no = v_rel;
    INSERT INTO iit.deal_amendments(deal_id, version_no, amendment_no, field, before, after, by, reason)
      VALUES (p_deal, v_rel, v_no, 'party:' || v_role || ':' || p_party_id::text, v_before, v_after, v_actor, p_reason);
    INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
      VALUES (p_deal, 'deal_amendment', NULL, 'party_amended', pg_catalog.jsonb_build_object('party_id', p_party_id, 'version_no', v_rel, 'reason', p_reason), v_actor, 'user', 'data_entry_ui');
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_no;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 6. manual Deals and draft editing (pre-release)
-- ---------------------------------------------------------------------------------------------------------------------
-- vehicle lookup-or-create by normalized VIN (T1: one Vehicle per VIN)
CREATE FUNCTION iit._vehicle_for_vin(p_vin text, p_attrs jsonb DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  IF p_vin IS NULL OR pg_catalog.btrim(p_vin) = '' THEN RAISE EXCEPTION 'FIELD_VALUE: vin cannot be empty'; END IF;
  SELECT id INTO v_id FROM iit.vehicles WHERE vin_normalized = pg_catalog.upper(pg_catalog.btrim(p_vin));
  IF v_id IS NULL THEN
    INSERT INTO iit.vehicles(vin, year, make_text, model_text, series, exterior_color)
      VALUES (pg_catalog.btrim(p_vin), (p_attrs ->> 'year')::int, p_attrs ->> 'make', p_attrs ->> 'model', p_attrs ->> 'series', p_attrs ->> 'exterior_color')
      RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;
-- create_manual_deal (data_entry, G9/G11): a consignment or auction Deal with draft v1 and its Source set (D-9 rule via set_source_channel's statement)
CREATE FUNCTION iit.create_manual_deal(p_origin text, p_vin text, p_channel_name text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; v_vehicle uuid; v_deal uuid; ch record;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  BEGIN
    IF p_origin NOT IN ('manual_consignment','manual_exception') THEN RAISE EXCEPTION 'ORIGIN_INVALID: % (manual_consignment | manual_exception; vAuto deals are created by intake)', p_origin; END IF;
    SELECT * INTO ch FROM iit.source_channels WHERE name = p_channel_name AND active;
    IF ch IS NULL THEN RAISE EXCEPTION 'CHANNEL_UNKNOWN: %', p_channel_name; END IF;
    IF ch.origin <> p_origin THEN RAISE EXCEPTION 'CHANNEL_ORIGIN_MISMATCH: % is a % channel, deal origin is %', p_channel_name, ch.origin, p_origin; END IF;
    v_vehicle := iit._vehicle_for_vin(p_vin);
    INSERT INTO iit.deals(vehicle_id, origin, source_channel_id, consumer_route) VALUES (v_vehicle, p_origin, ch.id, ch.route) RETURNING id INTO v_deal;
    INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES (v_deal, 1, 'draft', 'intake');
    INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
      VALUES (v_deal, 'deal', v_deal, 'deal_created', pg_catalog.jsonb_build_object('origin', p_origin, 'channel', ch.name), v_actor, 'user', 'data_entry_ui');
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_deal;
END $$;
-- set_deal_fact (data_entry): PRE-RELEASE draft editing of any _apply_field field; requirements recomputed on the draft.
CREATE FUNCTION iit.set_deal_fact(p_deal uuid, p_field text, p_value jsonb, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; w record;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF d.cancelled_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_CANCELLED: %', p_deal; END IF;
  IF iit.latest_released_version(p_deal) IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'RELEASED_USE_CORRECTIONS: deal % is released; use correct_field / amend_field', p_deal; END IF;
  BEGIN
    SELECT * INTO w FROM iit._apply_field(p_deal, p_field, p_value);
    IF iit.open_draft_version(p_deal) IS NOT NULL THEN PERFORM iit.compute_requirements(p_deal, iit.open_draft_version(p_deal)); END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 7. vAuto intake (Worker, §5.3 rules) — one call per observation the Worker's discovery loop fetched (§5.10 polling excluded)
-- ---------------------------------------------------------------------------------------------------------------------
-- Creates the Deal's facts from an observation body (first completion / restart). Field names are the D-7 allowlist names.
-- purchase_price ← appraisal.value is an ASSUMPTION for the owner (D-29). Personnel are mapped through external_user_map;
-- an unmapped name opens a non-blocking flag. The Source is NOT set here (vAuto Source is not in the allowlist; Data Entry sets it).
CREATE FUNCTION iit._deal_from_observation(p_body jsonb, p_restarted_from uuid) RETURNS uuid LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_vehicle uuid; v_deal uuid; v_party uuid; v_buyer uuid; v_closer uuid; v_region text;
BEGIN
  v_vehicle := iit._vehicle_for_vin(p_body -> 'vehicle' ->> 'vin', p_body -> 'vehicle');
  SELECT user_id INTO v_buyer  FROM iit.external_user_map WHERE system = 'vauto' AND external_username = p_body -> 'personnel' ->> 'buyer';
  SELECT user_id INTO v_closer FROM iit.external_user_map WHERE system = 'vauto' AND external_username = p_body -> 'personnel' ->> 'closer';
  INSERT INTO iit.deals(vehicle_id, origin, purchase_price, buyer_id, closer_id, restarted_from_deal_id)
    VALUES (v_vehicle, 'vauto_intake', (p_body -> 'appraisal' ->> 'value')::numeric, v_buyer, v_closer, p_restarted_from) RETURNING id INTO v_deal;
  INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES (v_deal, 1, 'draft', 'intake');
  IF p_body ? 'customer' THEN
    INSERT INTO iit.seller_parties(party_type, first_name, last_name, phone, email, city, state)
      VALUES ('person', p_body -> 'customer' ->> 'first_name', p_body -> 'customer' ->> 'last_name', p_body -> 'customer' ->> 'phone', p_body -> 'customer' ->> 'email', p_body -> 'customer' ->> 'city', p_body -> 'customer' ->> 'state')
      RETURNING id INTO v_party;
    INSERT INTO iit.deal_parties(deal_id, party_id, role) VALUES (v_deal, v_party, 'owner');
  END IF;
  v_region := pg_catalog.upper(pg_catalog.btrim(coalesce(p_body -> 'title' ->> 'region', '')));
  INSERT INTO iit.deal_titles(deal_id, title_state) VALUES (v_deal, CASE WHEN v_region ~ '^[A-Z]{2}$' THEN v_region END);
  IF p_body ? 'lien' AND coalesce(p_body -> 'lien' ->> 'owner', '') <> '' THEN
    INSERT INTO iit.deal_liens(deal_id, position, lienholder_name_raw, lienholder_phone, payoff_amount, payoff_good_through, per_diem, source)
      VALUES (v_deal, 'lien', p_body -> 'lien' ->> 'owner', p_body -> 'lien' ->> 'phone', (p_body -> 'lien' ->> 'payoff')::numeric, (p_body -> 'lien' ->> 'payoff_date')::date, (p_body -> 'lien' ->> 'per_diem')::numeric, 'vauto');
  ELSE
    INSERT INTO iit.deal_liens(deal_id, source) VALUES (v_deal, 'vauto');            -- position unknown: Data Entry decides (required fact)
  END IF;
  IF p_body -> 'personnel' ->> 'buyer'  IS NOT NULL AND v_buyer  IS NULL THEN INSERT INTO iit.intake_flags(deal_id, code, detail) VALUES (v_deal, 'vauto_buyer_unmapped',  p_body -> 'personnel' ->> 'buyer'); END IF;
  IF p_body -> 'personnel' ->> 'closer' IS NOT NULL AND v_closer IS NULL THEN INSERT INTO iit.intake_flags(deal_id, code, detail) VALUES (v_deal, 'vauto_closer_unmapped', p_body -> 'personnel' ->> 'closer'); END IF;
  PERFORM iit.compute_requirements(v_deal, 1);
  RETURN v_deal;
END $$;
-- Change flags on the update path (intake step 6): the observation is compared with the Deal's current facts; a difference on a
-- fact Data Entry owns opens a BLOCKING flag (resolve or accept before release — D-28). One open flag per code.
CREATE FUNCTION iit._vauto_change_flags(p_deal uuid, p_body jsonb) RETURNS int LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE d record; v_owner record; n int := 0; v_code text; v_detail text; v_price numeric; v_vin text;
BEGIN
  SELECT dl.*, v.vin_normalized INTO d FROM iit.deals dl JOIN iit.vehicles v ON v.id = dl.vehicle_id WHERE dl.id = p_deal;
  SELECT sp.* INTO v_owner FROM iit.deal_parties dp JOIN iit.seller_parties sp ON sp.id = dp.party_id WHERE dp.deal_id = p_deal AND dp.role = 'owner' ORDER BY dp.ordinal LIMIT 1;
  v_price := (p_body -> 'appraisal' ->> 'value')::numeric;
  v_vin := pg_catalog.upper(pg_catalog.btrim(coalesce(p_body -> 'vehicle' ->> 'vin', '')));
  FOR v_code, v_detail IN
    SELECT * FROM (VALUES
      ('vauto_mismatch_price',    CASE WHEN v_price IS DISTINCT FROM d.purchase_price THEN pg_catalog.format('vauto=%s deal=%s', v_price, d.purchase_price) END),
      ('vauto_mismatch_vin',      CASE WHEN v_vin <> '' AND v_vin <> d.vin_normalized THEN pg_catalog.format('vauto=%s deal=%s', v_vin, d.vin_normalized) END),
      ('vauto_mismatch_customer', CASE WHEN v_owner.id IS NOT NULL AND (pg_catalog.regexp_replace(coalesce(p_body -> 'customer' ->> 'phone', ''), '[^0-9]', '', 'g') IS DISTINCT FROM v_owner.phone_normalized
                                                                  OR (p_body -> 'customer' ->> 'last_name') IS DISTINCT FROM v_owner.last_name) THEN 'customer phone or surname differs' END)
    ) AS x(code, detail) WHERE detail IS NOT NULL LOOP
    IF NOT EXISTS (SELECT 1 FROM iit.intake_flags WHERE deal_id = p_deal AND code = v_code AND status = 'open') THEN
      INSERT INTO iit.intake_flags(deal_id, code, detail, blocks_release) VALUES (p_deal, v_code, v_detail, true); n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;
-- ingest_vauto_observation (tav_worker, §5.3): stores the observation (unchanged content → nothing else happens, invariant 15)
-- and applies the intake rules for the appraisal's latest episode. Returns {observation_id, outcome, deal_id, action, flags}.
CREATE FUNCTION iit.ingest_vauto_observation(p_external_id text, p_account_context text, p_body jsonb, p_fetched_at timestamptz DEFAULT now()) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_prev iit.actor_ctx; v_ref uuid; v_obs uuid; v_hash text; v_completed boolean; ep record; prev record; v_deal uuid; v_action text := 'none'; n int := 0; v_item uuid; v_transition text;
BEGIN
  v_prev := iit.actor_push(iit.worker_user(), 'worker');
  BEGIN
    IF p_external_id IS NULL OR pg_catalog.btrim(p_external_id) = '' THEN RAISE EXCEPTION 'FIELD_VALUE: external_id required'; END IF;
    SELECT id INTO v_ref FROM iit.external_references WHERE system = 'vauto_appraisal' AND external_id = p_external_id AND account_context = coalesce(p_account_context, '');
    IF v_ref IS NULL THEN INSERT INTO iit.external_references(system, external_id, account_context) VALUES ('vauto_appraisal', p_external_id, coalesce(p_account_context, '')) RETURNING id INTO v_ref; END IF;
    -- serialize per appraisal: lock the Deal of the latest episode if any (intake rules read and write that Deal)
    SELECT * INTO ep FROM iit.appraisal_episodes WHERE appraisal_ref_id = v_ref ORDER BY episode_no DESC LIMIT 1;
    IF ep.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = ep.deal_id FOR UPDATE; END IF;
    SELECT * INTO prev FROM iit.vauto_observations WHERE appraisal_ref_id = v_ref ORDER BY seq DESC LIMIT 1;
    v_hash := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p_body::text, 'UTF8')), 'hex');
    v_completed := (p_body -> 'appraisal' ->> 'is_completed')::boolean;
    BEGIN
      INSERT INTO iit.vauto_observations(appraisal_ref_id, is_completed, last_modified, created_at_vauto, body, body_hash, fetched_at)
        VALUES (v_ref, v_completed, (p_body -> 'timestamps' ->> 'last_modified')::timestamptz, (p_body -> 'timestamps' ->> 'created')::timestamptz, p_body, v_hash, p_fetched_at)
        RETURNING id INTO v_obs;
    EXCEPTION WHEN unique_violation THEN                                                   -- UNCHANGED_OBSERVATION (001 dedupe trigger)
      PERFORM iit.actor_restore(v_prev);
      RETURN pg_catalog.jsonb_build_object('observation_id', prev.id, 'outcome', 'unchanged', 'deal_id', ep.deal_id, 'action', 'none', 'flags', 0);
    END;
    IF ep IS NULL THEN
      -- no reference/episode yet: a COMPLETED appraisal creates the Deal and episode 1; an incomplete one is only recorded
      IF coalesce(v_completed, false) THEN
        v_deal := iit._deal_from_observation(p_body, NULL);
        INSERT INTO iit.appraisal_episodes(appraisal_ref_id, deal_id, episode_no, start_basis) VALUES (v_ref, v_deal, 1, 'first_completion');
        INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
          VALUES (v_deal, 'deal', v_deal, 'deal_created', pg_catalog.jsonb_build_object('origin', 'vauto_intake', 'observation_id', v_obs, 'episode_no', 1), iit.worker_user(), 'worker', 'intake_worker');
        v_action := 'created';
      END IF;
    ELSIF ep.ended_at IS NULL THEN
      -- open episode: update path — change flags only
      v_deal := ep.deal_id;
      n := iit._vauto_change_flags(v_deal, p_body);
      v_action := 'updated';
    ELSE
      -- ended episode (cancelled/voided): nothing is created or reopened unless the observation shows a TRANSITION since ended_at
      v_deal := ep.deal_id;
      IF prev IS NULL THEN v_transition := 'first observation after the episode ended';
      ELSIF coalesce(prev.is_completed, false) = false AND coalesce(v_completed, false) AND p_fetched_at > ep.ended_at THEN v_transition := 'isCompleted false→true after ended_at';
      ELSIF p_fetched_at > ep.ended_at AND (
              (prev.body -> 'appraisal' ->> 'value') IS DISTINCT FROM (p_body -> 'appraisal' ->> 'value')
           OR (prev.body -> 'vehicle' ->> 'vin') IS DISTINCT FROM (p_body -> 'vehicle' ->> 'vin')
           OR (prev.body -> 'customer') IS DISTINCT FROM (p_body -> 'customer')
           OR (prev.body -> 'notes_sanitized') IS DISTINCT FROM (p_body -> 'notes_sanitized')) THEN v_transition := 'material content change after ended_at';
      END IF;
      IF v_transition IS NOT NULL THEN
        SELECT id INTO v_item FROM iit.work_items WHERE appraisal_ref_id = v_ref AND kind = 'restart_candidate' AND status = 'open';
        IF v_item IS NULL THEN
          INSERT INTO iit.work_items(kind, deal_id, appraisal_ref_id, assigned_role, detail)
            VALUES ('restart_candidate', v_deal, v_ref, 'data_entry', pg_catalog.jsonb_build_object('evidence', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('observation_id', v_obs, 'transition', v_transition))))
            RETURNING id INTO v_item;
        ELSE                                                                                -- one open task per appraisal: add the evidence only
          UPDATE iit.work_items SET detail = pg_catalog.jsonb_set(detail, '{evidence}', (detail -> 'evidence') || pg_catalog.jsonb_build_object('observation_id', v_obs, 'transition', v_transition)) WHERE id = v_item;
        END IF;
        v_action := 'restart_candidate';
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN pg_catalog.jsonb_build_object('observation_id', v_obs, 'outcome', 'stored', 'deal_id', v_deal, 'action', v_action, 'flags', n);
END $$;
-- resolve_restart (data_entry, §5.3): closes a restart_candidate task. 'restart_new_episode' creates the new Deal (facts from the
-- LATEST observation, restarted_from_deal_id set) and the next episode with basis data_entry_restart; 'no_restart' needs a reason.
CREATE FUNCTION iit.resolve_restart(p_item uuid, p_decision text, p_reason text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; w record; v_obs record; v_deal uuid; v_ep int;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  BEGIN
    IF p_decision NOT IN ('restart_new_episode','no_restart') THEN RAISE EXCEPTION 'RESTART_DECISION: % (restart_new_episode | no_restart)', p_decision; END IF;
    IF p_reason IS NULL OR pg_catalog.btrim(p_reason) = '' THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
    SELECT deal_id INTO w FROM iit.work_items WHERE id = p_item;
    IF NOT FOUND THEN RAISE EXCEPTION 'WORK_ITEM_UNKNOWN: %', p_item; END IF;
    IF w.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = w.deal_id FOR UPDATE; END IF;
    SELECT * INTO w FROM iit.work_items WHERE id = p_item FOR UPDATE;
    IF w.kind <> 'restart_candidate' THEN RAISE EXCEPTION 'WORK_ITEM_KIND: % is %, not restart_candidate (use resolve_work_item)', p_item, w.kind; END IF;
    IF w.status <> 'open' THEN RAISE EXCEPTION 'WORK_ITEM_NOT_OPEN: %', p_item; END IF;
    IF p_decision = 'restart_new_episode' THEN
      SELECT * INTO v_obs FROM iit.vauto_observations WHERE appraisal_ref_id = w.appraisal_ref_id ORDER BY seq DESC LIMIT 1;
      v_deal := iit._deal_from_observation(v_obs.body, w.deal_id);
      SELECT coalesce(max(episode_no), 0) + 1 INTO v_ep FROM iit.appraisal_episodes WHERE appraisal_ref_id = w.appraisal_ref_id;
      INSERT INTO iit.appraisal_episodes(appraisal_ref_id, deal_id, episode_no, started_by, start_basis) VALUES (w.appraisal_ref_id, v_deal, v_ep, v_actor, 'data_entry_restart');
      INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
        VALUES (v_deal, 'deal', v_deal, 'deal_created', pg_catalog.jsonb_build_object('origin', 'vauto_intake', 'restarted_from_deal_id', w.deal_id, 'episode_no', v_ep, 'reason', p_reason), v_actor, 'user', 'data_entry_ui');
    END IF;
    UPDATE iit.work_items SET status = 'closed', closed_by = v_actor, closed_at = now(), outcome = p_decision || ': ' || p_reason WHERE id = p_item AND status = 'open';
    INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
      VALUES (w.deal_id, 'work_item', p_item, 'work_item_closed', pg_catalog.jsonb_build_object('outcome', p_decision, 'reason', p_reason, 'deal_id', v_deal), v_actor, 'user', 'data_entry_ui');
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_deal;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 8. release_deal with the D-25a release path (replaces 003's; only the skip-audit block is new)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iit.release_deal(p_deal uuid, p_actor_base44_user_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; v_draft int; v_prev_rel int; v_missing text[]; v_snap jsonb; v_wm bigint; v_check uuid; h record;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  -- 1. intake status permits release
  IF d.cancelled_at IS NOT NULL OR d.intake_status = 'voided' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'RELEASE_REFUSED: deal % is cancelled or voided', p_deal; END IF;
  v_draft := iit.open_draft_version(p_deal);
  IF v_draft IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'RELEASE_REFUSED: deal % has no open draft', p_deal; END IF;
  -- 2. Source/channel set (and consistent with the origin) + 3. required facts (G13) — one list, so Data Entry sees everything at once
  v_missing := iit.missing_required_facts(p_deal);
  IF d.source_channel_id IS NULL AND NOT ('source_channel' = ANY (v_missing)) THEN v_missing := v_missing || 'source_channel'; END IF;
  IF pg_catalog.cardinality(v_missing) > 0 THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'RELEASE_REFUSED: missing required facts: %', pg_catalog.array_to_string(v_missing, ', '); END IF;
  IF d.consumer_route IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'RELEASE_REFUSED: consumer_route is not set for deal %', p_deal; END IF;
  -- 4. no open blocking flags
  IF EXISTS (SELECT 1 FROM iit.intake_flags f WHERE f.deal_id = p_deal AND f.status = 'open' AND f.blocks_release) THEN
    PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'RELEASE_REFUSED: deal % has open blocking flags', p_deal; END IF;
  -- 5. parser re-run pending: NOT CHECKED (no parser objects, D-19)
  -- 6. every requirement in the computed set is satisfied (§5.6) — recomputed from the current facts first
  PERFORM iit.compute_requirements(p_deal, v_draft);
  IF NOT iit.requirements_all_satisfied(p_deal, v_draft) THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'RELEASE_REFUSED: deal % v% has unsatisfied report requirements', p_deal, v_draft; END IF;
  -- freeze: snapshot of the current facts; watermark = last history row visible before the freeze (direct edits outside the
  -- Deal lock are not fenced by this — §2.5 risk, trusted not proven)
  v_snap := iit.build_deal_snapshot(p_deal, v_draft);
  SELECT max(id) INTO v_wm FROM iit.record_history;
  v_prev_rel := iit.latest_released_version(p_deal);
  UPDATE iit.deal_versions SET status = 'released', released_by = v_actor, released_at = now(), snapshot = v_snap, history_watermark = v_wm
   WHERE deal_id = p_deal AND version_no = v_draft AND status = 'draft';
  IF v_prev_rel IS NOT NULL THEN UPDATE iit.deal_versions SET status = 'superseded' WHERE deal_id = p_deal AND version_no = v_prev_rel; END IF;
  UPDATE iit.deals SET intake_status = 'released', current_version_no = v_draft WHERE id = p_deal;   -- caches (D-17 rule)
  IF d.consumer_route = 'risk_audit' THEN v_check := iit.create_audit_attempt(p_deal, v_actor); END IF;   -- binds holds covering v_draft (D-23)
  -- D-25 (Rami, 26 Oct, option a): on the skip-audit route a material-correction hold is released BY THE RELEASE of the version
  -- it covers (no attempt exists to decide it). Recorded as a 'released' event citing the version; the hold row cites it too.
  IF d.consumer_route = 'skip_audit' THEN
    FOR h IN SELECT id FROM iit.audit_holds WHERE deal_id = p_deal AND released_at IS NULL AND cause = 'material_correction' AND covers_version_no = v_draft LOOP
      UPDATE iit.audit_holds SET released_at = now(), released_by_version_no = v_draft WHERE id = h.id;
      INSERT INTO iit.audit_hold_events(hold_id, event, to_version_no, reason, by) VALUES (h.id, 'released', v_draft, 'skip-audit route: corrected version released (D-25a)', v_actor);
    END LOOP;
    UPDATE iit.deals SET on_hold = iit.deal_has_open_hold(p_deal) WHERE id = p_deal;
  END IF;
  -- §5.8: initial add_31_row delivery NOT queued (bridge excluded)
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (p_deal, 'deal_version', NULL, 'deal_released', pg_catalog.jsonb_build_object('version_no', v_draft, 'from_version_no', v_prev_rel), v_actor, 'user', 'data_entry_ui');
  PERFORM iit.actor_restore(v_prev);
  RETURN v_draft;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 9. grants and RLS: staff functions → iit_integration; the Worker function → tav_worker only; helpers owner-only
-- ---------------------------------------------------------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA iit FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  iit.set_seller_party(uuid,text,int,jsonb,text), iit.correct_party(uuid,text,int,jsonb,text,text), iit.amend_party(uuid,uuid,jsonb,text,text),
  iit.create_manual_deal(text,text,text,text), iit.set_deal_fact(uuid,text,jsonb,text), iit.resolve_restart(uuid,text,text,text),
  iit.correct_field(uuid,text,jsonb,text,text), iit.release_deal(uuid,text)
TO iit_integration;
GRANT EXECUTE ON FUNCTION iit.ingest_vauto_observation(text,text,jsonb,timestamptz) TO tav_worker;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA iit TO iit_integration;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA iit TO iit_integration;
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'iit' AND c.relkind = 'r' AND NOT c.relrowsecurity LOOP
    EXECUTE pg_catalog.format('ALTER TABLE iit.%I ENABLE ROW LEVEL SECURITY', r.relname);
  END LOOP; END $$;
RESET ROLE;
COMMIT;
