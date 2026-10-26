# Interim Inventory Tool — Phase 1a Supabase Schema Design (v0.4, for review)

**Date:** 19 Oct 2026 · **Author:** Claude · **Reviewer:** Codex · **Approver:** Rami

**Status:** Design for review. Nothing has been created in Supabase.

- v0.4 supersedes v0.3.
- §0b answers Codex's five v0.3 findings and its smaller points.
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

## 0b. Changes from v0.3 (Codex review of v0.3)

| # | Finding | Resolution in v0.4 | Section |
|---|---|---|---|
| 1 | Authorization checked, not enforced at execution | The check and its use are now one transaction: `authorize_and_consume()`, called as the step immediately before the side effect. It takes a Deal-row lock, so it is serialized against hold creation (FOR SHARE vs FOR UPDATE). No reusable token and no 120-second allowance. Concurrent hold: consumption either happened before the hold or is denied. Actions already in flight are listed as work items. The residual seconds-long window is presented as a business exception (RR2), with a proxy-execution alternative. | §6.1–6.4 |
| 2 | Skip-audit Deals denied | `row_actionable` explicitly allows a released Deal with a confirmed `skip_audit` route, no holds and a canonical link. Unknown or hold routes are denied. | §6.3 |
| 3 | Duplicate containment overstated | Destination-side prevention first: the tool supplies the 3.1 `iD` itself, so a retried Add is rejected by AppSheet as a duplicate key (to be proven in S2). Fallback: a Bridge Key column, set out as an interface change under AM1, with its exposure stated rather than claimed away. | §5.8, §6.8 |
| 4 | Non-material corrections suspend approval | Corrections are now split. **Material** (D21) corrections open a draft and a hold. **Administrative** amendments keep the approval and are recorded in `deal_amendments` and `record_history`. `release_deal()` freezes the existing draft. | §5.5, §5.7 |
| 5 | Freshness used a completion date that doesn't exist | The baseline is now the **appraisal date**, vAuto `created` (D25), or the Deal creation date for manual Deals. No use of first-observed completion. | §5.6 |
| — | Waiver revocation | Revocations are separate append-only rows. Only the latest waiver counts; revoking it never brings back an older one. | §5.6 |
| — | Multiple observations per pass | The uniqueness rule is removed. Stability now compares (ID, last-modified, content hash), and a content change for the same ID within a pass makes the window unstable. | §5.10 |
| — | Signing-secret custody | S1 now covers who holds the key: whoever holds the signing key can impersonate any user. Holders are kept to a minimum: asymmetric signing key or gateway custody, rotation, and per-call staff re-check. | §2.4 |
| — | RR1 split | RR1a covers personal actions that cannot be gated. RR1b covers how fast a hold appears in the Scheduling view (seconds normally; 30-minute expiry is only the backstop). | §11 |

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

6. **Key custody.** Whoever holds the Supabase JWT signing key can mint a token for any user. A broker token limits only that token's own permissions. Controls:
   - **One holder.** Exactly one component signs tokens: Base44's backend secret store, or the Cloudflare gateway.
   - **Asymmetric keys if available.** If Supabase asymmetric signing keys or third-party auth are available, only the private key holder can sign.
   - **Rotation.** The key is rotated on a schedule and on any staff or vendor change.
   - **Per-call re-check.** Every function checks `staff_identities.active` on each call.
   - **Audit trail.** Every minted token is logged with the Base44 user and the request ID.

   S1 must confirm which of these controls Supabase and Base44 actually support.

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
| Deal-wide holds (T45, T55) | `audit_holds`, `authorize_and_consume` | Any open hold ⇒ every iD of the Deal is denied at once (read live; no delivery needed) |
| Unlinked rows blocked (T55, T57) | `authorize_and_consume` (default-deny) | Unlinked or duplicate ⇒ denied |
| Version-bound approval | `deal_versions`, `prequalification_checks`, `audit_decisions` | Authorization needs an approval on the latest released version, with no open draft |
| Fail-closed actions (T56) | `authorize_and_consume`, `gate_authorizations`; the `Audit Gate` display table | Every gated bot and Zap authorizes live; any error denies; display CLEAR rows expire after 30 minutes |
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

