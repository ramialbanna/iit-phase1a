-- 002_reports_audit_holds.sql — report pack (§5.6), Risk Audit attempts/decisions (§5.7), audit holds with exact binding (§5.7a).
-- Depends on 001. EXCLUDED: release_deal / corrections / cancel (003, workflow); §6 gate incl. the §6.4 unfinished-action
-- sweep (open_hold states the dependency and does NOT stub it); §5.8 bridge (owner decision); storage bucket creation
-- (Supabase Storage is configured at application time — docs/migrations/002.md D-14).
BEGIN;
SET ROLE iit_owner;
SET search_path = pg_catalog;

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. report pack tables (§5.6)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.external_vehicle_reports (    -- IIT-owned; ERD name kept; holds organization reports too (G6)
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES iit.deals(id),
  subject_type text NOT NULL CHECK (subject_type IN ('vehicle','organization')),
  vehicle_id uuid NULL REFERENCES iit.vehicles(id),
  subject_org_id uuid NULL REFERENCES iit.organizations(id),
  report_type text NOT NULL CHECK (report_type IN ('ADD_BASIC','ADD_DETAILED','CARFAX','AUTOCHECK','VINAUDIT','FL_DMV','OK_DMV','OPENCORPORATES')),
  acquisition text NOT NULL CHECK (acquisition IN ('manual_upload','api_pull')),
  pulled_at timestamptz NOT NULL,              -- date pulled at the provider
  uploaded_by uuid REFERENCES iit.users(id),
  replaces_report_id uuid REFERENCES iit.external_vehicle_reports(id),
  object_path text UNIQUE,                     -- Storage object in the private bucket; set by begin_report_upload
  file_recorded_at timestamptz, file_bytes bigint, file_sha256 text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT report_exclusive_subject CHECK (
       (subject_type = 'vehicle'      AND vehicle_id IS NOT NULL AND subject_org_id IS NULL)
    OR (subject_type = 'organization' AND subject_org_id IS NOT NULL AND vehicle_id IS NULL)),
  CHECK (replaces_report_id IS NULL OR replaces_report_id <> id),
  CHECK ((file_recorded_at IS NULL) = (file_sha256 IS NULL))
);
CREATE UNIQUE INDEX reports_replaced_once ON iit.external_vehicle_reports (replaces_report_id) WHERE replaces_report_id IS NOT NULL;
SELECT iit.attach_history('iit.external_vehicle_reports');

-- requirement rules (reference data; G10: rules apply only to origin vauto_intake — data-driven per origin)
CREATE TABLE iit.report_requirement_rules (
  origin text NOT NULL CHECK (origin IN ('vauto_intake','manual_consignment','manual_exception')),
  report_type text NOT NULL,
  condition text NOT NULL CHECK (condition IN ('always','title_state_fl','title_state_ok_not_tribal','business_seller')),
  subject_type text NOT NULL CHECK (subject_type IN ('vehicle','organization')),
  active boolean NOT NULL DEFAULT true,
  PRIMARY KEY (origin, report_type)
);
SELECT iit.attach_history('iit.report_requirement_rules', 'origin,report_type', true);
-- Seeds: ONLY the conditional rules the design states (v0.1 §5.7 / T51). Which report types are 'always' required for vAuto
-- Deals is an owner decision (docs/migrations/002.md D-12); adding them is a data change, not a code change.
INSERT INTO iit.report_requirement_rules(origin, report_type, condition, subject_type) VALUES
  ('vauto_intake','FL_DMV','title_state_fl','vehicle'),
  ('vauto_intake','OK_DMV','title_state_ok_not_tribal','vehicle'),
  ('vauto_intake','OPENCORPORATES','business_seller','organization');

