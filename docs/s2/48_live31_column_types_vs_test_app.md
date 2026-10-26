# 48 — Live 3.1 column types vs the TEST app (read-only capture, 26 Oct 10:41 CT) — package v0.68

**Status.** Read-only capture of the live `TAV_DCLv3.1` editor, Data → `01_MY CAR LIST` (102 columns, 5 screenshots: `evidence/project/GE_captures/LIVE31_schema_types_cols*_20261026_1041CT.png`). No live edit; SAVE grey throughout. Purpose: answer docs/47 §5 (which correction is faithful for run 2) and record the type gap between live and the header-built test app for Part C. Statements below are from the screenshots; nothing is inferred about runtime acceptance in live.

## 1. Payload columns — live type vs test type vs planned value
| Payload column | Live 3.1 type (observed) | Test app type (observed, `ADD_preflight_data_cols*`) | Planned value | Run-2 position |
|---|---|---|---|---|
| `ID` | Text, **Key**, Editable ✗, Require ✓, Initial `UNIQUEID()` | Text, Key, Editable ✓ (forced), Require ✓, Initial `UNIQUEID()` | `S2A-20261026-0001` | unchanged (known fidelity limit: Editable) |
| `Deal Status` | **Enum**, Initial `"In-Progress"` | Text | `In-Progress` | unchanged; value equals live's own initial |
| `Title` | **Enum** | Text | `Floored` | unchanged in test; **live Enum membership of `Floored` not verified** |
| `Title State` | **Ref** (→ a States table) | Text | `TX` | unchanged in test; **in live this must be a key of the referenced table — not verified** |
| `Year` | Number | Number (P1 done) | `2019` | ✓ |
| `Make` / `Model` / `Trim/Series` | Text | Text | — | ✓ |
| **`Color`** | **Text** | **Color** (auto-typed; rejected `Gray`) | `Gray` | **P5a: test `Color` → Text** (fidelity correction toward live) |
| `Trans A/M` | **Enum** | Text | `Automatic` | unchanged in test; live Enum membership not verified |
| `VIN` | Text, Label | Text, Label | `TSTADD0001X000001` | ✓ |
| `Miles` | **Number** | Text | `41200` | unchanged for run 2 (accepts); recorded gap |
| `Buyer` / `Closer` | **Ref** (→ `BuyersClosersML`) | Text | `Synthetic Buyer` / `Synthetic Closer` | unchanged in test; **in live these are foreign keys — synthetic names would be dangling refs** |
| `Deposit` | **Price** | Text | `500` | unchanged for run 2; recorded gap |
| `Total Price` | Price | Price | `24850` | ✓ |
| `First Name` / `Last Name` | Name | Name | `Test` / `Add` | ✓ |
| **`Customer Number`** | **Phone** | **Number** (auto-typed; predicted to reject) | `(555) 0199-0000` | **P5b: test `Customer Number` → Phone** (match live individually, per Codex; not Text) |
| `City` / `State` | Text | Text | `Dallas` / `TX` | ✓ |
| `Dealer/Auction Name` | Name | Name | `Synthetic Dealer` | ✓ |
| `Updated By` | **Email, app formula `useremail()`** | Text, no formula | `rami@texasautovalue.com` | unchanged in test; **in live a formula column — API-supplied value may be overridden; observe, don't assume** |
| `vAuto - Notes` | LongText | LongText | text | ✓ |

## 2. Columns the payload does not set — live initial values / formulas (observed)
`Date` Date Initial `TODAY()` **Require ✓**; `TimeStamp` DateTime Initial `NOW()`; `Office Time`/`Meeting Time`/`Time Back` Time Initial `TIMENOW()`; `Date Created` Date Initial `TODAY()`; `Last Updated` DateTime formula `now()`; `Balance`/`Balance Owed` Price formula `[Total Price]-[Deposit]`; virtual `_ComputedName` (Name, `CONCATENATE([First…`), `DupCheck` (Text, `CONCATENATE([Deal S…`), `InProgressDuplicate` (Ref, `ANY(SELECT(01_MY…`). Many Yes/No, Enum, EnumList and Ref columns elsewhere (rows 46–98). **`Date` is Require ✓ in live** with an initial value — whether the initial value satisfies Require on an API Add is one of the things run 2 can only observe on the **test** app (where `Date` is Date, Require ✗), so it stays open for live.

## 3. What this means
- **Run-2 correction (concrete, two cells, test app only):** P5a `Color` Color → **Text**; P5b `Customer Number` Number → **Phone**. Both mirror the live type for that column individually. Payload unchanged. Harness unchanged (`b9442a5b…`). No other test-app type is changed for run 2 — the probe's question is C1 (supplied key) and the remaining gaps do not block an Add to the test app.
- **Recorded fidelity gap (Part C design input, not adopted):** the header-built test app has **Text** where live has **Enum/Ref/Price/Number/Phone/Email+formula** for at least 9 payload columns. An Add accepted by the test app therefore does **not** show live would accept the same payload: live `Title State`, `Buyer`, `Closer` are Refs (values must be existing keys), `Title`/`Trans A/M`/`Deal Status` are Enums (membership unverified), `Updated By` is a formula column. Whether the bridge must resolve names to ref keys and restrict to enum members is a **proposed design question** for Part C, to be decided on evidence from live 3.1's reference tables — not assumed here, and no mapping is adopted.
- **Baseline fact for later:** live 3.1 has 102 columns (3 virtual); the test app has 100 (1 virtual, `_ComputedName`, auto-created). Live has 20 tables; the test app has 1.

## 4. Request
Codex: confirm P5a/P5b as the concrete run-2 correction (test-app edits only, screenshot + SAVE + clean ✓ before the run). The §3 fidelity gap is submitted as a finding and a design question, not as a bridge requirement. Run 2 still requires Rami's fresh explicit go. No live edits, API Add tests or bridge implementation are authorized.
