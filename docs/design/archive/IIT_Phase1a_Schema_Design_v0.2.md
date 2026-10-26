# Interim Inventory Tool — Phase 1a Supabase Schema Design (v0.2, for review)

**Date:** 19 Oct 2026 · **Author:** Claude · **Reviewer:** Codex · **Approver:** Rami

**Status:** Design for review. Nothing has been created in Supabase. v0.2 supersedes v0.1 and answers all 12 of Codex's findings. The finding-by-finding change log is in §0.

**Baseline:**
- *Interim Inventory Tool Business Analysis v0.2* (approved): decisions T1–T58.
- *vAuto Intake & Risk Audit v0.3* (approved): decisions D1–D25 and questions Q1–Q13.
- The developers' Full ERD (PDF).

**The developers' actual DDL has not been supplied.** Every "Reuse" or "Extend" mapping is **provisional** until their migration or DDL files are checked (§11, action X1).

**Phase 1a covers:** vAuto intake, Data Entry, the report pack, Risk Audit, the AppSheet gate, the 3.1 bridge, polling and reconciliation, and the activity log.

**Later review steps:** the Worker, the AppSheet changes and the Base44 build prompts.

---

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
   ──▶ looks up staff_identities (base44_user_id → users.id, roles)
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

Prove three things:
1. Base44 backend functions can resolve the verified user server-side and keep a secret JWT signing key.
2. A minted JWT gets through Supabase RLS with the expected `auth.uid()`.
3. A client cannot call Supabase directly with a forged identity.

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
| Deal-wide holds (T45, T55) | `audit_holds` → `gate_events` | Any open hold ⇒ every linked iD gets `BLOCK` |
| Unlinked rows blocked (T55, T57) | `gate_events` (default-deny) | No `CLEAR` means blocked |
| Version-bound approval | `deal_versions`, `prequalification_checks`, `audit_decisions` | `CLEAR` needs an approval on the current version |
| Hold delivery proven (T56) | `gate_events.delivery_id` → `bridge_deliveries.verified_at` | The tool shows `CLEAR` only after verification; `BLOCK` publishes immediately |
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
  - the 3.1 seller matches **any** seller party on the Deal (`owner`, `co_owner`, `business_seller`), by normalized full name **or** normalized phone.

  If any condition fails, `link_status='conflict'` and a work item is opened.
- **Linking grants nothing by itself.** Linking only makes the row eligible for gate evaluation (§6).

### 5.5 Deal versions (Finding 4)

```sql
CREATE TABLE deal_versions (                  -- immutable; replaces v0.1 deal_releases
  deal_id uuid NOT NULL REFERENCES deals(id),
  version_no int NOT NULL,
  cause text NOT NULL CHECK (cause IN ('initial_release','material_correction','resubmission')),
  snapshot jsonb NOT NULL,                    -- allowlisted intake values as released (§7)
  report_requirement_set_id uuid NOT NULL,    -- requirements computed for this version
  released_by uuid NOT NULL, released_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (deal_id, version_no)
);
```

**Rules:**
- **A material correction** (D21: price, VIN, owner, lien, title state) made after release is held as a pending change:
  - it is recorded in `record_history` and flagged `pending_material`;
  - an `audit_hold` is opened immediately (§6);
  - the Deal stays held until Data Entry re-releases it, which creates version N+1.
- **A new version supersedes old attempts.** Every open Risk Audit attempt on an older version is set to `superseded`, and a new Pending attempt is created on N+1 with the same officer (T36).
- **Approval eligibility** (`app.deal_is_approved(deal)`) is true only when all of these hold:
  - the latest decision on the attempt covering `current_version_no` is `approved`;
  - there are no pending material changes;
  - no attempt on the current version is open with a decision made later.

  Approvals on older versions never count.

### 5.6 Report pack (Finding 9)

