# Worker v0.1 — §6 gate routes, vAuto intake poll, gate attempt expiry

Status: **local review package, rev 3 — Codex ACCEPT 2026-10-28** (v0.1 P1/P1/P2 and rev-2 P2 applied). Deployment gated by D-40, D-46, live vAuto verification I-V1–I-V3 and explicit authorization. `cd worker && npm test` → 73 tests pass; `npm run typecheck` clean (TypeScript 6.0.3 strict, `erasableSyntaxOnly`). No `wrangler.toml` is committed (template only); nothing is deployed; no live integration was contacted. For Codex review.

Base: the S2 spike Worker v0.79 (Codex-accepted). Carried over **verbatim** except headers/env names: `db_adapter.ts` (pg 8.23.1, strict URL, Hyperdrive-internal vs verify-full, no pipelining, public close only), `deadline.ts`, `read31.ts` (the AppSheet `Find`), and the adapter / read-fixture tests. Dropped: everything S2-specific (identity probe, prepare/commit fault injection, reconcile, `s2test` functions). The spike's `package-lock.json` is reused unchanged (same pinned dependency; no new dependency).

## 0. Rev 2 — Codex rev-1 findings
| # | Finding | Change | Control |
|---|---|---|---|
| P1 | vAuto credentials (client secret, bearer token) could be sent to any allowlisted host | `outboundGate` for `vauto` requests requires the exact **https origin** of `VAUTO_BASE_URL` or `VAUTO_TOKEN_URL` (scheme, host, port) **and** an allowlisted host (`ORIGIN_NOT_VAUTO` otherwise); a `next` cursor on a foreign origin is refused (`next_foreign_origin`), items already fetched are kept; non-https vAuto URLs refused at config load | contract (appsheet host, other port, http, look-alike host, unconfigured vAuto URL all refused), vauto (foreign `next` → no third request; token to a non-vAuto origin → no request) |
| P1 | Duplicate secret values made identity ambiguous (last match won) | `identify` returns a name only when **exactly one** secret matches; `validateConfig` refuses duplicate values at load (every route → `500 CONFIG_INVALID`, names only in the message) | contract: duplicate → 500, value absent from the message, `identify` null |
| P2 (rev 2) | `startsWith("https://")` was a prefix check, not URL validation | vAuto URLs must parse (`new URL`) as `https:` with a host and without userinfo or fragment; otherwise `CONFIG_INVALID` | contract: `https://`, userinfo, fragment, `ftp:`, non-URL, schemeless all refused; a non-default port accepted (WHATWG-normalized forms such as `https:///x` are tolerated as valid hosts) |
| P2 | The poll budget bounded only the start of each item, so a slow database could extend the run | Absolute deadline: the listing gets `budget − reserve`; every ingest call is bounded by `min(dbCallTimeoutMs, time left)`; nothing starts after the deadline; a timeout at the deadline marks `budget_exhausted` and stops | poll: six 80-ms ingests under a 400-ms budget finish within budget + close bound with `budget_exhausted`; no budget left → nothing listed |