CREATE TABLE iit.deal_report_requirements (    -- derived for the DRAFT, frozen with it at release (§5.6)
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL, version_no int NOT NULL,
  requirement_key text NOT NULL,               -- '<report_type>:<subject>' — stable across versions when the subject is unchanged
  report_type text NOT NULL,
  subject_type text NOT NULL CHECK (subject_type IN ('vehicle','organization')),
  subject_vin text, subject_org_id uuid REFERENCES iit.organizations(id),
  freshness_baseline timestamptz NOT NULL,
  computed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (deal_id, version_no, requirement_key),
  FOREIGN KEY (deal_id, version_no) REFERENCES iit.deal_versions(deal_id, version_no),
  CHECK ((subject_type = 'vehicle') = (subject_vin IS NOT NULL)), CHECK ((subject_type = 'organization') = (subject_org_id IS NOT NULL))
);
SELECT iit.attach_history('iit.deal_report_requirements', 'id', true);   -- recomputation on a draft removes/adds rows; every change recorded
-- requirement rows may change only while their version is a DRAFT (Codex 002 finding 4); the composite FK gives ownership, this gives immutability
CREATE FUNCTION iit.requirements_frozen_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_status text; r record;
BEGIN
  r := CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
  SELECT status INTO v_status FROM iit.deal_versions WHERE deal_id = r.deal_id AND version_no = r.version_no;
  IF v_status IS DISTINCT FROM 'draft' THEN RAISE EXCEPTION 'REQUIREMENTS_FROZEN: % on v% of deal % (%)', TG_OP, r.version_no, r.deal_id, coalesce(v_status, 'no version'); END IF;
  IF TG_OP = 'UPDATE' AND (NEW.deal_id <> OLD.deal_id OR NEW.version_no <> OLD.version_no) THEN
    SELECT status INTO v_status FROM iit.deal_versions WHERE deal_id = NEW.deal_id AND version_no = NEW.version_no;
    IF v_status IS DISTINCT FROM 'draft' THEN RAISE EXCEPTION 'REQUIREMENTS_FROZEN: cannot move a requirement onto a non-draft version'; END IF;
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER requirements_frozen BEFORE INSERT OR UPDATE OR DELETE ON iit.deal_report_requirements FOR EACH ROW EXECUTE FUNCTION iit.requirements_frozen_guard();

CREATE TABLE iit.report_validations (          -- append-only; authoritative = highest id per (report, requirement_key, version)
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  report_id uuid NOT NULL REFERENCES iit.external_vehicle_reports(id),
  requirement_key text NOT NULL,
  deal_id uuid NOT NULL, version_no int NOT NULL,
  outcome text NOT NULL CHECK (outcome IN ('valid','rejected')),
  checks jsonb NOT NULL,                       -- allowlisted: subject_match, owned_by_deal, readable, complete, fresh
  reason text,
  validated_by uuid NOT NULL REFERENCES iit.users(id),
  at timestamptz NOT NULL DEFAULT now(),
  carried_from_validation_id bigint REFERENCES iit.report_validations(id),
  FOREIGN KEY (deal_id, version_no) REFERENCES iit.deal_versions(deal_id, version_no)
);
SELECT iit.make_append_only('iit.report_validations');
INSERT INTO iit.json_schemas(name, schema, note) VALUES
  ('report_validation_checks', '{"subject_match":true,"owned_by_deal":true,"readable":true,"complete":true,"fresh":true}', '§5.6 validation checks; booleans');
CREATE TRIGGER report_validations_policy BEFORE INSERT ON iit.report_validations FOR EACH ROW EXECUTE FUNCTION iit.enforce_json('checks', 'report_validation_checks');
-- activity detail keys written by THIS slice (decision, reason) — extending the allowlist is a reviewed change (history-covered row)
UPDATE iit.json_schemas SET schema = schema || '{"decision":true,"reason":true}'::jsonb, updated_at = now(), note = note || '; 002: decision, reason' WHERE name = 'activity_event_detail';

CREATE TABLE iit.report_waivers (              -- append-only; only the latest row per (deal, requirement_key, version) counts
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL, version_no int NOT NULL, requirement_key text NOT NULL,
  waived_by uuid NOT NULL REFERENCES iit.users(id), reason text NOT NULL, at timestamptz NOT NULL DEFAULT now(),
  seq bigint GENERATED ALWAYS AS IDENTITY,
  FOREIGN KEY (deal_id, version_no) REFERENCES iit.deal_versions(deal_id, version_no)
);
SELECT iit.make_append_only('iit.report_waivers');
CREATE TABLE iit.report_waiver_revocations (   -- append-only
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  waiver_id uuid NOT NULL REFERENCES iit.report_waivers(id),
  revoked_by uuid NOT NULL REFERENCES iit.users(id), reason text NOT NULL, at timestamptz NOT NULL DEFAULT now()
);
SELECT iit.make_append_only('iit.report_waiver_revocations');

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. Risk Audit (§5.7) and holds (§5.7a)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.prequalification_checks (     -- one row = one Risk Audit attempt (U3)
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES iit.deals(id),
  deal_version_no int NOT NULL,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','decided','superseded')),
  reopened_from_check_id uuid REFERENCES iit.prequalification_checks(id),
  opened_at timestamptz NOT NULL DEFAULT now(), opened_by uuid REFERENCES iit.users(id),
  FOREIGN KEY (deal_id, deal_version_no) REFERENCES iit.deal_versions(deal_id, version_no)
);
CREATE UNIQUE INDEX one_open_check_per_deal ON iit.prequalification_checks (deal_id) WHERE status = 'open';
-- exactly one CURRENT attempt (open or decided) per deal: a newer attempt supersedes every earlier one (Codex 002 finding 2)
CREATE UNIQUE INDEX one_current_check_per_deal ON iit.prequalification_checks (deal_id) WHERE status <> 'superseded';
ALTER TABLE iit.prequalification_checks ADD CONSTRAINT prequalification_checks_id_deal_version_uq UNIQUE (id, deal_id, deal_version_no);
SELECT iit.attach_history('iit.prequalification_checks');