### 5.5 Deal versions, and two kinds of correction (Findings v0.2-3/4, v0.3-4)

The `deal_versions` table is as in v0.3: `draft` → `released` → `superseded`, with exactly one draft per Deal at a time.

**Every correction to a released Deal is one of two kinds:**

| Kind | Which fields | Effect |
|---|---|---|
| **Material** (D21) | price, VIN, owner/sellers, lien position or lienholder, title state (including the tribal flag) | Opens draft N+1 and an Audit hold **immediately**. The Deal is not actionable until N+1 is released (and approved, on the Risk Audit route). |
| **Administrative** | Every other field, e.g. phone formatting, colour, trim, email, Dealer Sold To, deposit wording where the amount is unchanged | Applied straight to the released version as a numbered **amendment**. **Approval is kept**: no draft, no hold, no re-audit. Kept in `deal_amendments` (append-only: `deal_id`, `version_no`, `amendment_no`, `field`, `before`, `after`, `by`, `reason`, `at`) and in `record_history`. If the field also appears in 3.1, a same-day correction work item is created for Data Entry, because the bridge is add-only. |

- **Which fields are material** is reference data (`material_fields`), set from D21.
- **Proposed addition for Rami (R2):** treat a **Source/channel change after release** as material, because it can move a Deal between the Risk Audit and skip-audit routes.
- **Report requirements change only through material fields** (VIN, owner type or business seller, title state, tribal). An administrative amendment therefore never changes the requirement set.

**Release.** `release_deal()` freezes the **existing draft**: it moves the row from `draft` to `released` and writes the snapshot and watermark in the same transaction. It does not insert a new version row.

**Approval eligibility.** The latest decision on the attempt for the latest released version is `approved`, and there is no open material draft. Administrative amendments never affect eligibility.

### 5.6 Report pack: authoritative validation (Findings 3, 4, 9)

The report columns are as in v0.2, plus `deal_id NOT NULL`. A report belongs to one Deal.

**Requirements**
- `deal_report_requirements` (`deal_id`, `version_no`, `requirement_key`, `report_type`, `subject_type`, `subject_vin` / `subject_org_id`, `freshness_baseline`) is derived for the **draft** and frozen with it at release.
- `freshness_baseline` is the **appraisal date**, taken from vAuto `created` (D25: reports are pulled after the appraisal date), for vAuto Deals, and the Deal's creation date for manual Deals (confirmed by Rami). The completion time is not used: Cox does not provide it.

**Validations and waivers**
- **`report_validations`** is append-only: `id` (bigint identity), `report_id`, `requirement_key`, `deal_id`, `version_no`, `outcome` (`valid` / `rejected`), `checks` jsonb (`subject_match`, `owned_by_deal`, `readable`, `complete`, `fresh`), `reason`, `validated_by`, `at`, `carried_from_validation_id`.
- **Authoritative validation:** for each (`report_id`, `requirement_key`, `version_no`), the row with the highest `id`. Later rows supersede earlier ones. A rejection followed by a corrected re-validation therefore ends `valid`, and a later rejection overrides an earlier `valid`.
- **Waivers** live in `report_waivers` (append-only) and `report_waiver_revocations` (append-only: `waiver_id`, `revoked_by`, `reason`, `at`).
  - For each (`deal_id`, `requirement_key`, `version_no`), **only the latest waiver row counts**.
  - If that waiver has a revocation, the requirement is unwaived.
  - An older waiver never comes back.
  - A new waiver needs a new row.

**When a requirement R on version N is satisfied**
- **By a report**, when all of these hold:
  - `report.deal_id` = the Deal;
  - no later report replaces it (`replaces_report_id` chain);
  - its subject equals R's subject (VIN, or organization);
  - `pulled_at` is on or after R's `freshness_baseline`;
  - its authoritative validation for (R, N) is `valid`.
- **Or by a waiver:** the latest waiver for (R, N) exists and has no revocation.

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
- `deal_version_no` is not the latest released version, or a **material** draft is open.

