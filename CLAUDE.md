# iit-phase1a — project instructions

- Source of truth: Design v0.17 (`docs/design/IIT_Phase1a_Schema_Design_v0.17.md`). Where the design says "as in v0.1/v0.3", the DDL comes from the archived versions in `docs/design/archive/`. Gaps are listed as decisions for the owner, never filled silently.
- Schema `iit` on the existing Supabase project; the spike schema `s2test` is untouched until the owner says tear down.
- §5.8 bridge objects are **excluded**. Any function the design couples to the bridge (e.g. `release_deal` queuing `add_31_row`) states the dependency in a comment and does nothing bridge-related.
- Every migration: `supabase/migrations/<14-digit version>_<name>.sql` (Supabase CLI versioning; no embedded `BEGIN`/`COMMIT` — the CLI runner supplies the transaction) + `supabase/tests/NNN_<name>_test.sql` (pgTAP-free plain SQL asserts that run on local Postgres 16; `run_local.sh` pairs them by `<name>` and applies each migration with `psql -1` as `deployer`, a non-superuser CREATEROLE login shaped like Supabase's `postgres`; any statement on an `iit` object runs after `SET ROLE iit_owner`, since the executor holds `iit_owner` with SET only) + a `docs/migrations/NNN.md` note listing design mapping, exclusions and open decisions.
- Functions: SECURITY DEFINER, `SET search_path = ''`, fully-qualified names, actor push/restore per §5.9.1, EXECUTE only to the roles named in the design.
- No live 3.1 writes, no production data, no deployment without explicit owner confirmation.
- Commits: conventional, ≤72-char subject, body says why.
