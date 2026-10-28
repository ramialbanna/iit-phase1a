-- 005_gate.sql — §6 AppSheet gate: authorization consumed at execution (authorize_and_consume), outcome reporting
-- (report_action_outcome), attempt timeout (expire_stale_attempts), Data Entry resolution of unknown outcomes, the §6.4
-- unfinished-action sweep in open_hold (the dependency 002 named), tav_worker grants; plus D-32 (title-region flag) and
-- D-30 (consignment function). Depends on 001–004.
-- EXCLUDED and named: the Worker itself (credential verification of each integration, the 3.1 Deal Status read, the
-- `Audit Gate` display table push) — the Worker passes the verified caller_integration and the 3.1 read result into these
-- functions; same-run replay (§6.2: disabled until an enforceable single-execution mechanism is proven — nothing here
-- enables it); the proven-idempotent target list (seeded EMPTY, D-36); §5.8 bridge; polling; lienholder sync.
BEGIN;
SET ROLE iit_owner;
SET search_path = pg_catalog;

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. reference data and settings
-- ---------------------------------------------------------------------------------------------------------------------
-- 3.1 Deal Status vocabulary for the gate (§6.3 "an inactive status is denied"). UNKNOWN statuses are denied too (fail closed);
-- the owner completes the list (D-34). Values are the 3.1 texts as read back in S2.
CREATE TABLE iit.legacy_31_statuses (
  status text PRIMARY KEY, active boolean NOT NULL, note text NOT NULL
);
INSERT INTO iit.legacy_31_statuses VALUES
  ('In-Progress', true, 'S2 read-back'), ('Same Day Deal', true, 'S2 read-back'),
  ('Rescheduled', false, '§6.3'), ('Canceled', false, '§6.3'), ('Canceled In Scheduling', false, '§6.3');
SELECT iit.attach_history('iit.legacy_31_statuses', 'status', true);
-- Which authenticated integration may perform which action (§6.2 caller identity + Codex 005 P1: the first caller must be
-- proven eligible for the action, not merely authenticated). SEEDED EMPTY (D-40): the owner's S2 inventory (each AppSheet app and
-- each Zap, and the action it performs) fills it; until then every authorize call is denied integration_not_allowed.
CREATE TABLE iit.gate_integration_actions (
  caller_integration text NOT NULL, action text NOT NULL, note text NOT NULL,
  PRIMARY KEY (caller_integration, action)
);
SELECT iit.attach_history('iit.gate_integration_actions', 'caller_integration,action', true);
-- targets proven (S2 B8) to dedupe by action_key: a duplicate grant is harmless there. SEEDED EMPTY (D-36): no target is proven.
CREATE TABLE iit.gate_idempotent_targets (
  action text PRIMARY KEY, note text NOT NULL
);
SELECT iit.attach_history('iit.gate_idempotent_targets', 'action', true);
INSERT INTO iit.system_settings VALUES
  ('gate_31_read_max_age_seconds', '60'::jsonb, now()),      -- D-35: a 3.1 read older than this is not "inside the grant path"
  ('gate_attempt_timeout_seconds', '600'::jsonb, now());     -- §6.2: a granted attempt with no report within 10 minutes → outcome_unknown
-- work-item kinds for the gate, and the link to the action (AM4 "work-item linkage column" — here only for gate items)
ALTER TABLE iit.work_items ADD COLUMN gated_action_id uuid;
DO $$ DECLARE c text; BEGIN
  SELECT conname INTO c FROM pg_catalog.pg_constraint WHERE conrelid = 'iit.work_items'::regclass AND contype = 'c' AND pg_catalog.pg_get_constraintdef(oid) LIKE '%legacy_match%';
  IF c IS NULL THEN RAISE EXCEPTION '005: work_items kind CHECK not found'; END IF;
  EXECUTE pg_catalog.format('ALTER TABLE iit.work_items DROP CONSTRAINT %I', c);
END $$;
ALTER TABLE iit.work_items ADD CONSTRAINT work_items_kind_check CHECK (kind IN (
    'legacy_match','link_conflict','restart_candidate','cancel_31_update','reaudit_31_correction','cutover_unresolved',
    'same_day_31_correction','lienholder_unmatched','report_rejected',
    'gate_unfinished_action','gate_outcome_unknown','gate_completed_after_hold','gate_conflicting_reports',
    'id_collision','delivery_failed_manual','vin_validation_rejected','duplicate_row'));
-- allowlists: outcome evidence (§7) and gate event detail
INSERT INTO iit.json_schemas(name, schema, note) VALUES
  ('gate_outcome_evidence', '{"provider_message_id":true,"package_id":true,"trip_id":true,"target":true,"http_status":true,"note":true}', '§6.2 outcome evidence (D-37); no payloads'),
  ('gate_event_detail', '{"reason":true,"supplied_row_status":true,"read_31_status":true,"read_31_at":true,"status_mismatch":true,"outcome":true,"attempt_no":true,"hold_id":true,"replay":true,"resolution":true,"caller_integration":true}', '§6.2 gated_action_events.detail');