CREATE TABLE iit.audit_decisions (             -- append-only (T49)
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  check_id uuid NOT NULL REFERENCES iit.prequalification_checks(id),
  decision text NOT NULL CHECK (decision IN ('pending','approved','changes_required','escalated','cancelled')),
  decided_by uuid NOT NULL REFERENCES iit.users(id), comments text, decided_at timestamptz NOT NULL DEFAULT now(),
  seq bigint GENERATED ALWAYS AS IDENTITY
);
SELECT iit.make_append_only('iit.audit_decisions');

ALTER TABLE iit.material_corrections ADD CONSTRAINT material_corrections_id_deal_draft_uq UNIQUE (id, deal_id, draft_version_no);
ALTER TABLE iit.audit_decisions ADD CONSTRAINT audit_decisions_id_check_uq UNIQUE (id, check_id);
CREATE TABLE iit.audit_holds (                 -- §5.7a DDL + released_at/by cache maintained only by record_decision
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES iit.deals(id),
  cause text NOT NULL CHECK (cause IN ('material_correction','reaudit_request','cancel','cutover_unresolved')),
  correction_id uuid REFERENCES iit.material_corrections(id),
  covers_version_no int,
  covering_check_id uuid REFERENCES iit.prequalification_checks(id),
  reconciliation_item_id uuid,                 -- FK arrives with the reconciliation slice
  opened_at timestamptz NOT NULL DEFAULT now(), opened_by uuid NOT NULL REFERENCES iit.users(id),
  released_at timestamptz, released_by_decision_id uuid REFERENCES iit.audit_decisions(id),
  CHECK (cause <> 'material_correction' OR (correction_id IS NOT NULL AND covers_version_no IS NOT NULL)),
  CHECK (cause <> 'cutover_unresolved' OR reconciliation_item_id IS NOT NULL),
  CHECK ((released_at IS NULL) = (released_by_decision_id IS NULL)),
  CHECK (cause <> 'cancel' OR released_at IS NULL),                     -- G12: a cancel hold is never released
  -- same-deal / same-version relationships (Codex 002 finding 5); NULLs (unbound holds) are allowed by MATCH SIMPLE
  CONSTRAINT audit_holds_correction_same_deal_fk FOREIGN KEY (correction_id, deal_id, covers_version_no) REFERENCES iit.material_corrections(id, deal_id, draft_version_no),
  CONSTRAINT audit_holds_check_same_deal_fk FOREIGN KEY (covering_check_id, deal_id, covers_version_no) REFERENCES iit.prequalification_checks(id, deal_id, deal_version_no),
  CONSTRAINT audit_holds_release_on_covering_check_fk FOREIGN KEY (released_by_decision_id, covering_check_id) REFERENCES iit.audit_decisions(id, check_id)
);
CREATE INDEX audit_holds_open_idx ON iit.audit_holds (deal_id) WHERE released_at IS NULL;
SELECT iit.attach_history('iit.audit_holds');
CREATE TABLE iit.audit_hold_events (           -- append-only: bound, rebound, released
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hold_id uuid NOT NULL REFERENCES iit.audit_holds(id),
  event text NOT NULL CHECK (event IN ('bound','rebound','released')),
  check_id uuid REFERENCES iit.prequalification_checks(id), decision_id uuid REFERENCES iit.audit_decisions(id),
  from_version_no int, to_version_no int,
  reason text NOT NULL, by uuid NOT NULL REFERENCES iit.users(id), at timestamptz NOT NULL DEFAULT now()
);
SELECT iit.make_append_only('iit.audit_hold_events');
-- released_at may only move NULL → value, exactly once
CREATE FUNCTION iit.audit_holds_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF OLD.released_at IS NOT NULL AND (NEW.released_at IS DISTINCT FROM OLD.released_at OR NEW.released_by_decision_id IS DISTINCT FROM OLD.released_by_decision_id) THEN
    RAISE EXCEPTION 'HOLD_RELEASE_IMMUTABLE: hold % was already released', OLD.id; END IF;
  IF NEW.deal_id <> OLD.deal_id OR NEW.cause <> OLD.cause OR NEW.correction_id IS DISTINCT FROM OLD.correction_id OR NEW.opened_at <> OLD.opened_at OR NEW.opened_by <> OLD.opened_by THEN
    RAISE EXCEPTION 'HOLD_IMMUTABLE: identity fields of hold % cannot change', OLD.id; END IF;
  -- a release must cite an APPROVED decision on exactly the covering check (the FK guarantees the check; this guarantees the value)
  IF NEW.released_by_decision_id IS NOT NULL AND OLD.released_by_decision_id IS NULL THEN
    IF NEW.covering_check_id IS NULL THEN RAISE EXCEPTION 'HOLD_RELEASE_UNBOUND: hold % has no covering check', OLD.id; END IF;
    IF NOT EXISTS (SELECT 1 FROM iit.audit_decisions d WHERE d.id = NEW.released_by_decision_id AND d.check_id = NEW.covering_check_id AND d.decision = 'approved') THEN
      RAISE EXCEPTION 'HOLD_RELEASE_INVALID: decision % is not an approved decision on covering check %', NEW.released_by_decision_id, NEW.covering_check_id; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER audit_holds_guard BEFORE UPDATE ON iit.audit_holds FOR EACH ROW EXECUTE FUNCTION iit.audit_holds_guard();

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. pure helpers (no actor): versions, requirements, satisfaction, eligibility
-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION iit.latest_released_version(p_deal uuid) RETURNS int LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT max(version_no) FROM iit.deal_versions WHERE deal_id = p_deal AND status = 'released' $$;
CREATE FUNCTION iit.open_draft_version(p_deal uuid) RETURNS int LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT version_no FROM iit.deal_versions WHERE deal_id = p_deal AND status = 'draft' $$;
CREATE FUNCTION iit.open_material_draft_exists(p_deal uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM iit.deal_versions WHERE deal_id = p_deal AND status = 'draft' AND cause = 'material_correction') $$;
CREATE FUNCTION iit.deal_has_open_hold(p_deal uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM iit.audit_holds WHERE deal_id = p_deal AND released_at IS NULL) $$;

