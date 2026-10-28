> **Recorded in the IIT repo on 2026-10-28** from the TAVOps Logistics handoff (`to-iit-workflow-008-logistics-requirements-handoff-2026-10-28.md`).
> Status: **requirements as received, for planning only.** Not authorized for implementation. Planning note: `docs/migrations/008-plan.md`.
> **Owner amendment A1 (28 Oct 2026), supersedes the correlation-id rule in §2 and §3.3 below:** `p_correlation_id` must be an opaque,
> Worker-generated **canonical UUID** (lowercase, hyphenated, version 4 — `crypto.randomUUID()`). Arbitrary 1–64-character values are
> **not** accepted, because they could carry a VIN, deal number, 3.1 ID, email or other business identifier. A missing or invalid value
> gets a server-generated audit UUID (returned in the denial); the rejected value is never stored. See `008-plan.md` §4.

# IIT migration 008: Logistics read interface — requirements v2.1 (from TAVOps Logistics, 2026-10-28)

**For:** the IIT project's reviewed Codex/Claude workflow (owner decision L-B). **Status:** requirements only. Logistics does not write or apply this migration.
**v2 corrects v1:** v1 declared the functions `STABLE` while also requiring every call (including failed ones) to write an audit row. That can't hold: an audit insert in a call that later raises is rolled back, and PostgreSQL has no ordinary autonomous transactions. v2 fixes the audit semantics (§3) and makes credential enforcement for the new role explicit (§4). **v2.1** defines the audit values stored for invalid inputs (§3.3) and the caller's handling of denials (§3.4).
**Approval:** approved for **planning handoff** only. Not authorized for implementation.

**Do not implement until (L-G):**
1. the IIT Migration 001 deployment-role defect is fixed and merged;
2. IIT 007 (Base44 staff-screen reads) has final contracts;
3. 008 is based on the resulting canonical `main`.

**Context:** IIT is the system of record. Logistics keeps only logistics-owned records and references `iit.deals.id` by soft reference. Logistics reads IIT only through the three functions below, called by the Logistics Worker through PostgREST with a dedicated credential whose JWT role is `iit_logistics_reader`. Full design: `logistics-l0-iit-alignment-proposal-v0.3-2026-10-28.md` (v0.3.1).

---

## 1. Roles and grants
- **`iit_logistics_reader`:** NOLOGIN, NOINHERIT. Granted to `authenticator` with `SET TRUE, INHERIT FALSE, ADMIN FALSE`.
- **EXECUTE** on exactly the three public functions in §2 (exact signatures), and on nothing else in `iit`: no table, sequence, helper, staff-RPC or Worker-function privilege.
- **Revoked from** `PUBLIC`, `anon`, `authenticated`, `service_role`, `iit_base44`, `tav_worker`, `iit_integration`.
- **Not granted to `iit_logistics_reader`:** the internal helpers (§3.1).

## 2. Functions
All three are `VOLATILE` (each call writes an audit row), `SECURITY DEFINER`, owned by `iit_owner`, with `SET search_path = ''`.

| Function | `rows[]` element (one per input position) |
|---|---|
| `iit.logistics_resolve_31(p_legacy_iids text[], p_correlation_id text)` | `ordinality, legacy_iid, found, deal_id, link_status, source_status, kind` (from `source_records`) |
| `iit.logistics_deal_summaries(p_deal_ids uuid[], p_correlation_id text)` | `ordinality, deal_id, found, deal_number, vin_normalized, year, make_text, model_text, purchase_price, dealer_sold_to, source_channel_name, intake_status, cancelled_at, stock_number` (`idms_stock` external reference, if any). **Excludes** parties, liens, titles, reports, audit detail, deposit and balance |
| `iit.logistics_vin_candidates(p_vins text[], p_correlation_id text)` | `ordinality, vin_normalized, found, candidate_count, deal_id, deal_number`, where `deal_id` is set **only when exactly one non-cancelled deal** exists (otherwise null, with `candidate_count` showing 0 or >1). Exact match only, no prefix or partial search |

**Return contract:** a single `jsonb` envelope:
```
{ "status": "ok" | "denied",
  "error_code": null | "<code>",            -- set only when status = denied
  "correlation_id": "<p_correlation_id>",
  "rows": [ … ]                            -- present only when status = ok
}
```
- **Rows:** one per array position, **duplicates included**, in input order, each with `ordinality` (1-based) and `found`. Only the documented keys; no enumeration beyond the requested identifiers.
- **VINs:** normalized with IIT's rule (`upper(btrim(vin))`, as `vehicles.vin_normalized`).

