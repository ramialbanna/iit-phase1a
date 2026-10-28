# Phase C post-application verification — 2026-10-28

Read-only verification of project `fqxfrtfiysbuctcccudb` after the owner-run `supabase db push --linked` from `main` at
`c4650bc9206fe54cd3813dc8e65864d519e7af8f` (CLI 2.98.2; 001–006 applied, exit 0). Remote output was compared line by line
with a fresh local PostgreSQL 17.11 install of the same commit, applied by a non-superuser `CREATEROLE` executor with no
tests run, and with the pre-application `s2test` baseline (`s2test-before-2026-10-28.txt`).

**Result: PASS on all 16 items.** Two observations, now owner decisions V-1 and V-2 (below). Neither is a deployment
discrepancy, and neither changes current effective access. V-2 is a required correction before any new IIT function is
deployed.

## Method

- One psql session through the session pooler as `postgres`, password at psql's hidden prompt; exit 0.
- `BEGIN TRANSACTION READ ONLY` → `transaction_read_only = on` (start and end) → `ROLLBACK`. No `COMMIT`.
- Catalog reads, `pg_has_role`/`has_*_privilege` checks, row counts and stable-content MD5s of `iit` tables (no values
  printed), and the exact Phase B `s2test` catalog queries. `SET LOCAL ROLE iit_owner` only around the row-count section:
  the executor correctly holds `iit_owner` with SET only and cannot read `iit` tables otherwise. No `iit`/`s2test` function
  was called, no RPC or migration test was run, no `s2test` row was read.
- Remote output: 455 lines, SHA-256 `990bc4e74f435172da52c47580858ce56696d9e45f391c162bda65d1cb0ea78f` (not committed).
- Executor/bootstrap names normalized (`postgres`/`deployer` → `<executor>`; `supabase_admin`/local bootstrap →
  `<bootstrap>`) so remote and reference diff directly.

## Results

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Local repo clean `main` at `c4650bc` | **PASS** | HEAD `c4650bc9206fe54cd3813dc8e65864d519e7af8f`, tree clean before this file |
| 2 | Read-only transaction | **PASS** | session default `off` (pooler), `BEGIN` → `transaction_read_only = on` → … → `on` → `ROLLBACK` |
| 3 | Password handling | **PASS** | psql hidden prompt in the owner's Terminal; not in the command, history or output |
| 4 | Migration history | **PASS** | `20261028000101` foundation, `…102` reports_audit_holds, `…103` deal_workflow, `…104` intake, `…105` gate, `…106` base44_rpc_role; count 6, distinct 6, in order |
| 5 | Schema `iit` owned by `iit_owner` | **PASS** | owner `iit_owner`; ACL `{iit_owner=UC, iit_integration=U, tav_worker=U, iit_base44=U}` — identical to reference |
| 6 | IIT roles exist, NOLOGIN | **PASS** | all four `login=false`, not superuser, no BYPASSRLS/CREATEROLE/CREATEDB/replication, no role config; `iit_base44` NOINHERIT |
| 7 | Membership graph | **PASS** (see V-1) | identical to reference — table below |
| 8 | Inventory | **PASS** | 51 tables, 11 sequences, 87 indexes, 0 views, 0 materialized views, 76 functions (same signatures, owners, SECURITY DEFINER flags, `proconfig`, ACLs and body MD5s), 91 triggers, 0 policies, 1 composite type `actor_ctx` — every line identical to reference |
| 9 | `iit_base44` privileges | **PASS** | schema USAGE yes, CREATE no; EXECUTE on exactly 27 functions, set-equal to the 006 test's manifest; 0 table/sequence privileges; 0 of the 4 Worker-only functions (`authorize_and_consume`, `expire_stale_attempts`, `ingest_vauto_observation`, `report_action_outcome`) |
| 10 | PUBLIC / `anon` / `authenticated` / `service_role` | **PASS** (see V-2) | no ACL entry for any of them on the schema, any relation or any function; effective: schema USAGE false, executable functions 0, selectable relations 0 for each API role |
| 11 | D-36 / D-40 | **PASS** | `gate_idempotent_targets` 0 rows; `gate_integration_actions` 0 rows |
| 12 | Reference / service data | **PASS** | 10 tables hold migration-created rows. **Nine** seed tables match the reference in row count **and** stable-content MD5: `json_schemas` 7, `legacy_31_statuses` 5, `material_fields` 8, `report_requirement_rules` 3, `required_fact_rules` 27, `roles` 4 (`admin, audit_lead, auditor, data_entry`), `source_channels` 4, `system_settings` 3 (`gate_31_read_max_age_seconds, gate_attempt_timeout_seconds, legacy_31_consignment_total_price`), `users` 1 (service user `…f00d` "TAV Intake Worker"). The tenth, `record_history`, has the expected **20 rows** and the same structure (identical column, constraint, trigger and ACL inventory, item 8) and purpose — the history of those seed inserts — but its **raw hash differs**, because its rows carry an identity `id` and embedded generated values (timestamps, generated keys); its hash also differs between two independent local builds. The other 41 tables: 0 rows |
| 13 | `s2test` unchanged | **PASS** | 193/193 non-blank lines identical to the baseline: schema owner/ACL, 18 tables / 25 indexes / 6 sequences, every relation's owner, ACL, RLS flags, estimated rows and size, columns, indexes, 51 constraints, 24 function signatures/owners/SECURITY DEFINER/ACLs, 7 triggers, no policies, no types (only difference: one trailing blank line in formatting) |
| 14a | PostgREST not exposing `iit` | **PASS (database evidence)** | no `pgrst.db_schemas` setting on `authenticator`. Supabase's exposed-schema list is project configuration, not fully visible from SQL — confirm in Dashboard → API → Exposed schemas |
| 14b | No Base44 credential | **PASS (database evidence)** | `revoked_credentials` 0, `staff_identities` 0, no staff users. A JWT is minted outside the database, so its absence is attested, not provable here; none was minted in this work |
| 14c | No Worker login / real-login membership | **PASS** | no Worker login exists; the only login memberships involving `tav_worker`, `iit_integration` or `iit_owner` are the `postgres` deployment executor's automatic ADMIN-only creator grants on those roles plus its explicit SET-only membership in `iit_owner`; `iit_base44` reachable only via `authenticator` (and V-1) |
| 14d | No Worker deployed / vAuto contact / live 3.1 write | **PASS (database evidence)** | `vauto_observations`, `external_references`, `appraisal_episodes`, `deals`, `gated_actions`, `gated_action_attempts`, `gated_action_events`, `work_items`, `activity_events` all 0 rows; nothing was deployed or contacted in this work |
| 15 | No remote tests / RPCs | **PASS** | none run |
| 16 | No change made | **PASS** | read-only transaction rolled back; no repair, grant, revoke, expose, seed or populate |