-- compute the requirement set for a DRAFT version from the rules and the Deal's current facts (§5.6; G10 by origin).
-- Returns the number of requirement rows now on the draft. Called by workflow functions (003) under the Deal lock.
CREATE FUNCTION iit.compute_requirements(p_deal uuid, p_version int) RETURNS int LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_origin text; v_vin text; v_state text; v_tribal boolean; v_org uuid; v_baseline timestamptz; v_status text; n int;
BEGIN
  SELECT status INTO v_status FROM iit.deal_versions WHERE deal_id = p_deal AND version_no = p_version;
  IF v_status IS DISTINCT FROM 'draft' THEN RAISE EXCEPTION 'REQUIREMENTS_FROZEN: version % of deal % is %', p_version, p_deal, coalesce(v_status,'missing'); END IF;
  SELECT d.origin, v.vin_normalized INTO v_origin, v_vin FROM iit.deals d JOIN iit.vehicles v ON v.id = d.vehicle_id WHERE d.id = p_deal;
  SELECT t.title_state, t.is_tribal INTO v_state, v_tribal FROM iit.deal_titles t WHERE t.deal_id = p_deal;
  SELECT sp.business_org_id INTO v_org FROM iit.deal_parties dp JOIN iit.seller_parties sp ON sp.id = dp.party_id WHERE dp.deal_id = p_deal AND dp.role = 'business_seller' ORDER BY dp.ordinal LIMIT 1;
  -- freshness baseline: appraisal 'created' for vAuto Deals (latest observation), else the Deal's creation (D25)
  SELECT max(o.created_at_vauto) INTO v_baseline FROM iit.vauto_observations o JOIN iit.appraisal_episodes e ON e.appraisal_ref_id = o.appraisal_ref_id WHERE e.deal_id = p_deal;
  IF v_baseline IS NULL THEN SELECT created_at INTO v_baseline FROM iit.deals WHERE id = p_deal; END IF;
  DELETE FROM iit.deal_report_requirements WHERE deal_id = p_deal AND version_no = p_version;   -- recompute (recorded as D history)
  INSERT INTO iit.deal_report_requirements(deal_id, version_no, requirement_key, report_type, subject_type, subject_vin, subject_org_id, freshness_baseline)
  SELECT p_deal, p_version,
         r.report_type || ':' || CASE r.subject_type WHEN 'vehicle' THEN v_vin ELSE v_org::text END,
         r.report_type, r.subject_type, CASE WHEN r.subject_type = 'vehicle' THEN v_vin END, CASE WHEN r.subject_type = 'organization' THEN v_org END, v_baseline
    FROM iit.report_requirement_rules r
   WHERE r.active AND r.origin = v_origin
     AND CASE r.condition
           WHEN 'always' THEN true
           WHEN 'title_state_fl' THEN v_state = 'FL'
           WHEN 'title_state_ok_not_tribal' THEN v_state = 'OK' AND NOT coalesce(v_tribal, false)
           WHEN 'business_seller' THEN v_org IS NOT NULL
         END
     AND (r.subject_type <> 'organization' OR v_org IS NOT NULL);
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $$;

