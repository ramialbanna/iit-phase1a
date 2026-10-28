# Phase C, application attempt 1 — 2026-10-28

The first authorized `supabase db push --linked` against `fqxfrtfiysbuctcccudb` (TAV Interim Inventory Tool), from `main`
at `56ecd4a94e5f591c3c5a60d925e63776b843d010` with Supabase CLI 2.98.2, stopped safely in the first migration. Recorded from
the owner's report of the run and of the read-only audit that followed; no command in this record was re-run for it.

## Failure

| Item | Value |
|---|---|
| Migration | `20261028000101_foundation.sql` |
| Statement | `CREATE SCHEMA IF NOT EXISTS iit AUTHORIZATION iit_owner` |
| Error | `ERROR: must be able to SET ROLE "iit_owner" (SQLSTATE 42501)` |
| Executor | `postgres` (Supabase: `CREATEROLE`, not superuser) |

The CLI executes each migration file together with its `schema_migrations` insert as one implicitly transactional batch
(`pkg/migration/file.go`, `ExecBatch`), so the failure rolled back everything in 001, including its `CREATE ROLE`s, and
001 was **not recorded**. Migrations 002–006 were not attempted.

## State after the attempt (read-only audit)

- `supabase_migrations.schema_migrations` **exists and contains zero rows**. The CLI's `CreateMigrationTable` runs before
  the first migration and outside its batch, so the history schema and table persist although no migration applied.
- Schema `iit`: absent.
- Roles `iit_owner`, `iit_integration`, `tav_worker`, `iit_base44`: absent.
- D-36 `iit.gate_idempotent_targets` and D-40 `iit.gate_integration_actions`: absent.
- `s2test`: unchanged.

## Consequence for the next attempt

The next `db push` sees an existing, empty history table and all six versions pending; no `migration repair` is needed or
authorized. Root cause and fix: `docs/migrations/001.md` §0c (rev 5) and `docs/migrations/006.md` (rev 4). The fix is
local-only until reviewed, merged, and a new application is separately authorized.
