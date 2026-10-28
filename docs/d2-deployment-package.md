# D-2 deployment package — Base44 → Supabase through the narrow PostgREST RPC path (option c)

Status: **reviewed package, rev 2 (Codex rev-1 P1/P2 applied) — nothing applied, no role created on the live project, no credential minted, no schema exposed, no secret stored.** Owner decision 28 Oct 2026 (Rami): option (c). Base44 confirmed its backend functions can keep a credential server-side, make server-side HTTPS POSTs with `apikey`, `Authorization`, `Accept-Profile`, `Content-Profile`, call a hardcoded allowlist of RPC functions without SQL text or table access, and rotate a secret under the same name (publication activates it). Every step that touches the live project is listed in §7 and requires separate explicit authorization, in order, after Codex review.

## 1. The staff-facing RPC manifest (derived from merged migrations 001–005, `main` at `8758fb4`)
Exactly the functions whose EXECUTE 001–005 grant to `iit_integration`; migration 006 grants the same 27 to the new PostgREST role and nothing else. Every one takes `p_actor_base44_user_id text` as its **last** argument and starts with `require_role` (§2.2); PostgREST calls them by **named** JSON parameters (`p_…`).

| Migration | Function (PostgREST: `POST /rest/v1/rpc/<name>`, `Content-Profile: iit`) | Role checked inside | Returns |
|---|---|---|---|
| 001 | `set_staff_identity(p_base44_user_id, p_display_name, p_email, p_actor_base44_user_id)` | admin | uuid |
| 001 | `set_staff_role(p_user_id, p_role, p_grant, p_actor_base44_user_id)` | admin | void |
| 001 | `deactivate_staff(p_base44_user_id, p_actor_base44_user_id)` | admin | void |
| 002 | `record_decision(p_check_id, p_decision, p_comments, p_actor_base44_user_id)` | auditor | uuid |
| 002 | `request_reaudit(p_deal, p_reason, p_actor_base44_user_id)` | audit_lead | uuid |
| 002 | `validate_report(p_report, p_requirement_key, p_outcome, p_checks, p_reason, p_actor_base44_user_id)` | data_entry (D-13) | bigint |
| 002 | `waive_report(p_deal, p_requirement_key, p_reason, p_actor_base44_user_id)` | audit_lead | uuid |
| 002 | `revoke_waiver(p_waiver, p_reason, p_actor_base44_user_id)` | audit_lead | bigint |
| 002 | `begin_report_upload(p_deal, p_report_type, p_subject_type, p_vehicle, p_subject_org, p_acquisition, p_pulled_at, p_replaces, p_actor_base44_user_id)` | data_entry | uuid + path |
| 002 | `finish_report_upload(p_report, p_bytes, p_sha256, p_actor_base44_user_id)` | data_entry | void |
| 002 | `authorize_report_access(p_report, p_actor_base44_user_id)` | data_entry / auditor / audit_lead | object path (signed URL issued by the app, D-14/P8) |
| 003 | `set_source_channel(p_deal, p_channel_name, p_actor_base44_user_id)` | data_entry | void |
| 003 | `release_deal(p_deal, p_actor_base44_user_id)` | data_entry | int (version) |
| 003 | `correct_field(p_deal, p_field, p_value, p_reason, p_actor_base44_user_id)` | data_entry | uuid (correction) |
| 003 | `amend_field(p_deal, p_field, p_value, p_reason, p_actor_base44_user_id)` | data_entry | int (amendment_no) |
| 003 | `rebind_hold(p_hold, p_reason, p_actor_base44_user_id)` | audit_lead (D-24) | int |
| 003 | `resolve_flag(p_flag, p_status, p_resolution, p_actor_base44_user_id)` | data_entry | void |
| 003 | `resolve_work_item(p_item, p_outcome, p_actor_base44_user_id)` | the item's assigned role | void |
| 003 | `cancel_deal(p_deal, p_reason, p_actor_base44_user_id)` | data_entry | uuid (hold) |
| 004 | `set_seller_party(p_deal, p_role, p_ordinal, p_party, p_actor_base44_user_id)` | data_entry | uuid |
| 004 | `correct_party(p_deal, p_role, p_ordinal, p_party, p_reason, p_actor_base44_user_id)` | data_entry | uuid |
| 004 | `amend_party(p_deal, p_party_id, p_party, p_reason, p_actor_base44_user_id)` | data_entry | int |
| 004 | `create_manual_deal(p_origin, p_vin, p_channel_name, p_actor_base44_user_id)` | data_entry | uuid |
| 004 | `set_deal_fact(p_deal, p_field, p_value, p_actor_base44_user_id)` | data_entry | void |
| 004 | `resolve_restart(p_item, p_decision, p_reason, p_actor_base44_user_id)` | data_entry | uuid |
| 005 | `resolve_unknown_outcome(p_action_id, p_resolution, p_evidence, p_reason, p_actor_base44_user_id)` | data_entry | void |
| 005 | `set_consignment(p_deal, p_consignor_party_id, p_amount, p_notes, p_actor_base44_user_id)` | data_entry | uuid |

