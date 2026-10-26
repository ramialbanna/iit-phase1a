# Interim Inventory Tool — Phase 1a Supabase Schema Design (v0.3, for review)

**Date:** 19 Oct 2026 · **Author:** Claude · **Reviewer:** Codex · **Approver:** Rami

**Status:** Design for review. Nothing has been created in Supabase.

- v0.3 supersedes v0.2.
- §0a answers Codex's eight v0.2 findings.
- §0 keeps the v0.1 change log.

**Baseline:**
- *Interim Inventory Tool Business Analysis v0.2* (approved): decisions T1–T58.
- *vAuto Intake & Risk Audit v0.3* (approved): decisions D1–D25 and questions Q1–Q13.
- The developers' Full ERD (PDF).

**The developers' actual DDL has not been supplied.** Every "Reuse" or "Extend" mapping is **provisional** until their migration or DDL files are checked (§11, action X1).

**Phase 1a covers:** vAuto intake, Data Entry, the report pack, Risk Audit, the AppSheet gate, the 3.1 bridge, polling and reconciliation, and the activity log.

**Later review steps:** the Worker, the AppSheet changes and the Base44 build prompts.

---

## 0a. Changes from v0.2 (Codex review of v0.2)

| # | Finding | Resolution in v0.3 | Section |
|---|---|---|---|
| 1 | A delayed BLOCK still permits work | **Fail-closed live authorization.** Every gated bot and Zap calls `authorize_action` as its first step and continues only on `allowed=true`. Any error, timeout or unknown result denies. The AppSheet gate table now drives display only, and its CLEAR rows expire after 30 minutes unless renewed. Manual actions outside the systems are logged as residual risk RR1. | §6 |
| 2 | The gate mechanism changes an approved decision | Set out as **design amendment AM1** for Rami, to follow Codex's acceptance of §6. Deal-wide holds, unlinked-row blocking and selective release are preserved. | §6.6 |
| 3 | Release and validation are circular | **Draft version, then freeze.** Intake opens draft v1. Requirements, validations and waivers attach to the draft. Release freezes it. Any change to a released field opens draft N+1. An invalidation table is defined. | §5.5 |
| 4 | Which validation is authoritative | The latest validation row per report, requirement and version is authoritative. Satisfaction also checks Deal ownership, subject, freshness and that the report has not been replaced. Waivers are revocable and do not carry over; carried-over validations are explicit rows. | §5.6 |
| 5 | Two matching passes don't prove completeness | Every pass and every observation is recorded. Discovery is separated from processing. Stability is judged on matching (appraisal ID, last-modified) pairs, and records that leave the window are checked individually. Failure handling is defined. Marked **unproven** until the acceptance tests pass. | §5.10 |
| 6 | The notes sanitizer doesn't enforce the policy | Allowlisting of structured fields is now separate from handling of free text. The digit-run redaction proposal is withdrawn. Rami gets a precise choice of three options (R1); a modified text is never called "original". | §7, §11 |
| 7 | Delivery evidence and lease recovery | Start and completion are separate append-only events. An expired `in_flight` lease becomes `uncertain` and is recovered with an existence check. **Fencing tokens** stop a late sender from changing state. A Bridge Key in 3.1 rows enables duplicate detection, and default-deny means a duplicate is never actionable. | §5.8 |
| 8 | Identity bootstrap, seller match, history creation | Identity broker role for the bootstrap (§2.1). Reschedule seller match tightened to phone **and** surname/business name. History now captures INSERT. The Worker acts as a fixed service user. Both cases are added to S1 and X2. | §2, §5.4, §5.9 |

## 0. Changes from v0.1 (Codex findings)

