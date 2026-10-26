# 56 — AM5 (draft v0.2): duplicate mutation, stale in-flight senders and uncertain retries — design amendment to v0.17 §5.8 / docs/26, for Codex review (v0.77 safety-claim corrections applied) — package v0.78

**Status.** Draft for review. Nothing here is adopted into Design v0.17 or docs/26; nothing is implemented. It responds to docs/54 (an Add on an occupied key was **accepted** and **re-stamped the existing row**) and to Codex's correction that "mandatory lookup + local fencing" is **not** a complete fix. It names the races that remain under every option and the residual an owner would have to accept explicitly. E-3′ (docs/55) is pending; where its outcome changes a conclusion that is marked.

## 1. What changed in the premises
| v0.17 §5.8 premise | Status after docs/54 |
|---|---|
| "AppSheet rejects any second Add as a duplicate key" | **False on the test app** (1 sample): HTTP 200, same `_RowNumber` echoed, no second row, initial-value columns re-stamped. |
| "the existence check is simply a read by that iD" | Still true as a *read*; but a read proves nothing about what a concurrent or stale sender does **after** the read. |
| IN-2 "identical payload ⇒ a late send is harmless at the destination" | **Weakened:** harmless to business fields *as read back* (not proven untouched); **not** harmless to initial-value columns (`TIMENOW()`, `TODAY()`-style, live `NOW()`); unknown for supplied fields when payloads differ (E-3′). |
| Duplicate handling branch `duplicate_key → read row → ours/unrelated` | No observed trigger. Cannot be "replaced" by `accepted_existing` alone — the response does not distinguish a first Add from a repeat (docs/54 A2 echoed_ok). Ownership can only be decided by **reading and comparing the row** (V-1). C2 is **not** passed. |

## 2. The races (what can still go wrong, independent of any lookup)
| # | Race | Why lookup/fence do not close it | Consequence at the destination (observed/expected) |
|---|---|---|---|
| X-1 | **Two senders both observe absence** then both send (lookup and Add are separate HTTP calls) | Lookup is not a lock; the destination does not know about our fence | Second Add lands on the row the first created: re-stamp (observed); overwrite of supplied fields if payloads differ (E-3′) — under IN-2 payloads are identical, so exposure = re-stamp |
| X-2 | **Stale sender**: a sender that lost its lease/fence (slow, GC pause, network stall) sends **after** another attempt completed or **after Data Entry took over and edited the row in AppSheet** | The fence is enforced only in our Postgres on *result* calls; AppSheet accepts the stale Add | Re-stamp at minimum; **if E-3′ shows field overwrite, the stale sender's stored payload overwrites Data Entry's manual edits** (same key, older values) |
| X-3 | **Uncertain retry vs. the original still committing**: existence check says absent while the first request is still in flight at AppSheet; resend lands after it | Absence at time *t* is not absence at *t+δ* | = X-1 |
| X-4 | **Native collision**: a non-bridge row whose key equals a supplied iD | Nothing at AppSheet protects it; a supplied-iD Add **writes into that row** | Corruption of someone else's row (not observed; inferred from docs/54 + E-3′) |
| X-5 | **Lookup lies**: Find returns stale/partial data (eventual consistency) | Our correctness depends on a read we cannot verify | Wrong recovery decision (`recovered` on a row that is not ours, or resend on a false absence → X-1) |

## 3. Options (each with what it closes and what it leaves)

**O-A. Single intended sender + lease/timeout discipline** (control-plane, no AppSheet change) — *narrows, does not close*
- **Mechanism (supported on the chosen Hyperdrive path — session-scoped `pg_advisory_lock` is NOT, because connections are pooled and a lock taken on one pooled session is not held by the next):** a `bridge_send_slots(table_key PK, holder_attempt_id, fence, lease_until)` row per destination table, acquired by a compare-and-set `UPDATE … WHERE lease_until < now() OR holder IS NULL` inside the claim transaction, released on result. This guarantees at most one **intended** sender holds the slot at any instant **in our database**. It says nothing about requests already dispatched.
- **Lease/timeout discipline:** the sender gives its AppSheet call a hard client timeout `T_req`, re-checks fence and slot immediately before dispatch, and the slot may be re-acquired only after `lease_until + T_req + skew`. This **reduces** the overlap between two intended senders to (i) the interval between the pre-dispatch check and the request leaving the host, and (ii) any period in which AppSheet is still processing a request whose response we have given up on.
- **What it does NOT establish:** a finite safe window. We have **no demonstrated bound** on how long AppSheet may take to commit a dispatched request after our client timeout, nor on how long a stalled sender process may take to resume and dispatch a request it had already prepared. A lease longer than the client timeout bounds *our* behaviour, not AppSheet's commit time. Therefore O-A does not close X-1, X-2 or X-3; it makes them rarer by an amount we cannot quantify from current evidence. Measuring AppSheet's commit latency distribution (test-app probe: many Adds with instrumented timing) would be required before any numeric claim.

**O-B. Make duplicate/stale sends *detectable*** (data-plane discipline) — *detects, does not neutralize*
- Keep IN-2 (identical bytes). **Post-send audit:** after `confirmed`, the read-back stores the row's initial-value column values; a later read-back showing those values **advanced** without a bridge send opens a `late_send_suspected` work item. This converts an otherwise invisible duplicate/stale send into a recorded event.
- **Correction (Codex):** omitting initial-value columns from the payload does **not** prevent re-stamps — docs/54's payload omitted them and they were re-stamped anyway. Detection is all O-B provides. Whether the re-stamped columns (`TimeStamp`, `Office Time`, `Meeting Time`, `Time Back`, `Date`, `Date Created`, …) may be treated as non-authoritative **depends on their downstream use** (Zaps, the 4.1 script, reports, dispatch scheduling) — **not checked**; declaring them non-authoritative requires that inventory (U-4/E-5) and a design approval. Until then every re-stamp is a data change with unknown consequence.
- Leaves: all of X-1…X-5 as risks; field overwrite (E-3′) entirely.