**Explicitly NOT in the manifest** (and denied to the role by test): all helpers (`row_actionable`, `open_hold`, `create_audit_attempt`, `build_deal_snapshot`, `actor_push`, `require_role`, `_…`), the Worker functions (`authorize_and_consume`, `report_action_outcome`, `expire_stale_attempts`, `ingest_vauto_observation`), every table and sequence.

## 2. What the initial screens need
**Writes — Data Entry screens:** `create_manual_deal`, `set_deal_fact`, `set_seller_party`, `set_consignment`, `set_source_channel`, `begin/finish_report_upload`, `validate_report`, `resolve_flag`, `release_deal`, `correct_field`, `correct_party`, `amend_field`, `amend_party`, `resolve_work_item`, `resolve_restart`, `resolve_unknown_outcome`, `cancel_deal`, `authorize_report_access`.
**Writes — Risk Audit screens:** `record_decision`, `request_reaudit`, `waive_report`, `revoke_waiver`, `rebind_hold`, `authorize_report_access`.
**Admin:** `set_staff_identity`, `set_staff_role`, `deactivate_staff` (first-run bootstrap: the first admin identity must be created by the owner outside the app — §7 step 6).

**Reads — a gap this package names rather than fills.** With direct `SELECT` denied (§5 below), the screens cannot list deals, flags, work items, requirements or holds. They need **read RPCs** (SECURITY DEFINER, role-checked, returning allowlisted JSON), none of which exist yet. Proposed set for **migration 007** (to be written and reviewed before any screen is built): `get_deal(p_deal, actor)` (deal + version + facts + parties + requirements/satisfaction + open flags + holds), `list_deals(p_filter, actor)` (queue views: new / in review / released / on hold), `list_work_items(p_role, actor)`, `list_audit_queue(actor)` (current attempts pending decision), `get_report(p_report, actor)`, `list_staff(actor)` (admin). Until 007 is merged the manifest is write-only and no screen can be completed.

## 3. The dedicated role (migration 006)
`iit_base44`: `NOLOGIN NOINHERIT`, not superuser, no BYPASSRLS, no CREATEROLE/DB. Grants: `USAGE ON SCHEMA iit` + `EXECUTE` on the 27 functions above. Explicit `REVOKE ALL` on every table and sequence (they were never granted; the statement records the intent). `GRANT iit_base44 TO authenticator` so PostgREST can assume it (created only if `authenticator` exists — it does on Supabase; the local runner creates it to mirror that). Not `postgres`, `service_role`, `anon` or `authenticated`.

## 4. How PostgREST assumes the role from the server-side credential
PostgREST logs in as `authenticator`, verifies the request's JWT with the project's JWT secret, and runs `SET ROLE <claims.role>`; the claims are also exposed to SQL as `request.jwt.claims` (recorded as `origin_jwt_role` on every history row, §5.9.2). The **credential** is therefore a JWT signed with the project's JWT secret whose `role` claim is `iit_base44`:

```json
{ "role": "iit_base44", "iss": "supabase", "iat": <now>, "exp": <now + 180 days>, "jti": "<uuid>" }
```
Request shape from a Base44 backend function (never from the browser):
```
POST https://fqxfrtfiysbuctcccudb.supabase.co/rest/v1/rpc/release_deal
apikey: <project publishable/anon key>            -- gateway routing only; grants nothing (anon has no access to iit)
Authorization: Bearer <the iit_base44 JWT>
Content-Profile: iit
Content-Type: application/json
{"p_deal":"…","p_actor_base44_user_id":"<signed-in Base44 user id, from the server session>"}
```
`p_actor_base44_user_id` must come from Base44's server-side session, never from the request the browser sent (§8 invariant 12d).
**To verify at application (I-D2a):** whether the project uses legacy JWT keys or the newer publishable/secret key scheme for the `apikey` gateway header; a custom-claim JWT is verified against the JWT secret either way, but the header value differs. **I-D2b:** confirm on the live project that `authenticator` is the PostgREST login role and that `SET ROLE iit_base44` succeeds for it (006 grants the membership; Z6 proves the escalation bounds from a real `authenticator` login locally).

