-- 003_deal_workflow.sql — post-intake Deal lifecycle: Source/channel setting (D-9 cache rule), release with frozen snapshot and
-- watermark (§5.5/§5.7), material corrections (§5.5 D21 → draft N+1 + hold, §5.7a), administrative amendments (§5.5),
-- proof-based hold rebinding (§5.7a G4), flag and work-item resolution, cancellation (§5.7a G12).
-- Depends on 001 and 002. EXCLUDED: §5.8 bridge — release_deal does NOT queue add_31_row (dependency stated inline);
-- vAuto intake, draft-1 creation/editing, seller-party edits, reschedule linking, restart decisions (004, intake/parties
-- slice); §6 gate and the §6.4 sweep (open_hold still states that gap); parser re-run check (no parser objects exist — D-19).
BEGIN;
SET ROLE iit_owner;
SET search_path = pg_catalog;

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. reference data and allowlists
-- ---------------------------------------------------------------------------------------------------------------------
-- Fields that also appear in the 3.1 row. An administrative amendment to one of these opens a same-day correction work item
-- (§5.5, bridge is add-only). SEEDED EMPTY: the 3.1 field map is not in the repo (001 D-8). Until the owner supplies it,
-- no amendment opens such a work item; the code path is exercised by the tests with a test-only row.
CREATE TABLE iit.legacy_31_fields (
  field text PRIMARY KEY, note text NOT NULL
);
SELECT iit.attach_history('iit.legacy_31_fields', 'field', true);

-- deal_version_snapshot allowlist (§7: values of allowlisted columns only; §5.5 "the intake values as released").
-- Keys are the SOURCE COLUMN NAMES so that a record_history row can be checked against the snapshot mechanically (rebind proof).
-- Sections: deal, vehicle, title, lien, parties[], consignment, requirements[]. PROPOSAL — docs/migrations/003.md D-18.
UPDATE iit.json_schemas SET schema = '{
  "deal":    {"id":true,"deal_number":true,"origin":true,"source_channel_id":true,"consumer_route":true,
              "purchase_price":true,"deposit_amount":true,"balance":true,"balance_owed":true,
              "buyer_id":true,"closer_id":true,"dealer_sold_to":true,"dealer_auction_name":true,
              "consignment_id":true,"restarted_from_deal_id":true},
  "vehicle": {"id":true,"vin":true,"vin_normalized":true,"year":true,"make_text":true,"model_text":true,"series":true,"exterior_color":true},
  "title":   {"id":true,"deal_id":true,"custody":true,"title_state":true,"title_number":true,"title_miles":true,"brand":true,"is_tribal":true},
  "lien":    {"id":true,"deal_id":true,"position":true,"lienholder_org_id":true,"lienholder_name_raw":true,"lienholder_phone":true,
              "payoff_amount":true,"payoff_good_through":true,"per_diem":true},
  "parties": {"id":true,"party_id":true,"role":true,"ordinal":true,"party_type":true,"first_name":true,"last_name":true,
              "business_org_id":true,"phone_normalized":true,"email":true,"city":true,"state":true},
  "consignment":  {"id":true,"consignor_party_id":true,"consignment_amount":true},
  "requirements": {"requirement_key":true,"report_type":true,"subject_type":true,"subject_vin":true,"subject_org_id":true}
}'::jsonb, updated_at = now(), note = '003 release_deal snapshot: source column names per section (D-18)'
WHERE name = 'deal_version_snapshot';
-- activity detail keys written by THIS slice
UPDATE iit.json_schemas SET schema = schema || '{"field":true,"version_no":true,"from_version_no":true,"to_version_no":true,"outcome":true,"status":true,"channel":true}'::jsonb,
  updated_at = now(), note = note || '; 003: field, version_no, from/to_version_no, outcome, status, channel'
