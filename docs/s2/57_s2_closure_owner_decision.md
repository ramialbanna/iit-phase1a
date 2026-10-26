# 57 — S2 spike closed by owner decision; Phase 1a build starts with the core, bridge deferred — package v0.79

**Decision (Rami, 26 Oct 2026 13:32–13:33 CT).** "Enough of all these test, let start the project." Asked which scope: **"Build core now, bridge later."** Recorded verbatim.

## 1. What is closed
- The S2 spike stops at docs/56 v0.2. **E-3′ (docs/55) is accepted but not run; the O-E enforcement probe is not drafted.** Row 23 remains as created by docs/54; sheet last row 23 (`E3_preflight_sheet_rows_end_23_…1332CT.png`). No Add was sent after docs/54.
- Everything proven in S2 stands as recorded (docs/41–54): Worker↔Supabase via Hyperdrive; authorize/commit/report lifecycle incl. fencing, caller binding and scoped timeout; real AppSheet reads; RR4 status allowlist; outcome reporting; first Add with a supplied key (Editable ✓ and ✗) on the test app; Worker read-back; Add/Find response shapes; definitive-rejection shape; **duplicate Add on an occupied key accepted and re-stamped** (docs/54).
- Not established (carried as open, not closed): live 3.1 compatibility (docs/48 §3); duplicate-write behaviour with a changed payload (E-3′); destination-side enforcement (O-E); mixed writers (C4); downstream consumers (C6); lost-response recovery (C7). AM5 (docs/56) remains a discussion draft; no mitigation or residual is adopted.

## 2. Build scope and order (Phase 1a)
1. **Supabase schema** from Design v0.17 (tables, RLS, history triggers, gated-action functions) — the S2 `s2test` SQL is the prototype.
2. **Worker** — real routes promoted from the spike (authorize / commit / report / read), real schema, real roles.
3. **Intake & deal workflow** and AppSheet-side gating (bots call the Worker; no 3.1 writes).
4. **3.1 bridge — deferred.** Not built until Rami decides on the AM5 residual (rare late duplicate write re-stamps timestamp columns on a 3.1 row; detectable after the fact, not preventable by local means on current evidence) or O-E enforcement is proven. Until then the 3.1 row is created the way it is today (manually / existing flows); the IIT links to it by read-back only.

## 3. Standing rules carried into the build
Codex review stays in the loop per Rami's workflow; no live 3.1 writes; no production data touched without explicit confirmation; secrets only via the local secrets file; evidence retained. The S2 `s2test` schema is torn down (sql/90) only when Rami says so.
