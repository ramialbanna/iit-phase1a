# Migration 007 — stale-write gap report (Base44 mutation adapters → IIT write functions)

Status: **rev 2, 29 Oct 2026, for owner and Codex review** (rev 2: token coverage reference, Codex PR #15 P2). **Implemented by Migration 009** (`docs/migrations/009.md`): all G, P and E rows now require `p_expected_state`; admin writes and `create_manual_deal` are classified state-independent there; U rows still have no write path. Owner decision F: 007 does not change any of the 27 write
signatures; **before Base44 is connected to production, every state-dependent mutation must require an authoritative
expected-state token, with omission refused, or have equivalent database-enforced protection.** This is a mandatory
pre-connection gate, not optional future work. Nothing in this report is implemented yet.

## 1. What "protected" means here
A write is protected when the database itself refuses it if the state the user saw has changed, and an omitted check cannot
bypass that refusal. Today the 27 functions take no expected-state argument. Some refuse on their target's own state under a
row lock (shown below); that protects the target record, **not** the rest of the screen the user acted on. 007 supplies the
token every write would check: `get_deal.state_token` (`iit._deal_state_token`) and `get_unknown_outcome.state_token`
(`iit._action_state_token`), both recomputable inside a write under the Deal lock. Exactly what each token covers — and what it
deliberately does not — is the inventory in `007-contract-worksheet.md` §2.5; a write's check can rely on nothing outside it.

Legend: **G** = gap (no stale-state protection) · **P** = partial (target-state check only) · **E** = equivalent protection for
the decision being made · **U** = no IIT write path (mock-only or deferred).

## 2. Mutation-by-mutation

| # | Mock adapter (sends `expectedRevision`) | IIT write function | Existing database protection | Class | Pre-connection requirement |
|---|---|---|---|---|---|
| 1 | `submitMissingFacts {workItemId, facts (free text)}` | `set_deal_fact(p_deal, p_field, p_value)` per fact — the mock's free-text `facts` has no IIT form | Deal row `FOR UPDATE`; refuses cancelled and released deals (`RELEASED_USE_CORRECTIONS`) | **G** | mandatory expected deal token; Base44 must send structured field/value pairs |
| 2 | `submitPartyMapping {workItemId, matchType, matchedParty}` | `set_seller_party(p_deal, p_role, p_ordinal, p_party)` (draft) / `correct_party` (released); no "unmapped party" work item exists | Deal lock; draft/released split | **G** | mandatory expected deal token; the mapping work-item concept is deferred |
| 3 | `resolveSourceConflict {workItemId, conflictField, chosenValue}` | none — IIT has no source-conflict object | — | **U** | define canonically first (likely `set_deal_fact`/`correct_field` + `resolve_flag`), then token |
| 4 | `submitFieldCorrection {iitId, field, newValue}` | `correct_field(p_deal, p_field, p_value, p_reason)` | Deal lock; `NO_CHANGE`; opens/extends the material draft and its hold | **G** | mandatory expected deal token (a correction made on stale values silently overwrites another user's correction) |
| 5 | `submitFieldAmendment {iitId, field, newValue}` | `amend_field(p_deal, p_field, p_value, p_reason)` | Deal lock; `NO_CHANGE`; `MATERIAL_FIELD`; `NOT_RELEASED` | **G** | mandatory expected deal token |
| 6 | `resolveFlag {workItemId, resolutionNote}` | `resolve_flag(p_flag, p_status, p_resolution)` (keyed by flag, not work item) | flag row lock; `FLAG_NOT_OPEN` | **P** | flag double-resolution is prevented; token required because the decision depends on the displayed deal facts |
| 7 | `resolveWorkItem {workItemId, note}` | `resolve_work_item(p_item, p_outcome)` | Deal then item lock; authorization against the item's current assignment; `WORK_ITEM_NOT_OPEN`; exactly one open→closed transition | **E** (item) / **P** (deal context) | owner to decide whether item-state protection suffices; recommended: expected deal token for items with a deal |
| 8 | `submitCancellationInfo {canceledBy, canceledDate, cancellationCode}` | `cancel_deal(p_deal, p_reason)` — the three mock fields are not canonical | Deal lock; `DEAL_CANCELLED` (no double cancel) | **P** | mandatory expected deal token (cancelling a deal whose state changed since display) |
| 9 | `submitRescheduleInfo {newDate, carrier}` | none — transport/ETA are not in IIT; reschedules are 3.1 source records | — | **U** | deferred |
| 10 | `submitRestartDecision {workItemId, decision}` | `resolve_restart(p_item, p_decision, p_reason)` (decisions `restart_new_episode` / `no_restart`, not the mock's) | item lock; `WORK_ITEM_NOT_OPEN`; kind check | **E** (item) / **P** | as #7 |
| 11 | `submitConsignment {consignor, fee, feeSource, saleStatus, titleStatus, collectionStatus}` | `set_consignment(p_deal, p_consignor_party_id, p_amount, p_notes)` — only consignor, amount, notes are canonical | Deal lock; `NOT_CONSIGNMENT`; `PARTY_NOT_ON_DEAL`; `RELEASED_CONSIGNMENT_UNDECIDED` | **G** | mandatory expected deal token (the derived row's `state_token` is the deal token) |
| 12 | `resolveUnknownOutcome {outcomeId, resolution, evidence[]}` | `resolve_unknown_outcome(p_action_id, p_resolution, p_evidence, p_reason)` (resolutions `completed` / `failed_definitive`, not the mock's three) | action lock; `GATE_NOT_UNKNOWN` (only an unresolved action can be resolved; never twice) | **E** (action state) | owner to decide; recommended: expected action token so evidence/timeline seen by the operator is current |
| 13 | `submitAuditDecision {iitId, decision}` | `record_decision(p_check_id, p_decision, p_comments)` (keyed by attempt; decisions `approved` / `changes_required` / `escalated` / `cancelled` / `pending`; no `refuse`) | Deal lock; attempt reloaded; refuses superseded attempts, attempts not for the latest released version, open material drafts | **E** (version-bound) / **P** | the attempt binds the decision to a frozen version; recommended: expected deal token too, so holds/requirements shown are current |
| 14 | `assignAuditItem {iitId, auditor}` | none — IIT has no audit assignment | — | **U** | requires a schema decision (owner: not in 007) |
| 15 | `addReviewNote {iitId, note}` | none distinct — a `pending` decision with comments (`record_decision(check, 'pending', note)`) is the nearest canonical form, but its semantics are an owner decision | — | **U** | owner decision on review notes |

Writes in the 27-function manifest with no mock adapter yet, all state-dependent and all **G** today: `release_deal`
(freezes whatever the draft holds — the most important one), `set_source_channel`, `create_manual_deal` (creation, no prior
state), `begin_report_upload`/`finish_report_upload`, `validate_report`, `waive_report`, `revoke_waiver`, `request_reaudit`,
`rebind_hold`, `correct_party`, `amend_party`, and the admin writes `set_staff_identity`, `set_staff_role`, `deactivate_staff`.

## 3. Remediation shape (for a later migration; not decided here)
1. Each state-dependent write gains a **required** `p_expected_state text` (no SQL default; NULL refused with a fixed error,
   e.g. `STATE_TOKEN_REQUIRED`), and compares it, **after** taking the Deal lock, with `iit._deal_state_token(deal)` (or the
   action token); a mismatch raises `STALE_STATE` with the current token so the UI can reload.
2. Because this changes signatures, the old signatures are dropped in the same migration (no bypassable overload), the
   iit_base44 manifest test and D-2 §1 are updated, and the Base44 adapters must send the token from the last read.
3. Writes classed **E** may instead keep their target-state checks if the owner accepts them as equivalent protection.
4. The token covers exactly what the read showed; a write must not be accepted on a token computed by a different projection.

## 4. Gate
Base44 production connection (D-2 §7 step 7) is blocked until every **G** and **P** row above is either token-protected or
accepted by the owner as equivalent, every **U** row has a canonical write path or is removed from the screens, and a Codex
review has accepted the result.