WHERE name = 'activity_event_detail';

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. pure helpers (no actor)
-- ---------------------------------------------------------------------------------------------------------------------
-- The frozen snapshot of a Deal's current facts (§5.5). Built from table columns only — allowlisted by construction AND
-- re-checked by the deal_versions_snapshot_policy trigger. jsonb_strip_nulls: an absent key means SQL NULL.
CREATE FUNCTION iit.build_deal_snapshot(p_deal uuid, p_version int) RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
    'deal', (SELECT pg_catalog.jsonb_build_object('id', d.id, 'deal_number', d.deal_number, 'origin', d.origin, 'source_channel_id', d.source_channel_id,
               'consumer_route', d.consumer_route, 'purchase_price', d.purchase_price, 'deposit_amount', d.deposit_amount, 'balance', d.balance,
               'balance_owed', d.balance_owed, 'buyer_id', d.buyer_id, 'closer_id', d.closer_id, 'dealer_sold_to', d.dealer_sold_to,
               'dealer_auction_name', d.dealer_auction_name, 'consignment_id', d.consignment_id, 'restarted_from_deal_id', d.restarted_from_deal_id)
             FROM iit.deals d WHERE d.id = p_deal),
    'vehicle', (SELECT pg_catalog.jsonb_build_object('id', v.id, 'vin', v.vin, 'vin_normalized', v.vin_normalized, 'year', v.year, 'make_text', v.make_text,
                  'model_text', v.model_text, 'series', v.series, 'exterior_color', v.exterior_color)
                FROM iit.deals d JOIN iit.vehicles v ON v.id = d.vehicle_id WHERE d.id = p_deal),
    'title', (SELECT pg_catalog.jsonb_build_object('id', t.id, 'deal_id', t.deal_id, 'custody', t.custody, 'title_state', t.title_state, 'title_number', t.title_number,
                'title_miles', t.title_miles, 'brand', t.brand, 'is_tribal', t.is_tribal) FROM iit.deal_titles t WHERE t.deal_id = p_deal),
    'lien', (SELECT pg_catalog.jsonb_build_object('id', l.id, 'deal_id', l.deal_id, 'position', l.position, 'lienholder_org_id', l.lienholder_org_id, 'lienholder_name_raw', l.lienholder_name_raw,
               'lienholder_phone', l.lienholder_phone, 'payoff_amount', l.payoff_amount, 'payoff_good_through', l.payoff_good_through, 'per_diem', l.per_diem)
             FROM iit.deal_liens l WHERE l.deal_id = p_deal),
    'parties', coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', dp.id, 'party_id', sp.id, 'role', dp.role, 'ordinal', dp.ordinal,
                 'party_type', sp.party_type, 'first_name', sp.first_name, 'last_name', sp.last_name, 'business_org_id', sp.business_org_id,
                 'phone_normalized', sp.phone_normalized, 'email', sp.email, 'city', sp.city, 'state', sp.state) ORDER BY dp.role, dp.ordinal)
               FROM iit.deal_parties dp JOIN iit.seller_parties sp ON sp.id = dp.party_id WHERE dp.deal_id = p_deal), '[]'::jsonb),
    'consignment', (SELECT pg_catalog.jsonb_build_object('id', c.id, 'consignor_party_id', c.consignor_party_id, 'consignment_amount', c.consignment_amount)
                    FROM iit.consignments c WHERE c.deal_id = p_deal),
    'requirements', coalesce((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('requirement_key', q.requirement_key, 'report_type', q.report_type,
                       'subject_type', q.subject_type, 'subject_vin', q.subject_vin, 'subject_org_id', q.subject_org_id) ORDER BY q.requirement_key)
                     FROM iit.deal_report_requirements q WHERE q.deal_id = p_deal AND q.version_no = p_version), '[]'::jsonb)
  )) $$;