```sql
ALTER TABLE external_vehicle_reports ADD COLUMN
  deal_id uuid REFERENCES deals(id),
  report_type text NOT NULL,
  subject_type text NOT NULL CHECK (subject_type IN ('vehicle','organization')),
  subject_vin text,                 -- normalized VIN the report is ABOUT (vehicle reports)
  subject_org_id uuid REFERENCES organizations(id),   -- OpenCorporates
  provider_report_id text,          -- provider's own id/number where shown
  acquisition text NOT NULL CHECK (acquisition IN ('manual_upload','api_pull')),
  pulled_at timestamptz NOT NULL, uploaded_by uuid NOT NULL,
  replaces_report_id uuid REFERENCES external_vehicle_reports(id),
  CHECK ((subject_type='vehicle') = (subject_vin IS NOT NULL)),
  CHECK ((subject_type='organization') = (subject_org_id IS NOT NULL));
```

| Table | Purpose |
|---|---|
| `report_requirement_sets` / `deal_report_requirements` (NEW) | Computed per Deal version. Each row has a **requirement key**: report type plus its basis, e.g. `OK_DMV:title_state=OK:tribal=false`, `OPENCORPORATES:org=<id>`, `CARFAX:vin=<vin>`. Recomputed whenever owner type, business seller, title state, tribal flag or VIN changes. |
| `report_validations` (NEW, append-only) | `report_id`, `requirement_key`, `deal_version_no`, `outcome` (`valid` / `rejected`), `checks` (VIN/subject match, readable, complete, pulled on time), `reason`, `validated_by`, `at`. A report never has its validation overwritten; a re-check adds a row. |
| `report_waivers` (NEW, append-only) | `deal_id`, `requirement_key`, `deal_version_no`, `waived_by` (Audit Lead, checked), `reason`, `at` (D25) |

**Satisfaction rule.** A requirement on version N is satisfied by either:
- a `valid` validation for the **same requirement key** whose report subject still matches; or
- a waiver for the **same key on version N**.

**Carry-over rules:**
- A validation carries over to a new version only if the requirement key is unchanged.
- A waiver never carries over. A new version needs a new waiver.
- A replaced or rejected report never satisfies anything.

### 5.7 Risk Audit (Findings 4, 11)

**Attempts.** `prequalification_checks` gains:
- `deal_version_no NOT NULL`
- `status` (`open` / `decided` / `superseded`)
- `reopened_from_check_id`

**Decisions.** `audit_decisions` is append-only, as in v0.1. `record_decision()` rejects a decision when either:
- the attempt is `superseded`; or
- `deal_version_no <> deals.current_version_no`.

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

### 5.8 Bridge deliveries and attempts (Finding 11)

```sql
CREATE TABLE bridge_deliveries (              -- current state, one per logical write
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('add_31_row','add_gate_event')),
  idempotency_key text NOT NULL UNIQUE,       -- add_31_row:<deal>:initial | gate:<iid>:<seq>
  deal_id uuid NOT NULL, source_record_id uuid,
  payload jsonb NOT NULL,                     -- allowlisted (§7)
  state text NOT NULL CHECK (state IN ('pending','in_flight','uncertain','confirmed','retry_wait','failed_manual','superseded_manual')),
  owner text NOT NULL CHECK (owner IN ('worker','data_entry')),
  lease_holder text, lease_until timestamptz,
  next_attempt_at timestamptz, attempt_count int NOT NULL DEFAULT 0,
  confirmed_external_id text, verified_at timestamptz
);
CREATE TABLE bridge_attempts (                -- append-only
  delivery_id uuid NOT NULL REFERENCES bridge_deliveries(id),
  attempt_no int NOT NULL, started_at timestamptz NOT NULL, ended_at timestamptz,
  existence_checked boolean NOT NULL,         -- looked for an existing row before sending
  result text NOT NULL CHECK (result IN ('confirmed','already_present','uncertain','failed_retryable','failed_permanent')),
  external_id text, error_code text,          -- code only (§7)
  PRIMARY KEY (delivery_id, attempt_no)
);
```

**Claiming work.** The Worker claims deliveries with `SELECT … FOR UPDATE SKIP LOCKED` where the state is `pending`/`retry_wait`/`uncertain` and the lease has expired. It sets a lease and starts an attempt.

**Before each attempt.** For `add_31_row`, an existence check runs first. For `add_gate_event`, the check is on `gate:<iid>:<seq>`.

**Allowed transitions:**