| # | Finding | Resolution in v0.2 | Section |
|---|---|---|---|
| 1 | Authorization unresolved | Trusted staff-identity path: Base44's server side verifies the user, then mints a short-lived Supabase JWT for that staff member. RLS and `auth.uid()` apply. No service key in app paths. Hardened `SECURITY DEFINER` functions. Storage served by signed URLs after role checks. A verification spike is a precondition for approving migrations. | §2 |
| 2 | Link confirmation can come before hold protection | **The AppSheet gate becomes default-deny.** A row is actionable only when its latest gate event is `CLEAR`. The tool publishes `CLEAR` for a row only once these are all true, and verified at AppSheet: the row is linked, its Deal is approved at the current version, and the Deal has no open holds. A link row alone grants nothing. | §6 |
| 3 | "No open row" is ambiguous | Gate state is defined per iD: the highest sequence number wins. A late or duplicate event can never override a newer one. Holds keep their own identity internally; AppSheet only ever sees the computed `CLEAR`/`BLOCK`. | §6 |
| 4 | Approval not tied to a version | `deal_versions`: every material correction creates a new version. A decision counts only if it was made on the Deal's current version and no material change is pending. Older attempts are set to `superseded`. | §5.5, §5.7 |
| 5 | Restart detection | The appraisal identity stays stable, with `appraisal_episodes` under it. Restart intent is never inferred from an appraisal that is simply still completed. At most one open restart task per appraisal; Data Entry makes the explicit episode decision. | §5.3 |
| 6 | Cutover over-blocks | Global readiness is now separate from per-row eligibility. Activation needs the in-flight population accounted for and the unresolved rows proven blocked. Under default-deny, an unresolved row simply never gets `CLEAR`. | §6.4 |
| 7 | History incomplete | Two kinds of data are now separated. Observations are recorded on every fetch, even when the content is unchanged (A→B→A is preserved). Current records are mutable, but a trigger writes every change to `record_history` in the same transaction. | §5.9 |
| 8 | Prohibited data in JSON/logs | A storage policy covers each path, using allowlists rather than denylists. The address street line is dropped. Notes are sanitized when they arrive. Logs keep error codes only. Raw notes conflict with the policy; a business decision is needed (R1). | §7 |
| 9 | Report context | Each report records its subject (VIN or organization). Requirements are versioned. Validations and waivers are tied to a requirement key and a Deal version. Rules for carrying them over are stated. | §5.6 |
| 10 | Counts don't prove polling | Windows and observations are recorded per appraisal ID. A window completes only when the number of distinct IDs equals the count and every observation has been processed. Windows that still exceed 100 at the minimum span use a stability re-read. | §5.10 |
| 11 | Release/retry gaps | `release_deal()` runs every check atomically under a Deal lock. The bridge separates `bridge_deliveries` (current state, lease, retry, owner) from append-only `bridge_attempts`. | §5.7, §5.8 |
| 12 | Mapping grounding | Integration origin is kept separate from the acquisition Source. Seller matching now uses all seller parties. Organization roles are kept in our own table. Mappings are validated against the developers' DDL and sample Deals. | §4, §11 |

**Disposition of v0.1's open choices:**

| Item | Status |
|---|---|
| U2 separate seller profiles | **Kept** |
| U6 Deal number independent of 3.1 | **Kept** |
| U9 dated shift-calendar table | **Kept** |
| U1 lead requirement | Provisional pending the developers' DDL |
| U3 reuse of the Audit tables | Provisional pending the developers' DDL |

---

## 1. Principles

1. **Mirror the developers' schema where it fits; otherwise add a NEW table.** Every addition is listed in §10.
2. **Separate dimensions.** Intake, version, Audit, hold, gate, link, bridge and cancellation state each live in their own place. Parent-table status columns are caches only, never the authority.
3. **Two kinds of history:**
   - **Observations** (vAuto reads, 3.1 read-backs) are immutable and recorded on every fetch.
   - **Current records** (Deal fields, parties, title, lien, flags) are mutable, but every change is captured in `record_history` by trigger. No write path can skip it.
4. **Default-deny toward legacy systems.** A 3.1 row is never actionable unless the tool has positively cleared it and AppSheet has confirmed it.
5. **One door for writes.** All user writes go through authorized database functions under the caller's own identity (§2). Base44 never writes tables directly.
6. **Allowlist storage.** Only listed fields are stored from any external source (§7).
7. **Idempotent and leased external effects.** Each logical write has exactly one delivery record; attempts are append-only; a lease prevents concurrent senders.
8. **Postgres 15 compatible.** Conventions: `uuid` keys, `numeric(14,2)` money, `timestamptz` times, and `text` + `CHECK` constraints for status values.

---

## 2. Authorization (Finding 1)

### 2.1 Trust path

```
Staff browser ──(Base44 session)──▶ Base44 backend function
   Base44 server verifies the user (base44.auth.me() server-side; never a client-sent id)
   ──▶ mints a 60-second broker token (role = identity_broker) that may ONLY execute
       resolve_staff(base44_user_id) → users.id + app roles (staff_identities is provisioned
       by a management-role admin function; unmapped or disabled users get no token)
   ──▶ mints a Supabase JWT: sub = users.id, role = 'authenticated', app_roles = [...], exp ≤ 5 min
       signed with the Supabase JWT secret held only in Base44 secrets
   ──▶ calls Supabase RPC with that JWT
Supabase: RLS + functions read auth.uid() and app roles from the verified JWT
```

- **Actor attribution:** functions take the actor only from `auth.uid()`. Parameters such as `actor_id` do not exist.
- **Worker:** has its own Postgres role, `tav_worker`. It authenticates with a separate JWT whose role claim is `tav_worker`, and it may execute **only** the worker functions. The `service_role` key is used for migrations only; it is never deployed in Base44 or the Worker.
- **Role source:** `staff_identities` and `user_roles` in Supabase, which the developers' schema has. JWT claims are checked against the table on every call, so revoking a role takes effect immediately.

### 2.2 Function hardening

Applies to every write function, for example `release_deal`, `record_decision`, `correct_field`, `resolve_flag`, `upload_report`, `validate_report`, `waive_report` and `resolve_work_item`.

- `SECURITY DEFINER`, `SET search_path = ''`, fully-qualified names.
- `REVOKE EXECUTE ... FROM PUBLIC, anon`. `GRANT EXECUTE` only to `authenticated` or `tav_worker` as appropriate.
- The first statement checks the caller's role: `PERFORM app.require_role('data_entry')`, which raises an error if the role is missing.
- Each function writes its change and its history in one transaction.
- Tables have RLS enabled with **no** direct insert, update or delete policies for `authenticated`. Read access is through RLS `SELECT` policies by role.