-- Required intake facts (§5.7 step 3, G13): the names of REQUIRED facts for the Deal's origin that are not present.
CREATE FUNCTION iit.missing_required_facts(p_deal uuid) RETURNS text[] LANGUAGE sql STABLE SET search_path = '' AS $$
  WITH d AS (SELECT d.*, v.vin_normalized, sc.origin AS channel_origin
               FROM iit.deals d JOIN iit.vehicles v ON v.id = d.vehicle_id LEFT JOIN iit.source_channels sc ON sc.id = d.source_channel_id
              WHERE d.id = p_deal),
  facts AS (
    SELECT 'vin' AS fact,                  (SELECT vin_normalized <> '' FROM d) AS present UNION ALL
    SELECT 'purchase_price',               (SELECT purchase_price IS NOT NULL FROM d) UNION ALL
    SELECT 'purchase_price_empty',         (SELECT purchase_price IS NULL FROM d) UNION ALL
    SELECT 'deposit_stated',               (SELECT deposit_amount IS NOT NULL FROM d) UNION ALL
    SELECT 'title_custody',                EXISTS (SELECT 1 FROM iit.deal_titles t WHERE t.deal_id = p_deal AND t.custody IS NOT NULL) UNION ALL
    SELECT 'lien_position',                EXISTS (SELECT 1 FROM iit.deal_liens l WHERE l.deal_id = p_deal AND l.position IS NOT NULL) UNION ALL
    SELECT 'seller_party',                 EXISTS (SELECT 1 FROM iit.deal_parties dp WHERE dp.deal_id = p_deal AND dp.role IN ('owner','business_seller')) UNION ALL
    SELECT 'seller_phone',                 EXISTS (SELECT 1 FROM iit.deal_parties dp JOIN iit.seller_parties sp ON sp.id = dp.party_id
                                                    WHERE dp.deal_id = p_deal AND dp.role IN ('owner','co_owner','business_seller') AND sp.phone_normalized <> '') UNION ALL
    SELECT 'buyer',                        (SELECT buyer_id IS NOT NULL FROM d) UNION ALL
    SELECT 'closer',                       (SELECT closer_id IS NOT NULL FROM d) UNION ALL
    SELECT 'source_channel',               (SELECT source_channel_id IS NOT NULL AND channel_origin = origin FROM d) UNION ALL   -- channel must belong to the origin
    SELECT 'consignor',                    EXISTS (SELECT 1 FROM iit.consignments c WHERE c.deal_id = p_deal AND c.consignor_party_id IS NOT NULL))
  SELECT coalesce(pg_catalog.array_agg(r.fact ORDER BY r.fact), '{}'::text[])
    FROM iit.required_fact_rules r JOIN facts f ON f.fact = r.fact
   WHERE r.origin = (SELECT origin FROM d) AND r.required AND NOT coalesce(f.present, false) $$;

-- Containment proof for rebinding (§5.7a G4): every record_history row listed in the correction is (a) covered by the target
-- version's watermark and (b) its changed columns appear in the target snapshot with the SAME values. Returns NULL when the
-- proof holds, else the reason it fails. Columns outside the snapshot allowlist cannot be proven → fail closed.
CREATE FUNCTION iit.snapshot_contains_changes(p_deal uuid, p_version int, p_history_ids bigint[]) RETURNS text LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE v_snap jsonb; v_wm bigint; h record; v_section jsonb; k text; v_after jsonb; v_changed text[];
BEGIN
  SELECT snapshot, history_watermark INTO v_snap, v_wm FROM iit.deal_versions WHERE deal_id = p_deal AND version_no = p_version AND status = 'released';
  IF v_snap IS NULL THEN RETURN 'target version is not released'; END IF;
  IF p_history_ids IS NULL OR pg_catalog.cardinality(p_history_ids) = 0 THEN RETURN 'correction lists no history rows'; END IF;
  FOR h IN SELECT * FROM iit.record_history WHERE id = ANY (p_history_ids) ORDER BY id LOOP
    IF h.id > v_wm THEN RETURN pg_catalog.format('history %s is after the watermark %s of v%s', h.id, v_wm, p_version); END IF;
    IF h.op = 'D' THEN RETURN pg_catalog.format('history %s is a delete', h.id); END IF;
    v_section := CASE h.table_name
      WHEN 'deals'        THEN v_snap -> 'deal'
      WHEN 'vehicles'     THEN v_snap -> 'vehicle'
      WHEN 'deal_titles'  THEN v_snap -> 'title'
      WHEN 'deal_liens'   THEN v_snap -> 'lien'
      WHEN 'deal_parties' THEN (SELECT e FROM pg_catalog.jsonb_array_elements(v_snap -> 'parties') e WHERE e ->> 'id' = h.record_id::text)
      WHEN 'seller_parties' THEN (SELECT e FROM pg_catalog.jsonb_array_elements(v_snap -> 'parties') e WHERE e ->> 'party_id' = h.record_id::text)
      ELSE NULL END;
    IF v_section IS NULL THEN RETURN pg_catalog.format('history %s (%s %s) has no section in the v%s snapshot', h.id, h.table_name, h.record_key, p_version); END IF;
    IF h.table_name IN ('deals','vehicles','deal_titles','deal_liens') AND v_section ->> 'id' IS DISTINCT FROM h.record_id::text THEN
      RETURN pg_catalog.format('history %s is for %s %s, snapshot v%s holds %s', h.id, h.table_name, h.record_key, p_version, v_section ->> 'id'); END IF;
    -- changed columns: every key of `after` whose value differs from `before` (all keys on an INSERT)
    SELECT pg_catalog.array_agg(a.key) INTO v_changed FROM pg_catalog.jsonb_each(h.after) a
     WHERE h.before IS NULL OR (h.before -> a.key) IS DISTINCT FROM a.value;
    FOREACH k IN ARRAY coalesce(v_changed, '{}'::text[]) LOOP
      v_after := h.after -> k;
      IF NOT (v_section ? k) AND v_after <> 'null'::jsonb THEN
        RETURN pg_catalog.format('history %s: column %s.%s is not in the v%s snapshot', h.id, h.table_name, k, p_version); END IF;
      IF coalesce(v_section -> k, 'null'::jsonb) IS DISTINCT FROM v_after THEN
        RETURN pg_catalog.format('history %s: %s.%s = %s in the change, %s in snapshot v%s', h.id, h.table_name, k, v_after, coalesce(v_section -> k, 'null'::jsonb), p_version); END IF;
    END LOOP;
  END LOOP;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. internal helper: field writers shared by correct_field / amend_field (resolved actor; caller holds the Deal lock)