UPDATE iit.json_schemas SET schema = schema || '{"action_key":true,"attempt_id":true,"state":true,"caller_integration":true}'::jsonb, updated_at = now(), note = note || '; 005: action_key, attempt_id, state' WHERE name = 'activity_event_detail';

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. gate tables (§6.2)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.gated_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_key text NOT NULL UNIQUE,
  iid text NOT NULL, deal_id uuid REFERENCES iit.deals(id),            -- deal_id NULL only for a denial of an unknown/unlinked iD
  action text NOT NULL, caller_integration text NOT NULL, triggered_by_text text,
  state text NOT NULL CHECK (state IN ('denied','in_progress','completed','failed_definitive','outcome_unknown')),
  current_attempt_id uuid,                                              -- FK below
  authorized_at timestamptz, deal_version int,
  outcome_reported_at timestamptz, outcome_evidence jsonb,
  completed_after_hold boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (state <> 'denied' OR current_attempt_id IS NULL),
  CHECK (state = 'denied' OR current_attempt_id IS NOT NULL)
);
CREATE TABLE iit.gated_action_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_id uuid NOT NULL REFERENCES iit.gated_actions(id),
  attempt_no int NOT NULL,
  caller_integration text NOT NULL, caller_run_ref text,
  granted_at timestamptz NOT NULL DEFAULT now(),
  state text NOT NULL DEFAULT 'granted' CHECK (state IN ('granted','completed','failed_definitive','outcome_unknown','superseded')),
  supplied_row_status text, read_31_status text, read_31_at timestamptz,   -- §6.3 "recorded on the attempt"
  reported_at timestamptz,
  UNIQUE (action_id, attempt_no), UNIQUE (id, action_id)
);
CREATE UNIQUE INDEX one_granted_attempt_per_action ON iit.gated_action_attempts (action_id) WHERE state = 'granted';   -- §6.2 single executor
ALTER TABLE iit.gated_actions ADD CONSTRAINT gated_actions_current_attempt_fk FOREIGN KEY (current_attempt_id, id) REFERENCES iit.gated_action_attempts(id, action_id);
CREATE INDEX gated_actions_deal_idx ON iit.gated_actions (deal_id);
CREATE TRIGGER gated_actions_evidence_policy BEFORE INSERT OR UPDATE ON iit.gated_actions FOR EACH ROW EXECUTE FUNCTION iit.enforce_json('outcome_evidence', 'gate_outcome_evidence');
-- the action's identity (key, iD, action, bound integration) never changes once created (P1)
CREATE FUNCTION iit.gated_actions_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.action_key <> OLD.action_key OR NEW.iid <> OLD.iid OR NEW.action <> OLD.action OR NEW.caller_integration <> OLD.caller_integration OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'ACTION_IMMUTABLE: identity of gated action % cannot change', OLD.id; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER gated_actions_guard BEFORE UPDATE ON iit.gated_actions FOR EACH ROW EXECUTE FUNCTION iit.gated_actions_guard();
SELECT iit.attach_history('iit.gated_actions');
SELECT iit.attach_history('iit.gated_action_attempts');
-- every call and report is an append-only event
CREATE TABLE iit.gated_action_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  action_id uuid NOT NULL REFERENCES iit.gated_actions(id), attempt_id uuid REFERENCES iit.gated_action_attempts(id),
  event text NOT NULL CHECK (event IN ('denied','granted','replay','report','late_report','conflict','expired','resolved','swept','completed_after_hold')),
  caller_integration text, caller_run_ref text,
  detail jsonb,
  at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);