It locks the Deal row first (`FOR UPDATE`).

**`release_deal(deal)`.** One transaction, with the Deal row locked. It refuses the release unless every check passes:
1. Intake status permits release.
2. The Source/channel is set.
3. The required intake facts are present (VIN, price, deposit stated, title custody, lien position, seller party, phone, buying entity).
4. There are no open blocking flags.
5. No parser re-run is pending.
6. Every requirement in the computed set is satisfied (§5.6).

It then **freezes the existing draft** (`draft` → `released`, with snapshot and watermark), marks the previous released version `superseded`, and on the first release queues the initial `add_31_row` delivery.

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

**External duplicates.** Local fencing cannot stop a late sender from completing an Add at AppSheet. Duplicates are therefore prevented at AppSheet itself where possible:

1. **Primary: the tool supplies the iD.**
   - The bridge generates the 3.1 `iD` value deterministically from the delivery, in a format compatible with today's iDs, and sends it on the Add.
   - Every retry and every late sender sends the **same key**, so AppSheet rejects any second Add as a duplicate key. The existence check is simply a read by that iD.
   - No column changes.
   - **Spike S2 must prove four things:** the AppSheet API accepts a supplied key on Add for this table; it rejects a duplicate key; the iD format suits the 4.1 script and the Zaps; and no AppSheet initial value overwrites it.
2. **Fallback, if S2 fails: a Bridge Key column.**
   - A new column (3.1 grows from 98 to 99) holds the idempotency key. The existence check searches by it. Valid_If uniqueness is tried, but cannot be relied on for API Adds until proven.
   - **Exposure:** between a late duplicate Add and reconciliation (within one read-back cycle, a few minutes), the duplicate row exists in 3.1. Gated actions are still denied, because `row_actionable` requires a linked, canonical iD and the duplicate is unknown or non-canonical. **Ungated paths could still see it:** the Scheduling view (only if it lacks the gate filter), manual use, and any automation not yet gated.
   - **Recovery:** reconciliation marks the later row `duplicate` and opens a work item for Data Entry to cancel it in AppSheet.
   - This column is part of AM1 (§6.8).

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
| `poll_observations` | `pass_id`, `page_no`, `position`, `appraisal_id`, `last_modified`, `content_hash`. Unique per (`pass_id`, `page_no`, `position`). The same ID may appear several times in one pass, and **every occurrence is kept**. |
| `poll_discoveries` | `window_id`, `appraisal_id`, `last_modified`, `content_hash`. One row per **distinct version** of an appraisal seen in the window. |
| `poll_processing` | `discovery_id`, `outcome` (`created` / `updated` / `unchanged` / `flagged` / `error`), `processed_at` |

**A window is complete** when all of these hold:
1. **Single-page mode:** one pass returned `count_reported` ≤ 100, and the distinct IDs equal `count_reported`.
2. **Multi-pass mode:** two consecutive passes each return a **set of (appraisal ID, last-modified, content hash) triples**, and the two sets are identical. A pass is invalid if the same ID appears in it with differing content.
   - The number of distinct IDs equals `count_reported` on both passes.
   - **Records that leave the window between passes** are fetched individually by ID. If the new last-modified is later than the window's end, the record is accounted for: the next window will pick it up. Any other reason for leaving fails the window.
3. Every discovery has a processing outcome other than `error`.

**When stability can't be established** (the window is still unstable after five passes):
- the window fails;
- the checkpoint does not advance;
- the run raises an alert on Home;
- the window is retried on the next cycle.

Narrower time slices do not help when timestamps are equal, so the fallback is retrying until the data stops changing. The independent daily reconciliation against vAuto's completed-appraisal list (intake step 9) backs this up.

## 6. AppSheet gate: authorization consumed at execution (Findings v0.2-1, v0.3-1/2/3)

### 6.1 Principle

An action counts as authorized only if it **consumed** an authorization in one database transaction, as the last step before it acts. That transaction reads the current Deal, version, route, hold and link state.

