# Phase B remote preflight — 2026-10-28

Read-only inspection of the target Supabase project before IIT installation. Accepted by Codex on 2026-10-28.
No migration was applied; the inspection ran inside one read-only transaction that ended in `ROLLBACK`. Separately,
the owner rotated the `postgres` database password before the inspection (see "Credential handling").

## Target and provenance

| Item | Value |
|---|---|
| Project reference | `fqxfrtfiysbuctcccudb` |
| Project name / region | TAV Interim Inventory Tool / East US (North Virginia) |
| Repository commit inspected against | `ec71e4b52ccc25a05646915242a9ca4a491917fb` (`main`, squash merge of PR #10) |
| Migrations at that commit | `001`–`006` (pre-packaging names); SHA-256 listed in `docs/preflight/supabase-cli-packaging.md` |
| Supabase CLI | 2.98.2 (Homebrew), linked with `supabase link --project-ref fqxfrtfiysbuctcccudb` |
| Connection | session pooler `aws-0-us-east-1.pooler.supabase.com:5432`, database `postgres`, user `postgres.fqxfrtfiysbuctcccudb`, `sslmode=require`; password (rotated by the owner beforehand) entered only at psql's hidden prompt |
| Server | PostgreSQL 17.11; `current_user` = `session_user` = `postgres` |
| Client | psql 18.6 (libpq), `-X` (no psqlrc) |
| Original psql output | 281 lines, SHA-256 `36b798e473cd5e66ce9542f36bcc3428b5ddea69d02f9cc7d26e8a25444a56da` (not committed; the s2test section is preserved in `s2test-before-2026-10-28.txt`) |
| Inspection script | SHA-256 `e0f342e23b8b5163b49c1e1f3e3171ec53c1e218d8620c26c72aafa53ff301d5` (not committed) |

Linking was verified from the CLI 2.98.2 source (`internal/link/link.go`) to make Management API reads only and to write
only `supabase/.temp/` locally (excluded through `.git/info/exclude`, never committed). It does not connect to Postgres.

## Credential handling

- The initial connection attempts failed at authentication, before any SQL ran, because the previous database password
  was unavailable or incorrect.
- The owner then reset the `postgres` database password in the Supabase Dashboard. This password rotation is a remote
  credential change made intentionally by the owner; it is separate from, and not part of, the read-only inspection.
- The new password was saved only in the owner's password manager and entered only at psql's hidden terminal prompt.
  Its value was never shown to Claude, written into a command, recorded in shell history, printed in output, placed in
  the repository, or committed.

## Read-only proof

| Check | Result |
|---|---|
| `SHOW default_transaction_read_only` (session) | `off` — the shared session pooler does not propagate `PGOPTIONS`; a first run that required `on` aborted before any inspection |
| `BEGIN TRANSACTION READ ONLY` | `BEGIN` |
| `SHOW transaction_read_only` immediately after | `on` (guard passed; the script would have rolled back and exited 3 otherwise) |
| `SHOW transaction_read_only` after the last inspection query | `on` |
| End of transaction | `ROLLBACK` (no `COMMIT` anywhere in the script) |

The script contained no DDL, DML, `COPY`, `CALL`, `DO`, `SET`, sequence function, or call to any `iit`/`s2test` function.
Every inspection query ran inside the single read-only transaction. psql exited 0.

## Findings

### Migration history

- Schema `supabase_migrations`: **absent**. Table `supabase_migrations.schema_migrations`: **absent**. No relations in
  that schema.
- `supabase migration list` was therefore not run, and history was not initialized. The first CLI push will create it.

### IIT schema

- Schema `iit`: **absent**. Every object defined by migrations 001–006 lives in `iit` apart from the roles below and the
  `authenticator` membership grant, so there is no object overlap.
- Classification: **absent** (not partial, complete, or conflicting).

### Roles

| Role | Present | Attributes |
|---|---|---|
| `iit_owner` | no | — |
| `iit_integration` | no | — |
| `tav_worker` | no | — |
| `iit_base44` | no | — |
| `authenticator` | yes | LOGIN, NOINHERIT, not SUPERUSER, not BYPASSRLS, not CREATEROLE, not CREATEDB, no replication, no connection limit |

No other role named `iit%` or `tav%` exists. `authenticator` is **not** a member of `iit_base44` (the role is absent).

Memberships involving `authenticator`:

| Role granted | Member | Grantor | set / inherit / admin |
|---|---|---|---|
| `anon` | `authenticator` | `supabase_admin` | t / f / f |
| `authenticated` | `authenticator` | `supabase_admin` | t / f / f |
| `service_role` | `authenticator` | `supabase_admin` | t / f / f |
| `authenticator` | `postgres` | `supabase_admin` | t / t / t |
| `authenticator` | `supabase_storage_admin` | `supabase_admin` | t / f / f |
| `spike_identity_broker` | `authenticator` | `postgres` | t / f / f |
| `spike_tav_worker` | `authenticator` | `postgres` | t / f / f |

**Observation and owner decision.** `authenticator` can `SET ROLE` to two spike-environment roles,
`spike_identity_broker` and `spike_tav_worker`. Neither collides with an IIT role. Owner decision (2026-10-28): leave both
memberships completely unchanged — they belong to the existing spike environment and are outside this installation's
scope.

### D-36 and D-40

- `iit.gate_idempotent_targets` (D-36): **absent** (table does not exist; not "empty").
- `iit.gate_integration_actions` (D-40): **absent**.
- No remote D-36 or D-40 rows.

### s2test baseline (catalog and statistics only)

Full detail: `docs/preflight/s2test-before-2026-10-28.txt`. Summary:

- Schema owner `s2test_owner`; ACL `{s2test_owner=UC/s2test_owner,s2test_runner=U/s2test_owner}`.
- 18 tables, 25 indexes, 6 sequences; 51 constraints (18 p, 3 u, 17 f, 13 c); 24 functions (20 SECURITY DEFINER);
  7 append-only triggers, all enabled; no views, materialized views, procedures, policies, or custom types.
- RLS off and not forced on every table. `s2test_runner` holds `r` on every table and `a` on `identity_probes` only.
- Largest relations: `gated_actions` and `identity_probes` 188416 bytes each; estimated live rows range 0–426.
- No application row was selected, no `count(*)` was run on an `s2test` relation, no `s2test` function or trigger was
  invoked.

## Stop conditions

None triggered: project reference matched, read-only was proven, migration history is absent (not unexpected), IIT is
absent, no IIT roles or memberships exist, D-36/D-40 are absent.

## What did not happen

The successful inspection ran inside `BEGIN TRANSACTION READ ONLY` and ended with `ROLLBACK`. It made no remote DDL or
DML, no schema change, no role or membership change, no configuration-table change, and no application-data change.
No migration was applied; `supabase migration list`, `supabase db push` (with or without `--dry-run`), `repair` and
`reset` were not run; `s2test` was not modified; `iit` was not exposed.

The only remote change during Phase B was the owner's intentional `postgres` password rotation in the Dashboard, made
before the inspection (see "Credential handling"). The new password is held only in the owner's password manager; no
password, token, key, or credential-bearing connection string was printed, written to a file or command, placed in the
repository, or committed.