### 2.3 Storage

- Report files go in a private bucket, `report-files`.
- RLS on `storage.objects` denies all direct access.
- `get_report_url(report_id)` checks the caller's role and returns a signed URL valid for 60 seconds.
- Uploads use `begin_report_upload()`, which returns a signed upload URL. `finish_report_upload()` then records the file against the Deal.

### 2.4 Precondition before approving migrations (spike S1)

Prove these:
1. Base44 backend functions can resolve the verified user server-side and keep a secret JWT signing key.
2. A minted JWT gets through Supabase RLS with the expected `auth.uid()`.
3. A client cannot call Supabase directly with a forged identity.
4. The broker token can execute only `resolve_staff`. An unmapped or disabled Base44 user gets no user token.
5. The Worker service user is attributed correctly in `record_history`.

**Fallback if Base44 can't do this:** a Cloudflare Worker gateway verifies a Base44-issued, signed user token and mints the Supabase JWT. Same model, one extra hop.

---

## 3. How the required behaviours are supported

| Behaviour | Tables | Enforcement |
|---|---|---|
| Four-record identity (T1) | `vehicles`, `deals`, `source_records`; Sale Attempt in Phase 2 | Unique `vin_normalized`; `source_records.deal_id` NOT NULL once linked |
| Appraisal is a reference | `external_references`, `appraisal_episodes`, `vauto_observations` | One stable reference per appraisal; Deals attach through episodes |
| One initial 3.1 row per Deal (T24) | `source_records`, `bridge_deliveries` | Partial unique on the initial row; one delivery per logical key |
| Reschedule linking (T2) | `source_records` | Link function checks the Rescheduled mark, same Deal, same VIN and a seller-set match (§5.4) |
| Restarted purchases (T54) | `appraisal_episodes`, `deals.restarted_from_deal_id`, `work_items` | One open episode per appraisal; one open restart task; restart only by explicit Data Entry decision |
| Deal-wide holds (T45, T55) | `audit_holds`, `authorize_action` | Any open hold ⇒ every iD of the Deal is denied at once (read live; no delivery needed) |
| Unlinked rows blocked (T55, T57) | `authorize_action` (default-deny) | Unlinked or duplicate ⇒ denied |
| Version-bound approval | `deal_versions`, `prequalification_checks`, `audit_decisions` | Authorization needs an approval on the latest released version, with no open draft |
| Fail-closed actions (T56) | `authorize_action`, `gate_authorizations`; the `Audit Gate` display table | Every gated bot and Zap authorizes live; any error denies; display CLEAR rows expire after 30 minutes |
| Report history | `external_vehicle_reports`, `report_validations`, `report_waivers`, `deal_report_requirements` | Versioned requirement keys; append-only validations and waivers |
| Append-only activity | `activity_events`, `record_history`, plus every table in §5.9 | Grants plus `reject_mutation()` trigger |
| Polling completeness | `poll_runs`, `poll_windows`, `poll_observations`, `poll_checkpoints` | Checkpoint advances only after every leaf window is complete |

---

## 4. Mapping to the developers' tables (provisional, Finding 12)

| Developer table | Use | Change / note |
|---|---|---|
| `vehicles` | Vehicle | **Extend:** `vin_normalized` (unique), `make_text`, `model_text`, `series`, `exterior_color`. Assumes `model_id` is nullable (X1). |
| `deals` | Deal | **Extend** (§5.2) |
| `leads` | Seller/acquisition container | **Provisional (U1).** `leads.source` holds the **confirmed acquisition Source**, set by Data Entry; it stays NULL until set. Integration origin is a separate field, `deals.origin`. |
| `organizations` | Legal entities, lienholders, business sellers | **Reuse.** The developers' `kind` categories are not assumed; our roles are in NEW `organization_roles` (`org_id`, `role` = `tav_entity` / `lienholder` / `business_seller`). |
| `users`, `roles`, `user_roles`, `staff_profiles` | Staff and roles | **Reuse.** Plus NEW `staff_identities` (Base44 user to `users.id`) and NEW `external_user_map` (vAuto username to user). |
| `external_vehicle_reports`, `vehicle_history_findings`, `files`, `attachment_retention_policy` | Report pack | **Extend** (§5.6) |
| `prequalification_checks`, `prequalification_check_results` | Risk Audit attempts | **Provisional (U3), Extend** (§5.7) |
| `status_history`, `audit_logs`, `integrations`, `integration_call_logs` | History and integration logging | **Reuse.** Logs follow the §7 policy. |
| `consignments`, `dealers` | Manual consignment Deals | **Reuse** |
| `system_settings` | Non-dated settings | **Reuse.** The shift calendar is a dated NEW table, `shift_calendar`. |
| `reviews`, `approvals`, `notes` | Not used in Phase 1a | — |
| Sales, inventory, arbitration, payments | Later phases | — |

