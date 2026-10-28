# 008 — Logistics read interface: planning note (NOT a migration)

**Status:** planning only, on branch `docs/008-logistics-read-requirements`. No SQL, role, grant, function, table, credential or secret is created by this PR. Nothing is applied anywhere.
**Base:** `main` @ `c4650bc` (PR #12 merged: non-superuser executor `SET ROLE iit_owner`; `authenticator` memberships SET-only).
**Input:** `docs/migrations/008-logistics-requirements-v2.1.md` (TAVOps Logistics handoff, with owner amendment A1 on correlation ids).
**Remote state as reported by the owner:** 001–006 applied to the target project; **post-application verification still pending**. IIT 007 not finalized.

## 0. Gate: 008 is not written until all of these hold
1. The post-application verification of 001–006 is complete and recorded.
2. IIT 007 (Base44 staff-screen reads: `get_deal`, `list_deals`, `list_work_items`, `list_audit_queue`, `get_report`, `list_staff`) has final contracts and is merged. **007 stays reserved for those reads.**
3. 008 is branched from the `main` that results, and this note is re-checked against it (§7).
4. The owner decides the open questions in §9 (at least Q1–Q5).

## 1. Purpose and boundaries
- **What Logistics gets:** it references `iit.deals.id` (soft reference, Logistics side) and reads IIT **only** through three functions, called by the Logistics Worker via PostgREST with a dedicated JWT whose `role` claim is `iit_logistics_reader`.
- **No duplicate inventory.** 008 creates **no** inventory-bearing table. Its only table, `iit.logistics_read_audit`, stores no VIN, deal id, 3.1 ID, price or any row content: just function name, credential `jti`, correlation UUID, input count, outcome and error code. Logistics' own evidence store lives in the `logistics` schema and is not an IIT concern.
- **No direct IIT table access.** `iit_logistics_reader` gets `USAGE` on schema `iit` (needed to resolve the function names) and `EXECUTE` on exactly three functions. There is no table, sequence, view, helper or other-function privilege. RLS stays policy-less (deny by default). No FK into `iit` from `logistics`. Logistics never writes IIT.
- **The functions only read IIT business tables.** Their single write is the audit row.

## 2. Proposed objects and exact signatures

### 2.1 Public functions (EXECUTE to `iit_logistics_reader` only)
| Signature | Returns | Properties |
|---|---|---|
| `iit.logistics_resolve_31(p_legacy_iids text[], p_correlation_id text)` | `jsonb` envelope | `VOLATILE SECURITY DEFINER`, owner `iit_owner`, `SET search_path = ''` |
| `iit.logistics_deal_summaries(p_deal_ids text[], p_correlation_id text)` | `jsonb` envelope | same |
| `iit.logistics_vin_candidates(p_vins text[], p_correlation_id text)` | `jsonb` envelope | same |

**Two deliberate deviations from the requirements text (planning findings, §8 F1/F2):**
- **`p_deal_ids` is `text[]`, not `uuid[]`.** A malformed UUID typed as `uuid[]` fails in PostgREST/Postgres coercion **before** the function body runs, so it could never be an audited `INPUT_INVALID` denial. As `text[]`, each element is validated inside the body against the canonical UUID form, so a malformed one gives an audited `denied`.
- **`p_correlation_id` stays `text`, validated inside the body** (amendment A1, §4), for the same reason. Typed as `uuid`, an invalid value would raise before the body and couldn't receive the server-generated audit id.

**Envelope:**
```
{"status":"ok"|"denied", "error_code":null|"<code>", "correlation_id":"<uuid>", "rows":[...] /* only when ok */}
```
- **Rows:** one row per input position, duplicates included, each with `ordinality` (1-based) and `found`.

**Row keys:**
- `logistics_resolve_31`: `ordinality, legacy_iid, found, deal_id, link_status, source_status, kind` (from `iit.source_records`; `found = false` when no row has that `legacy_iid`).
- `logistics_deal_summaries`: `ordinality, deal_id, found, deal_number, vin_normalized, year, make_text, model_text, purchase_price, dealer_sold_to, source_channel_name, intake_status, cancelled_at` (from `iit.deals` ⋈ `iit.vehicles` ⋈ `iit.source_channels`). **`stock_number` is dropped pending Q1.**
- `logistics_vin_candidates`: `ordinality, vin_normalized, found, candidate_count, deal_id, deal_number`. `deal_id`/`deal_number` are set only when `candidate_count = 1` under the Q3 definition of a "live" deal. Exact `vin_normalized` match only.

### 2.2 Internal objects (no EXECUTE or privilege for anyone but `iit_owner`)
| Object | Kind | Notes |
|---|---|---|
| `iit.require_logistics_reader() RETURNS text` | `STABLE SECURITY DEFINER` | credential check (§3); returns the `jti`; raises `28000` on failure |
| `iit._logistics_resolve_31_rows(p text[]) RETURNS jsonb` | `STABLE` | read-only; builds the `rows` array |
| `iit._logistics_deal_summary_rows(p uuid[]) RETURNS jsonb` | `STABLE` | read-only; called only after the wrapper has validated and cast the text elements |
| `iit._logistics_vin_candidate_rows(p text[]) RETURNS jsonb` | `STABLE` | read-only; input already normalized `upper(btrim())` |
| `iit._logistics_audit(p_function text, p_jti text, p_correlation uuid, p_correlation_source text, p_input_count int, p_outcome text, p_error_code text)` | `VOLATILE` | the only writer of the audit table |
| `iit.logistics_read_audit` | table, append-only (`iit.make_append_only`) | `id bigint identity PK`, `at timestamptz default now()`, `function text CHECK IN (3 names)`, `credential_jti text NOT NULL`, `correlation_id uuid NOT NULL`, `correlation_source text CHECK IN ('caller','server')`, `input_count int NOT NULL CHECK >= 0`, `outcome text CHECK IN ('ok','denied')`, `error_code text`, `CHECK ((outcome='ok') = (error_code IS NULL))`, `CHECK (error_code IS NULL OR error_code IN (<fixed set>))` |
| `iit.require_role(text,text)` | `CREATE OR REPLACE` of the 006 function | adds one branch (§3.2); otherwise byte-for-byte unchanged |

### 2.3 Wrapper body order (each public function)
1. `v_jti := iit.require_logistics_reader();` (raises on credential failure, so no audit row: by design, §5).
2. Correlation (§4): if `p_correlation_id` isn't a canonical v4 UUID, set `v_corr := gen_random_uuid()`, `source = 'server'`, and deny `CORRELATION_INVALID`.
3. Input checks in a fixed order, computing `input_count` with `cardinality()` (0 when NULL):
   1. NULL array → `INPUT_EMPTY`;
   2. empty array → `INPUT_EMPTY`;
   3. any NULL element → `INPUT_NULL_ELEMENT`;
   4. more than 500 elements (VINs: 50) → `INPUT_TOO_LARGE`;
   5. any malformed element → `INPUT_INVALID`.
4. On a denial: `PERFORM iit._logistics_audit(..., 'denied', code)`, then **RETURN** the denial envelope (no raise).
5. Otherwise call the helper, `PERFORM iit._logistics_audit(..., 'ok', NULL)`, then RETURN the `ok` envelope.

**No actor push/restore (§5.9.1):** these functions change no business row, and `record_history` doesn't cover the append-only audit table. **This needs an owner and Codex confirmation:** CLAUDE.md says "actor push/restore per §5.9.1" for functions; this note reads that as applying to functions that mutate history-covered tables (Q6).

## 3. Credential enforcement changes

### 3.1 `iit.require_logistics_reader()` (new)
- `v_origin := nullif(current_setting('role', true), 'none')`; `v_claims := nullif(current_setting('request.jwt.claims', true), '')`.
- **`v_origin <> 'iit_logistics_reader'`** → `CREDENTIAL_WRONG_ORIGIN` (`28000`). This includes owner SQL, `postgres`, `service_role`, `authenticated`, `iit_base44` and `tav_worker`. The only legitimate caller is the PostgREST `SET ROLE` from the Logistics credential.
- Claims NULL → `CREDENTIAL_NO_CLAIMS`.
- `claims.role <> 'iit_logistics_reader'` → `CREDENTIAL_ROLE_MISMATCH`.
- `jti` NULL or empty → `CREDENTIAL_NO_JTI`.
- `jti` in `iit.revoked_credentials` → `CREDENTIAL_REVOKED`.
- **It reuses the existing `iit.revoked_credentials` table** (one `jti` namespace across credentials, which is safe because jtis are UUIDs).
- No staff actor: the caller is an integration, identified by `jti`.

### 3.2 `iit.require_role` change (one branch)
- Add `ELSIF v_role = 'iit_logistics_reader' THEN RAISE 'CREDENTIAL_ROLE_MISMATCH'` (any origin), so a Logistics token can never act as a staff actor, even through a function its role was somehow granted.
- If the origin is `iit_logistics_reader`, the function was reached despite no grant, so refuse (`CREDENTIAL_WRONG_ORIGIN`).
- The existing `iit_base44` branches are unchanged.
- **007 interaction (§7):** if 007 refactors credential checks into a shared helper, this branch moves there.

## 4. Correlation IDs (owner amendment A1)
- **Accepted form only:** `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`. That's a lowercase, hyphenated, RFC 4122 **version 4** UUID, as produced by the Worker's `crypto.randomUUID()`. Uppercase, braces, other versions, the nil UUID and anything else are rejected.
- **Rejected or missing:** the call is **denied** (`CORRELATION_INVALID` or `CORRELATION_MISSING`), the audit row stores `correlation_id = gen_random_uuid()` with `correlation_source = 'server'`, and that UUID is returned in the envelope. **The rejected value is never stored, logged or echoed.**
- **Why:** a caller-chosen string of up to 64 characters could carry a VIN (17), a deal number, a 3.1 ID, an email or a name. A v4 UUID can't, by construction.
- **Stored type:** `uuid`. The column can only hold UUIDs.

## 5. Audit transaction behaviour
| Case | DB behaviour | Durable record |
|---|---|---|
| success | returns `ok`; audit row commits with the call | `iit.logistics_read_audit` (`ok`) + Logistics Worker event |
| validation / correlation refusal | **returns** `denied` (no raise); audit row commits | `iit.logistics_read_audit` (`denied`, code) + Worker event |
| credential rejection (`require_logistics_reader`) | raises `28000` before any write | **Worker boundary** + Supabase API logs. **No IIT row, by design** (proven by test T9) |
| permission denied (role lacks EXECUTE) | `42501` before the body | Worker boundary + API logs |
| infrastructure/bug exception after the audit insert | raises; the audit row rolls back with the call | Worker boundary + Postgres/API logs |

- **No extension:** `dblink` and autonomous transactions are not used.
- **Caller rule:** an HTTP-200 `denied` envelope is a refusal; the Worker applies nothing from it.

## 6. Roles, memberships and the exact privilege matrix

### 6.1 Role and membership statements (following 001/006 as fixed by PR #12)
- **`iit_logistics_reader`:** created as the executor with `createrole_self_grant = ''` pinned around `CREATE ROLE iit_logistics_reader NOLOGIN NOINHERIT`. The executor ends with ADMIN only (no SET, no INHERIT), which the deploy-executor assertions extend to cover.
- **`authenticator` membership:** `GRANT iit_logistics_reader TO authenticator WITH ADMIN FALSE, INHERIT FALSE, SET TRUE` (only if `authenticator` exists), issued by the executor (whose ADMIN authorizes it).
- **Then, after `SET ROLE iit_owner`:**
  - `GRANT USAGE ON SCHEMA iit TO iit_logistics_reader`;
  - `GRANT EXECUTE` on the three exact signatures;
  - `REVOKE ALL ON FUNCTION` for each new object `FROM PUBLIC`;
  - explicit `REVOKE ALL ON ALL TABLES, ALL SEQUENCES IN SCHEMA iit FROM iit_logistics_reader` (documents intent).
- **Default privileges:** unchanged (001 already revokes functions from PUBLIC for objects `iit_owner` creates).

### 6.2 Privilege matrix (target; asserted by test T8)
| Object ↓ / Role → | `iit_logistics_reader` | `iit_base44` | `tav_worker` | `iit_integration` | `anon` / `authenticated` / `service_role` / PUBLIC | `iit_owner` |
|---|---|---|---|---|---|---|
| schema `iit` USAGE | **yes** | yes (006) | yes (001) | yes (001) | no | owner |
| `logistics_resolve_31(text[],text)` | **EXECUTE** | no | no | no | no | owner |
| `logistics_deal_summaries(text[],text)` | **EXECUTE** | no | no | no | no | owner |
| `logistics_vin_candidates(text[],text)` | **EXECUTE** | no | no | no | no | owner |
| `require_logistics_reader()`, `_logistics_*` helpers, `_logistics_audit` | no | no | no | no | no | owner |
| `iit.logistics_read_audit` (any privilege) | no | no | no | **see Q7** | no | owner |
| every other `iit` function (27 staff RPCs, Worker functions, helpers) | **no** | unchanged | unchanged | unchanged | no | owner |
| every `iit` table / sequence | **no** | no | no | unchanged | no | owner |
| `authenticator` membership | SET only | SET only (006) | — | — | — | — |

**Q7:** 001–005 each end with `GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA iit TO iit_integration` (e.g. `20261028000101_foundation.sql:735`); 006 does not. If 008 follows the 001–005 convention, `iit_integration` would get SELECT/INSERT/UPDATE on `iit.logistics_read_audit` (UPDATE still blocked by the append-only trigger, but INSERT would let it forge audit rows). Proposal: 008 does **not** repeat the blanket grant and adds an explicit `REVOKE ALL ON iit.logistics_read_audit FROM iit_integration`. Owner/Codex decide.

## 7. Dependencies on Migration 007
1. **Version and order:** 008's file is `supabase/migrations/<14-digit version>_logistics_read_interface.sql` with a version strictly greater than 007's (001–006 use `20261028000101`…`20261028000106`); tests are `008_logistics_read_interface_test.sql`.
2. **Credential enforcement:** if 007 changes `require_role` or introduces a shared credential helper, 008 rebases its §3.2 branch onto it rather than redefining `require_role`.
3. **Read conventions:** if 007 settles a read-envelope shape, error-code style or `json_schemas` allowlists for read outputs, 008 aligns with them (the envelope above is a proposal, not a constraint on 007).
4. **Read auditing:** if 007 adds auditing of Base44 reads, decide whether one table serves both (with a `credential_role` column) or 008 keeps its own (Q4).
5. **Schema exposure:** both depend on the D-2 §7 configuration step that exposes schema `iit` to PostgREST (`Content-Profile: iit`). 008 adds no exposure of its own.
6. **Test harness:** reuse 006's real-`authenticator` login pattern (Z6/Z8) for T1–T7.

## 8. Planning findings (conflicts with the requirements as received)
- **F1:** `p_deal_ids uuid[]` → `text[]` (§2.1). Otherwise a malformed id can't be an audited denial.
- **F2:** the correlation id is a strict v4 UUID (owner amendment A1). This replaces the v2.1 `^[A-Za-z0-9_.:-]{1,64}$` rule.
- **F3:** `stock_number` can't be supplied. `iit.external_references` (`idms_stock`) has **no link to a deal or vehicle** in 001–006, so the field is dropped from `logistics_deal_summaries` until a link exists (Q1).
- **F4:** the requirement "a non-17-character VIN after normalization → `INPUT_INVALID`" may refuse lookups of VINs IIT actually holds, since `iit.vehicles` doesn't constrain VIN length (Q2).
- **F5:** `logistics_resolve_31` returns `found = false` for every input until IIT populates `source_records`. Today nothing creates them (bridge deferred, cutover/manual linking not built, 3.1 allowlist D-8 empty). Logistics plans for this as the unresolved-link workflow. This is information, not a defect.
- **F6:** the "same pattern as 006" wording doesn't hold for an integration credential. 006 has a claim-less path for non-Base44 origins; 008 must refuse **every** origin except `iit_logistics_reader` (§3.1).

## 9. Open questions for the owner / Codex
1. **Q1:** stock number: add a deal ↔ `idms_stock` link in a future slice, or drop the field permanently from the Logistics read?
2. **Q2:** VIN validation: refuse non-17-character inputs (`INPUT_INVALID`), or accept any non-empty normalized VIN and return `found = false`?
3. **Q3:** the definition of a "live" deal for `vin_candidates`: `cancelled_at IS NULL` only, or also excluding `intake_status = 'voided'` and `final_closure_at IS NOT NULL`?
4. **Q4:** a dedicated `iit.logistics_read_audit` table (proposed), or reuse `iit.activity_events` (`actor_kind 'worker'`, extended `activity_event_detail` allowlist), or one table shared with any 007 read audit?
5. **Q5:** Logistics credential lifetime and rotation: does D-48 (180 days, reminders at 30/14/7, revoke by `jti`) apply unchanged?
6. **Q6:** confirm that read functions with no business-row mutation don't need actor push/restore (§2.3).
7. **Q7:** `iit_integration` privilege on the audit table (proposal: none).
8. **Q8:** retention of `iit.logistics_read_audit` (proposal: keep, matching other append-only IIT evidence).
9. **Q9:** the batch limits stay 500 / 50 (from the requirements). Confirm.

## 10. Tests required (for the future 008 test file; none written now)
- **T1–T7 credential**, from a real `authenticator` login:
  - T1: missing claims;
  - T2: mismatched role claim;
  - T3: missing `jti`;
  - T4: revoked `jti`;
  - T5: valid Logistics claims through the wrong originating role (`postgres`, `authenticated`, `iit_base44`, `service_role`);
  - T6: a Base44 credential calling each Logistics function (`42501`), and with coerced Logistics claims (refused);
  - T7: the Logistics credential calling each of the 27 staff RPCs, `require_role`, and each Worker function (`42501`), plus `require_role` refusing Logistics claims under any origin.
- **T8:** the exact-signature privilege matrix (§6.2): `has_function_privilege` / `has_table_privilege` / `has_schema_privilege` for every role × object, including "no" on every other `iit` function and table for `iit_logistics_reader`.
- **T9 audit:**
  - success → exactly one `ok` row;
  - each denial code → exactly one `denied` row;
  - credential rejection → zero rows;
  - an infrastructure exception after the insert → zero rows (rolled back);
  - no row ever contains an input identifier (scan all audit columns for the test VINs, deal ids and 3.1 IDs).
- **T10 contract:**
  - duplicates give duplicate rows with distinct `ordinality`;
  - order is preserved;
  - limits are 500 / 50 and 501 / 51 is denied;
  - NULL array → `input_count = 0`; NULL elements → array length;
  - envelope keys exact.
- **T11 correlation (A1):**
  - a valid v4 UUID is stored as given with `correlation_source = 'caller'`;
  - each of these gets a server UUID, a denial, and is **absent from every audit column**: missing; empty; uppercase UUID; braced UUID; v1 UUID; nil UUID; a VIN; a deal number; a 3.1-style ID; an email; a 64-character string; and a 10 KB string.
- **T12:** malformed elements in `p_deal_ids` are an audited `INPUT_INVALID` (F1).
- **T13 executor:** the `deploy_executor_test` assertions extend to `iit_logistics_reader`: the executor holds ADMIN only, and `authenticator` holds SET only.
- **T14 read-only:** a full run of each function changes no row in any `iit` business table (`record_history` count unchanged).
