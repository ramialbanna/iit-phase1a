# Supabase CLI packaging of migrations 001–006

Packages the six reviewed migrations for `supabase db push` against `fqxfrtfiysbuctcccudb`, whose remote migration
history is absent (`docs/preflight/phase-b-remote-preflight-2026-10-28.md`). Packaging only: nothing was pushed,
dry-run, or applied.

## Provenance

- Base: `main` at `ec71e4b52ccc25a05646915242a9ca4a491917fb` (squash merge of PR #10; docs-only since `f3bb30a`).
- Branch: `chore/supabase-cli-packaging`.
- Supabase CLI targeted: 2.98.2.

## Why the files change

The CLI only recognises `<version>_<name>.sql` and records `<version>` in `supabase_migrations.schema_migrations`;
CLI timestamp versions keep future migrations ordering after these six. The CLI 2.98.2 runner
(`pkg/migration/file.go`, `ExecBatch`) sends each file's statements **and** the history-row insert as one implicitly
transactional batch, after `RESET ALL` (`pkg/migration/apply.go`). An embedded `COMMIT;` would end that transaction
before the history insert, so a failure there could leave a migration applied but unrecorded. Removing the outer
wrapper keeps "migration + its history row" atomic. No transaction-disabling directive is added.

## Rename map and checksums

| Old file (at `ec71e4b`) | Old SHA-256 | New file | New SHA-256 | Wrapper lines removed |
|---|---|---|---|---|
| `001_foundation.sql` | `7a7153d765f6e77c975b1f7dc02f3f47eb8e79f482e6e678958b9ca9b6272cf6` | `20261028000101_foundation.sql` | `f54a96de196b13e170722b23338836022119a815d279838dd7c14fd5ff5f4281` | `BEGIN;` L11, `COMMIT;` L727 |
| `002_reports_audit_holds.sql` | `080f134177b9faba73b66301b336018601ec1568d8be26619e3a0180d94b78d6` | `20261028000102_reports_audit_holds.sql` | `aaf77537741f28ff984a847fb928a2cb8c62c389282a7834d479f609e2f712d1` | `BEGIN;` L5, `COMMIT;` L507 |
| `003_deal_workflow.sql` | `7fe1fd9894a9fc81a87278f2de3c516b31cc602355481be8983ca4e38c2d1941` | `20261028000103_deal_workflow.sql` | `4a15fcc4ba233121573e9a5753aa4e05efd3601e0cd39d548d467d9eeaecdace` | `BEGIN;` L7, `COMMIT;` L515 |
| `004_intake.sql` | `de9e8dbcba4a1a0673057cad7c5bc7a6d85c3cfb67a8f54e8744a2b0cfceb056` | `20261028000104_intake.sql` | `e0614e6cb543f02e769ac6b3b8738e8dec792d92fb0da2528df20e762445acd9` | `BEGIN;` L9, `COMMIT;` L726 |
| `005_gate.sql` | `4362d484c29420f1f090f5af3a646ffce1b9a036cff00003699f42ad317c4a31` | `20261028000105_gate.sql` | `122f339caf6e541adb7a7bbb42eb16d33dcecbdab062880b77f777fb6ad12c3a` | `BEGIN;` L9, `COMMIT;` L479 |
| `006_base44_rpc_role.sql` | `63f4b16e2876a915e1bfcf546b065bce0c76983e16fdb73e2528550b97b7db29` | `20261028000106_base44_rpc_role.sql` | `6d8b8cd9d109a65d9182854636afcca67a540f46cc4473338284cfe3707374b1` | `BEGIN;` L7, `COMMIT;` L81 |

Renamed with `git mv`; no copy of an old file remains.

## Wrapper-removal equivalence proof

For each file the old blob was taken from `ec71e4b` (`git show ec71e4b:supabase/migrations/<old>`), the two wrapper
lines were deleted with `sed -e '<B>d;<C>d'`, and the result was compared to the new file with `cmp`. All six:
`cmp` identical, and the SHA-256 of "old minus those two lines" equals the new SHA-256 above. `diff old new` shows
exactly two removed lines (`< BEGIN;`, `< COMMIT;`) per file and nothing else. Each old file had exactly one
column-0 `BEGIN;` and one column-0 `COMMIT;` (its last line); the new files have none. Files keep LF endings and a
final newline. The in-file header comments (e.g. `-- 001_foundation.sql — …`) still name the pre-packaging files:
they sit outside the wrapper but are kept to preserve byte-identity.

## Non-migration files changed

| File | Why |
|---|---|
| `supabase/tests/run_local.sh` | It derived the test number from the first three characters of the migration filename, which are now `202`. It now takes `<name>` from `<version>_<name>.sql`, finds `tests/NNN_<name>_test.sql`, and uses that `NNN` for the `[N]` limit and the matching `NNN_*_test.sh`; a migration with zero or more than one matching test file prints `FAIL` and stops the run (bash glob array, so `set -euo pipefail` cannot abort it silently). Each migration is applied with `psql -1` (single transaction, with the existing `ON_ERROR_STOP=1`), giving the same all-or-nothing apply the embedded wrapper used to provide. No test or assertion changed. |
| `CLAUDE.md` | The project rule named migrations `supabase/migrations/NNN_*.sql`; it now states the CLI-versioned name, the no-wrapper rule, and the harness pairing. |
| `docs/preflight/phase-b-remote-preflight-2026-10-28.md` | Sanitized Phase B report (owner decision 2). |
| `docs/preflight/s2test-before-2026-10-28.txt` | Catalog-only `s2test` before-baseline for post-application comparison (owner decision 2). |
| `docs/preflight/supabase-cli-packaging.md` | This note. |

No other reference needed to follow the rename: `docs/migrations/NNN.md` notes, the `NNN_*_test.sql`/`.sh` names and
the test-file header comments are unchanged.

## Tests (local only; nothing contacted Supabase)

Environment: macOS arm64, Homebrew `postgresql@16` 16.15 (installed for this run; the harness's
`/usr/lib/postgresql/16/bin` is a Linux path, so it was run with the Homebrew bin first on `PATH`), Node 26.0.0.

```
PATH=/opt/homebrew/opt/postgresql@16/bin:$PATH bash supabase/tests/run_local.sh   # exit 0
cd worker && npm ci && npm test && npm run typecheck                            # exit 0, exit 0
```

| Suite | Result |
|---|---|
| Apply `20261028000101`…`106` (each with `psql -1`) | 6/6 APPLY |
| `001_foundation_test.sql` … `006_base44_rpc_role_test.sql` | 6/6 `ALL 00N TESTS PASS` |
| CONC-1 | PASS — B blocked on A's Deal lock, re-read the superseded attempt and rejected |
| CONC-2a / CONC-2b | PASS / PASS |
| CONC-3 | PASS — B re-read the ENDED episode; restart_candidate opened |
| CONC-5a | PASS — exactly 1 attempt |
| CONC-5b | PASS — denied 'hold'; outstanding attempt swept to a work item |
| Worker tests | 73 pass, 0 fail |
| Worker typecheck | pass (`tsc --noEmit` for `tsconfig.json` and `tsconfig.test.json`) |

## Confirmations

- D-36 and D-40 remain unseeded: no migration inserts into or copies to `iit.gate_idempotent_targets` or
  `iit.gate_integration_actions`.
- No migration statement references `s2test`.
- No migration semantics changed: interiors are byte-identical; only the outer transaction wrapper moved from the file
  to the runner (CLI batch remotely, `psql -1` locally).
- `supabase db push --dry-run` and `supabase db push` were **not run**. `supabase migration list` was not run.

The checksums and confirmations above describe the packaging as merged in PR #11 (`56ecd4a`).

## Revision after application attempt 1 (branch `fix/001-executor-set-role`)

Attempt 1 failed in 001 before anything was recorded; remote `schema_migrations` exists with zero rows
(`phase-c-attempt-1-2026-10-28.md`). Two migrations change, by design (fix in `docs/migrations/001.md` §0c, `006.md` rev 4);
002–005 are byte-identical to PR #11.

| File | SHA-256 at PR #11 (`56ecd4a`) | SHA-256 now |
|---|---|---|
| `20261028000101_foundation.sql` | `f54a96de196b13e170722b23338836022119a815d279838dd7c14fd5ff5f4281` | `1cec9f02f61d6ababfff9574a39dce7ff80ea7defd91da48334e208438b9c9ec` |
| `20261028000102_reports_audit_holds.sql` | `aaf77537…f712d1` | unchanged |
| `20261028000103_deal_workflow.sql` | `4a15fcc4…eaecdace` | unchanged |
| `20261028000104_intake.sql` | `e0614e6c…2445acd9` | unchanged |
| `20261028000105_gate.sql` | `122f339c…6ad12c3a` | unchanged |
| `20261028000106_base44_rpc_role.sql` | `6d8b8cd9d109a65d9182854636afcca67a540f46cc4473338284cfe3707374b1` | `2fd7ad976c1277b3eb047874741052914ec896f1fbaaca7bd746d610f9d29c86` |

Filenames and versions are unchanged: nothing was recorded remotely, so re-versioning is not needed. The harness now
applies migrations as a non-superuser `CREATEROLE` login and runs `deploy_executor_test.sql` on a second, test-free
install; suites pass on local PostgreSQL 16.15 and 17.11.

## Intended future sequence — NOT RUN, each step needs its own authorization

1. Codex review of the fix PR; merge only after acceptance.
2. `supabase db push --dry-run --linked` (lists pending versions only; does not validate SQL).
3. Separately authorized: `supabase db push --linked` (history table already exists, empty; applies 101–106).
4. Post-application: re-run the Phase B catalog script and diff `s2test` against `s2test-before-2026-10-28.txt`;
   verify roles, `iit` inventory and that D-36/D-40 are still empty.