**Validation plan (X2).** Before migrations, run four representative Deals through the mapping and walk each one through the four-record model, the parties and the reports:
1. a consumer with a lien and two owners;
2. a business seller;
3. a manual consignment;
4. a Brown Fig auction buy.

---

## 5. Table design

Illustrative DDL sketch. This is not a migration.

### 5.1 Vehicles

As v0.1: generated `vin_normalized` with a unique index. The original VIN is kept.

### 5.2 Deals (developers' table, extended)

| Column | Purpose |
|---|---|
| `buying_entity_id`, `dealer_number` | Stamped at creation, never inferred (T4, D23) |
| `origin` | `vauto_intake` / `manual_consignment` / `manual_exception`. This is integration origin, **not** the Source. |
| `source_channel_id` | The confirmed acquisition Source (D12), set by Data Entry |
| `consumer_route` | `risk_audit` / `skip_audit` / `hold_in_data_entry` |
| `deposit_amount` | 0 is allowed; NULL means not provided |
| `balance`, `balance_owed` | Generated: `purchase_price − coalesce(deposit_amount,0)` (D22) |
| `dealer_sold_to`, `dealer_auction_name` | Data Entry (Q4) |
| `current_version_no` | Latest `deal_versions` row (cache) |
| `intake_status` | `new` / `in_review` / `released` / `voided` |
| `audit_status`, `on_hold`, `gate_clear` | **Caches only**; the authority is §5.7 and §6 |
| `restarted_from_deal_id` | Self-reference (T54) |
| `final_closure_at` | Start of retention (T52) |
| `data_entry_due_at` | Computed from `shift_calendar` (T50) |
| `deal_number` | Own sequence, independent of the 3.1 iD (U6) |

### 5.3 Appraisal identity and episodes (Finding 5)

```sql
CREATE TABLE external_references (            -- one stable row per external identity
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  system text NOT NULL,                       -- 'vauto_appraisal', 'appsheet_31', 'manheim_account', ...
  external_id text NOT NULL,
  account_context text NOT NULL DEFAULT '',   -- vAuto entityLogicalId; Manheim dealer number
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (system, external_id, account_context)
);

CREATE TABLE appraisal_episodes (             -- appraisal ↔ Deal over time
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  appraisal_ref_id uuid NOT NULL REFERENCES external_references(id),
  deal_id uuid NOT NULL REFERENCES deals(id),
  episode_no int NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(), started_by uuid,
  start_basis text NOT NULL CHECK (start_basis IN ('first_completion','data_entry_restart')),
  ended_at timestamptz, end_reason text CHECK (end_reason IN ('cancelled','voided')),
  UNIQUE (appraisal_ref_id, episode_no)
);
CREATE UNIQUE INDEX one_open_episode ON appraisal_episodes (appraisal_ref_id) WHERE ended_at IS NULL;
```

**Intake rules:**

| Situation | What happens |
|---|---|
| Completed appraisal, no reference yet | Create the reference, the Deal, and episode 1 (`first_completion`) |
| Reference exists and its episode is open | Update path (intake step 6); change flags only |
| Reference exists, latest episode ended (cancelled) | Nothing is created and nothing is reopened, **unless the latest observation shows a transition since the cancellation**. A transition means either: `isCompleted` was observed going false→true after `ended_at`; or a material content change (price, VIN, customer, notes) on an observation after `ended_at`. Only then is a `restart_candidate` work item opened. |
| Restart task already open for this appraisal | No new task. A partial unique index on `work_items (appraisal_ref_id, kind) WHERE status='open'` guarantees this. Only the new evidence is added to the existing task. |

An unchanged completed appraisal can never create a task.

Data Entry closes a restart task in one of two ways:
- **`restart_new_episode`:** creates a new Deal with `restarted_from_deal_id` set, a new episode with `data_entry_restart` basis, and fresh review.
- **`no_restart`:** requires a reason.

### 5.4 Source Records (3.1 rows)

The v0.1 columns stay. Changes:

- **Read-backs move out.** `raw` and `source_hash` move into immutable `source_observations`, one row per read-back of the row with its allowlisted columns. `source_records.current_observation_id` points at the latest.
- **Seller-set match (Finding 12).** A reschedule links only if every condition holds:
  - the replaced row is marked Rescheduled;
  - it belongs to the same Deal;
  - the normalized VIN is equal;
  - the 3.1 seller matches a seller party on the Deal (`owner`, `co_owner` or `business_seller`). That means the normalized phone is equal **and** either the normalized last name or the business name is equal. A match on name alone, or on phone alone, opens a `conflict` for Data Entry. This is checked against sample Deals in X2.

  If any condition fails, `link_status='conflict'` and a work item is opened.
- **Linking grants nothing by itself.** Linking only makes the row eligible for gate evaluation (§6).

### 5.5 Deal versions: draft, then frozen (Findings 3, 4)