## 1. What the Worker does (and the database decides)
| Concern | Worker | Database (001–005) |
|---|---|---|
| **Credential isolation** | Each integration (AppSheet app, each Zap) has its own secret `IIT_CRED_<NAME>`; the header `x-iit-credential` is matched constant-time against every secret and the matching NAME is the caller. The body can never name the integration (tests: contract, authorize_route "body ignored", report_route). Secrets are never logged; `no_writes.test` greps every `log({…})` for secret-bearing identifiers. Flag `IIT_ROUTES_ENABLED` off → every route 404 and nothing runs. | `authorize_and_consume` binds the action to that name and refuses others (005 P1/P2); `gate_integration_actions` (D-40, empty) decides whether the name may perform the action at all |
| **3.1 status read** | `read31.ts`: one `Find` on the configured app, bounded by `IIT_HTTP_READ_TIMEOUT_MS`; exact-identity and single-row validation; any failure → `status=NULL`. The read's completion time is sent with the status. The app must be the configured `IIT_APPSHEET_APP_ID` and the host allowlisted, else no request is made (authorize_route end-to-end test). | denies NULL/stale (>60 s, D-35)/unknown/inactive statuses (D-34); records the caller's own `row_status` as evidence only |
| **Gate calls** | `POST /gate/authorize` → one `SELECT iit.authorize_and_consume(...)`; the SQL jsonb is passed through; any DB failure (connect, error, timeout, row shape) → `502 allowed=false`. `POST /gate/report` → `iit.report_action_outcome(attempt, outcome, evidence, <verified integration>, run_ref)`; `recorded=false` → 403; server validation refusals (`GATE_OUTCOME`, `ATTEMPT_UNKNOWN`, `STORAGE_POLICY`) → 400; infrastructure → 502 `recorded=false`. | the whole §6.2 state table, binding, replay rule, evidence allowlist |
| **Outcome reporting / lost responses (RR2)** | A DB timeout *after* the statement was sent may hide a committed grant. The route answers 502 (the bot denies and does not act); the grant stays outstanding; a retry gets `in_progress`; `expire_stale_attempts` turns it into `outcome_unknown` + work item after 600 s (D-39). Documented in `db.ts`; no reconciliation path is attempted (the S2 commit-indeterminate machinery is deliberately not carried over). | as designed |
| **Polling / idempotency** | `scheduled()` every 5 min (template): `expire_stale_attempts(now())` first, then the vAuto poll: `GET /appraisals` filtered `ge(lastModified, now − lookback)` (default 180 min), paginated; every item → `sanitizeAppraisal` → `ingest_vauto_observation(id, entityLogicalId, body, now)`. Re-reading the same window every run is safe: the database stores an observation only when its content changed and every intake decision is keyed on the appraisal; the window overlaps by design. No checkpoint is persisted (D-41). Per-item failures are counted, never fatal; a failing later page still ingests the items that arrived (poll tests). | dedupe (001), §5.3 rules (004), one restart task per appraisal (004) |
| **Sanitizer (§7 allowlist)** | `sanitize.ts` copies only named fields; `lien.accountNumber`, `lien.address`, `customer.address`, remarks, condition flags and personnel e-mails are never read; a constant mirror of `json_schemas.vauto_observation` is asserted on every body before it leaves the Worker (`assertAllowlisted`). | enforces the same allowlist again, fail closed |
| **Timeouts** | per read, per DB call, per vAuto request, per poll run; validated at load (`validateConfig`); `race()` re-checks the clock and disposes late sessions. | server-side `statement_timeout` is not set by the Worker (D-47) |
| **Read-only** | `no_writes.test`: the only AppSheet action string in `src/` is `"Find"`; the only vAuto POST is the token request. The bridge does not exist here. | — |

## 2. Database access model
The Worker connects as a **login role that is a member of `tav_worker`** (through Hyperdrive, or `IIT_DB_URL` verify-full) and calls only the functions 004/005 granted to `tav_worker`: `ingest_vauto_observation`, `authorize_and_consume`, `report_action_outcome`, `expire_stale_attempts`. It has no table privileges (005 Y7). Which login role that is, and whether `SET ROLE tav_worker` is required on the connection path, is P6/D-46 — identified at application time, like D-2 for Base44.

## 3. Unverified against the live vAuto API (isolated, one function each)
| # | Assumption | Where |
|---|---|---|
| I-V1 | RQL date predicate `ge(lastModified,<iso>)` (the spec shows only `eq(vehicle.make,Toyota)`) | `vauto.ts rqlSince` |
| I-V2 | OAuth2 client-credentials: form POST to `VAUTO_TOKEN_URL`, Basic auth, scope `va.appraisal.read`, `access_token` in the body (the token endpoint is not in the spec) | `vauto.ts getToken` |
| I-V3 | `next` is an absolute URL, else a `{start},{count}` limit token | `vauto.ts nextUrl` |

## 4. Decisions required
| # | Decision | Meanwhile |
|---|---|---|
| D-41 | **Poll checkpoint** (§5.10 discovery/windows/checkpoints, "unproven strategy"): persist a checkpoint (needs a `tav_worker` function in a later migration) or keep the overlapping window | overlapping window, no checkpoint |
| D-42 | **Personnel mapping:** the API has `appraiser` and `salesPerson`, no closer. Mapped `salesPerson.userName → buyer`; `closer` is never filled by intake (Data Entry sets `closer_id`) | as mapped |
| D-43 | **Customer phone:** mobile, else home, else work | as mapped |
| D-44 | **Raw notes (R1 pending):** `remarks.vehicleConditionNotes` is NOT stored; `notes_sanitized` is never produced until the parser/retention decision | dropped |
| D-45 | **Condition:** the API has boolean flags, the allowlist has `condition.summary`; not mapped | dropped |
| D-46 | **Worker DB login role** (P6) | unknown; grants are on `tav_worker` |
| D-47 | **Server-side statement/lock timeouts** for Worker calls (the S2 `SET LOCAL` pattern) — add per-call `SET LOCAL statement_timeout` inside a transaction, or rely on client-side deadlines + `idle_in_transaction_session_timeout` on the role | client-side deadlines only |
| D-40 / D-36 | unchanged (005): empty until the S2 inventory / idempotency proof | every authorization denied |

## 5. Not here
Credential rotation and the Worker's own deployment configuration; the `Audit Gate` display push (CLEAR/BLOCK rows, 30-minute expiry — §6.5); bridge; reschedule linking (D-8); lienholder sync; Base44 screens.

## 6. How to run
`cd worker && npm ci && npm test && npm run typecheck`. No network, no database: every test uses scripted doubles; database behaviour is proven by `supabase/tests`.