- **Holds and consumption are serialized.** Opening a hold takes the Deal row lock with `FOR UPDATE`. Consuming an authorization takes it with `FOR SHARE`.
- **There is no reusable authorization.** No token outlives its transaction, so there is no 120-second allowance.
- **Every other outcome denies:** an error, a timeout, an unknown iD, or a missing response.

### 6.2 `authorize_and_consume(iD, action, caller_ref)`

This is a Cloudflare Worker endpoint backed by one Supabase function. Each call:

1. Locks the Deal row (`FOR SHARE`).
2. Evaluates `app.row_actionable(iD)` (§6.3).
3. If the row is actionable, writes a consumed `gate_authorizations` row for `(iD, action, caller_ref, deal_version, consumed_at)` and returns `allowed=true`. Otherwise it returns `allowed=false`, with the denial also logged.
4. Commits.

`caller_ref` is the AppSheet bot run or Zap run ID. It is unique per `(caller_ref, action)`, so a retried step cannot consume twice.

**Where it sits.** The call must be **the step immediately before the side effect**: the same bot or Zap, with no waits, delays or other branches between them.

### 6.3 `row_actionable(iD)`

A row is actionable only if all of these are true:
- the iD is linked, canonical (not a duplicate) and its link is confirmed;
- the Deal is not cancelled or voided;
- the Deal has **no open holds**;
- the Deal has **no open material draft** (§5.5);
- **and** one of these routes applies:
  - **Risk Audit route:** the route is `risk_audit` and the latest released version is approved (§5.7).
  - **Skip-audit route:** the route is a *confirmed* `skip_audit` from `source_channels`, and the latest released version exists. This covers dealer and auction Deals.

Any other route (`hold_in_data_entry`, unknown or NULL) is denied.

### 6.4 Concurrent hold: the residual in-flight window

Because the Deal lock serializes them, every consumption is either **before** a hold commits or **after** it:
- **After:** denied.
- **Before:** the action is ordered before the hold. It may still physically complete a few seconds later, which is the time between the consuming step and the side-effect step.

When a hold opens, `open_hold()` lists every authorization consumed for that Deal in the previous **N seconds** (proposed N = 60). It opens a work item for each one: "action in flight at hold". Data Entry checks the outcome and reverses it where possible, for example by recalling a package.

**This in-flight window is a business exception to T56's "blocked immediately".** It must be accepted by Rami (decision **RR2**, §11). The alternative removes the window completely: the Worker itself performs the gated side effects (proxy execution) instead of AppSheet or Zapier, which is a larger change to today's automations.

### 6.5 Components

| Component | Role |
|---|---|
| Gated AppSheet bots (package, texts, dispatch) and gated Zaps | The step immediately before the side effect calls `authorize_and_consume` and continues only on `allowed=true`. A failure, timeout or missing field stops the run. |
| `Audit Gate` table in AppSheet (add-only) | Drives the Scheduling view and badges only. BLOCK rows are pushed immediately; CLEAR rows expire after 30 minutes unless renewed. **It never authorizes anything.** |
| Manual actions outside AppSheet and Zapier | Not gateable; see RR1a. |

### 6.6 Holds, links, selective release, cutover

These carry over from v0.3:
- Deal-wide holds take effect immediately for every iD through §6.3.
- Unlinked and duplicate iDs are denied.
- A hold is released only by an approved decision on the attempt that covers it.
- Cutover readiness is proven by `row_actionable` returning false for every unresolved row.

### 6.7 Acceptance (T56)

Each scenario below must deny or be detected:
1. A BLOCK delivery fails while a bot fires on a stale CLEAR: the consume step denies.
2. The endpoint is down or times out: deny.
3. A Zap is queued before a hold and runs after it: deny.
4. A hold commits while a consume is running: the two are serialized. If the consume came first, an in-flight work item is opened.
5. A step is retried with the same `caller_ref`: no second consumption.
6. A bot has a delay between consume and act: rejected at configuration review. The S2 inventory checks every bot and Zap.
7. A duplicate or unknown iD: deny.
8. A skip-audit Deal that is released, has no holds and has a canonical link: allow. An unknown route: deny.