CREATE INDEX gated_action_events_action_idx ON iit.gated_action_events (action_id, id);
CREATE TRIGGER gated_action_events_policy BEFORE INSERT ON iit.gated_action_events FOR EACH ROW EXECUTE FUNCTION iit.enforce_json('detail', 'gate_event_detail');
SELECT iit.make_append_only('iit.gated_action_events');
-- attempts: state moves granted → one terminal state (or superseded) exactly once; grant facts are immutable
CREATE FUNCTION iit.gated_action_attempts_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.action_id <> OLD.action_id OR NEW.attempt_no <> OLD.attempt_no OR NEW.caller_integration <> OLD.caller_integration
     OR NEW.caller_run_ref IS DISTINCT FROM OLD.caller_run_ref OR NEW.granted_at <> OLD.granted_at
     OR NEW.supplied_row_status IS DISTINCT FROM OLD.supplied_row_status OR NEW.read_31_status IS DISTINCT FROM OLD.read_31_status OR NEW.read_31_at IS DISTINCT FROM OLD.read_31_at THEN
    RAISE EXCEPTION 'ATTEMPT_IMMUTABLE: grant facts of attempt % cannot change', OLD.id; END IF;
  IF OLD.state <> 'granted' AND NEW.state <> OLD.state THEN RAISE EXCEPTION 'ATTEMPT_TERMINAL: attempt % is % and cannot become %', OLD.id, OLD.state, NEW.state; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER gated_action_attempts_guard BEFORE UPDATE ON iit.gated_action_attempts FOR EACH ROW EXECUTE FUNCTION iit.gated_action_attempts_guard();

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. row_actionable (§6.3) — pure; no actor; returns (actionable, reason, deal_id, deal_version)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION iit.row_actionable(p_iid text, OUT actionable boolean, OUT reason text, OUT deal_id uuid, OUT deal_version int)
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE s record; d record; v_route text;
BEGIN
  actionable := false;
  SELECT * INTO s FROM iit.source_records WHERE legacy_iid = p_iid;
  IF NOT FOUND THEN reason := 'unknown_iid'; RETURN; END IF;
  IF s.link_status <> 'linked' OR s.deal_id IS NULL THEN reason := 'unlinked'; RETURN; END IF;
  IF s.appsheet_link_confirmed_at IS NULL THEN reason := 'link_unconfirmed'; RETURN; END IF;
  IF s.status <> 'current' THEN reason := 'row_' || s.status; RETURN; END IF;                 -- rescheduled / cancelled / duplicate
  deal_id := s.deal_id;
  SELECT d2.*, sc.route AS channel_route INTO d FROM iit.deals d2 LEFT JOIN iit.source_channels sc ON sc.id = d2.source_channel_id AND sc.active WHERE d2.id = s.deal_id;
  IF d.cancelled_at IS NOT NULL OR d.intake_status = 'voided' THEN reason := 'deal_cancelled'; RETURN; END IF;
  IF iit.deal_has_open_hold(s.deal_id) THEN reason := 'hold'; RETURN; END IF;
  IF iit.open_material_draft_exists(s.deal_id) THEN reason := 'material_draft'; RETURN; END IF;
  deal_version := iit.latest_released_version(s.deal_id);
  IF deal_version IS NULL THEN reason := 'not_released'; RETURN; END IF;
  v_route := d.channel_route;                                                                 -- CONFIRMED route from source_channels, not the cache
  IF v_route = 'risk_audit' THEN
    IF iit.approval_eligible(s.deal_id) THEN actionable := true; reason := 'approved'; ELSE reason := 'not_approved'; END IF;
  ELSIF v_route = 'skip_audit' THEN
    actionable := true; reason := 'skip_audit';
  ELSE
    reason := 'route_' || coalesce(v_route, 'unknown');                                      -- hold_in_data_entry, unknown, NULL → denied
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. §6.4 sweep (internal; called by open_hold under the Deal lock)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION iit._sweep_unfinished_actions(p_deal uuid, p_hold uuid, p_actor uuid) RETURNS int LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE a record; n int := 0;
BEGIN
  FOR a IN SELECT g.id, g.action_key, g.state FROM iit.gated_actions g
            WHERE g.deal_id = p_deal AND (g.state = 'outcome_unknown' OR EXISTS (SELECT 1 FROM iit.gated_action_attempts t WHERE t.action_id = g.id AND t.state = 'granted')) LOOP
    IF NOT EXISTS (SELECT 1 FROM iit.work_items w WHERE w.gated_action_id = a.id AND w.kind = 'gate_unfinished_action' AND w.status = 'open') THEN
      INSERT INTO iit.work_items(kind, deal_id, gated_action_id, assigned_role, detail)
        VALUES ('gate_unfinished_action', p_deal, a.id, 'data_entry', pg_catalog.jsonb_build_object('action_key', a.action_key, 'state', a.state, 'hold_id', p_hold));
      n := n + 1;
    END IF;
    INSERT INTO iit.gated_action_events(action_id, event, detail) VALUES (a.id, 'swept', pg_catalog.jsonb_build_object('hold_id', p_hold));
  END LOOP;
  RETURN n;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5. authorize_and_consume (tav_worker, §6.2) — the Worker has verified the caller's credential (caller_integration) and