**O-C. Data Entry edit discipline** (process) — *reduces exposure for the normal case only*
- Takeover of an `in_flight` delivery allowed only after `lease_until + T_req + skew`; the Base44 action tells Data Entry not to edit the AppSheet row until the delivery is `confirmed`/`failed_manual` **and** that time has passed.
- **What it does NOT establish:** that no stale request can arrive after that time (same unbounded tail as O-A). It lowers the chance that a manual edit is overwritten by a stale send; it does not make it impossible. If E-3′ shows field overwrite, the consequence of the residual is loss of a manual edit.

**O-D. Namespace as a correctness requirement** (already proposed, now load-bearing)
- Supplied iDs must be un-producible by `UNIQUEID()` **and** by every other writer (Zapier, scripts, manual). Enforce on read-back: any row whose key matches the supplied grammar but has no delivery → `foreign_row_in_namespace` work item. C4 (mixed writers) becomes the evidence that nothing else produces keys in the namespace.
- Closes: X-4 for native keys (8-hex vs `S2A-…`), subject to C4. Leaves: a human typing an `S2A-…` key by hand (process risk, recorded).

**O-E. Destination-side enforcement** (AppSheet-side change; **would change live 3.1**, so outside S2's gate) — *two separate questions*
- A Valid_If on `ID` (or a `Bridge Key` column with a uniqueness Valid_If, v0.17 fallback 2). **Question 1 — enforcement:** are Valid_If rules honoured on **API** Adds at all (B-VIN0, open)? A bounded test-app probe (to be drafted separately **after** E-3′) can answer this for one request. **Question 2 — concurrency:** even if one request is rejected, that does **not** show atomic uniqueness under two concurrent requests (AppSheet evaluates Valid_If against its view of the data; two in-flight Adds may both pass). Question 2 cannot be answered by a single-request probe and is kept separate. No closure of X-1/X-2/X-3 is claimed for O-E.

**O-F. Different write primitive** — if AppSheet's API offers an `Add` mode that fails on existing keys, or if `Edit` vs `Add` semantics differ in a way we can exploit (unknown; not in the two docs we have). Research item, not a design option yet.

## 4. Direction for discussion (not adopted, not a safety claim)
**O-A + O-B + O-C + O-D** reduce and detect; **none closes a race**, and together they leave an unquantified tail (§5). **O-E** is the only option that could enforce at the destination, and it has two open questions (enforcement, then concurrency). Order: E-3′ (docs/55) first — it decides whether the tail's consequence is a re-stamp or an overwrite of fields; then a separately drafted O-E enforcement probe; then, if enforcement holds, a design for the concurrency question; then AM5 v0.3 with whatever residual remains stated numerically only if measured.

## 5. Residual that would need explicit owner acceptance — **all unaccepted proposals**
| # | Residual | Status of our knowledge | Who would accept |
|---|---|---|---|
| RES-1 | A request AppSheet commits **after** our client timeout (or a stalled sender's late dispatch) lands after another attempt or after `confirmed` → at minimum re-stamps initial-value columns on a confirmed row; detected by O-B's audit, not prevented | **Frequency unknown** — no bound on destination processing time or sender stalls has been demonstrated; no "low frequency" claim is made | Rami |
| RES-2 | If E-3′ shows **field overwrite**: the same tail overwrites **supplied** fields with the stored payload — a no-op for business values unless Data Entry edited them meanwhile (O-C narrows that window; it does not close it) | Depends on E-3′ | Rami |
| RES-3 | A human writing a key in the `S2A-…` grammar by hand | Process rule + `foreign_row_in_namespace` detection | Rami |
| RES-4 | Find consistency (X-5): recovery trusts a read we cannot verify; a false `recovered` links a wrong row only if the stored-payload comparison (V-1: VIN + marker + intake fields) also passes | Bounded by V-1's strictness, not eliminated | Codex / Rami |
| RES-5 | Live 3.1 may differ from the test app (types, Valid_If, bots, downstream consumers) — all evidence is test-app | Re-verify on a faithful copy before any live write (separately gated) | — |
| RES-6 | Downstream use of initial-value columns is **unknown**; a re-stamp may have consequences we have not inventoried | Requires the U-4/E-5 consumer inventory | Rami |

## 6. What this amendment does **not** do
It does not replace the `duplicate_key` branch with a passing C2; it does not adopt a retry policy (D-2 stands); it does not declare mandatory lookup + fencing sufficient; **it does not claim any finite safe window, any race closure, or any frequency for the residual tail (v0.2)**; it does not change Design v0.17 or docs/26 — it proposes the text for AM5 v0.2 once E-3′ (and, if agreed, an O-E probe) have reported.

## 7. Request
**v0.2 closure of Codex's v0.77 corrections:** O-A/O-C no longer claim a finite window, X-3 closure or low frequency; O-B is detection only and the non-authoritative label is withdrawn pending the downstream inventory; advisory locks replaced by a CAS slot row with no claim over dispatched requests; O-E split into enforcement vs concurrency with no closure claimed; residuals kept as unaccepted proposals (RES-6 added).

Codex: review the race table (§2) for omissions, the revised options (§3), and the residual table (§5). The O-E enforcement probe will be drafted separately after E-3′. No new Add, live capture, live writes or bridge implementation are authorized.
