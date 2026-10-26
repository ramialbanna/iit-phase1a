# iit-phase1a — Interim Inventory Tool, Phase 1a

Texas Auto Value's interim inventory tool: Supabase (Postgres, schema `iit`) + Cloudflare Worker + AppSheet gating.
Built from **Design v0.17** (`docs/design/`), after the S2 spike (`docs/s2/`, closed 26 Oct 2026 by owner decision).

## Scope (owner decision, 26 Oct 2026)
1. Schema `iit` — migrations under `supabase/migrations/`, validated locally before anything touches Supabase.
2. Worker — routes promoted from the S2 spike after review.
3. Intake & deal workflow, AppSheet-side gating.
4. **3.1 bridge — deferred.** No bridge tables, routes or behaviour exist in this repo until the AM5 residual is decided.

## Rules
- Nothing here writes to live `3.1 MY CAR LIST`.
- No production migration without explicit owner confirmation; every migration ships with local validation (`supabase/tests/`).
- Secrets never enter the repo (`.env*` ignored; local secrets file only).
- Conventional commits; small PRs; Codex review before anything is applied.