### 6.8 Amendment AM1 for Rami (after Codex accepts §6)

1. **Authorization.** Gated actions consume a live authorization from the tool, fail closed, and run as the final step before acting. `Auditing Complete` becomes informational, and the add-only `Audit Gate` table drives display only.
2. **3.1 interface.** One of the following, depending on spike S2 (§5.8):
   - **(a)** The tool supplies the 3.1 `iD` value itself. There is no column change.
   - **(b)** A new `Bridge Key` column is added, so 3.1 grows from 98 to 99 columns.

   Option (b) changes three things that must be checked and signed off by Rami (T44):
   - the 4.1 script's column mapping;
   - any Zap that reads columns by position;
   - the AppSheet table schema.

**Business rules unchanged:**
- Deal-wide holds
- unlinked-row blocking
- selective release
- skip-audit routes
- T56, subject to the RR2 in-flight exception

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

22. (Superseded by 28.)
23. Releasing a draft freezes it. An update to a released version is rejected. A released-field change opens exactly one draft.
24. A rejection after a valid validation leaves the report unsatisfying; a re-validation after a rejection satisfies. A replaced report never satisfies.
25. A late completion with a stale fence changes no state. With a supplied iD, a second Add is rejected by AppSheet (S2). Under the Bridge Key fallback, the non-canonical row is denied by `authorize_and_consume`.
26. A window with an ID whose content changed between passes is not stable. A record that left the window is accounted for only after an individual fetch.
27. INSERTs into mutable tables create version 1 in `record_history`.

Added in v0.4:

28. Every scenario in §6.7 has the stated outcome. A consumption and a hold on the same Deal never both succeed in an order that leaves an action authorized after the hold.
29. An administrative amendment keeps the approval and creates no draft. A material correction always opens a draft and a hold.
30. Revoking the latest waiver leaves the requirement unwaived, even if an older waiver exists.
31. A retried Add with the same supplied iD creates no second 3.1 row (S2).
32. A report pulled before the appraisal `created` date fails freshness.

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
| S2 | AppSheet/Zapier spike. Prove: (1) a bot webhook with return values gates its next step and fails closed; (2) a Zapier Filter stops on failure; (3) consume-then-act has no intervening steps in any gated bot or Zap, checked against an inventory of each Zap's data source (3.1 or 4.1); (4) a supplied iD is accepted on Add and a duplicate key is rejected (else the Bridge Key fallback); (5) the latency of the authorize call is acceptable | Claude to prepare; run against a test copy of 3.1 |
| R1 | **How raw vAuto notes are retained** (Rami). The options:<br>**(A) Recommended:** keep the notes exactly as received in the restricted evidence store, like report files (role-restricted, never shown in general screens). This extends the T43 exception to notes. Parsed labels are stored as structured fields.<br>**(B)** Keep no raw notes; store only the parsed allowlisted labels plus a transformation record (labels found, dropped-line count, hash of the original). The original wording is lost for disputes.<br>**(C)** Keep raw notes visible like other fields. Not recommended: conflicts with the policy. | **Rami** |
| RR1a | Accept that manual actions outside AppSheet and Zapier (personal calls and texts) cannot be technically gated; procedure only. | **Rami** |
| RR1b | Accept that a hold reaches the Scheduling **view** at the speed of BLOCK delivery plus AppSheet sync (normally seconds to a few minutes; the 30-minute CLEAR expiry is the backstop if BLOCK fails). Gated **actions** are still denied immediately. | **Rami** |
| RR2 | Accept the in-flight window: an action that consumed its authorization just before a hold committed may complete a few seconds after it. Each such action becomes a work item to review or reverse. **Alternative:** proxy execution, where the Worker performs gated side effects itself, with no window but a larger change. | **Rami** |
| R2 | Proposed: treat a Source/channel change after release as **material** (it can switch between the Risk Audit and skip-audit routes) | **Rami** |
| AM1 | Design amendment to the gate mechanism (§6.6). Codex reviews §6 first; then Rami confirms. | Codex, then **Rami** |