-- authoritative validation for (report, requirement_key, version): highest id
CREATE FUNCTION iit.authoritative_validation(p_report uuid, p_key text, p_version int) RETURNS text LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT outcome FROM iit.report_validations WHERE report_id = p_report AND requirement_key = p_key AND version_no = p_version ORDER BY id DESC LIMIT 1 $$;

-- §5.6 "When a requirement R on version N is satisfied": by a report (owned, not replaced, subject equal, fresh, authoritative valid) or by an unrevoked latest waiver
CREATE FUNCTION iit.requirement_satisfied(p_deal uuid, p_version int, p_key text) RETURNS boolean LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE r record; w record;
BEGIN
  SELECT * INTO r FROM iit.deal_report_requirements WHERE deal_id = p_deal AND version_no = p_version AND requirement_key = p_key;
  IF r IS NULL THEN RAISE EXCEPTION 'REQUIREMENT_UNKNOWN: % on % v%', p_key, p_deal, p_version; END IF;
  IF EXISTS (
    SELECT 1 FROM iit.external_vehicle_reports rep
     LEFT JOIN iit.vehicles v ON v.id = rep.vehicle_id
     WHERE rep.deal_id = p_deal
       AND rep.report_type = r.report_type                                                                       -- qualification (Codex 002 finding 3)
       AND (rep.acquisition <> 'manual_upload' OR rep.file_recorded_at IS NOT NULL)                              -- an unfinished upload is not a report
       AND NOT EXISTS (SELECT 1 FROM iit.external_vehicle_reports x WHERE x.replaces_report_id = rep.id)        -- not replaced
       AND rep.subject_type = r.subject_type
       AND ((r.subject_type = 'vehicle' AND v.vin_normalized = r.subject_vin) OR (r.subject_type = 'organization' AND rep.subject_org_id = r.subject_org_id))
       AND rep.pulled_at >= r.freshness_baseline
       AND iit.authoritative_validation(rep.id, p_key, p_version) = 'valid') THEN RETURN true; END IF;
  SELECT * INTO w FROM iit.report_waivers WHERE deal_id = p_deal AND version_no = p_version AND requirement_key = p_key ORDER BY seq DESC LIMIT 1;
  IF w IS NOT NULL AND NOT EXISTS (SELECT 1 FROM iit.report_waiver_revocations WHERE waiver_id = w.id) THEN RETURN true; END IF;
  RETURN false;
END $$;
CREATE FUNCTION iit.requirements_all_satisfied(p_deal uuid, p_version int) RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT NOT EXISTS (SELECT 1 FROM iit.deal_report_requirements q WHERE q.deal_id = p_deal AND q.version_no = p_version AND NOT iit.requirement_satisfied(p_deal, p_version, q.requirement_key)) $$;