**Input validation** returns `denied` (it doesn't raise):

| Condition | `error_code` |
|---|---|
| `p_correlation_id` NULL, empty or > 64 characters | `CORRELATION_REQUIRED` |
| array NULL or empty | `INPUT_EMPTY` |
| any NULL element | `INPUT_NULL_ELEMENT` |
| more than 500 elements (`vin_candidates`: more than 50) | `INPUT_TOO_LARGE` |
| malformed element (for example a non-17-character VIN after normalization) | `INPUT_INVALID` |

## 3. Audit semantics (the v1 correction)

### 3.1 Design: option 1, a VOLATILE audited wrapper with read-only helpers
Each public function is a thin `VOLATILE SECURITY DEFINER` wrapper:
1. **Credential check (§4).** On failure it **raises**, consistent with `require_role`.
2. **Input validation (§2).** On failure it inserts the audit row with `outcome = 'denied'` and the code, then **returns** the `denied` envelope without raising, so the audit row commits.
3. **Data.** It calls a `STABLE` internal helper (`iit._logistics_resolve_31_rows`, …) that only reads. The helper has no EXECUTE for `iit_logistics_reader`.
4. **Success.** It inserts the audit row with `outcome = 'ok'` and returns the `ok` envelope.

**Audit table:** `iit.logistics_read_audit`, append-only (`make_append_only`), with columns:
- `id`, `at`;
- `function`;
- `credential_jti` (or another non-secret credential id);
- `correlation_id`;
- `input_count`;
- `outcome` (`ok`, `denied`);
- `error_code`.

**Never** VINs, deal ids, 3.1 IDs or row contents. The IIT reviewers may instead use `iit.activity_events`, provided these fields and the no-identifier rule hold.

No extension (`dblink` or similar) is added for this.

### 3.2 Which layer durably records each case
| Case | DB behaviour | Durable record |
|---|---|---|
| **Success** | returns `ok` | **IIT** `logistics_read_audit` (`ok`) **+** a Logistics Worker event |
| **Business/validation refusal** (§2 table) | returns `denied` (no raise) | **IIT** `logistics_read_audit` (`denied`, code) **+** a Logistics Worker event |
| **Credential/authentication rejection** (§4) | **raises** (`28000`), so any IIT write is rolled back | **Logistics Worker boundary** (HTTP status, PostgREST error code, correlation id, credential id; no identifiers) **+** Supabase API logs |
| **Permission denied** (role lacks EXECUTE; PostgREST/Postgres `42501` before the function body runs) | raises | **Worker boundary** + Supabase API logs |
| **Database/infrastructure exception** (bug, timeout, connection loss) | raises; rolled back | **Worker boundary** + Supabase API/Postgres logs |

**Worker boundary record (Logistics side):** every 008 attempt writes one `logistics.events` row:
- `provider = 'iit'` (a value Logistics 003 adds);
- `event_type` = function name;
- `dedupe_key` = correlation id;
- `payload` = `{input_count, http_status, error_code, outcome, latency_ms, credential_id}` (no identifiers).

The correlation id joins the two sides.

### 3.3 Audit values for invalid inputs (v2.1)
The audit row is always written with bounded, identifier-free values:

| Input problem | `correlation_id` stored | `input_count` stored |
|---|---|---|
| `p_correlation_id` NULL, empty, or not matching `^[A-Za-z0-9_.:-]{1,64}$` | a **server-generated** id (`gen_random_uuid()::text`, prefixed `srv-`), **returned in the denial envelope**. The caller's value is **never stored**, whatever its length | the array length, as below |
| array NULL | as above, or the caller's value if valid | **0** |
| array with NULL elements | as above | the **array length** (NULL elements counted; contents never stored) |
| array too large | as above | the **array length** (counted with `cardinality()`; nothing else from the array is read or stored) |
| a malformed element | as above | the array length |

`error_code` is always one of the fixed codes in §2. No caller text is ever copied into the audit row.

### 3.4 Caller handling (Logistics Worker)
An HTTP-200 response whose envelope has `status = "denied"` is a **refusal**, never a successful IIT read:
- the Worker records it as `outcome = 'denied'` in `logistics.events`;
- it applies no data from it (no link, no verification, no `last_iit_verified_at` update);
- a denial in a scheduled run stops that run's IIT-dependent steps and raises an operator-visible error.

## 4. Credential enforcement for `iit_logistics_reader` (explicit, not "same pattern")
`require_role` in 006 is built around the Base44 originating role and a staff actor. Logistics reads have **no staff actor**: the caller is an integration. 008 adds **`iit.require_logistics_reader()`** (or extends `require_role` with an explicit branch; the IIT reviewers choose), and reuses `iit.revoked_credentials`:
- **Originating role `iit_logistics_reader`** (`current_setting('role')` at call start): claims must exist; `claims.role` must equal `iit_logistics_reader`; `jti` must be present and must not be in `iit.revoked_credentials`. Otherwise raise `28000` with codes `CREDENTIAL_NO_CLAIMS`, `CREDENTIAL_ROLE_MISMATCH`, `CREDENTIAL_NO_JTI` or `CREDENTIAL_REVOKED`.
- **Any other originating role:** the logistics functions refuse (`CREDENTIAL_WRONG_ORIGIN`), including owner SQL and service paths. The only legitimate caller is the Logistics credential.
- **`require_role` must also refuse** claims naming `iit_logistics_reader` under any origin (`CREDENTIAL_ROLE_MISMATCH`), so a Logistics token can never act as a staff actor.

**Required tests:**
1. missing claims → `CREDENTIAL_NO_CLAIMS`;
2. mismatched JWT `role` claim → `CREDENTIAL_ROLE_MISMATCH`;
3. missing `jti` → `CREDENTIAL_NO_JTI`;
4. revoked `jti` → `CREDENTIAL_REVOKED`;
5. a valid Logistics claim presented through the wrong originating DB role (for example `postgres`, `authenticated`, `iit_base44`) → refused;
6. a **Base44** credential calling a logistics function → permission denied (no EXECUTE), and with claims coerced → refused;
7. a **Logistics** credential calling any Base44 staff RPC, `require_role`-guarded function or Worker function (`authorize_and_consume`, `report_action_outcome`, `expire_stale_attempts`, `ingest_vauto_observation`) → permission denied;
8. an exact-signature privilege matrix: `has_function_privilege` is true only for `iit_logistics_reader` on the three signatures, and false for every other role on them and for `iit_logistics_reader` on every other `iit` function;
9. audit: success and each §2 denial produce exactly one `logistics_read_audit` row with no identifiers; a credential rejection produces **no** IIT row (proving the §3.2 split);
10. contract: duplicate inputs give duplicate rows with distinct `ordinality`; input order is preserved; the size limits are enforced.