-- ---------------------------------------------------------------------------------------------------------------------
-- Applies ONE field change and returns (table_name, record_id, before jsonb, after jsonb) for history collection and amendments.
-- Supported fields are an explicit list; anything else raises FIELD_UNSUPPORTED (seller-party fields and deposit_amount are
-- deferred — docs/migrations/003.md D-20/D-21). The G8 consignment CHECK on deals still applies.
CREATE FUNCTION iit._apply_field(p_deal uuid, p_field text, p_value jsonb, OUT table_name text, OUT record_id uuid, OUT before jsonb, OUT after jsonb)
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
      RAISE EXCEPTION 'FIELD_UNSUPPORTED: % is not editable through this slice (seller-party fields, deposit_amount: 004 / D-20, D-21)', p_field;
  END CASE;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. staff-facing functions (§2.2): require_role → push → Deal lock → work → restore. EXECUTE → iit_integration only.
-- ---------------------------------------------------------------------------------------------------------------------
-- set_source_channel (data_entry): the ONLY writer of deals.source_channel_id and of the consumer_route cache (D-9 rule: both in
-- one statement, from source_channels.route). A channel must belong to the Deal's origin. After the first release a change is
-- REFUSED until the owner decides R2/D-5 (Source change after release as material or not) — fail closed, not silently allowed.
CREATE FUNCTION iit.set_source_channel(p_deal uuid, p_channel_name text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; ch record;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF d.cancelled_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_CANCELLED: %', p_deal; END IF;
  SELECT * INTO ch FROM iit.source_channels WHERE name = p_channel_name AND active;
  IF ch IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'CHANNEL_UNKNOWN: %', p_channel_name; END IF;
  IF ch.origin <> d.origin THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'CHANNEL_ORIGIN_MISMATCH: % is a % channel, deal origin is %', p_channel_name, ch.origin, d.origin; END IF;
  IF iit.latest_released_version(p_deal) IS NOT NULL AND d.source_channel_id IS DISTINCT FROM ch.id THEN
    PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'SOURCE_CHANGE_AFTER_RELEASE_UNDECIDED: R2/D-5 is an open owner decision; the Source of a released deal cannot change through this function'; END IF;
  UPDATE iit.deals SET source_channel_id = ch.id, consumer_route = ch.route WHERE id = p_deal;    -- cache rule D-9: one statement, one writer
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (p_deal, 'deal', p_deal, 'source_channel_set', pg_catalog.jsonb_build_object('channel', ch.name), v_actor, 'user', 'data_entry_ui');
  PERFORM iit.actor_restore(v_prev);
END $$;

-- release_deal (data_entry, §5.7): one transaction under the Deal lock. Refuses unless every check passes; then FREEZES the
-- existing draft (draft → released with snapshot + watermark), supersedes the previous released version, and on the Risk
-- Audit route opens the attempt for the released version (which binds the holds covering it — 002 create_audit_attempt).
-- BRIDGE DEPENDENCY (§5.8, excluded): the design queues the initial add_31_row delivery on the FIRST release. This function
-- does NOT do that and provides no placeholder; the bridge slice, if adopted, adds it here.
-- PARSER DEPENDENCY (§5.7 step 5 "no parser re-run is pending"): no parser objects exist in this schema (D-19); nothing is checked.
CREATE FUNCTION iit.release_deal(p_deal uuid, p_actor_base44_user_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; v_draft int; v_prev_rel int; v_missing text[]; v_snap jsonb; v_wm bigint; v_check uuid;
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
  -- §5.8: initial add_31_row delivery NOT queued (bridge excluded)
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (p_deal, 'deal_version', NULL, 'deal_released', pg_catalog.jsonb_build_object('version_no', v_draft, 'from_version_no', v_prev_rel), v_actor, 'user', 'data_entry_ui');
  PERFORM iit.actor_restore(v_prev);
  RETURN v_draft;
END $$;

-- correct_field (data_entry, §5.5 material correction): the field must be in material_fields; the Deal must have a released
-- version. Opens draft N+1 (cause material_correction) if no material draft is open, applies the change, recomputes the draft's
-- requirements, carries validations over (only when the draft is opened by this call), records the material_corrections row
-- with the EXACT record_history ids of the change, and opens the hold covering the draft (002 open_hold). Returns the correction id.
CREATE FUNCTION iit.correct_field(p_deal uuid, p_field text, p_value jsonb, p_reason text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; v_rel int; v_draft int; v_new_draft boolean := false; v_mark bigint; w record; v_ids bigint[]; v_corr uuid; v_hold uuid; v_cause text;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF d.cancelled_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_CANCELLED: %', p_deal; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.material_fields WHERE field = p_field) THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'NOT_MATERIAL: % is not a material field (use amend_field)', p_field; END IF;
  IF p_field = 'seller_parties' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'CORRECTION_UNSUPPORTED: seller-party corrections arrive with the parties slice (004)'; END IF;
  IF p_reason IS NULL OR pg_catalog.btrim(p_reason) = '' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  v_rel := iit.latest_released_version(p_deal);
  IF v_rel IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'NOT_RELEASED: deal % has no released version; edit the draft through the intake functions', p_deal; END IF;
  v_draft := iit.open_draft_version(p_deal);
  IF v_draft IS NOT NULL THEN
    SELECT cause INTO v_cause FROM iit.deal_versions WHERE deal_id = p_deal AND version_no = v_draft;
    IF v_cause <> 'material_correction' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DRAFT_OPEN_NON_MATERIAL: deal % has an open % draft v%', p_deal, v_cause, v_draft; END IF;
  ELSE
    v_draft := v_rel + 1; v_new_draft := true;
    INSERT INTO iit.deal_versions(deal_id, version_no, status, cause) VALUES (p_deal, v_draft, 'draft', 'material_correction');
  END IF;
  SELECT coalesce(max(id), 0) INTO v_mark FROM iit.record_history;
  SELECT * INTO w FROM iit._apply_field(p_deal, p_field, p_value);
  IF w.before IS NOT DISTINCT FROM w.after THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'NO_CHANGE: % already has that value', p_field; END IF;
  -- the exact history rows of this change (this table, this record, written after the mark, under the Deal lock)
  SELECT pg_catalog.array_agg(id ORDER BY id) INTO v_ids FROM iit.record_history WHERE id > v_mark AND table_name = w.table_name AND record_id = w.record_id;
  IF v_ids IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'HISTORY_MISSING: no history row recorded for % on %', p_field, w.table_name; END IF;
  PERFORM iit.compute_requirements(p_deal, v_draft);                                    -- VIN / title / tribal may change the keys
  IF v_new_draft THEN PERFORM iit.carry_over_validations(p_deal, v_rel, v_draft, v_actor); END IF;
  INSERT INTO iit.material_corrections(deal_id, from_version_no, draft_version_no, fields, history_ids, by)
    VALUES (p_deal, v_rel, v_draft, ARRAY[p_field], v_ids, v_actor) RETURNING id INTO v_corr;
  v_hold := iit.open_hold(p_deal, 'material_correction', v_actor, v_corr, v_draft);
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, before, after, actor_id, actor_kind, source)
    VALUES (p_deal, 'material_correction', v_corr, 'field_corrected', pg_catalog.jsonb_build_object('field', p_field, 'from_version_no', v_rel),
            pg_catalog.jsonb_build_object('field', p_field, 'version_no', v_draft, 'reason', p_reason), v_actor, 'user', 'data_entry_ui');
  PERFORM iit.actor_restore(v_prev);
  RETURN v_corr;
END $$;

-- amend_field (data_entry, §5.5 administrative amendment): the field must NOT be material; applied straight to the live record
-- of a released Deal as a numbered amendment on the latest released version. No draft, no hold, approval kept. If the field is
-- listed in legacy_31_fields, a same-day correction work item goes to Data Entry (the bridge is add-only). Returns amendment_no.
CREATE FUNCTION iit.amend_field(p_deal uuid, p_field text, p_value jsonb, p_reason text, p_actor_base44_user_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; v_rel int; w record; v_no int;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF d.cancelled_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_CANCELLED: %', p_deal; END IF;
  IF EXISTS (SELECT 1 FROM iit.material_fields WHERE field = p_field) THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'MATERIAL_FIELD: % is material (use correct_field)', p_field; END IF;
  IF p_reason IS NULL OR pg_catalog.btrim(p_reason) = '' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  v_rel := iit.latest_released_version(p_deal);
  IF v_rel IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'NOT_RELEASED: deal % has no released version; edit the draft through the intake functions', p_deal; END IF;
  SELECT * INTO w FROM iit._apply_field(p_deal, p_field, p_value);
  IF w.before IS NOT DISTINCT FROM w.after THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'NO_CHANGE: % already has that value', p_field; END IF;
  SELECT coalesce(max(amendment_no), 0) + 1 INTO v_no FROM iit.deal_amendments WHERE deal_id = p_deal AND version_no = v_rel;
  INSERT INTO iit.deal_amendments(deal_id, version_no, amendment_no, field, before, after, by, reason) VALUES (p_deal, v_rel, v_no, p_field, w.before, w.after, v_actor, p_reason);
  IF EXISTS (SELECT 1 FROM iit.legacy_31_fields WHERE field = p_field) THEN
    INSERT INTO iit.work_items(kind, deal_id, assigned_role, due_at, detail)
      VALUES ('same_day_31_correction', p_deal, 'data_entry', pg_catalog.date_trunc('day', now()) + interval '1 day', pg_catalog.jsonb_build_object('field', p_field, 'amendment_no', v_no));
  END IF;
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (p_deal, 'deal_amendment', NULL, 'field_amended', pg_catalog.jsonb_build_object('field', p_field, 'version_no', v_rel, 'reason', p_reason), v_actor, 'user', 'data_entry_ui');
  PERFORM iit.actor_restore(v_prev);
  RETURN v_no;
END $$;

-- rebind_hold (audit_lead, §5.7a G4 rebinding): only for an OPEN material_correction hold whose covering version was SUPERSEDED
-- before approval. The hold moves to the latest released version only after snapshot_contains_changes() proves that version's
-- snapshot contains every change in material_corrections.history_ids; the proof result is written on the 'rebound' event. If a
-- current attempt for the target version exists the hold is bound to it, else it is bound when that attempt is created.
-- Without proof the hold stays as it is (REBIND_REFUSED). Role choice is a proposal (D-24).
CREATE FUNCTION iit.rebind_hold(p_hold uuid, p_reason text, p_actor_base44_user_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; h record; v_deal uuid; v_target int; v_cover_status text; v_fail text; v_ids bigint[]; v_check uuid; v_check_ver int;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'audit_lead');
  v_prev := iit.actor_push(v_actor, 'user');
  SELECT deal_id INTO v_deal FROM iit.audit_holds WHERE id = p_hold;
  IF v_deal IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'HOLD_UNKNOWN: %', p_hold; END IF;
  PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
  SELECT * INTO h FROM iit.audit_holds WHERE id = p_hold;                              -- reloaded under the lock
  IF h.released_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REBIND_REFUSED: hold % is released', p_hold; END IF;
  IF h.cause <> 'material_correction' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REBIND_REFUSED: only material_correction holds rebind (hold % is %)', p_hold, h.cause; END IF;
  SELECT status INTO v_cover_status FROM iit.deal_versions WHERE deal_id = v_deal AND version_no = h.covers_version_no;
  IF v_cover_status IS DISTINCT FROM 'superseded' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REBIND_REFUSED: covering version v% of hold % is % (rebinding applies only when it was superseded before approval)', h.covers_version_no, p_hold, coalesce(v_cover_status, 'missing'); END IF;
  v_target := iit.latest_released_version(v_deal);
  IF v_target IS NULL OR v_target <= h.covers_version_no THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REBIND_REFUSED: no newer released version for deal %', v_deal; END IF;
  SELECT history_ids INTO v_ids FROM iit.material_corrections WHERE id = h.correction_id;
  v_fail := iit.snapshot_contains_changes(v_deal, v_target, v_ids);
  IF v_fail IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REBIND_REFUSED: proof failed for hold % → v%: %', p_hold, v_target, v_fail; END IF;
  v_check := iit.current_attempt(v_deal);
  SELECT deal_version_no INTO v_check_ver FROM iit.prequalification_checks WHERE id = v_check;
  IF v_check_ver IS DISTINCT FROM v_target THEN v_check := NULL; END IF;               -- bound later by create_audit_attempt for v_target
  UPDATE iit.audit_holds SET covers_version_no = v_target, covering_check_id = v_check WHERE id = p_hold;
  INSERT INTO iit.audit_hold_events(hold_id, event, check_id, from_version_no, to_version_no, reason, by)
    VALUES (p_hold, 'rebound', v_check, h.covers_version_no, v_target,
            pg_catalog.format('%s | proof: v%s snapshot (watermark) contains history %s', p_reason, v_target, pg_catalog.array_to_string(v_ids, ',')), v_actor);
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (v_deal, 'audit_hold', p_hold, 'hold_rebound', pg_catalog.jsonb_build_object('from_version_no', h.covers_version_no, 'to_version_no', v_target, 'reason', p_reason), v_actor, 'user', 'audit_ui');
  PERFORM iit.actor_restore(v_prev);
  RETURN v_target;
END $$;

-- resolve_flag (data_entry): closes an open intake flag as 'resolved' or 'accepted' with a resolution text. Deal lock taken
-- (§5.7 locking: flag changes cannot race a release).
CREATE FUNCTION iit.resolve_flag(p_flag uuid, p_status text, p_resolution text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; v_deal uuid; f record;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  IF p_status NOT IN ('resolved','accepted') THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'FLAG_STATUS: % (resolved | accepted)', p_status; END IF;
  IF p_resolution IS NULL OR pg_catalog.btrim(p_resolution) = '' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  SELECT deal_id INTO v_deal FROM iit.intake_flags WHERE id = p_flag;
  IF v_deal IS NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'FLAG_UNKNOWN: %', p_flag; END IF;
  PERFORM 1 FROM iit.deals WHERE id = v_deal FOR UPDATE;
  SELECT * INTO f FROM iit.intake_flags WHERE id = p_flag;
  IF f.status <> 'open' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'FLAG_NOT_OPEN: % is %', p_flag, f.status; END IF;
  UPDATE iit.intake_flags SET status = p_status, resolved_by = v_actor, resolution = p_resolution, resolved_at = now() WHERE id = p_flag;
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (v_deal, 'intake_flag', p_flag, 'flag_resolved', pg_catalog.jsonb_build_object('status', p_status, 'reason', p_resolution), v_actor, 'user', 'data_entry_ui');
  PERFORM iit.actor_restore(v_prev);
END $$;

-- resolve_work_item: the actor must hold the item's assigned_role. restart_candidate items are NOT closed here — their outcomes
-- (restart_new_episode / no_restart, §5.3) create Deals and episodes and belong to the intake slice (004).
CREATE FUNCTION iit.resolve_work_item(p_item uuid, p_outcome text, p_actor_base44_user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; w record;
BEGIN
  SELECT * INTO w FROM iit.work_items WHERE id = p_item;
  IF w IS NULL THEN RAISE EXCEPTION 'WORK_ITEM_UNKNOWN: %', p_item; END IF;
  v_actor := iit.require_role(p_actor_base44_user_id, w.assigned_role);
  v_prev := iit.actor_push(v_actor, 'user');
  IF p_outcome IS NULL OR pg_catalog.btrim(p_outcome) = '' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  IF w.deal_id IS NOT NULL THEN PERFORM 1 FROM iit.deals WHERE id = w.deal_id FOR UPDATE; END IF;
  SELECT * INTO w FROM iit.work_items WHERE id = p_item;
  IF w.status <> 'open' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'WORK_ITEM_NOT_OPEN: %', p_item; END IF;
  IF w.kind = 'restart_candidate' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'WORK_ITEM_KIND_DEFERRED: restart decisions arrive with the intake slice (004)'; END IF;
  UPDATE iit.work_items SET status = 'closed', closed_by = v_actor, closed_at = now(), outcome = p_outcome WHERE id = p_item;
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (w.deal_id, 'work_item', p_item, 'work_item_closed', pg_catalog.jsonb_build_object('outcome', p_outcome), v_actor, 'user', 'data_entry_ui');
  PERFORM iit.actor_restore(v_prev);
END $$;

-- cancel_deal (data_entry, §5.7a G12): terminal. Sets cancelled_at and opens the never-released 'cancel' hold in the same
-- transaction (open_hold runs the §6.4 sweep once the gate slice adds it — stated there, not emulated). Ends the Deal's open
-- appraisal episode, and opens a cancel_31_update work item when a linked current 3.1 row exists (the bridge is add-only, so
-- 3.1 is updated by Data Entry). A restart is a new Deal (§5.3, 004).
CREATE FUNCTION iit.cancel_deal(p_deal uuid, p_reason text, p_actor_base44_user_id text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prev iit.actor_ctx; d record; v_hold uuid;
BEGIN
  v_actor := iit.require_role(p_actor_base44_user_id, 'data_entry');
  v_prev := iit.actor_push(v_actor, 'user');
  IF p_reason IS NULL OR pg_catalog.btrim(p_reason) = '' THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  SELECT * INTO d FROM iit.deals WHERE id = p_deal FOR UPDATE;
  IF NOT FOUND THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_UNKNOWN: %', p_deal; END IF;
  IF d.cancelled_at IS NOT NULL THEN PERFORM iit.actor_restore(v_prev); RAISE EXCEPTION 'DEAL_CANCELLED: % was cancelled at %', p_deal, d.cancelled_at; END IF;
  UPDATE iit.deals SET cancelled_at = now(), cancellation_reason = p_reason, audit_status = 'cancelled' WHERE id = p_deal;
  v_hold := iit.open_hold(p_deal, 'cancel', v_actor);
  UPDATE iit.appraisal_episodes SET ended_at = now(), end_reason = 'cancelled' WHERE deal_id = p_deal AND ended_at IS NULL;
  IF EXISTS (SELECT 1 FROM iit.source_records s WHERE s.deal_id = p_deal AND s.link_status = 'linked' AND s.status = 'current') THEN
    INSERT INTO iit.work_items(kind, deal_id, assigned_role, detail) VALUES ('cancel_31_update', p_deal, 'data_entry', pg_catalog.jsonb_build_object('reason', p_reason));
  END IF;
  INSERT INTO iit.activity_events(deal_id, entity_type, entity_id, action, after, actor_id, actor_kind, source)
    VALUES (p_deal, 'deal', p_deal, 'deal_cancelled', pg_catalog.jsonb_build_object('reason', p_reason), v_actor, 'user', 'data_entry_ui');
  PERFORM iit.actor_restore(v_prev);
  RETURN v_hold;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5. grants and RLS
-- ---------------------------------------------------------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA iit FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  iit.set_source_channel(uuid,text,text), iit.release_deal(uuid,text), iit.correct_field(uuid,text,jsonb,text,text), iit.amend_field(uuid,text,jsonb,text,text),
  iit.rebind_hold(uuid,text,text), iit.resolve_flag(uuid,text,text,text), iit.resolve_work_item(uuid,text,text), iit.cancel_deal(uuid,text,text)
TO iit_integration;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA iit TO iit_integration;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA iit TO iit_integration;
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'iit' AND c.relkind = 'r' AND NOT c.relrowsecurity LOOP
    EXECUTE pg_catalog.format('ALTER TABLE iit.%I ENABLE ROW LEVEL SECURITY', r.relname);
  END LOOP; END $$;
RESET ROLE;
COMMIT;