## 5. Denials proven (006 tests, local; §7 repeats them live)
| Requirement | Test |
|---|---|
| Approved RPC succeeds; actor and staff-role checks still apply | Z2a (data_entry creates a deal), Z2b (auditor refused 42501), Z2c/Z2d (unknown / empty actor refused 28000), Z2e (history: `exec_role = iit_owner`, `origin_role = iit_base44`, `actor_kind = user`) |
| Unapproved function denied | Z3a–h (open_hold, the four Worker functions, snapshot helper, actor_push, require_role → 42501) |
| Direct table reads and writes denied | Z4 (SELECT on every `iit` table, INSERT, UPDATE, DELETE, sequence, DDL → 42501); Z1e/Z1f (no privilege at all) |
| `anon` / `authenticated` remain denied | Z5 (no EXECUTE on any manifest function, no schema usage); `tav_worker` has none of the staff functions |
| Credential cannot invoke Worker-only functions | Z3b–e, Z5c |
| Role cannot escalate from PostgREST's real session | Z6a–d (login as `authenticator`, `SET ROLE iit_base44`, then owner/worker/integration/postgres all refused); Z6e approved RPC works there; Z6f table read refused there |
| `s2test` untouched | 006 contains no reference to `s2test` (grep in the review package); nothing in 001–006 touches any schema but `iit` |
| Manifest is EXACTLY the 27 named signatures (not a count) | Z1d (count) + Z1d2 (set equality on `regprocedure` text) |
| Per-token revocation: revoked jti refused, token without jti refused, replacement token works, list not deletable or writable by the credential role (nor deletable by the owner), non-PostgREST path unchanged | Z8a–g |

## 6. Credential procedures (owner-executed, each step logged in the decisions log)
**Revocation mechanism (rev 2, Codex P1):** a JWT cannot be withdrawn before `exp`, and revoking the role's membership and re-granting it would re-enable a compromised token. Migration 006 therefore adds `iit.revoked_credentials(jti)` and makes `require_role()` refuse, on every staff function, any `iit_base44` token whose `jti` is listed — and any `iit_base44` token **without** a `jti`. Revocation is immediate, permanent (the table has no DELETE, even for the owner), independent of the role, and cannot be undone or performed through any RPC (the credential role has no privilege on the table). Z8 proves all of this from a real `authenticator` login.
- **Creation:** mint the JWT (§4) with the project's JWT secret on the owner's machine (never in chat, never in the repo); claims `role: iit_base44`, a fresh `jti` (uuid), `exp` 180 days; record `jti` and `exp` in the decisions log. Store it in Base44 as a backend secret under one fixed name (e.g. `IIT_RPC_TOKEN`); publication activates it.
- **Storage:** Base44 backend secret only; never a client-side variable, never a repo file, never a chat message. The `apikey` publishable key is not a secret.
- **Rotation (routine, before `exp`):** mint a new JWT (new `jti`), update the Base44 secret under the same name, publish, then `INSERT INTO iit.revoked_credentials(jti, reason) VALUES ('<old jti>', 'rotated <date>')` so the old token is dead before its `exp`.
- **Revocation (token compromised):** `INSERT INTO iit.revoked_credentials(jti, reason) VALUES ('<jti>', '<why>')` as the owner (SQL editor) — every call with that token fails `CREDENTIAL_REVOKED` from that instant; then mint a new token (new `jti`), store, publish. The role, its grants and `authenticator` membership are untouched, so nothing can re-enable the old token. If the `jti` is unknown (log lost), revoke every token issued so far by listing all recorded jtis, and additionally `REVOKE iit_base44 FROM authenticator` until the new token is in place. If the project **JWT secret** itself is compromised, rotate it in Supabase (invalidates every key project-wide — coordinate) and mint anew.
- **Emergency disable (stop every Base44 write now):** `REVOKE USAGE ON SCHEMA iit FROM iit_base44;` — reversible with `GRANT`; this is a pause, not a revocation (a compromised token would work again after `GRANT`, so revoke its `jti` as well).
- **Never:** the `service_role` key as the Base44 credential (broadly privileged, bypasses RLS, defeats the narrow door); the Management API path for app writes; a token without a `jti`.

## 7. Application sequence — each step needs separate explicit authorization, after Codex review of this package
1. Apply migrations 001–006 to project `fqxfrtfiysbuctcccudb` (as the owner, via the SQL editor or CLI), in order, in one session; run the read-only verification queries from §5 on the live project (schema, roles, function count 27, no table privileges for `iit_base44`, `authenticator` membership).
2. Expose `iit` to PostgREST: Supabase Dashboard → Project Settings → API → **Exposed schemas**: add `iit` (keeps `public`); **Extra search path** unchanged. Verify `GET /rest/v1/` with the `iit_base44` token and `Accept-Profile: iit` lists only the 27 RPC functions and no tables.
3. Mint the credential (§6) and run the live denial checks from §5 with it: approved RPC with a real staff identity, unapproved RPC, `GET /rest/v1/deals` (must be 404/401), the same with the anon key only.
4. Store the credential in Base44 (§6), publish.
5. Populate reference data that 001–005 leave to the owner (D-1 roles are seeded; D-4 vAuto channels; D-12 report rules) — data rows, reviewed.
6. Bootstrap the first admin: insert the owner's `staff_identities` row + `admin` role as the owner (one SQL statement, logged), so `set_staff_identity` can be used for everyone else.
7. Only then: connect Base44 screens (after migration 007 read RPCs exist).
Not in this sequence: the Worker (D-46 login role, D-40, I-V1–3), the bridge, `s2test` teardown.
