# Migration 007 — preflight, application and post-application verification — 2026-10-29

Project `fqxfrtfiysbuctcccudb` (TAV Interim Inventory Tool). `main` at `52287bada6f90abc61fcf305281a75feb92ac1b0` (PR #15).
Migration `supabase/migrations/20261028000107_staff_read_rpcs.sql`, SHA-256
`5a265622acc1e7e09748b30af9a2a1db2534d5201c92e8f48b3d470620821c70`; 001–006 byte-identical to their verified checksums.

**Result: applied successfully; 16/16 read-only post-application checks PASS.** One observation (O-1) was diagnosed as
existing Supabase platform behaviour and accepted by the owner as decision **V-3** (§5). Two verification-wrapper false
negatives are recorded in §4; both were resolved by read-only diagnosis only — no repair, retry, grant, revoke, migration
edit or remote test was performed.

## 1. Method
Every remote step was run by the owner in the owner's Terminal; passwords were entered at psql's hidden prompt or a hidden
shell read and passed only to the one process that needed them. Every inspection ran inside
`BEGIN TRANSACTION READ ONLY` with `transaction_read_only = on` proven at start and end, and ended with `ROLLBACK`. No IIT
staff, Worker or business RPC was called, no migration test ran remotely, no `s2test` row was read. Outputs are kept outside
the repository (SHA-256 below).

| Step | Output | Result |
|---|---|---|
| Read-only preflight (Phase C inventory + `s2test` catalog + 007 absence) | `4390f5ae…f04584e7`, 694 lines | inventory identical to Phase C; history 001–006; no 007 object, history row or `iit_owner` default-ACL row; `s2test` unchanged |
| `supabase db push --dry-run --linked` (CLI 2.98.2) | `c14ab6c0…4394bdeab`, 8 lines | exit 0; exactly `20261028000107_staff_read_rpcs.sql` proposed; no `Initialising login role` |
| Pre-apply re-inspection (same script, inside the apply wrapper) | `4390f5ae…f04584e7` — byte-identical to the preflight | PASS |
| `supabase db push --linked` | `1d379604…4236a45e06`, 9 lines | exit 0; only 007 listed; `Applying migration 20261028000107_staff_read_rpcs.sql...`; `Finished supabase db push.`; no `Initialising login role` (see §4.1) |
| Read-only post-application verification | `27e472f9…9c32a653`, 739 lines | 16/16 PASS (§3) |
| Read-only O-1 diagnostic | `c134a309…d29ef7`, 63 lines | §5 |

## 2. What changed remotely
Exactly the Migration 007 objects: the global V-2 default ACL row; `iit.read_access_audit` with its identity sequence, primary
key and append-only trigger; 20 owner-only helpers; 10 read RPCs granted to `iit_base44`. The remote inventory change since
the Phase C post-application verification equals, line for line, the change between local reference installs of 001–006 and
001–007: 52 lines added and 6 count lines replaced (`iit_base44` executable 27→37, functions 76→106, history 6→7, tables
51→52, sequences 11→12, indexes 87→88). `record_history` is unchanged (20 rows, same content hash).

## 3. Post-application verification (16 items)

| # | Check | Result |
|---|---|---|
| 1 | History `20261028000101`–`107`, each once, in order | PASS (count 7, distinct 7) |
| 2 | 007 recorded as `staff_read_rpcs` | PASS |
| 3 | `read_access_audit` (identity `id`), its sequence, primary-key index, `zz_append_only` trigger; 20 helpers; 10 RPC signatures | PASS |
| 4 | All 30 functions owned by `iit_owner`, `search_path=""` | PASS |
| 5 | 10 RPCs SECURITY DEFINER, ACL `{iit_owner=X, iit_base44=X}` | PASS |
| 6 | Helpers owner-only (`{iit_owner=X}`); none executable by `iit_base44`, `iit_integration`, `tav_worker`, `anon`, `authenticated`, `service_role`, `authenticator` | PASS |
| 7 | `iit_base44` executes exactly 37 = `iit_integration`'s 27 + the 10 approved signatures; no table or sequence privilege | PASS |
| 8 | `iit_integration` 27; `tav_worker` 4 | PASS |
| 9 | PUBLIC, `anon`, `authenticated`, `service_role`: no function, table, sequence or schema access to `iit`; 0 PUBLIC ACL entries | PASS |
| 10 | One IIT default-ACL row: `iit_owner`, global (namespace 0), functions, `{iit_owner=X/iit_owner}`; no PUBLIC | PASS |
| 11 | `read_access_audit`: ACL `{iit_owner=arwdDxtm/iit_owner}` (no IIT grant to any other role), append-only, not history-covered, 0 rows | PASS — effective read access by platform roles: O-1 / V-3 (§5) |
| 12 | Role memberships and the executor's SET-only `iit_owner` membership unchanged; no IIT login role | PASS |
| 13 | D-36 `gate_idempotent_targets` 0 rows; D-40 `gate_integration_actions` 0 rows | PASS |
| 14 | Inventory differs from the pre-application baseline only by the expected 007 additions (§2) | PASS |
| 15 | `s2test` catalog metadata identical to the pre-application baseline (192 data lines) | PASS |
| 16 | No `pgrst.db_schemas` setting on `authenticator` (IIT not exposed); `revoked_credentials`, `staff_identities`, staff users 0; no Worker login; Worker/vAuto/3.1 tables 0 rows | PASS (database evidence; none of these was done) |

## 4. Verification-wrapper false negatives (resolved read-only)

### 4.1 Application wrapper
The wrapper checked for `Applying migration 20261028000107_staff_read_rpcs.sql...` as an exact line. The CLI printed its
confirmation prompt without a newline, so the captured line was ` [Y/n] Applying migration 20261028000107_staff_read_rpcs.sql...`
and the wrapper reported "NOT as expected" although the CLI exited 0 and printed `Finished supabase db push.`. The owner
treated it as requiring read-only verification, not a retry; the verification (§3) confirmed the application.

### 4.2 First post-application evaluation
The evaluator compared the remote presence checks with a local reference install, which has none of Supabase's platform
roles. It therefore reported the platform roles' effective table access (§5) as an unexpected grant. (The same first
evaluation also counted the `s2test` baseline file's title line as data; that comparison bug was fixed and all runs re-evaluate
as identical.) The read-only O-1 diagnostic established that no IIT grant exists and that the access comes from platform role
membership.

