# Migration 007 — staff read RPC contract (approved direction)

Status: **rev 2, 29 Oct 2026 — owner decisions A–H, Q1 and Q2 applied; Codex PR #15 review (P1 admin visibility, P2 state-token coverage) applied; implemented in
`supabase/migrations/20261028000107_staff_read_rpcs.sql`; for Codex review.** Not applied to Supabase. Sources: the owner's
decision messages of 29 Oct 2026, the Base44 mock-service contract export (prototype only; 11 query adapters, 15 mutation
adapters, 1 identity method), `docs/d2-deployment-package.md`, migrations 001–006 as merged (`main` at `8205530`).
Every returned field below names its canonical source; a mock field with no canonical source is listed in §5 as deferred,
never invented. The stale-write analysis of the 15 mutation adapters is in `007-stale-write-gap-report.md`.

## 1. Owner decisions (29 Oct 2026)

| # | Decision |
|---|---|
| A | Ten read RPCs: `get_my_profile`, `get_deal`, `list_work_items`, `list_audit_queue`, `list_unknown_outcomes`, `get_unknown_outcome`, `get_dashboard_summary`, `list_staff`, `list_source_channels`, `search_deals`. No activity-history RPC (activity is a `get_deal` section). No consignment-queue RPC (`list_work_items` virtual kind). `get_report` **deferred** until a real report-screen contract exists; `authorize_report_access` unchanged. |
| B | Admin has no operational deal visibility. Data Entry: its queues, work items, consignment setup, unknown outcomes, permitted deal detail incl. seller contact and operational financial/title/lien fields. Auditor/audit_lead: audit queues and audit-review deal detail, evidence/title/lien/purchase/correction facts, **no seller phone/email**. audit_lead also sees escalations. No read RPC for `iit_integration`. anon, authenticated, service_role, tav_worker denied. Credential errors are never masked. |
| C | Excluded: licensed vAuto/MMR valuations, raw vAuto notes, unrestricted source observations, unrestricted before/after history, gate action keys and raw integration payloads, report object paths, secrets. Canonical fields only. |
| D | Fixed JSON envelopes; keyset cursors; default 50, max 100, above 100 rejected; unique tie-breaker; empty lists are not errors; credential/role checks before identifier resolution; fixed not-found for authorized callers; no existence disclosure to unauthorized callers. |
| E | One identifier-minimized read-access audit table, written by `get_deal` and `get_unknown_outcome` (and later get_report-style functions); lists, search, reference data and aggregates are not audited row by row. Transaction semantics documented (§2.4). |
| F | Detail responses return the authoritative state token. The 27 write signatures do not change in 007. A mutation-by-mutation stale-write gap report is produced. **Before Base44 is connected to production, every state-dependent mutation must require an authoritative expected-state token (omission must not bypass it) or have equivalent database-enforced protection — a mandatory pre-connection gate.** |
| G | Prototype mismatches are documented (§6), not copied. |
| Q1 | `list_work_items` virtual kind `consignment_setup`: every open manual-consignment deal (`intake_status` new/in_review, not cancelled or voided), complete or not, as `record_type: "derived_deal"` rows keyed by `deal_id`; no work item is created; `set_consignment` stays the write path. |
| Q2 | `search_deals` types: `iit_id` → `iit.deals.id`; `deal_number` → `iit.deals.deal_number`; `vin` → `vehicles.vin_normalized`; `source_31_id` (label "3.1 ID") → `source_records.legacy_iid` with `link_status = 'linked'` only, no VIN fallback. Stock number deferred. |

Interpretations made while implementing (none changes a signature, authorization boundary or business rule; listed for review):
- **Audit-review visibility** (B.3): an auditor or audit lead may open a deal that has at least one Risk Audit attempt (`prequalification_checks` row); other deals are invisible to them and answer exactly like an unknown id. Data Entry sees every deal.
- **Several roles**: a caller holding several roles receives the union of the projections those roles permit; there is no caller-chosen projection.
- **Work items inside `get_deal`** follow `list_work_items`' rule: only items assigned to a role the caller holds.
- **Audit decision comments** are returned to audit roles only (B.2 does not list them for Data Entry).
- **Free-text fields with no allowlist are excluded**: intake-flag `detail` (holds raw vAuto fragments), work-item `detail` (may hold action keys), gate evidence `note`, gate event `reason`.