| From | To |
|---|---|
| `pending` | `in_flight` |
| `in_flight` | `confirmed`, `uncertain`, `retry_wait` or `failed_manual` |
| `retry_wait` | `in_flight` (by backoff schedule) |
| `uncertain` | `in_flight` (an existence check is required) |
| `failed_manual` | owner switches to `data_entry`; a work item is opened |

**Manual fallback.** Data Entry records the iD they entered by hand. The function verifies it exists and that the delivery is not leased, then sets `superseded_manual`.

No transition skips the attempt log.

### 5.9 History model (Finding 7)

| Class | Tables | Rule |
|---|---|---|
| Immutable observations | `vauto_observations`, `source_observations`, `poll_observations` | Every fetch adds a row. Content is stored once in `content_blobs (hash PK, body jsonb)`, and each observation references its hash. A→B→A gives three observations. |
| Immutable decisions and events | `audit_decisions`, `deal_versions`, `report_validations`, `report_waivers`, `bridge_attempts`, `gate_events`, `activity_events`, `status_history`, `valuations` | `reject_mutation()` on UPDATE/DELETE; no grants |
| Mutable current records | `deals` (non-cache fields), `deal_parties`, `seller_parties`, `deal_titles`, `deal_liens`, `intake_flags`, `work_items`, `source_records`, `audit_holds` | An `AFTER UPDATE OR DELETE` trigger writes `record_history (table, row_id, version_no, before, after, changed_by=auth.uid(), reason, at)` in the same transaction. DELETE is rejected on all of these. A reviewer's view at time *t* can be rebuilt from `record_history` plus the versions. |

**Snapshot reference.** `deal_versions.snapshot` and each Audit attempt record the `record_history` version numbers they cover. That shows exactly what the reviewer saw.

### 5.10 Polling (Finding 10)

| Table | Rule |
|---|---|
| `poll_runs` | `stream`, `started_at`, `status` |
| `poll_windows` | `run_id`, `parent_window_id`, `window_start`, `window_end`, `count_reported`, `distinct_seen`, `mode` (`single_page` / `stability_paged`), `status` (`open` / `complete` / `failed` / `split`). A window over 100 records is split, and its children cover the parent range exactly with no gaps; a range check proves the coverage. |
| `poll_observations` | `window_id`, `appraisal_id`, `last_modified`, `content_hash`, `outcome` (`created` / `updated` / `unchanged` / `flagged` / `error`), `processed_at`. Unique `(window_id, appraisal_id)`. |
| `poll_checkpoints` | Advances to a run's upper bound only if every leaf window is `complete`. |

**When a leaf window is complete:**
- it has `distinct_seen = count_reported`;
- every observation has a processed outcome other than `error`;
- for `single_page` mode, the count is 100 or fewer.

**Minimum-span windows.** If a window still holds more than 100 records at the minimum span (one second, e.g. a bulk edit with equal timestamps), it switches to `stability_paged`. It pages in a fixed sort order and repeats the full read until two consecutive passes return the same set of distinct IDs, matching `count_reported`. Duplicate IDs never count twice.

The acceptance cases are kept in the test plan: equal timestamps with more than 100 records, concurrent edits, failures, completion reversals, and reconciliation.

---

## 6. AppSheet gate: default-deny (Findings 2, 3, 6)

### 6.1 Model

AppSheet gets **one** add-only table, `Audit Gate`, with these columns:
- `iD`
- `seq` (integer, monotonic per iD)
- `state` (`CLEAR` / `BLOCK`)
- `deal_version`
- `reason`
- `issued_at`

The gate state for an iD is the row with the **highest `seq`** for that iD. A row is actionable only when that state is `CLEAR`. With no rows at all, it is blocked.

Every gated path checks this at the moment it acts:
- the Scheduling actionable view;
- package creation;
- texts;
- dispatch bots;
- Zaps.

**This implements T30, T45 and T55.** One table and one rule replace v0.1's separate hold and link rows. Auditing Complete becomes informational only.

### 6.2 What the tool publishes

| Event | Publishes | Timing |
|---|---|---|
| Hold opened (re-audit, material change, cancel) | `BLOCK` for every linked iD of the Deal | **Immediately**, with high priority. Holds are never gated behind clearance. |
| Row linked while the Deal is not clear | Nothing (default-deny already blocks) | — |
| Deal becomes clear: approved at the current version, no open holds, no pending material change, row linked | `CLEAR` for each linked iD | Only after every pending `BLOCK` for that iD is `confirmed` and verified |
| Non-consumer route (`skip_audit`) | `CLEAR` once the row is linked and the Deal is released with no holds | Same verification |