-- §5.5 approval eligibility: THE current attempt (the single non-superseded check) is for the latest released version, its latest
-- decision is 'approved', and no material draft is open. A newer attempt supersedes any earlier approval (Codex 002 finding 2).
CREATE FUNCTION iit.current_attempt(p_deal uuid) RETURNS uuid LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT id FROM iit.prequalification_checks WHERE deal_id = p_deal AND status <> 'superseded' $$;
CREATE FUNCTION iit.approval_eligible(p_deal uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce((
    SELECT c.deal_version_no = iit.latest_released_version(p_deal)
       AND (SELECT d.decision FROM iit.audit_decisions d WHERE d.check_id = c.id ORDER BY d.seq DESC LIMIT 1) = 'approved'
      FROM iit.prequalification_checks c WHERE c.id = iit.current_attempt(p_deal)), false)
  AND NOT iit.open_material_draft_exists(p_deal) $$;

-- carry-over of authoritative valid validations from version N to draft N+1 (§5.6): same key, same subject, still fresh; never creates requirements
CREATE FUNCTION iit.carry_over_validations(p_deal uuid, p_from int, p_to int, p_actor uuid) RETURNS int LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE n int;
BEGIN
  INSERT INTO iit.report_validations(report_id, requirement_key, deal_id, version_no, outcome, checks, reason, validated_by, carried_from_validation_id)
  SELECT v.report_id, v.requirement_key, p_deal, p_to, 'valid', v.checks, 'carried over from v' || p_from, p_actor, v.id
    FROM iit.report_validations v
    JOIN iit.deal_report_requirements qn ON qn.deal_id = p_deal AND qn.version_no = p_to AND qn.requirement_key = v.requirement_key
    JOIN iit.deal_report_requirements qo ON qo.deal_id = p_deal AND qo.version_no = p_from AND qo.requirement_key = v.requirement_key
    JOIN iit.external_vehicle_reports rep ON rep.id = v.report_id
   WHERE v.deal_id = p_deal AND v.version_no = p_from
     AND v.id = (SELECT max(id) FROM iit.report_validations x WHERE x.report_id = v.report_id AND x.requirement_key = v.requirement_key AND x.version_no = p_from)
     AND v.outcome = 'valid'
     AND qn.subject_type = qo.subject_type AND qn.subject_vin IS NOT DISTINCT FROM qo.subject_vin AND qn.subject_org_id IS NOT DISTINCT FROM qo.subject_org_id
     AND rep.pulled_at >= qn.freshness_baseline;
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. holds: open / bind / release (internal helpers with a resolved actor; run under the caller's pushed context)
-- ---------------------------------------------------------------------------------------------------------------------
-- open_hold: Deal row locked FOR UPDATE (§6.1 serialization). DEPENDENCY (§6.4): the sweep of unfinished gated actions
-- belongs here and will be added by the gate migration when gated_actions exists; until then nothing is swept and this
-- function documents that gap rather than emulating it.
CREATE FUNCTION iit.open_hold(p_deal uuid, p_cause text, p_actor uuid, p_correction uuid DEFAULT NULL, p_covers_version int DEFAULT NULL, p_reconciliation_item uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_hold uuid;
BEGIN
  PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  INSERT INTO iit.audit_holds(deal_id, cause, correction_id, covers_version_no, reconciliation_item_id, opened_by)
    VALUES (p_deal, p_cause, p_correction, p_covers_version, p_reconciliation_item, p_actor) RETURNING id INTO v_hold;
  UPDATE iit.deals SET on_hold = true, gate_clear = false WHERE id = p_deal;      -- caches
  -- §6.4 sweep: NOT IMPLEMENTED HERE (gated_actions arrives with the gate migration)
  RETURN v_hold;
END $$;

-- create_audit_attempt: opens the attempt for the latest released version; supersedes an open attempt; binds every hold
-- whose covers_version_no equals that version ('bound' event, covering_check_id set) — §5.7a binding (G4)
CREATE FUNCTION iit.create_audit_attempt(p_deal uuid, p_actor uuid, p_reopened_from uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_ver int; v_check uuid; h record;
BEGIN
  PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;
  v_ver := iit.latest_released_version(p_deal);
  IF v_ver IS NULL THEN RAISE EXCEPTION 'NO_RELEASED_VERSION: deal % has no released version to audit', p_deal; END IF;
  UPDATE iit.prequalification_checks SET status = 'superseded' WHERE deal_id = p_deal AND status <> 'superseded';   -- the new attempt is the only current one
  INSERT INTO iit.prequalification_checks(deal_id, deal_version_no, opened_by, reopened_from_check_id) VALUES (p_deal, v_ver, p_actor, p_reopened_from) RETURNING id INTO v_check;
  UPDATE iit.deals SET audit_status = 'pending' WHERE id = p_deal AND consumer_route = 'risk_audit';
  FOR h IN SELECT id FROM iit.audit_holds WHERE deal_id = p_deal AND released_at IS NULL AND covers_version_no = v_ver AND cause IN ('material_correction','reaudit_request') LOOP
    UPDATE iit.audit_holds SET covering_check_id = v_check WHERE id = h.id;
    INSERT INTO iit.audit_hold_events(hold_id, event, check_id, to_version_no, reason, by) VALUES (h.id, 'bound', v_check, v_ver, 'attempt created for covering version', p_actor);
  END LOOP;
  RETURN v_check;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5. staff-facing functions (§2.2): require_role → push → work under the Deal lock → restore
-- ---------------------------------------------------------------------------------------------------------------------
-- record_decision (§5.7): rejects if the attempt is superseded, or its version is not the latest released, or a material draft is open.
-- On 'approved': releases every open hold whose covering_check_id is EXACTLY this check (G4) and refreshes caches.
CREATE FUNCTION iit.record_decision(p_check_id uuid, p_decision text, p_comments text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; c record; v_dec uuid; h record; v_deal uuid;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'auditor');
  v_prev := iit.actor_push(v_actor, 'user');
  -- the first lookup only identifies the Deal; the check is RELOADED after the lock (Codex 002 finding 1)
  SELECT deal_id INTO v_deal FROM iit.prequalification_checks WHERE id = p_check_id;
  IF v_deal IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'CHECK_UNKNOWN: %', p_check_id; END IF;
  PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
  SELECT * INTO c FROM iit.prequalification_checks WHERE id = p_check_id;
  IF c.status = 'superseded' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DECISION_REJECTED: attempt % is superseded', p_check_id; END IF;
  IF c.deal_version_no IS DISTINCT FROM iit.latest_released_version(c.deal_id) THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DECISION_REJECTED: attempt % is for v%, latest released is v%', p_check_id, c.deal_version_no, iit.latest_released_version(c.deal_id); END IF;
  IF iit.open_material_draft_exists(c.deal_id) THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DECISION_REJECTED: deal % has an open material draft', c.deal_id; END IF;
  INSERT INTO iit.audit_decisions(check_id, decision, decided_by, comments) VALUES (p_check_id, p_decision, v_actor, p_comments) RETURNING id INTO v_dec;
  UPDATE iit.prequalification_checks SET status = CASE WHEN p_decision = 'pending' THEN 'open' ELSE 'decided' END WHERE id = p_check_id;
  UPDATE iit.deals SET audit_status = p_decision WHERE id = c.deal_id;
  IF p_decision = 'approved' THEN
    FOR h IN SELECT id FROM iit.audit_holds WHERE deal_id = c.deal_id AND released_at IS NULL AND covering_check_id = p_check_id AND cause <> 'cancel' LOOP
      UPDATE iit.audit_holds SET released_at = now(), released_by_decision_id = v_dec WHERE id = h.id;
      INSERT INTO iit.audit_hold_events(hold_id, event, check_id, decision_id, reason, by) VALUES (h.id, 'released', p_check_id, v_dec, 'approved decision on the covering attempt', v_actor);
    END LOOP;
    UPDATE iit.deals SET on_hold = iit.deal_has_open_hold(c.deal_id) WHERE id = c.deal_id;
  END IF;
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (c.deal_id, 'prequalification_check', p_check_id, 'decision_recorded', pg_catalog.jsonb_build_object('decision', p_decision), v_actor, 'user', 'audit_ui');
  PERFORM iit.actor_restore(v_prev);
  RETURN v_dec;
END $$;

-- request_reaudit (audit_lead): opens a 'reaudit_request' hold bound to a fresh attempt on the latest released version
CREATE FUNCTION iit.request_reaudit(p_deal uuid, p_reason text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; v_hold uuid; v_check uuid; v_ver int;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'audit_lead');
  v_prev := iit.actor_push(v_actor, 'user');
  PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;                 -- lock first, then read the covering version (finding 1)
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  v_ver := iit.latest_released_version(p_deal);
  IF v_ver IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'NO_RELEASED_VERSION: %', p_deal; END IF;
  v_hold := iit.open_hold(p_deal, 'reaudit_request', v_actor, NULL, v_ver);
  v_check := iit.create_audit_attempt(p_deal, v_actor);
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (p_deal, 'audit_hold', v_hold, 'reaudit_requested', pg_catalog.jsonb_build_object('reason', p_reason), v_actor, 'user', 'audit_ui');
  PERFORM iit.actor_restore(v_prev);
  RETURN v_hold;
END $$;

-- validate_report (data_entry): appends an authoritative validation for (report, requirement, CURRENT DRAFT). Deal lock taken.
CREATE FUNCTION iit.validate_report(p_report uuid, p_requirement_key text, p_outcome text, p_checks jsonb, p_reason text, p_actor_base44_user_id text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; v_deal uuid; v_ver int; v_id bigint;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT deal_id INTO v_deal FROM iit.external_vehicle_reports WHERE id = p_report;
  IF v_deal IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REPORT_UNKNOWN: %', p_report; END IF;
  PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
  IF EXISTS (SELECT 1 FROM iit.external_vehicle_reports WHERE id = p_report AND acquisition = 'manual_upload' AND file_recorded_at IS NULL) THEN
    PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REPORT_FILE_UNAVAILABLE: % has no recorded file; validate after finish_report_upload', p_report; END IF;
  v_ver := iit.open_draft_version(v_deal);
  IF v_ver IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'NO_DRAFT: validations attach to the open draft; deal % has none', v_deal; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.deal_report_requirements WHERE deal_id = v_deal AND version_no = v_ver AND requirement_key = p_requirement_key) THEN
    PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REQUIREMENT_UNKNOWN: % on draft v% of %', p_requirement_key, v_ver, v_deal; END IF;
  INSERT INTO iit.report_validations(report_id, requirement_key, deal_id, version_no, outcome, checks, reason, validated_by)
    VALUES (p_report, p_requirement_key, v_deal, v_ver, p_outcome, p_checks, p_reason, v_actor) RETURNING id INTO v_id;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_id;
END $$;

-- waive_report / revoke_waiver (audit_lead; D25)
CREATE FUNCTION iit.waive_report(p_deal uuid, p_requirement_key text, p_reason text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; v_ver int; v_id uuid;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'audit_lead');
  v_prev := iit.actor_push(v_actor, 'user');
  PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;
  v_ver := iit.open_draft_version(p_deal);
  IF v_ver IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'NO_DRAFT: waivers attach to the open draft; deal % has none', p_deal; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.deal_report_requirements WHERE deal_id = p_deal AND version_no = v_ver AND requirement_key = p_requirement_key) THEN
    PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REQUIREMENT_UNKNOWN: % on draft v% of %', p_requirement_key, v_ver, p_deal; END IF;
  INSERT INTO iit.report_waivers(deal_id, version_no, requirement_key, waived_by, reason) VALUES (p_deal, v_ver, p_requirement_key, v_actor, p_reason) RETURNING id INTO v_id;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_id;
END $$;
CREATE FUNCTION iit.revoke_waiver(p_waiver uuid, p_reason text, p_actor_base44_user_id text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; v_deal uuid; v_id bigint;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'audit_lead');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT deal_id INTO v_deal FROM iit.report_waivers WHERE id = p_waiver;
  IF v_deal IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'WAIVER_UNKNOWN: %', p_waiver; END IF;
  PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
  INSERT INTO iit.report_waiver_revocations(waiver_id, revoked_by, reason) VALUES (p_waiver, v_actor, p_reason) RETURNING id INTO v_id;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_id;
END $$;

-- report upload / access (§2.3): the bucket 'report-files' is private; paths are deal-scoped; the Base44 backend does the transfer
CREATE FUNCTION iit.begin_report_upload(p_deal uuid, p_report_type text, p_subject_type text, p_vehicle uuid, p_subject_org uuid, p_acquisition text, p_pulled_at timestamptz, p_replaces uuid, p_actor_base44_user_id text)
RETURNS TABLE (report_id uuid, object_path text) LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; v_id uuid; v_path text;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF p_replaces IS NOT NULL AND NOT EXISTS (SELECT 1 FROM iit.external_vehicle_reports WHERE id = p_replaces AND deal_id = p_deal) THEN
    PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REPLACES_OTHER_DEAL: % is not a report of deal %', p_replaces, p_deal; END IF;
  v_id := gen_random_uuid(); v_path := 'report-files/' || p_deal::text || '/' || v_id::text;
  INSERT INTO iit.external_vehicle_reports(id, deal_id, subject_type, vehicle_id, subject_org_id, report_type, acquisition, pulled_at, uploaded_by, replaces_report_id, object_path)
    VALUES (v_id, p_deal, p_subject_type, p_vehicle, p_subject_org, p_report_type, p_acquisition, p_pulled_at, v_actor, p_replaces, v_path);
  PERFORM iit.actor_restore(v_prev);
  RETURN QUERY SELECT v_id, v_path;
END $$;
CREATE FUNCTION iit.finish_report_upload(p_report uuid, p_bytes bigint, p_sha256 text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  UPDATE iit.external_vehicle_reports SET file_recorded_at = now(), file_bytes = p_bytes, file_sha256 = p_sha256 WHERE id = p_report AND file_recorded_at IS NULL;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REPORT_UNKNOWN_OR_ALREADY_RECORDED: %', p_report; END IF;
  PERFORM iit.actor_restore(v_prev);
END $$;
CREATE FUNCTION iit.authorize_report_access(p_report uuid, p_actor_base44_user_id text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE v_path text; v_ok boolean := false;
BEGIN
  -- any of the staff roles that work with reports; writes nothing
  BEGIN PERFORM iit.require_role(p_actor_base44_user_id, 'data_entry'); v_ok := true; EXCEPTION WHEN OTHERS THEN NULL; END;
  IF NOT v_ok THEN BEGIN PERFORM iit.require_role(p_actor_base44_user_id, 'auditor'); v_ok := true; EXCEPTION WHEN OTHERS THEN NULL; END; END IF;
  IF NOT v_ok THEN BEGIN PERFORM iit.require_role(p_actor_base44_user_id, 'audit_lead'); v_ok := true; EXCEPTION WHEN OTHERS THEN NULL; END; END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'ROLE_MISSING: report access' USING ERRCODE = '42501'; END IF;
  SELECT object_path INTO v_path FROM iit.external_vehicle_reports WHERE id = p_report AND file_recorded_at IS NOT NULL;
  IF v_path IS NULL THEN RAISE EXCEPTION 'REPORT_FILE_UNAVAILABLE: %', p_report; END IF;
  RETURN v_path;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 6. grants and RLS
-- ---------------------------------------------------------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA iit FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  iit.record_decision(uuid,text,text,text), iit.request_reaudit(uuid,text,text),
  iit.validate_report(uuid,text,text,jsonb,text,text), iit.waive_report(uuid,text,text,text), iit.revoke_waiver(uuid,text,text),
  iit.begin_report_upload(uuid,text,text,uuid,uuid,text,timestamptz,uuid,text), iit.finish_report_upload(uuid,bigint,text,text),
  iit.authorize_report_access(uuid,text)
TO iit_integration;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA iit TO iit_integration;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA iit TO iit_integration;
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'iit' AND c.relkind = 'r' AND NOT c.relrowsecurity LOOP
    EXECUTE pg_catalog.format('ALTER TABLE iit.%I ENABLE ROW LEVEL SECURITY', r.relname);
  END LOOP; END $$;
RESET ROLE;
COMMIT;