### Membership graph (remote = reference)

| Role | Member | Grantor | ADMIN | INHERIT | SET |
|---|---|---|---|---|---|
| `iit_owner` | `postgres` (executor) | `postgres` | false | false | **true** |
| `iit_owner` | `postgres` | `supabase_admin` (CREATEROLE auto-grant) | true | false | false |
| `iit_integration` | `postgres` | `supabase_admin` (auto-grant) | true | false | false |
| `tav_worker` | `postgres` | `supabase_admin` (auto-grant) | true | false | false |
| `iit_base44` | `postgres` | `supabase_admin` (auto-grant) | true | false | false |
| `iit_base44` | `authenticator` | `postgres` | **false** | **false** | **true** |

`pg_has_role(postgres, iit_owner)`: MEMBER true, SET true, USAGE (inherit) **false** — the executor does not inherit
`iit_owner` privileges. `authenticator → iit_base44`: SET true, USAGE false. No IIT role is a member of any role.

## Owner decisions (2026-10-28)

### V-1 — accept `supabase_storage_admin` → `authenticator` → `iit_base44` reachability for Phase 1

**Finding.** Supabase's own platform grant `authenticator ← supabase_storage_admin` (SET TRUE, present in Phase B before
application) chains with the approved `authenticator → iit_base44` (SET ONLY), so the Storage service role can
`SET ROLE authenticator` and then `SET ROLE iit_base44`, reaching EXECUTE on the 27 manifest functions. No IIT grant was
added for it; the direct IIT graph is exactly as designed. It is inherent to granting anything to `authenticator`.

**Decision.**
- Accepted for Phase 1 as a documented **Supabase platform trust boundary**.
- No Supabase-managed role or membership is revoked or altered.
- Every originating-role, JWT-role, `jti`, revocation (`iit.revoked_credentials`) and staff-role check in `require_role()`
  remains mandatory on every staff function; nothing is relaxed because of this path.
- A platform-managed database role holding an arbitrary SQL session is **outside the application credential boundary**:
  the D-48 credential controls what a PostgREST caller holding an `iit_base44` token can do; they do not, and are
  not claimed to, constrain Supabase's own service roles.

### V-2 — the per-schema default function-privilege revoke is ineffective; correct it before any new IIT function

**Finding.** `ALTER DEFAULT PRIVILEGES FOR ROLE iit_owner IN SCHEMA iit REVOKE ALL ON FUNCTIONS FROM PUBLIC` (001, 006)
creates no `pg_default_acl` row — none remotely, none in the reference. PostgreSQL's built-in PUBLIC EXECUTE on new
functions is a global default and cannot be removed per schema. Proven locally on a rolled-back probe: a function created
by `iit_owner` in `iit` gets `proacl` NULL, i.e. PUBLIC EXECUTE.

**Current state is safe.** All 76 deployed functions have PUBLIC EXECUTE revoked explicitly (item 10: no PUBLIC entry on
any function; 0 executable functions for `anon`, `authenticated`, `service_role`). This is a **latent risk for future
functions**, not a defect in current effective access. Unrevoked, a future function would be executable by PUBLIC — and
so by `iit_base44`, `iit_integration` and `tav_worker`, which hold USAGE on `iit`.

**Decision — required correction before any new IIT function is deployed.**
- Migration 007 must add, **without** an `IN SCHEMA` clause:
  `ALTER DEFAULT PRIVILEGES FOR ROLE iit_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;`
- Every function must still receive an explicit `REVOKE ALL ON FUNCTION … FROM PUBLIC` (defence in depth; the default
  does not cover functions created by other roles).
- A regression test must inspect the global default ACL for `iit_owner` (a `pg_default_acl` row with
  `defaclnamespace = 0`, object type `f`, no PUBLIC EXECUTE) and prove that a newly created test function owned by
  `iit_owner` does not receive PUBLIC EXECUTE.
- Migration 007 is not applied until the correction and its tests are reviewed. Nothing was changed for this decision.

## Not done

No `db push`, dry run, migration repair, remote SQL write, role or configuration change, PostgREST exposure, credential,
D-36/D-40 population, Worker deployment, Base44 enablement, vAuto contact, 3.1 write, or `s2test` change.