## 2. Common contract

### 2.1 Shape and authorization
Every RPC is `SECURITY DEFINER`, `SET search_path = ''`, owned by `iit_owner`, created after 007's V-2 default revoke, with its
own `REVOKE ALL … FROM PUBLIC` and `GRANT EXECUTE` to `iit_base44` only. No SQL `DEFAULT`s: callers pass every named
parameter (`p_limit` NULL = 50, `p_cursor` NULL = first page). `p_actor_base44_user_id` is last, from Base44's server session.

Authorization runs first, through `iit._read_ctx` / `iit._require_read`, which call `iit.require_role` itself for each candidate
role: the 006 originating-role, claims, `jti`, revocation, active-identity and staff-role checks are reused unchanged. Only
`ROLE_MISSING` (42501) is caught to learn which roles are held; every 28000 credential or identity error propagates with its
own message. A `''` sentinel forces one full check even when no candidate role is held (`get_my_profile` for a staff member
with no role).

### 2.2 Errors and envelopes
| Case | Result |
|---|---|
| credential / identity | 28000 `CREDENTIAL_NO_CLAIMS` · `CREDENTIAL_ROLE_MISMATCH` · `CREDENTIAL_NO_JTI` · `CREDENTIAL_REVOKED` · `ACTOR_REQUIRED` · `ACTOR_UNKNOWN_OR_INACTIVE` |
| role | 42501 `ROLE_MISSING: <rpc>` — raised before any identifier is resolved, identical for existing and unknown ids |
| parameter | 22023 `INVALID_PARAMETER: <name>` (limit outside 1..100, unknown filter value, malformed/forged/foreign cursor, malformed lookup value) |
| unknown record, authorized caller | `{"status":"not_found","record_type":"<type>"}` |
| record outside the caller's visibility | the same not-found envelope (audited as `denied`) |
| list | `{"status":"ok","items":[…],"next_cursor":text\|null,"limit":int,"as_of":timestamptz}` (empty `items` for no rows) |
| single record | `{"status":"ok","record_type":"…","data":{…}, …}` |

Every object is built with `jsonb_build_object` from named columns — never `to_jsonb(row)` — so a new column never leaks.

### 2.3 Paging
Keyset cursors: opaque base64 JSON carrying the last row's sort keys and a query-shape tag (`q`: RPC + filters). A cursor from
another query, with a missing or mistyped key, longer than 512 characters or not decodable is `INVALID_PARAMETER: p_cursor`. A
cursor can only position within rows the caller may already see. Each list fetches `limit + 1` rows to decide `next_cursor`.
Per-deal collections inside `get_deal` are capped at 100 and named in `truncated` when the cap is hit.

### 2.4 Read-access audit (`iit.read_access_audit`)
Columns: `id`, `at` (clock time), `actor_user_id` (internal `users.id`), `credential_jti` (only when the originating role is
`iit_base44`), `origin_role`, `rpc`, `category` (`deal_detail` · `unknown_outcome_detail` · `report_detail` reserved),
`target_type` (`deal` · `deal_version` · `gated_action` · `report` reserved), `target_id`, `target_version`, `outcome`
(`granted` · `not_found` · `denied`), `correlation_id` (from a well-formed `X-Correlation-Id` request header, else NULL). No
returned data, VIN, seller data, evidence text or search term is stored. Append-only (`make_append_only`, rejected even for the
superuser); no IIT grant to any role but `iit_owner`; not history-covered (it is itself the record). Owner-only describes IIT's
grants: platform-managed roles with `pg_read_all_data` (e.g. `postgres`) can still read it, as every `iit` table (V-3,
`docs/preflight/migration-007-application-2026-10-29.md` §5).

**Transaction semantics.** The row is written in the caller's transaction. A raised exception (credential, role, parameter,
infrastructure) and a rolled-back caller transaction leave **no row**; those failures must be recorded at the calling server
boundary (Base44 backend / PostgREST logs). Outcomes that must be durably audited — an unknown record, a record outside the
caller's visibility — therefore return the not-found envelope instead of raising, and are committed with the call. `get_deal`
and `get_unknown_outcome` are `VOLATILE` for this reason (PostgREST runs them read-write on `POST`); every other read is
`STABLE`.