--    read the iD's Deal Status from 3.1 (read_31_status / read_31_at) before calling. Nothing here trusts the caller's own
--    row_status; it is evidence only. Lock order: Deal FOR SHARE (holds take FOR UPDATE, §6.1) → action row FOR UPDATE.
-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION iit.authorize_and_consume(p_action_key text, p_iid text, p_action text, p_caller_integration text, p_caller_run_ref text,
                                          p_triggered_by text, p_supplied_row_status text, p_read_31_status text, p_read_31_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_prev iit.actor_ctx; ra record; g record; t record; v_deny text; v_max_age int; v_mismatch boolean; v_attempt uuid; v_no int; v_detail jsonb; v_active boolean;
BEGIN
  v_prev := iit.actor_push(iit.worker_user(), 'worker');
  BEGIN
    IF coalesce(p_action_key, '') = '' OR coalesce(p_iid, '') = '' OR coalesce(p_action, '') = '' OR coalesce(p_caller_integration, '') = '' THEN
      RAISE EXCEPTION 'GATE_ARGS: action_key, iid, action and caller_integration are required'; END IF;
    -- P1 allowlist FIRST (Codex 005 rev-3): an integration not listed for this action is refused before any lookup, lock or
    -- row creation, so it can never bind an action key. Logged in activity_events (there is no gated_actions row to attach to).
    IF NOT EXISTS (SELECT 1 FROM iit.gate_integration_actions x WHERE x.caller_integration = p_caller_integration AND x.action = p_action) THEN
      INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
        VALUES (NULL, 'gate_request', NULL, 'integration_not_allowed', pg_catalog.jsonb_build_object('action_key', p_action_key, 'caller_integration', p_caller_integration), iit.worker_user(), 'worker', 'gate');
      PERFORM iit.actor_restore(v_prev);
      RETURN pg_catalog.jsonb_build_object('allowed', false, 'reason', 'integration_not_allowed');
    END IF;
    -- eligibility at this moment (§6.3), then the Deal lock FOR SHARE and a re-check under it (a hold that committed first is seen)
    SELECT * INTO ra FROM iit.row_actionable(p_iid);
    IF ra.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = ra.deal_id FOR SHARE; SELECT * INTO ra FROM iit.row_actionable(p_iid); END IF;
    -- authoritative 3.1 status (§6.3): missing/failed read → deny; stale read → deny; unknown or inactive status → deny
    SELECT (value #>> '{}')::int INTO v_max_age FROM iit.system_settings WHERE key = 'gate_31_read_max_age_seconds';
    SELECT active INTO v_active FROM iit.legacy_31_statuses WHERE status = p_read_31_status;
    v_deny := CASE
      WHEN p_read_31_status IS NULL OR p_read_31_at IS NULL THEN 'read_31_failed'
      WHEN p_read_31_at < pg_catalog.clock_timestamp() - pg_catalog.make_interval(secs => v_max_age) OR p_read_31_at > pg_catalog.clock_timestamp() + interval '5 seconds' THEN 'read_31_stale'
      WHEN v_active IS NULL THEN 'status_31_unknown'
      WHEN NOT v_active THEN 'status_31_inactive'
      WHEN NOT ra.actionable THEN ra.reason
      END;
    v_mismatch := p_supplied_row_status IS DISTINCT FROM p_read_31_status;
    v_detail := pg_catalog.jsonb_build_object('supplied_row_status', p_supplied_row_status, 'read_31_status', p_read_31_status, 'read_31_at', p_read_31_at, 'status_mismatch', v_mismatch);
    -- the action row: created on first sight (a denial is kept), then locked so one caller at a time decides for this key
    INSERT INTO iit.gated_actions(action_key, iid, deal_id, action, caller_integration, triggered_by_text, state)
      VALUES (p_action_key, p_iid, ra.deal_id, p_action, p_caller_integration, p_triggered_by, 'denied') ON CONFLICT (action_key) DO NOTHING;
    SELECT * INTO g FROM iit.gated_actions WHERE action_key = p_action_key FOR UPDATE;
    IF g.iid <> p_iid OR g.action <> p_action THEN RAISE EXCEPTION 'GATE_KEY_REUSED: action_key % belongs to %/%', p_action_key, g.action, g.iid; END IF;
    -- P1 (Codex 005 rev-1): an action is BOUND to the integration that first presented its key. Any other authenticated
    -- integration is denied and logged — it can neither take the key over after a failure nor replay it.
    IF g.caller_integration <> p_caller_integration THEN
      INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, g.current_attempt_id, 'denied', p_caller_integration, p_caller_run_ref, v_detail || '{"reason":"wrong_integration"}');
      PERFORM iit.actor_restore(v_prev);
      RETURN pg_catalog.jsonb_build_object('allowed', false, 'reason', 'wrong_integration', 'action_id', g.id);
    END IF;
    SELECT * INTO t FROM iit.gated_action_attempts WHERE action_id = g.id AND state = 'granted';
    -- state table of §6.2, in order
    IF t.id IS NOT NULL THEN
      -- P2: a replay is possible only for the bound integration (checked above) AND a proven-idempotent target
      IF v_deny IS NULL AND t.caller_integration = p_caller_integration AND EXISTS (SELECT 1 FROM iit.gate_idempotent_targets x WHERE x.action = g.action) THEN
        INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, t.id, 'replay', p_caller_integration, p_caller_run_ref, v_detail || '{"replay":true}');
        PERFORM iit.actor_restore(v_prev);
        RETURN pg_catalog.jsonb_build_object('allowed', true, 'replay', true, 'attempt_id', t.id, 'action_id', g.id, 'reason', 'idempotent_target');
      END IF;
      -- default: the open attempt keeps sole ownership (same-run replay is NOT enabled — §6.2 "not enabled unless proven")
      INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, t.id, 'denied', p_caller_integration, p_caller_run_ref, v_detail || pg_catalog.jsonb_build_object('reason', 'in_progress'));
      PERFORM iit.actor_restore(v_prev);
      RETURN pg_catalog.jsonb_build_object('allowed', false, 'reason', 'in_progress', 'attempt_id', t.id, 'action_id', g.id);
    END IF;
    IF g.state = 'completed' THEN
      INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, g.current_attempt_id, 'denied', p_caller_integration, p_caller_run_ref, v_detail || '{"reason":"already_completed"}');
      PERFORM iit.actor_restore(v_prev);
      RETURN pg_catalog.jsonb_build_object('allowed', false, 'reason', 'already_completed', 'action_id', g.id);
    END IF;
    IF g.state = 'outcome_unknown' THEN
      INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, g.current_attempt_id, 'denied', p_caller_integration, p_caller_run_ref, v_detail || '{"reason":"outcome_unknown"}');
      PERFORM iit.actor_restore(v_prev);
      RETURN pg_catalog.jsonb_build_object('allowed', false, 'reason', 'outcome_unknown', 'action_id', g.id);
    END IF;
    -- state denied / in_progress-without-granted-attempt (cannot occur) / failed_definitive: a fresh eligibility decision
    IF v_deny IS NOT NULL THEN
      INSERT INTO iit.gated_action_events(action_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, 'denied', p_caller_integration, p_caller_run_ref, v_detail || pg_catalog.jsonb_build_object('reason', v_deny));
      IF g.state = 'denied' AND g.deal_id IS NULL AND ra.deal_id IS NOT NULL THEN UPDATE iit.gated_actions SET deal_id = ra.deal_id WHERE id = g.id; END IF;
      PERFORM iit.actor_restore(v_prev);
      RETURN pg_catalog.jsonb_build_object('allowed', false, 'reason', v_deny, 'action_id', g.id);
    END IF;
    SELECT coalesce(max(attempt_no), 0) + 1 INTO v_no FROM iit.gated_action_attempts WHERE action_id = g.id;
    INSERT INTO iit.gated_action_attempts(action_id, attempt_no, caller_integration, caller_run_ref, supplied_row_status, read_31_status, read_31_at)
      VALUES (g.id, v_no, p_caller_integration, p_caller_run_ref, p_supplied_row_status, p_read_31_status, p_read_31_at) RETURNING id INTO v_attempt;
    UPDATE iit.gated_actions SET state = 'in_progress', current_attempt_id = v_attempt, deal_id = ra.deal_id, authorized_at = now(), deal_version = ra.deal_version,
                                 triggered_by_text = p_triggered_by WHERE id = g.id;                       -- caller_integration is never rewritten (P1)
    INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, v_attempt, 'granted', p_caller_integration, p_caller_run_ref, v_detail || pg_catalog.jsonb_build_object('attempt_no', v_no));
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN pg_catalog.jsonb_build_object('allowed', true, 'replay', false, 'attempt_id', v_attempt, 'action_id', g.id, 'deal_id', ra.deal_id, 'deal_version', ra.deal_version);
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 6. report_action_outcome (tav_worker, §6.2): same integration only; completed / failed_definitive / failed_ambiguous;
--    every report is an event; late reports never change state; conflicting reports → outcome_unknown + work item;
--    a completion after a hold opened is flagged (§6.4).
-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION iit.report_action_outcome(p_attempt_id uuid, p_outcome text, p_evidence jsonb, p_caller_integration text, p_caller_run_ref text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_prev iit.actor_ctx; t record; g record; v_state text; v_hold_after boolean := false; v_result text;
BEGIN
  v_prev := iit.actor_push(iit.worker_user(), 'worker');
  BEGIN
    IF p_outcome IS NULL OR p_outcome NOT IN ('completed','failed_definitive','failed_ambiguous') THEN RAISE EXCEPTION 'GATE_OUTCOME: % (completed | failed_definitive | failed_ambiguous)', coalesce(p_outcome, 'NULL'); END IF;
    SELECT action_id INTO t FROM iit.gated_action_attempts WHERE id = p_attempt_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'ATTEMPT_UNKNOWN: %', p_attempt_id; END IF;
    SELECT deal_id INTO g FROM iit.gated_actions WHERE id = t.action_id;
    IF g.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = g.deal_id FOR SHARE; END IF;
    SELECT * INTO g FROM iit.gated_actions WHERE id = t.action_id FOR UPDATE;
    SELECT * INTO t FROM iit.gated_action_attempts WHERE id = p_attempt_id;
    IF t.caller_integration <> coalesce(p_caller_integration, '') THEN
      INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail)
        VALUES (g.id, t.id, 'late_report', p_caller_integration, p_caller_run_ref, pg_catalog.jsonb_build_object('reason', 'wrong_integration', 'outcome', p_outcome, 'caller_integration', p_caller_integration));
      PERFORM iit.actor_restore(v_prev);                                                      -- rejected AND logged (the event is kept)
      RETURN pg_catalog.jsonb_build_object('recorded', false, 'result', 'wrong_integration', 'state', g.state);
    END IF;
    IF t.state <> 'granted' OR g.current_attempt_id IS DISTINCT FROM t.id THEN
      -- superseded or already finished: late evidence, kept, state unchanged. A DIFFERENT outcome on a finished attempt is a conflict.
      IF t.state IN ('completed','failed_definitive') AND t.state <> p_outcome THEN
        INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, t.id, 'conflict', p_caller_integration, p_caller_run_ref, pg_catalog.jsonb_build_object('outcome', p_outcome));
        IF g.current_attempt_id = t.id THEN
          UPDATE iit.gated_actions SET state = 'outcome_unknown' WHERE id = g.id;
          INSERT INTO iit.work_items(kind, deal_id, gated_action_id, assigned_role, detail) VALUES ('gate_conflicting_reports', g.deal_id, g.id, 'data_entry', pg_catalog.jsonb_build_object('action_key', g.action_key, 'first', t.state, 'then', p_outcome));
          v_result := 'conflict_outcome_unknown';
        ELSE v_result := 'late_conflict'; END IF;
      ELSE
        INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, t.id, 'late_report', p_caller_integration, p_caller_run_ref, pg_catalog.jsonb_build_object('outcome', p_outcome));
        v_result := 'late_evidence';
      END IF;
      PERFORM iit.actor_restore(v_prev);
      RETURN pg_catalog.jsonb_build_object('recorded', true, 'result', v_result, 'state', (SELECT state FROM iit.gated_actions WHERE id = g.id));
    END IF;
    -- current granted attempt
    INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, t.id, 'report', p_caller_integration, p_caller_run_ref, pg_catalog.jsonb_build_object('outcome', p_outcome));
    v_state := CASE p_outcome WHEN 'completed' THEN 'completed' WHEN 'failed_definitive' THEN 'failed_definitive' ELSE 'outcome_unknown' END;
    UPDATE iit.gated_action_attempts SET state = v_state, reported_at = now() WHERE id = t.id;
    IF p_outcome = 'completed' AND g.deal_id IS NOT NULL THEN
      v_hold_after := EXISTS (SELECT 1 FROM iit.audit_holds h WHERE h.deal_id = g.deal_id AND h.opened_at >= t.granted_at);
    END IF;
    UPDATE iit.gated_actions SET state = v_state, outcome_reported_at = now(), outcome_evidence = CASE WHEN p_outcome = 'completed' THEN coalesce(p_evidence, '{}'::jsonb) ELSE outcome_evidence END,
                                 completed_after_hold = completed_after_hold OR v_hold_after WHERE id = g.id;
    IF v_hold_after THEN
      INSERT INTO iit.gated_action_events(action_id, attempt_id, event, caller_integration, caller_run_ref, detail) VALUES (g.id, t.id, 'completed_after_hold', p_caller_integration, p_caller_run_ref, pg_catalog.jsonb_build_object('outcome', p_outcome));
      INSERT INTO iit.work_items(kind, deal_id, gated_action_id, assigned_role, detail) VALUES ('gate_completed_after_hold', g.deal_id, g.id, 'data_entry', pg_catalog.jsonb_build_object('action_key', g.action_key));
    END IF;
    IF p_outcome = 'failed_ambiguous' THEN
      INSERT INTO iit.work_items(kind, deal_id, gated_action_id, assigned_role, detail) VALUES ('gate_outcome_unknown', g.deal_id, g.id, 'data_entry', pg_catalog.jsonb_build_object('action_key', g.action_key, 'cause', 'failed_ambiguous'));
    END IF;
    v_result := v_state;
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN pg_catalog.jsonb_build_object('recorded', true, 'result', v_result, 'state', v_state, 'completed_after_hold', v_hold_after);
END $$;