```sql
CREATE TABLE deal_versions (
  deal_id uuid NOT NULL REFERENCES deals(id),
  version_no int NOT NULL,
  status text NOT NULL CHECK (status IN ('draft','released','superseded')),
  cause text NOT NULL CHECK (cause IN ('intake','material_correction','resubmission')),
  opened_at timestamptz NOT NULL DEFAULT now(),
  released_by uuid, released_at timestamptz,
  snapshot jsonb,                       -- set once, at release (allowlisted, §7); NULL while draft
  history_watermark bigint,             -- max record_history id covered by the snapshot
  PRIMARY KEY (deal_id, version_no),
  CHECK ((status = 'draft') = (released_at IS NULL))
);
CREATE UNIQUE INDEX one_draft_per_deal ON deal_versions (deal_id) WHERE status = 'draft';
```

**Lifecycle**

1. **Intake** opens draft version 1. Data Entry works on the draft: corrections, parties, title and lien, reports, validations and waivers all attach to it.
2. **Requirements are computed on the draft** and recomputed on every change to their inputs (§5.6).
3. **`release_deal()`** checks the draft (§5.7). If every check passes, it **freezes** the version: status becomes `released`, and the snapshot and watermark are written. A released version is immutable; a trigger rejects any update to a row whose status is `released`, except the move to `superseded`.
4. **A change to a field captured in a released version** opens a new draft N+1, with cause `material_correction` (D21 fields) or `resubmission`.
   - For a material change, an Audit hold is opened at once (§6) and the Deal stays held until N+1 is released and approved.
   - Version N becomes `superseded` when N+1 is released.
5. **Approval eligibility.** The decision that counts is the latest one on the attempt for the **latest released version**, and the Deal must have **no open draft**. While a draft is open, the Deal is not approved for gating, whatever was decided earlier.

**What invalidates validation work on a draft**

| Change | Effect |
|---|---|
| VIN | All vehicle-subject validations become inapplicable; requirement keys change (§5.6) |
| Title state, or the tribal flag | The FL/OK DMV requirement keys change; old keys drop out |
| Owner type, or the business-seller organization | The OpenCorporates key changes; old key drops out |
| Any other field | Validations stay as they are |

### 5.6 Report pack: authoritative validation (Findings 3, 4, 9)

The report columns are as in v0.2, plus `deal_id NOT NULL`. A report belongs to one Deal.

**Requirements**
- `deal_report_requirements` (`deal_id`, `version_no`, `requirement_key`, `report_type`, `subject_type`, `subject_vin` / `subject_org_id`, `freshness_baseline`) is derived for the **draft** and frozen with it at release.
- `freshness_baseline` is the appraisal completion date for vAuto Deals and the Deal's creation date for manual Deals (T53).

**Validations and waivers**
- **`report_validations`** is append-only: `id` (bigint identity), `report_id`, `requirement_key`, `deal_id`, `version_no`, `outcome` (`valid` / `rejected`), `checks` jsonb (`subject_match`, `owned_by_deal`, `readable`, `complete`, `fresh`), `reason`, `validated_by`, `at`, `carried_from_validation_id`.
- **Authoritative validation:** for each (`report_id`, `requirement_key`, `version_no`), the row with the highest `id`. Later rows supersede earlier ones. A rejection followed by a corrected re-validation therefore ends `valid`, and a later rejection overrides an earlier `valid`.
- **`report_waivers`** is append-only, and also has a `revoked_by_waiver_id`. The authoritative waiver for (`deal_id`, `requirement_key`, `version_no`) is the latest one not revoked.

**When a requirement R on version N is satisfied**
- **By a report**, when all of these hold:
  - `report.deal_id` = the Deal;
  - no later report replaces it (`replaces_report_id` chain);
  - its subject equals R's subject (VIN, or organization);
  - `pulled_at` is on or after R's `freshness_baseline`;
  - its authoritative validation for (R, N) is `valid`.
- **Or by a waiver:** an authoritative, unrevoked waiver for (R, N).

**Replacement**
- A replaced report is never eligible again.
- The replacing report needs its own validation.

**Carry-over to a new draft N+1**
- An authoritative `valid` validation from N is copied as a new row on N+1, with `carried_from_validation_id` set, only when the requirement key is unchanged, the subject is unchanged, and freshness still holds.
- Waivers never carry over.

### 5.7 Risk Audit (Findings 4, 11)

**Attempts.** `prequalification_checks` gains:
- `deal_version_no NOT NULL`
- `status` (`open` / `decided` / `superseded`)
- `reopened_from_check_id`

**Decisions.** `audit_decisions` is append-only, as in v0.1. `record_decision()` rejects a decision when either:
- the attempt is `superseded`; or
- `deal_version_no` is not the latest released version, or a draft is open.

It locks the Deal row first (`FOR UPDATE`).

**`release_deal(deal)`.** One transaction, with the Deal row locked. It refuses the release unless every check passes:
1. Intake status permits release.
2. The Source/channel is set.
3. The required intake facts are present (VIN, price, deposit stated, title custody, lien position, seller party, phone, buying entity).
4. There are no open blocking flags.
5. No parser re-run is pending.
6. Every requirement in the computed set is satisfied (§5.6).

It then writes the `deal_versions` row and, if this is the first release, queues the initial `add_31_row` delivery.