### 2.5 State tokens (rev 2, Codex P2)
`state_token = 'v1:' || md5(…)`, computed by `iit._deal_state_token(deal)`, never stored, so a future expected-state check
inside a write can recompute the same value under the Deal lock (gap report §3). It is one md5 over named categories. A
**mutable** table enters as its full rows (`to_jsonb`, ordered by key; hashed only, never returned). An **append-only** table
enters as a deterministic watermark — its rows never change or disappear, so the watermark moves on every accepted append.

| Category | What enters the token | Covers in `get_deal` |
|---|---|---|
| `deal` | full `deals` row | `deal`, `purchase`, `version.current_version_no`, eligibility inputs |
| `vehicle` | full `vehicles` row | `vehicle`, VIN-based requirements |
| `source_channel` | full row of the deal's channel | `deal.source_channel`, missing-fact `source_channel` |
| `fact_rules` | `required_fact_rules` rows for the deal's origin | `missing_required_facts`, release eligibility |
| `versions` | every `deal_versions` row except `snapshot` | `version`, frozen `version`, eligibility |
| `title`, `lien`, `consignment` | full rows | those sections |
| `parties` | full `deal_parties` + `seller_parties` rows | `parties`, frozen parties (same rows) |
| `organizations` | `(id, name)` of business sellers and the lienholder | `business_org`, `lienholder` |
| `flags`, `holds`, `requirements`, `reports`, `attempts`, `work_items`, `gated_actions` | full rows of `intake_flags`, `audit_holds`, `deal_report_requirements`, `external_vehicle_reports`, `prequalification_checks`, `work_items` (all roles, not only the caller's), `gated_actions` | those sections, requirement satisfaction, approval eligibility |
| `validations_wm`, `waivers_wm`, `revocations_wm` | `max(report_validations.id)`, `max(report_waivers.seq)`, `max(report_waiver_revocations.id)` | requirement satisfaction |
| `decisions_wm` | `max(audit_decisions.seq)` over the deal's attempts | `current_attempt.decisions`, approval eligibility |
| `corrections_wm`, `amendments_wm` | `(count, max(at))` of `material_corrections`; `max(deal_amendments.id)` | `corrections` |
| `activity_wm` | `max(activity_events.id)` for the deal | `activity` |
| `users` | `(id, display_name)` of every user the sections reference (buyer, closer, releaser, correction and amendment authors, deciders, activity actors) | every staff reference |

Not in the token, deliberately: `deal_versions.snapshot` (written once at release; the version's `status`/`released_at` change
with it), `record_history` and `read_access_audit` (telemetry — a read never changes the token), any column of
`organizations`/`users` other than those listed, and tables `get_deal` does not read. The token does **not** cover reference
data that only stored rows depend on (e.g. `report_requirement_rules`, which act through `compute_requirements` into
`deal_report_requirements`, which is covered).

`get_unknown_outcome.state_token` = `iit._action_state_token(action)`: md5 over the full `gated_actions` row, its full
`gated_action_attempts` rows, `max(gated_action_events.id)`, the full rows of its linked `work_items`, and the deal token.

Proven by test R13 (one isolated accepted change per category; repeated reads, read-audit rows and other deals' changes leave
the token unchanged) and by one mutant per category that removes it from the token.

## 3. Base44 adapter mapping

| Mock adapter | Database contract | Notes |
|---|---|---|
| `getMockIdentity` (identity) | `get_my_profile` | Roles from `user_roles`; the client-supplied `mockRole` and role switcher are removed (G). |
| `queryDataEntrySummary` | `get_dashboard_summary` → `data.data_entry` | Counts in §4.7; mock-only cards deferred (§5). |
| `queryRiskAuditSummary` | `get_dashboard_summary` → `data.risk_audit` | Counts in §4.7; "today" and aging cards deferred. |
| `queryDataEntryQueue` | `list_work_items(p_kind, p_status, …)` | data_entry/auditor/audit_lead; server filters: kind, status. Other mock filters deferred (§5); nav badge = a list call. |
| `queryConsignmentQueue` | `list_work_items('consignment_setup', …)` | Derived deal rows (Q1). |
| `queryRiskAuditQueue` | `list_audit_queue(p_queue, …)` | `p_queue`: NULL / `open` / `escalated`. Assignment and auditor filter deferred (no IIT assignment). |
| `queryDealDetail` | `get_deal(p_deal, NULL, …)` | Role projections (§4.2). |
| `queryAuditReview` | `get_deal(p_deal, NULL or version, …)` | Same RPC; `approval_eligibility` + attempt for audit roles; the frozen release via `p_version`. |
| `queryActivityHistory` | none — `get_deal.data.activity` | Unused in the prototype (A). |
| `queryUnknownOutcomes` | `list_unknown_outcomes` | `outcome_unknown` actions only; "conflicting" becomes `has_conflicting_reports`. |
| `queryUnknownOutcome` | `get_unknown_outcome` | Bounded detail (§4.6). |
| `queryGlobalSearch` | `search_deals(p_type, p_value, …)` | Exact lookups only (Q2); seller/dealer/consignor/stock search not implemented. |
| auditor selector (hard-coded in the client) | `list_staff('auditor_selector', …)` | Names only; there is no IIT assignment to submit them to yet. |
| fixed source selectors | `list_source_channels` | Active channels. |
| staff admin | `list_staff('admin', …)` | |

Derived in Base44 (no RPC): enumerations fixed by CHECK constraints (roles, report types, decision values, party roles,
origins), saved filter views (browser only), and display formatting.

## 4. Per-RPC contracts and field sources

Notation: `field ← table.column` or `← computation`. "(DE)" = Data Entry projection only; "(AU)" = audit-review projection only.

### 4.1 `get_my_profile(p_actor_base44_user_id text) → jsonb`
Roles: any active staff identity (a staff member with no role gets `roles: []`). Not audited.
`data.user_id ← staff_identities.user_id` · `data.display_name ← users.display_name` · `data.roles ← user_roles.role` (sorted).

### 4.2 `get_deal(p_deal uuid, p_version int, p_actor_base44_user_id text) → jsonb`
Roles: data_entry (every deal), auditor/audit_lead (deals with a Risk Audit attempt). Admin alone: 42501. Audited: every call
that passes authorization (`granted` / `not_found` / `denied`).
Envelope: `status`, `record_type: "deal"`, `view: "live"|"frozen"`, `projections` (`data_entry`, `audit_review`), `data`, `state_token`.
Live (`p_version` NULL):
- `deal`: `id, deal_number, origin, intake_status, audit_status, on_hold, gate_clear, consumer_route, data_entry_due_at, created_at, cancelled_at, cancellation_reason, restarted_from_deal_id, dealer_sold_to, dealer_auction_name ← deals.*` · `source_channel{id,name,route} ← source_channels` · `buyer, closer{id,display_name} ← users`
- `purchase`: `purchase_price, deposit_amount, balance, balance_owed ← deals` (both projections: owner B.3 "purchase facts")
- `vehicle`: `vin, year, make_text, model_text, series, exterior_color ← vehicles`
- `parties[]`: `deal_party_id, role, ordinal ← deal_parties` · `party_id, party_type, first_name, last_name, city, state ← seller_parties` · `business_org{id,name} ← organizations` · `phone, email ← seller_parties` **(DE)**
- `consignment`: `consignor_party_id, consignment_amount ← consignments` · `notes` **(DE)**
- `title`: `custody, title_state, title_number, title_miles, brand, is_tribal, current_location, received_at ← deal_titles`
- `lien`: `position, lienholder_name_raw, lienholder_phone, payoff_amount, payoff_good_through, per_diem, source ← deal_liens` · `lienholder{id,name} ← organizations` (lienholder phone is the lender's, not the seller's)
- `missing_required_facts ← iit.missing_required_facts(deal)`
- `requirements{version_no, items[]}`: `requirement_key, report_type, subject_type, freshness_baseline ← deal_report_requirements` of the open draft, else the latest released version · `satisfied ← iit.requirement_satisfied`
- `flags[]` (open): `id, code, blocks_release, opened_at ← intake_flags`
- `holds[]` (open): `id, cause, opened_at, covers_version_no, covering_check_id ← audit_holds`
- `work_items[]` (assigned to a held role): `id, kind, assigned_role, status, due_at, opened_at, closed_at, outcome, gated_action_id ← work_items`
- `corrections.material[]`: `id, from_version_no, draft_version_no, fields, at ← material_corrections` · `by ← users` — `corrections.amendments[]`: `version_no, amendment_no, field, reason, at ← deal_amendments` · `by ← users` (no before/after values)
- `activity[]` (100 newest): `id, occurred_at, entity_type, action, actor_kind, source ← activity_events` · `actor ← users` (no before/after)
- `current_attempt`: `check_id, deal_version_no, status, opened_at, reopened_from_check_id ← prequalification_checks` (the non-superseded attempt) · `decisions[]`: `decision, decided_at ← audit_decisions` · `decided_by ← users` · `comments` **(AU)**
- `version`: `current_version_no ← deals` · `latest_released_version_no ← iit.latest_released_version` · `open_draft_version_no ← iit.open_draft_version` · `draft_cause ← deal_versions.cause`
- `release_eligibility` **(DE)** `{eligible, blocking[], missing_required_facts, authority: "release_deal"}` ← the `release_deal` preconditions evaluated read-only (cancelled/voided, no open draft, missing facts incl. source channel, consumer route, open blocking flags, stored requirements of the draft). Advisory: `release_deal` recomputes requirements before its own check.
- `approval_eligibility` **(AU)** `{eligible, blocking[], open_hold_count, authority: "record_decision"}` ← the `record_decision` preconditions (current attempt exists, is for the latest released version, no open material draft).
- `truncated[]` ← collections that hit the 100 cap.
Frozen (`p_version` = a released or superseded version; a draft or unknown version → `not_found` `deal_version`):
`version{version_no, status, cause, opened_at, released_at, released_by}` ← `deal_versions` · `snapshot` ← `deal_versions.snapshot`
re-projected through the same allowlist (seller phone/email DE only; no ids beyond the business ones listed) ·
`requirement_satisfaction[]` ← that version's `deal_report_requirements` + `iit.requirement_satisfied`.

### 4.3 `list_work_items(p_kind text, p_status text, p_limit int, p_cursor text, p_actor_base44_user_id text) → jsonb`
Roles (rev 2, Codex P1): **data_entry, auditor, audit_lead only**. Rows: stored items whose `assigned_role` is one of those operational roles that the caller actually holds (no role parameter). Admin-assigned items are returned to nobody; an admin-only caller gets `ROLE_MISSING: list_work_items` before any work item, deal or parameter is read — the same refusal whatever rows exist. Admin's read surface is `list_staff('admin', …)` only. `consignment_setup`: Data Entry only.
Filters: `p_kind` NULL (all stored kinds) · one of the 17 `work_items_kind_check` kinds · `consignment_setup`. `p_status`
NULL/`open` · `closed` (derived rows: open only). Ordering: open `(opened_at, id)`; closed `(closed_at DESC, id DESC)`;
derived `deal_number`. Not audited.
Stored row (`record_type: "work_item"`): `id, kind, assigned_role, status, due_at, opened_at, closed_at, outcome, gated_action_id ← work_items` · `overdue ← status = 'open' AND due_at < now()` · `deal{id, deal_number} ← deals` + `vin, year, make_text, model_text ← vehicles`.
Derived row (`record_type: "derived_deal"`): `deal_id, deal_number, intake_status ← deals` · `vehicle{vin, year, make_text, model_text} ← vehicles` · `consignor_present ← EXISTS consignments.consignor_party_id` · `consignment_amount ← consignments` · `missing_required_facts ← iit.missing_required_facts` (complete result) · `state_token ← iit._deal_state_token`.

### 4.4 `list_audit_queue(p_queue text, p_limit int, p_cursor text, p_actor_base44_user_id text) → jsonb`
Roles: auditor, audit_lead. Rows: non-superseded attempts with `status = 'open'` (`queue_reason: "open"`); for audit leads also
decided attempts whose latest decision is `escalated` (`queue_reason: "escalated"`). `p_queue = 'escalated'` from a non-lead: 42501.
No assignment (none exists in IIT). Ordering `(opened_at, check_id)`. Not audited.
Row (`record_type: "audit_attempt"`): `check_id, deal_version_no, opened_at, reopened_from_check_id ← prequalification_checks` · `deal{id, deal_number, on_hold} ← deals` + vehicle summary · `latest_decision{decision, decided_at} ← audit_decisions` (no comments) · `open_hold_count ← audit_holds` · `material_draft_open ← iit.open_material_draft_exists` · `requirements_all_satisfied ← iit.requirements_all_satisfied(deal, deal_version_no)`.

### 4.5 `list_unknown_outcomes(p_limit int, p_cursor text, p_actor_base44_user_id text) → jsonb`
Roles: data_entry (the role of `resolve_unknown_outcome`). Rows: `gated_actions.state = 'outcome_unknown'`. Ordering `(created_at, id)`. Not audited.
Row (`record_type: "gated_action"`): `id, action, caller_integration, state, authorized_at, deal_version, created_at ← gated_actions` · `source_31_id ← gated_actions.iid` · `deal{id, deal_number} ← deals` · `has_conflicting_reports ← EXISTS gated_action_events.event = 'conflict'` · `open_work_item_id ← work_items.gated_action_id`. Excluded: `action_key`, `triggered_by_text`, `outcome_evidence`.

### 4.6 `get_unknown_outcome(p_action uuid, p_actor_base44_user_id text) → jsonb`
Roles: data_entry. Visible actions: state `outcome_unknown`, or one with a `resolved` event (was an unknown outcome); any other
gate action answers like an unknown id (audited `denied`). Audited.
`action{id, action, caller_integration, state, authorized_at, deal_version, outcome_reported_at, completed_after_hold, created_at} ← gated_actions` · `source_31_id ← iid` ·
`evidence ← outcome_evidence` keys `provider_message_id, package_id, trip_id, target, http_status` (the 005 allowlist minus free-text `note`) ·
`attempts[]{attempt_no, state, granted_at, reported_at, supplied_row_status, read_31_status, read_31_at} ← gated_action_attempts` ·
`timeline[]{event, at, attempt_no, detail} ← gated_action_events` with `detail` keys `outcome, status_mismatch, resolution, replay, attempt_no, hold_id` only ·
`deal{id, deal_number, on_hold, vehicle, open_holds[]{id, cause, opened_at}}` · `work_items[]{id, kind, assigned_role, status, opened_at, closed_at} ← work_items.gated_action_id` ·
`state_token ← iit._action_state_token`. Excluded: `action_key`, `triggered_by_text`, `caller_run_ref`, evidence `note`, event `reason`.

### 4.7 `get_dashboard_summary(p_actor_base44_user_id text) → jsonb`
Roles: data_entry and/or auditor/audit_lead; a section per held role; admin alone 42501. Counts only. Not audited.
`data_entry`: `new_intake`, `in_review` ← open deals (`intake_status`, not cancelled) · `missing_required_facts` ← open deals with a non-empty `missing_required_facts` · `open_blocking_flags` ← open deals with an open blocking flag · `overdue_data_entry` ← open deals with `data_entry_due_at < now()` · `unknown_outcomes` ← `gated_actions` outcome_unknown · `consignment_setup` ← the Q1 set · `deals_on_hold` ← deals with an open hold · `restart_candidates` ← open `restart_candidate` items · `open_work_items` ← open items assigned to data_entry.
`risk_audit`: `awaiting_decision` ← open attempts · `blocked_by_holds` ← open attempts on a deal with an open hold · `missing_evidence` ← open attempts whose version's requirements are not all satisfied · `material_drafts_open` ← current attempts on a deal with an open material draft · `escalated` (audit_lead only) ← current attempts whose latest decision is escalated.

### 4.8 `list_staff(p_purpose text, p_include_inactive boolean, p_limit int, p_cursor text, p_actor_base44_user_id text) → jsonb`
`admin` (admin role): `record_type: "staff"`, `user_id, display_name, email, created_at ← users` · `base44_user_id, deactivated_at ← staff_identities` · `active ← staff_identities.active AND users.active` · `roles ← user_roles`; inactive staff only with `p_include_inactive = true`.
`auditor_selector` (auditor/audit_lead): `record_type: "staff_option"`, `user_id, display_name` of active staff holding `auditor`; no email; `p_include_inactive = true` → 22023.
Service users excluded. Ordering `(display_name, user_id)`. Not audited.

### 4.9 `list_source_channels(p_limit int, p_cursor text, p_actor_base44_user_id text) → jsonb`
Roles: data_entry. Active rows: `id, name, route, origin ← source_channels`. Ordering `(name, id)`. Not audited.

### 4.10 `search_deals(p_type text, p_value text, p_limit int, p_cursor text, p_actor_base44_user_id text) → jsonb`
Roles: data_entry, auditor, audit_lead; results limited to deals the caller could open with `get_deal`. Value trimmed, 1–64
characters; `iit_id` must be a UUID, `deal_number` digits, `vin` upper-cased. Ordering `deal_number`. Not audited; the search
term is never stored.
Row (`record_type: "deal_match"`): `deal_id, deal_number, intake_status, audit_status ← deals` · `vehicle{vin, year, make_text, model_text}` · `matched_on ← p_type` · `match_label` ("IIT ID" · "Deal number" · "VIN" · "3.1 ID"). No seller, dealer, consignor or price.

## 5. Deferred and unsupported mock fields (no canonical source in 001–006)

- **Deal record:** `stockNumber` (no deal link for `idms_stock` references); `vehicle.trim` (no column; `series` is returned), `vehicle.mileage` (only `deal_titles.title_miles`); `dealType`/`runningFour`; `stage`/`status`/`priority` as mock enums (IIT has `intake_status`, `audit_status`, `on_hold`); `sources[]`; `seller` as a single name (IIT has parties); `dealer{name, rooftop}` (only `dealer_sold_to`, `dealer_auction_name`); `purchase.date`, `purchase.method`; `title.status`/`title.evidence[]`, `lien.bank`/`lien.evidence[]` as text lists; `transport{carrier, location, eta}`; `inspection{…}`; `funding{status, wireDate, wireRef}`; requirement statuses `missing`/`conflicting`/`not_applicable`/`awaiting_correction` (IIT: satisfied true/false); holds `label`/`blocking`/`openedBy` text; gate `expiresAt`, `lastKnownState`, outcome `conflicting`/`pending`, `reports[].late` (events `late_report` exist), `resolved{}` object; `observations[]` (raw source observations — excluded by C); `conflicts[]` (no conflict object); corrections `oldValue`/`newValue` (history excluded by C); `cancellation{canceledBy, canceledDate, cancellationCode}` (IIT: `cancelled_at`, `cancellation_reason`); consignment `consignorRooftop`, `dealerSourceField`, `fee`, `feeSource`, `saleStatus`, `titleStatus`, `collectionStatus`, `missingDealer`, `missingFee`, `obligations`; `audit.auditor`, `audit.returnCount`, decision `refuse`; `revision` (replaced by `state_token`).
- **Work-item row:** `title`, `priority`, `status` `in_progress`/`blocked`, `stage`, `source`, `assignee` (role, not person), `hold`, `missingCount`, `conflict`, `dealType`, `ageDays` (computable by the client from `opened_at`).
- **Dashboard cards:** `sourceConflicts`, `unmappedParties`, `canceledRescheduled`, `aging` (5-day threshold), `approvedToday`/`returnedToday`/`refusedToday` (no canonical day boundary or time zone; no `refuse` decision), `agingBeyondTarget` (2-day target), `materialCorrections` (merged into `material_drafts_open`).
- **Queue filters:** Data Entry `stage, source, assignee, priority, minAge, dealType, consignmentStatus, holdStatus, hasMissing, hasConflicts`; Risk Audit `route, stage, requirementStatus, holdStatus, materialCorrection, auditor, minAge, dealType, decision`. Each needs a canonical source and an owner-approved bounded filter before it is added.
- **Search:** stock number, seller, dealer, consignor names (not implemented — A.10).
- **Reports:** `get_report` deferred (A).

## 6. Prototype mismatches (owner G) — not copied

1. Mock queries have no authorization; every IIT read checks the credential and staff roles first.
2. Mock lists are unbounded and sorted client-side; IIT lists are capped (≤ 100), server-ordered with a unique tie-breaker, and cursor-paged.
3. `expectedRevision` is optional and bypassable; IIT returns an authoritative `state_token`, and the pre-connection gate (F) requires mandatory expected-state enforcement in the database.
4. `queryGlobalSearch` is a substring search over names; IIT search is exact lookup on four identifiers.
5. `queryActivityHistory` is unused; activity is a `get_deal` section.
6. No report screen exists; `get_report` is deferred.
7. Auditor names are hard-coded; `list_staff('auditor_selector')` lists real active auditors.
8. Audit assignment does not exist in IIT; `assignAuditItem` has no database path (gap report).
9. Many mock fields have no canonical source (§5).
10. `mockRole` is client-supplied; IIT roles come only from `user_roles` via `get_my_profile`, and the role switcher must not ship.