### 6.3 Ordering, duplicates, concurrency

- **Sequence.** `seq` comes from a per-iD counter, assigned under the Deal lock in the same transaction as the decision or hold that caused it.
  - A late or duplicate `CLEAR` with a lower `seq` can never override a newer `BLOCK`.
  - Duplicates share an idempotency key, so the same `seq` is never written twice.
- **Holds.** Holds keep their identity internally (`audit_holds`, with release tied to the exact covering attempt and its `approved` decision). AppSheet never interprets holds; it only sees the computed state.
- **Verification (T56).** A read-back confirms the highest `seq` row in AppSheet matches what the tool expects. `deals.gate_clear` stays false until that is verified.
- **Failure and staleness.** These cases cover a delivery failure, AppSheet being stale, or a Zap already queued:
  - Because of default-deny, a delayed `CLEAR` only delays work; it never exposes anything.
  - A delayed `BLOCK` is the one exposure, so `BLOCK` deliveries get first priority. Home shows a red "hold not yet confirmed at AppSheet" exception.
  - Every gated automation re-checks the gate immediately before acting.
  - The trial must demonstrate each of these cases.

### 6.4 Cutover (Finding 6, T57)

**Global readiness** is checked before the gate is turned on. All of the following must hold:
1. every in-flight 3.1 row has a `reconciliation_items` row with an outcome of `linked` or `blocked_unresolved`;
2. every `linked` row's Deal approvals and holds have been reconciled;
3. a read-back shows every `blocked_unresolved` row has no `CLEAR` in AppSheet.

**Row eligibility** is per row. A resolved row gets `CLEAR` independently, and unresolved rows simply stay blocked. One unresolved legacy row does not stop the cutover.

---

## 7. Storage policy per path (Finding 8)

| Path | Allowed content | Enforcement |
|---|---|---|
| vAuto observations | Allowlisted fields only: vehicle, appraisal value, personnel, customer name/phone/email/postal code/city/state, title region/name, tag, lien owner/phone/payoff/payoff date/per diem, condition, timestamps, sanitized notes. **Dropped:** `lien.accountNumber`, `customer.address` street line, `workPhone`/`pagerPhone` unless needed. | The Worker's sanitizer is allowlist-based. A DB `CHECK (app.json_is_clean(body))` rejects any key outside the allowlist schema. |
| vAuto notes text | **Conflict:** D-rule "store original notes unchanged" vs the no-account-number/home-address policy | **Needs Rami (R1).** Recommended: at intake, redact digit runs of 6 or more on lines not labelled VIN/PHONE/PRICE/MILES/DEPOSIT, plus any line labelled ACCT/ACCOUNT. Store the redacted text as the original, with a `redactions` log of position and type (not the value). The template forbids account numbers. |
| 3.1 read-backs | Allowlisted field-map columns only (groups A–E). The Lien Bank Overnight Address is a bank address and is allowed. | Same `json_is_clean` check |
| `record_history`, `activity_events`, `deal_versions` snapshots | Values of allowlisted columns only. They never contain raw payloads. | Built by functions from sanitized columns; CHECK as above |
| `bridge_deliveries.payload` | Field-map groups A–D for 3.1 rows; gate fields for gate events | View-built payload; CHECK |
| `integration_call_logs`, `bridge_attempts`, `audit_logs` | Operation, status code, error **code**, duration, correlation ID. **Never** request or response bodies. | No body columns. Error text is truncated and passed through the sanitizer. |
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
| S1 | Base44 identity/JWT spike (§2.4) | Claude to prepare; run in a Base44 dev app |
| R1 | Decide how vAuto notes are stored (§7): sanitized original (recommended) vs extending the T43 exception to restricted raw notes | **Rami** |
| — | AppSheet default-deny gate (§6) replaces the hold-table and link-row mechanism. It implements T30, T45 and T55. Rami to confirm the mechanism change; no business rule changes. | **Rami** to note; Codex to review |