**Locking.** Every function that changes flags, reports, parties or fields takes the same Deal lock, so a release cannot race with those changes.

### 5.8 Bridge deliveries: fencing, recovery, external duplicates (Finding 7)

```sql
CREATE TABLE bridge_deliveries (               -- current state, one per logical write
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('add_31_row','add_gate_event')),
  idempotency_key text NOT NULL UNIQUE,
  deal_id uuid NOT NULL, source_record_id uuid,
  payload jsonb NOT NULL,
  state text NOT NULL CHECK (state IN ('pending','in_flight','uncertain','confirmed','retry_wait','failed_manual','superseded_manual')),
  owner text NOT NULL CHECK (owner IN ('worker','data_entry')),
  fence bigint NOT NULL DEFAULT 0,             -- incremented on every claim and on manual takeover
  lease_until timestamptz, next_attempt_at timestamptz,
  confirmed_external_id text, verified_at timestamptz
);
CREATE TABLE bridge_attempt_events (           -- append-only; start and end are separate rows
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  delivery_id uuid NOT NULL REFERENCES bridge_deliveries(id),
  fence bigint NOT NULL,
  event text NOT NULL CHECK (event IN ('started','existence_checked','sent','completed','abandoned','late_completion_ignored')),
  result text, external_id text, error_code text,
  at timestamptz NOT NULL DEFAULT now()
);
```

**Attempt evidence.** Each step of an attempt is written as its own row when it happens: `started` (with the new fence), then `existence_checked`, then `sent`, then `completed`. Nothing is written before the fact.

**Claiming a delivery.** A delivery can be claimed in either of two cases:
- its state is `pending`, `retry_wait` or `uncertain` and its next attempt is due; or
- its state is `in_flight` and its lease has expired. Such an attempt counts as abandoned: an `abandoned` event is written and the state becomes `uncertain`.

Every claim increments `fence`. Every claim from `uncertain` must run the existence check first.

**Fencing a late sender.** `complete_delivery(id, fence, …)` changes state only if `fence` still matches the current fence. A completion carrying an old fence is recorded as `late_completion_ignored` and does not change state. Manual takeover by Data Entry also increments the fence.

**External duplicates.** Local uniqueness cannot stop a late sender from adding a second row in AppSheet. Three things contain that:
1. **Bridge Key.** Every 3.1 row the bridge writes carries its idempotency key in a new column, `Bridge Key`. The existence check searches by this key.
2. **Duplicate detection.** If a late sender creates a second row anyway, reconciliation finds two rows with the same Bridge Key. The earliest row stays canonical. The other is marked `duplicate`, and a work item tells Data Entry to cancel it in AppSheet.
3. **Default-deny.** The gate (§6) never authorizes a duplicate iD, so it is never actionable even before cleanup.

Whether an AppSheet Valid_If rule can enforce Bridge Key uniqueness on API adds is checked in spike S2.

### 5.9 History model (Finding 7, plus Finding 8 history)

- **Immutable observations and events.** Unchanged from v0.2, but `bridge_attempts` is replaced by `bridge_attempt_events`.
- **Mutable current records.** The history trigger now fires `AFTER INSERT OR UPDATE`, so a record's creation is captured as version 1. `DELETE` is rejected.
- **Actor.** Every history row records `changed_by = auth.uid()` and `actor_kind`.
  - The Worker authenticates as a fixed `users` row ("TAV Intake Worker", `actor_kind='worker'`) under the `tav_worker` role.
  - System triggers record `actor_kind='system'` along with the invoking actor.
- **What a reviewer saw.** `deal_versions.history_watermark` plus `record_history` reconstruct exactly what was in front of the reviewer.

### 5.10 Polling: discovery, processing, stability (Finding 10, *unproven strategy*)

This design is an **unproven strategy**. It is accepted only after the sandbox acceptance tests pass. Those tests cover: more than 100 records with equal timestamps; edits made during a run; failures; completion reversals; and reconciliation.

**Tables**

| Table | Contents |
|---|---|
| `poll_windows` | As in v0.2. `mode` is `single_page` or `multi_pass`. |
| `poll_passes` (NEW) | `window_id`, `pass_no`, `started_at`, `ended_at`, `count_reported`, `pages_read` |
| `poll_observations` | `pass_id`, `appraisal_id`, `last_modified`, `content_hash`, `page_no`, `position`. Unique per (`pass_id`, `appraisal_id`). A record that appears twice within one pass is logged as `dup_in_pass` and its content is still kept. |
| `poll_discoveries` | `window_id`, `appraisal_id`, `last_modified`, `content_hash`. One row per **distinct version** of an appraisal seen in the window. |
| `poll_processing` | `discovery_id`, `outcome` (`created` / `updated` / `unchanged` / `flagged` / `error`), `processed_at` |

**A window is complete** when all of these hold:
1. **Single-page mode:** one pass returned `count_reported` ≤ 100, and the distinct IDs equal `count_reported`.
2. **Multi-pass mode:** two consecutive passes return the **same set of (appraisal ID, last-modified) pairs**, and the size of that set equals `count_reported` on both passes.
   - **Records that leave the window between passes** are fetched individually by ID. If the new last-modified is later than the window's end, the record is accounted for: the next window will pick it up. Any other reason for leaving fails the window.