-- expire_stale_attempts (tav_worker, §6.2/§6.4 "silent actions"): granted attempts older than the timeout → outcome_unknown + work item.
-- Returns the number expired. The Worker calls it on its schedule; the timeout is a setting, not a promise (RR2).
CREATE FUNCTION iit.expire_stale_attempts(p_now timestamptz DEFAULT now()) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_prev iit.actor_ctx; v_timeout int; a record; n int := 0;
BEGIN
  v_prev := iit.actor_push(iit.worker_user(), 'worker');
  BEGIN
    SELECT (value #>> '{}')::int INTO v_timeout FROM iit.system_settings WHERE key = 'gate_attempt_timeout_seconds';
    FOR a IN SELECT t.id AS attempt_id, g.id AS action_id, g.deal_id, g.action_key FROM iit.gated_action_attempts t JOIN iit.gated_actions g ON g.id = t.action_id
              WHERE t.state = 'granted' AND t.granted_at < p_now - pg_catalog.make_interval(secs => v_timeout) ORDER BY t.granted_at LOOP
      IF a.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = a.deal_id FOR SHARE; END IF;
      PERFORM 1 FROM iit.gated_actions WHERE id = a.action_id FOR UPDATE;
      IF NOT EXISTS (SELECT 1 FROM iit.gated_action_attempts WHERE id = a.attempt_id AND state = 'granted') THEN CONTINUE; END IF;   -- reported meanwhile
      UPDATE iit.gated_action_attempts SET state = 'outcome_unknown', reported_at = p_now WHERE id = a.attempt_id;
      UPDATE iit.gated_actions SET state = 'outcome_unknown' WHERE id = a.action_id;
      INSERT INTO iit.gated_action_events(action_id, attempt_id, event, detail) VALUES (a.action_id, a.attempt_id, 'expired', pg_catalog.jsonb_build_object('reason', 'no report within timeout'));
      INSERT INTO iit.work_items(kind, deal_id, gated_action_id, assigned_role, detail) VALUES ('gate_outcome_unknown', a.deal_id, a.action_id, 'data_entry', pg_catalog.jsonb_build_object('action_key', a.action_key, 'cause', 'timeout'));
      n := n + 1;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN n;
END $$;

-- resolve_unknown_outcome (data_entry, §6.2 "resolved by Data Entry"): records what actually happened to an outcome_unknown
-- action — 'completed' with the evidence found, or 'failed_definitive' (which makes a fresh authorization possible). Never a retry itself.
CREATE FUNCTION iit.resolve_unknown_outcome(p_action_id uuid, p_resolution text, p_evidence jsonb, p_reason text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; g record; w record;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  BEGIN
    IF p_resolution IS NULL OR p_resolution NOT IN ('completed','failed_definitive') THEN RAISE EXCEPTION 'GATE_RESOLUTION: % (completed | failed_definitive)', coalesce(p_resolution, 'NULL'); END IF;
    IF p_reason IS NULL OR pg_catalog.btrim(p_reason) = '' THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
    SELECT deal_id INTO g FROM iit.gated_actions WHERE id = p_action_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTION_UNKNOWN: %', p_action_id; END IF;
    IF g.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = g.deal_id FOR SHARE; END IF;
    SELECT * INTO g FROM iit.gated_actions WHERE id = p_action_id FOR UPDATE;
    IF g.state <> 'outcome_unknown' THEN RAISE EXCEPTION 'GATE_NOT_UNKNOWN: action % is %', p_action_id, g.state; END IF;
    UPDATE iit.gated_actions SET state = p_resolution, outcome_reported_at = now(), outcome_evidence = CASE WHEN p_resolution = 'completed' THEN coalesce(p_evidence, '{}'::jsonb) ELSE outcome_evidence END WHERE id = p_action_id;
    INSERT INTO iit.gated_action_events(action_id, attempt_id, event, detail) VALUES (p_action_id, g.current_attempt_id, 'resolved', pg_catalog.jsonb_build_object('resolution', p_resolution, 'reason', p_reason));
    FOR w IN SELECT id FROM iit.work_items WHERE gated_action_id = p_action_id AND status = 'open' AND kind IN ('gate_outcome_unknown','gate_conflicting_reports') LOOP
      UPDATE iit.work_items SET status = 'closed', closed_by = v_actor, closed_at = now(), outcome = p_resolution || ': ' || p_reason WHERE id = w.id;
    END LOOP;
    INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
      VALUES (g.deal_id, 'gated_action', p_action_id, 'outcome_resolved', pg_catalog.jsonb_build_object('action_key', g.action_key, 'state', p_resolution, 'reason', p_reason), v_actor, 'user', 'data_entry_ui');
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 7. D-30 consignment function (data_entry, PR3): consignor must be a party of the Deal; pre-release only (a post-release
--    change to the consignor or the amount is not a decided workflow — D-38, fail closed)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION iit.set_consignment(p_deal uuid, p_consignor_party_id uuid, p_amount numeric, p_notes text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; v_id uuid;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  BEGIN
    IF d.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'DEAL_CANCELLED: %', p_deal; END IF;
    IF d.origin <> 'manual_consignment' THEN RAISE EXCEPTION 'NOT_CONSIGNMENT: deal % has origin %', p_deal, d.origin; END IF;
    IF iit.latest_released_version(p_deal) IS NOT NULL THEN RAISE EXCEPTION 'RELEASED_CONSIGNMENT_UNDECIDED: changing a released consignment is not a reviewed workflow (D-38)'; END IF;
    IF NOT EXISTS (SELECT 1 FROM iit.deal_parties WHERE deal_id = p_deal AND party_id = p_consignor_party_id) THEN RAISE EXCEPTION 'PARTY_NOT_ON_DEAL: % is not a party of deal %', p_consignor_party_id, p_deal; END IF;
    IF p_amount IS NOT NULL AND p_amount < 0 THEN RAISE EXCEPTION 'FIELD_VALUE: consignment_amount cannot be negative'; END IF;
    SELECT id INTO v_id FROM iit.consignments WHERE deal_id = p_deal;
    IF v_id IS NULL THEN
      INSERT INTO iit.consignments(deal_id, consignor_party_id, consignment_amount, notes) VALUES (p_deal, p_consignor_party_id, p_amount, p_notes) RETURNING id INTO v_id;
    ELSE
      UPDATE iit.consignments SET consignor_party_id = p_consignor_party_id, consignment_amount = p_amount, notes = p_notes WHERE id = v_id;
    END IF;
    UPDATE iit.deals SET consignment_id = v_id WHERE id = p_deal AND consignment_id IS DISTINCT FROM v_id;
    INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
      VALUES (p_deal, 'consignment', v_id, 'consignment_set', pg_catalog.jsonb_build_object('party_id', p_consignor_party_id), v_actor, 'user', 'data_entry_ui');
  EXCEPTION WHEN OTHERS THEN PERFORM iit.actor_restore(v_prev); RAISE;
  END;
  PERFORM iit.actor_restore(v_prev);
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 8. open_hold with the §6.4 sweep (replaces 002's; only the sweep call is new) and _deal_from_observation with D-32
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iit.open_hold(p_deal uuid, p_cause text, p_actor uuid, p_correction uuid DEFAULT NULL, p_covers_version int DEFAULT NULL, p_reconciliation_item uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_hold uuid;
BEGIN
  PERFORM 1 FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  -- initial covering version of a material-correction hold = the correction's draft version (rebinding later changes it with proof)
  IF p_cause = 'material_correction' AND NOT EXISTS (SELECT 1 FROM iit.material_corrections m WHERE m.id = p_correction AND m.deal_id = p_deal AND m.draft_version_no = p_covers_version) THEN
    RAISE EXCEPTION 'HOLD_COVERS_MISMATCH: correction % of deal % is not for draft v%', p_correction, p_deal, p_covers_version; END IF;
  INSERT INTO iit.audit_holds(deal_id, cause, correction_id, covers_version_no, reconciliation_item_id, opened_by)
    VALUES (p_deal, p_cause, p_correction, p_covers_version, p_reconciliation_item, p_actor) RETURNING id INTO v_hold;
  UPDATE iit.deals SET on_hold = true, gate_clear = false WHERE id = p_deal;      -- caches
  -- §6.4 sweep (005): every gated action of this Deal with a granted attempt, or in state outcome_unknown, REGARDLESS of age,
  -- gets a work item so it stays visible until resolved. Holds are never released here; nothing changes on the action itself.
  PERFORM iit._sweep_unfinished_actions(p_deal, v_hold, p_actor);
  RETURN v_hold;
END $$;
CREATE OR REPLACE FUNCTION iit._deal_from_observation(p_body jsonb, p_restarted_from uuid) RETURNS uuid LANGUAGE plpgsql SET search_path = '' AS $$
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
  -- D-32 (Rami, 26 Oct): a title region that is not a two-letter state is flagged for Data Entry (non-blocking); state left empty
  IF (p_body -> 'title') ? 'region' AND NOT (v_region ~ '^[A-Z]{2}$') THEN
    INSERT INTO iit.intake_flags(deal_id, code, detail) VALUES (v_deal, 'vauto_title_region_unmapped', coalesce(p_body -> 'title' ->> 'region', '')); END IF;
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

-- ---------------------------------------------------------------------------------------------------------------------
-- 9. grants and RLS: Worker functions → tav_worker only; staff functions → iit_integration; helpers owner-only
-- ---------------------------------------------------------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA iit FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iit.authorize_and_consume(text,text,text,text,text,text,text,text,timestamptz), iit.report_action_outcome(uuid,text,jsonb,text,text), iit.expire_stale_attempts(timestamptz) TO tav_worker;
GRANT EXECUTE ON FUNCTION iit.resolve_unknown_outcome(uuid,text,jsonb,text,text), iit.set_consignment(uuid,uuid,numeric,text,text) TO iit_integration;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA iit TO iit_integration;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA iit TO iit_integration;
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'iit' AND c.relkind = 'r' AND NOT c.relrowsecurity LOOP
    EXECUTE pg_catalog.format('ALTER TABLE iit.%I ENABLE ROW LEVEL SECURITY', r.relname);
  END LOOP; END $$;
RESET ROLE;
COMMIT;