Neither case involved any repair, retry, grant, revoke, migration edit or remote test.

## 5. O-1 and owner decision V-3 — platform-managed roles and IIT tables

**Measured (29 Oct 2026).** `postgres`, `supabase_etl_admin` and `supabase_read_only_user` are not superusers, hold BYPASSRLS,
and are direct, inheriting members of `pg_read_all_data`; none of the three holds `pg_write_all_data` or inherits `iit_owner`.
Each has exactly **SELECT** — no INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES or TRIGGER — on `read_access_audit` and on the
pre-existing `deals`, `revoked_credentials` and `record_history`, can reach 52 of 52 `iit` tables, and has `USAGE` on schema
`iit`. Sequence privileges were not measured; by PostgreSQL's definition `pg_read_all_data` confers `SELECT` (not `USAGE` or
`UPDATE`) on sequences. `iit` has no RLS policies, so BYPASSRLS adds nothing. No migration grants anything to these roles or
to any predefined role.

**Nature.** `pg_read_all_data` and `pg_write_all_data` are PostgreSQL predefined roles whose membership on this project is
managed by Supabase, i.e. platform-managed. They confer read (respectively write) access to every table in every schema
regardless of the table's own ACL. Platform-managed roles — for example `postgres`, `supabase_admin` (the bootstrap
superuser, which bypasses ACLs altogether) and `service_role` — may therefore receive effective `iit` table access through
such memberships or attributes even while every `iit` ACL remains owner-only. As measured on 29 Oct 2026, `service_role` holds
no `iit` table, sequence or schema access; that is the platform's current configuration, not something IIT enforces. The
access predates Migration 007 and applied to every `iit` table created by 001–006.

**Decision V-3 (owner, 29 Oct 2026).** Accept the measured Supabase platform behaviour for Phase 1 as a documented platform
trust boundary, alongside V-1. No Supabase-managed role, membership or attribute is revoked or altered.

**IIT's application security boundary** (what IIT does enforce):
- no direct `iit` table or sequence privilege for `anon`, `authenticated`, `iit_base44`, Worker callers (`tav_worker`) or any
  other ordinary application role;
- application access only through the approved RPC functions (`iit_base44`: the 37-function manifest; `tav_worker`: its four
  Worker functions);
- the originating-role, JWT-role, `jti`, revocation (`iit.revoked_credentials`), staff-identity and staff-role checks in
  `require_role()` remain mandatory on every staff function.

IIT does **not** restrict, and makes no claim to restrict, Supabase's own administrative or service roles. "Owner-only" in
IIT documents describes IIT's grants (ACLs), not the effective access of platform-managed roles.

## 6. Not done
No PostgREST exposure, credential, Base44 secret or connection, Worker login or deployment, vAuto contact, live 3.1 write,
D-36/D-40 population, `s2test` change, repair, reset, seed, grant, revoke or configuration change.