3. Every discovery has a processing outcome other than `error`.

**When stability can't be established** (the window is still unstable after five passes):
- the window fails;
- the checkpoint does not advance;
- the run raises an alert on Home;
- the window is retried on the next cycle.

Narrower time slices do not help when timestamps are equal, so the fallback is retrying until the data stops changing. The independent daily reconciliation against vAuto's completed-appraisal list (intake step 9) backs this up.

## 6. AppSheet gate: fail-closed live authorization (Findings 1, 2, 3, 6)

### 6.1 Principle

Every action is authorized live, at the moment it is taken. Data copied into AppSheet is never treated as permission.

- **Allowed:** the tool's authorization endpoint confirms, at that moment, that the iD is cleared.
- **Denied:** every other outcome, including an error, a timeout, an unknown iD or a missing response.

A delayed BLOCK can therefore no longer leave an action running on an old CLEAR.

### 6.2 Components

| Component | Role |
|---|---|
| `authorize_action(iD, action, caller)` | A Cloudflare Worker endpoint backed by a Supabase function. It returns `{allowed: true, auth_id, deal_version, expires_in: 120}` only when all of these hold, read from the database at call time: the row is linked and canonical (not a duplicate); the Deal is approved on its latest released version, with no open draft; there are no open holds; the Deal is not cancelled or voided. Every call, allowed or denied, is logged in `gate_authorizations`. An `auth_id` is single-use and valid for 120 seconds for that iD and action. |
| AppSheet bots: package, texts, dispatch, and any other gated bot | **Step 1** calls the webhook `authorize_action` and uses its return value. **Step 2** continues only if `allowed = TRUE`; it branches on the return value, and its default path stops. A failed or timed-out webhook stops the bot. |
| Zaps (03/04 Fire-off and any gated Zap) | **Step 1** is a Webhooks by Zapier request to `authorize_action`. **Step 2** is a Filter that continues only if `allowed` is exactly `true`; a missing field means stop. A queued Zap therefore authorizes when it **runs**, not when it was queued. |
| `Audit Gate` table (add-only, in AppSheet) | **Display only.** It drives the Scheduling view (show only CLEAR rows) and the badges, using the highest `seq` per iD. CLEAR rows also carry `valid_until` (issued_at + 30 min), and the tool renews them while the conditions hold. A row whose CLEAR has expired disappears from the view even if a BLOCK never arrives. The table cannot authorize anything. |
| Manual human actions outside AppSheet (calls, texts from personal phones) | **Cannot be gated technically.** They are covered by the view filter (fail-closed through `valid_until`) and by procedure. Recorded as residual risk RR1 for Rami to accept. |

### 6.3 Holds, links and selective release

These behaviours are preserved:

- **Deal-wide holds.** Any open `audit_holds` row for the Deal makes `authorize_action` deny every iD of that Deal straight away, because the check reads the database. No delivery is needed for it to take effect.
- **Unlinked rows.** Unlinked or duplicate rows are denied.
- **Selective release.** Releasing a hold requires the approved decision on the attempt that covers it. Releasing one hold leaves other open holds in force.
- **Ordering.** Gate rows in AppSheet are ordered by `seq` (highest wins), as in v0.2. They affect display only.

### 6.4 Cutover (T57)

Unchanged from v0.2, with two differences:
- Readiness is now proven with `authorize_action`: every `blocked_unresolved` row must return `allowed=false`.
- Every gated bot and Zap must be shown to include step 1. The inventory of Zaps and their data sources (3.1 or 4.1) is part of the AppSheet review step.

### 6.5 What must be proven (T56 acceptance)

Each of the following scenarios must be shown to deny:
1. A BLOCK delivery to AppSheet fails, and a bot fires on a row still showing CLEAR.
2. The endpoint is down or times out.
3. A Zap is queued before a hold and runs after it.
4. A hold is opened concurrently with an authorization call. The call must deny, or must have been issued before the hold committed and expire within 120 seconds.
5. A late or duplicate gate row arrives.
6. A row is a duplicate.
7. An unresolved cutover row is acted on.

### 6.6 Amendment for Rami (after Codex accepts §6)

**Proposed design amendment AM1, which changes the approved mechanism in T30, T45 and T55:**
- Gated actions are authorized live by the tool and fail closed.
- The add-only `Audit Gate` table drives display only.
- `Auditing Complete` stays in 3.1 but is no longer the authorization; it is informational.

The business rules are unchanged: Deal-wide holds, blocking of unlinked rows, selective release, and T56 delivery proof.

## 7. Storage policy per path (Finding 8)

| Path | Allowed content | Enforcement |
|---|---|---|
| vAuto observations | Allowlisted fields only: vehicle, appraisal value, personnel, customer name/phone/email/postal code/city/state, title region/name, tag, lien owner/phone/payoff/payoff date/per diem, condition, timestamps, sanitized notes. **Dropped:** `lien.accountNumber`, `customer.address` street line, `workPhone`/`pagerPhone` unless needed. | The Worker's sanitizer is allowlist-based. A DB `CHECK (app.json_is_clean(body))` rejects any key outside the allowlist schema. |
| vAuto notes text (free text) | **Structured allowlisting does not reach inside free text** (Finding 6). Notes are handled separately, with Rami's decision R1 (§11). Under any option, the parsed, allowlisted labels go to structured fields, and the general UI never shows raw notes. | See R1 |
| 3.1 read-backs | Allowlisted field-map columns only (groups A–E). The Lien Bank Overnight Address is a bank address and is allowed. | Same `json_is_clean` check |
| `record_history`, `activity_events`, `deal_versions` snapshots | Values of allowlisted columns only. They never contain raw payloads. | Built by functions from sanitized columns; CHECK as above |
| `bridge_deliveries.payload` | Field-map groups A–D for 3.1 rows; gate fields for gate events | View-built payload; CHECK |
| `integration_call_logs`, `bridge_attempt_events`, `audit_logs` | Operation, status code, error **code**, duration, correlation ID. **Never** request or response bodies. | No body columns. Error text is truncated and passed through the sanitizer. |
| Report files (Storage) | As received, which may include account numbers. **The only exception (T43).** | Private bucket; signed URLs after a role check |

---

## 8. Invariants to test

v0.1's eleven invariants are kept, adjusted to the new design. These are added:

12. A forged or missing actor cannot write. A function called without the required role raises an error. `auth.uid()` is the only actor.
13. A `CLEAR` is never published while the Deal has an open hold, a pending material change, or an approval only on an older version.
14. Out-of-order or duplicate gate events: lower-`seq` rows never change the computed state.
15. An unchanged completed appraisal on a cancelled episode creates no task. A real transition creates exactly one.
16. A→B→A appraisal content gives three observations. A reviewer's view can be rebuilt from `record_history`.
17. A payload containing a key outside the allowlist, or an account-number field, is rejected on every JSON column.
18. Waivers do not carry over to a new version. A requirement-key change invalidates the carried-over validation.
19. A window whose duplicates mask a missed ID fails the distinct-count check. The checkpoint does not advance.
20. Two Workers can never hold the same delivery. Failed deliveries are retried until they become `failed_manual` and are handed to Data Entry. Manual fallback prevents a later duplicate.
21. A release racing a flag or report change: whichever commits second either sees the other's result or is rejected.

Added in v0.3:

22. Every scenario in §6.5 results in deny.
23. Releasing a draft freezes it. An update to a released version is rejected. A released-field change opens exactly one draft.
24. A rejection after a valid validation leaves the report unsatisfying; a re-validation after a rejection satisfies. A replaced report never satisfies.
25. A late completion with a stale fence changes no state. Two rows with the same Bridge Key: one is canonical, the other is denied by `authorize_action`.
26. A window with an ID whose content changed between passes is not stable. A record that left the window is accounted for only after an individual fetch.
27. INSERTs into mutable tables create version 1 in `record_history`.

## 9. Assumptions

As v0.1 (A1–A6). A5 is replaced by §2, pending spike S1.

## 10. Additions to raise with the developers

As v0.1, plus:
- appraisal episodes;
- versioned Deals;
- requirement-keyed report validations and waivers;
- organization roles.

The gate, bridge and polling tables are interim-only.

## 11. Actions before migration approval

| # | Action | Owner |
|---|---|---|
| X1 | Obtain the developers' actual DDL or migrations and re-check every Reuse/Extend mapping (nullability, types, constraints, `lead_id`, `kind` values) | Rami to request; Claude to diff |
| X2 | Walk four representative Deals through the mapping (§4) | Claude, reviewed by Codex |
| S1 | Base44 identity/JWT spike, including broker bootstrap and Worker attribution (§2.4) | Claude to prepare; run in a Base44 dev app |
| S2 | AppSheet/Zapier spike. Prove four things: an AppSheet bot webhook with return values gates its next step and fails closed on error or timeout; a Zapier Filter stops when the webhook fails; Valid_If uniqueness on Bridge Key holds for API adds; the latency of the authorize call is acceptable | Claude to prepare; run against a test copy of 3.1 |
| R1 | **How raw vAuto notes are retained** (Rami). The options:<br>**(A) Recommended:** keep the notes exactly as received in the restricted evidence store, like report files (role-restricted, never shown in general screens). This extends the T43 exception to notes. Parsed labels are stored as structured fields.<br>**(B)** Keep no raw notes; store only the parsed allowlisted labels plus a transformation record (labels found, dropped-line count, hash of the original). The original wording is lost for disputes.<br>**(C)** Keep raw notes visible like other fields. Not recommended: conflicts with the policy. | **Rami** |
| RR1 | Accept the residual risk that manual actions outside AppSheet and Zapier (personal calls and texts) cannot be technically gated. They are covered by the expiring view and by procedure. | **Rami** |
| AM1 | Design amendment to the gate mechanism (§6.6). Codex reviews §6 first; then Rami confirms. | Codex, then **Rami** |
