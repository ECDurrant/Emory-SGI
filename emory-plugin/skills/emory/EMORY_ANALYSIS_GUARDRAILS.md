# Emory Analysis Guardrails
---

## 0. PRE-POST VERIFICATION GATE — read before any `-Post` (added 2026-09-15, INC1320603)

**The failure this prevents.** A card was posted to #api-support-intake stating that
"9 further dealers carry the same broken config and should be checked." **That number was never
verified.** It came from a cohort query that filtered a **literal date value**
(`Expiration_Sales_Date = '2026-07-23'`), which both *missed* affected dealers (terminated on other
dates) and *included* healthy ones (already re-enrolled). The verdict was correct; the **scope was
wrong**, and it reached a team channel as fact. The real set was 5, not 10. Re-posting a correction
does not undo people having read the first one.

**The rule.** Every factual claim on a card — **especially counts, scope claims
("N other dealers/VINs affected"), and any assertion of a mechanism** — must trace to a query
**actually run**, whose logic you checked. **Inference is not verification.** If you did not run it,
it does not go on the card.

**The gate.** `emory_post.ps1` now **refuses to post** unless the verdict JSON carries a
`verification` array — one entry per load-bearing claim, naming the claim and how it was
established. Entries under 25 characters are rejected ("checked" is not evidence). Dry runs are
never gated, so drafting stays frictionless. The gate cannot check a claim is *true* — only that
you enumerated it against evidence before delivery, which is precisely the step that was skipped.

```json
"verification": [
  "Scope = 5 dealers - ran the has_open=0 AND has_inverted=1 aggregation over all program-20378
   dealers on rate system 4639; result was exactly HPPFL062, 073, 109, 118, 150.",
  "RETRACTED from the prior card: the '9 further dealers' claim - traced to a literal-date
   cohort query that was never validated."
]
```

**Three specific habits this encodes:**

1. **Never filter a cohort on a literal value** you happened to observe in one row (a date, a
   class code, a status). Express the *condition* instead (`Expiration < Effective`), then verify
   the query returns the row you already know about **plus** nothing obviously healthy.
2. **A refutation can itself be incomplete.** Here the hypothesis looked disproven because the
   dealer held 67 contracts for the product. The resolution was that the *comparison* dealers had a
   **second, open row** the reported dealer lacked. **Check for additional rows before accepting OR
   rejecting** a finding.
3. **Prefer a natural experiment to timeline correlation.** "Contracts stop the day before the
   sync" at one dealer is suggestive. "This dealer sold zero while broken, then sold two days after
   a replacement row appeared, and four unreplaced dealers have sold none ever" is proof. Go find
   the second kind before posting.

**Carry retractions forward explicitly.** When a corrected card supersedes an earlier one, state
what was withdrawn in the card body — do not silently drop it and re-post a cleaner version.

 — Lessons from INC1315776

**Purpose:** Prevent the 6 critical mistakes that led to an incomplete verdict on INC1315776.

---

## 1. Rate Table Locator (NEVER GUESS THE TABLE)

**Mistake:** Searched `RATE_SKU_VCI` for Porsche (PBL) products and concluded "0 rates" without checking the correct table.

**Fix:** Always map product → carrier → correct rate table BEFORE querying.

| Product Code | Carrier | Rate Table | Location | Must Check |
|---|---|---|---|---|
| **PO*** | Porsche (PBL) | `RATE_SKU_PBL` | **LIVE EAS DB (Tier 2)** | ✅ LIVE DB — not in Snowflake |
| **AU***, **VW***, **DU*** | VCI (Audi/VW/Ducati) | `RATE_SKU_VCI` | Snowflake (Tier 1) | Snowflake replica |
| **BM***, **MINI** | BMW | `RATE_SKU_BMW` | Snowflake (Tier 1) | Snowflake replica |
| **GM***, **CB*** | GM | `RATE_SKU_GM` | Snowflake RR_UTILITY (Tier 1) | RoadRunner replica |
| **HCI***, **PPES** | HCI 2.0 / Kia PPES | `RATE_SKU_HCI2O` | **LIVE EAS DB (Tier 2)** | ✅ LIVE DB — not replicated |
| **QS*** | QualityShield (competitive brand) | Varies (check product master) | Varies | ✅ VERIFY — not all QS products replicated |
| **SG Agents program 20376** (`SAFE`, `GAPE`, `RVGP`, `BTGP`, `AG**`, `SVSC`, `SLSE`…) | SGI Agents channel | `dbo.Rate_sku_SG_Agents` (2.87M rows) | **LIVE EAS DB (Tier 2)** | ✅ **NOT replicated to Snowflake AT ALL** — the table does not exist in `STAGING.EAS`. Sweeping every replicated `RATE_SKU_*` returns 0 and looks like "no rates loaded." GAP bands here are keyed on **`amount_finance_from`/`amount_financed_to`**, not MSRP. |

**Protocol:**
1. Extract product code (e.g., POTW → PO prefix)
2. Look up in table above
3. If "LIVE EAS DB" — query Tier 2, NOT Snowflake
4. If location says "NOT replicated" — do NOT query Snowflake and conclude "no rates"
5. Always verify the table location before querying

---

## 2. Step 7 Eligibility — READ THE SOURCE, NEVER GUESS

**Mistake:** Said "may be New/CPO-only" without reading the Master Eligibility Matrix.

**Fix:** Step 7 is mandatory when rates/classing fail. Always READ the actual source.

**When Step 7 is MANDATORY (non-negotiable):**
- ✅ Check 5 (rates) = FAIL or NEEDS REVIEW
- ✅ Check 6 (classing) = FAIL or NEEDS REVIEW  
- ✅ Any product didn't return rates
- ✅ Case symptom is "won't rate on [condition]"

**The Protocol (MUST follow in order):**
1. **Identify the OEM** from product code (Porsche → PBL tab, VCI → VWFS tab, etc.)
2. **Open the Master Eligibility Matrix** (`Downloads\Emory OEM Knowledge Base\Master Eligibility Matrix.xlsx`)
3. **Read the tab for that OEM** — look for:
   - New/Used/CPO eligibility
   - State exclusions
   - Finance type restrictions
   - Model year / odometer / term limits
   - Other requirements
4. **Cite the exact row and field** — e.g., "PBL tab, POTW row: New/Used/CPO = [value]"
5. **Do NOT say "may be"** — say either "IS eligible per matrix" or "NOT eligible per matrix" or "Matrix unclear — verify with OEM team"

**If matrix is unclear or says "Not stated in source":**
- Flag it as NEEDS REVIEW
- Do NOT guess
- State that eligibility requires OEM confirmation

---

## Porsche (PBL) Eligibility Reference

**Products:** POTW (Tire & Wheel), POMC (Multi-Coverage), POCP (CPO VSC)

| Product | Eligible? | Condition Notes |
|---|---|---|
| POTW | ✅ Yes | No condition-specific exclusions per matrix |
| POMC | ✅ Yes | No condition-specific exclusions per matrix |
| POCP | ❌ No | Entirely excluded from Porsche program |

**Source:** Partner Profile - Porsche Bentley Lamborghini US - Eligibility Coverage sheet  
**Memory:** [[porsche-pbl-eligibility]]

---

## 3. Duplicate Contract Interpretation (ALWAYS CLASSIFY THE STATUS)

**Mistake:** Found contracts with status "R" and "A" but didn't interpret what that means for the case.

**Fix:** Always classify duplicate contracts by their status and what it means.

**Contract Status Meanings (Legacy):**
| Status | Meaning | Impact | Action |
|---|---|---|---|
| **A** | Active | Contract in force, covers the vehicle | **BLOCKS new sale** — same product/VIN |
| **R** | Replaced/Rescinded | Previous contract no longer in force | May indicate failed/retry scenario |
| **C** | Cancelled | Intentionally cancelled | Not a blocker (vehicle available) |
| **E** | Expired | Passed its natural end date | Not a blocker (old contract) |

**Duplicate Classification:**
```
IF contract exists AND status = A (Active)
  → "Active duplicate — likely blocks new sale"
  → Escalate to Account Management immediately

IF contract exists AND status = R (Replaced)
  → "Contract was replaced — may indicate failed attempt"
  → Still investigate why they're requesting again 4 days later

IF contract exists AND status = C or E
  → "Old contract — not a current blocker"
  → Continue investigation of the missing rates
```

**What I should have said in INC1315776:**
> "Found two POCP contracts on this VIN (SG0009958690 [EAS, status R], 9006013850 [Legacy, status A]). The EAS contract shows status 'Replaced,' which may indicate the first attempt failed. The Legacy contract shows status 'Active.' This suggests the system may have attempted to write the contract twice and one succeeded while the other was replaced. **Account Management must clarify whether this is a legitimate retry/upsell scenario or a duplicate-sale block.**"

---

## 4. Probe 2 (SR Dedup) — ALWAYS ATTEMPT, NEVER ASSUME UNAVAILABLE

**Mistake:** Noted "Salesforce not available" without actually trying to open it.

**Fix:** Explicit steps to run Probe 2 every time.

**Probe 2 Execution (no excuses):**

1. **Check if Salesforce tab already open:**
   ```
   mcp__Claude_Browser__tabs_context → see if safe-guardproducts.my.salesforce.com is already open
   ```

2. **If NOT open, open it yourself:**
   ```
   mcp__Claude_Browser__preview_start with url: https://safe-guardproducts.my.salesforce.com
   Wait for page to load
   If login page appears → pause and tell analyst to log in (NEVER enter credentials)
   ```

3. **Run global search (Salesforce search bar at top):**
   - Search for the full 17-char VIN
   - Scope to open + last 180 days
   - Look for Support_Request__c OR Case objects

4. **Classify result:**
   - Same SR number = dedup context, continue
   - Different SR number = **DUPLICATE TICKET** → consolidate, don't double-work
   - No results = clean signal, proceed

5. **If Salesforce login required and analyst unavailable:**
   - Do NOT assume it's unavailable
   - State explicitly: "⚠️ SR-dedup NOT checked — awaiting Salesforce login"
   - This is a stated blocker, not a silent skip

**Example verdict banner if Probe 2 runs:**
```
Duplicate check:
  ✅ Contract dedup — found 2 POCP contracts on this VIN
  ✅ SR dedup — no prior SRs on this VIN
  → Clean signal: proceed with investigation
```

**Example if Probe 2 cannot run:**
```
Duplicate check:
  ✅ Contract dedup — found 2 POCP contracts on this VIN
  ⚠️ SR dedup NOT checked — Salesforce login required
  → Incomplete: cannot confirm no parallel work
```

---

## 5. Carrier-Specific Gotchas (REFERENCE TABLE)

**Mistake:** Didn't know RATE_SKU_PBL wasn't in Snowflake, searched wrong table, got false conclusion.

**Fix:** Explicit list of carriers with special handling.

| Carrier | Rate Table Location | Gotcha | Emory Step |
|---|---|---|---|
| **Porsche (PBL)** | Live EAS DB `RATE_SKU_PBL` | ❌ NOT in Snowflake replica | Query Tier 2 |
| **HCI 2.0** | Live EAS DB `RATE_SKU_HCI2O` | ❌ NOT replicated | Query Tier 2 |
| **GM** | Snowflake `RR_UTILITY.RATE_SKU_GM` | ✅ In RR replica | Query Tier 1 RR tables |
| **Porsche rates (pricing)** | API-computed | ⚠️ Not pre-stored — live rating engine | No SKU table, verify with live-fire |
| **VCI (VW/Audi/Ducati)** | Snowflake `RATE_SKU_VCI` | ✅ Standard replica | Query Tier 1 |

**Rule:** Before Check 5b, verify the table location. If Tier 2 or not replicated, MUST query live DB, not Snowflake.

---

## 6. Verification Checkpoints (BEFORE CONCLUDING)

**Mistake:** Concluded "no rates" based on Snowflake query when rates actually existed in a different system.

**Fix:** Add explicit "verify before concluding" step after each check.

**Check 1 — Dealer Status:**
- ✅ Query ran successfully
- ✅ Confirmed dealer_id or resolved code
- ❌ STOP if: dealer not found across any platform
- **Before concluding FAIL:** Verify spelling of dealer code against the case

**Check 2 — Product Assigned:**
- ✅ Query ran successfully  
- ✅ Product appears in assignment window
- ❌ STOP if: product not found after checking all platforms
- **Before concluding FAIL:** Verify product code is spelled exactly as in case; check if product was just added (sync delay)

**Check 3 — eContract Forms:**
- ✅ Query ran successfully
- ✅ Found at least one form
- ❌ STOP if: no forms found
- **Before concluding FAIL:** Verify product_code_id is correct; check if form is pending load

**Check 4 — Rate System:**
- ✅ Query ran successfully
- ✅ Rate system assigned (not stale)
- ❌ STOP if: 0 results
- **Before concluding FAIL:** Verify you queried the correct dealer_id; confirm this is really the right platform

**Check 5 — Rates (THE CRITICAL ONE):**
- ✅ Query ran to the CORRECT table (per Rate Table Locator above)
- ✅ Results match the carrier/program
- ❌ BEFORE saying "no rates": 
  - Verify table location (Tier 1 vs Tier 2)
  - If table is "not replicated," query Tier 2, not Snowflake
  - If rates are "API-computed," don't conclude from SKU table — verify with live-fire test
  - Check sibling products for comparison
- **Before concluding FAIL:** Did you search the right table for this carrier?

**Check 6 — Classing:**
- ✅ Queried Tier 2 first (EAS V_PROGRAM_VEHICLE_CLASS)
- ✅ Confirmed with Tier 1 (Snowflake) 
- ❌ STOP if: no rows after normalization
- **Before concluding FAIL:** Did you normalize make/model/trim correctly? Does a catch-all (ALL MAKES/ALL MODELS) row exist?

**Check 7 — Eligibility RAG (MANDATORY if rates/classing failed):**
- ✅ Read the Master Eligibility Matrix
- ✅ Found the right OEM tab
- ✅ Cited the exact row and field
- ❌ STOP if: matrix says "Not stated in source"
- **Before concluding:** Did you read the actual source, or guess?

---

## 7. Source-of-Truth Rules (added 2026-10-01 — data audit)

These came from a full read of all three platforms on 2026-10-01. Each one fixed a way Emory could
give a confident wrong answer.

| Rule | Why (evidence) |
|---|---|
| Route by **live product enrolment** (router R1), never by prefix | Codes are multi-written (EAS∩Legacy 45.7k dealers); HCI 1.0 (RR) and HCI 2.0 (EAS) share dealer prefixes but not product codes |
| RoadRunner = **`STAGING.RR_UTILITY`** only | `STAGING.RR` last synced 2024-08-13: 331,882 vs 457,750 dealer-product rows; ~700 GMF dealers missing |
| EAS dealer presence = **`V_DEALER`**, not `DEALER_PRODUCT_VW` | The view only lists dealers *with* products, so 0-product onboarding shells (e.g. `HPPNM027`) looked absent |
| VIN decode on SQL Server = **exact squished pattern** `LEFT(vin,8)+SUBSTRING(vin,10,2)` (or `,10,1` for 9-char powersports) | `'{vin}' LIKE vin_pattern+'%'` returned **0 rows** for a valid VIN — the pattern omits check digit 9 |
| Never gate on `RATE_SYSTEM_APPLICATION` sale dates | ~35% are stale stubs → false "Rate System Missing" (FDP_SYNC `has_open = 0` is the only exception) |
| EAS rates live in **two** places | RATE_SKU_<program> **or** PRODUCT_PLAN_SKU_PRICE_HEADER; Mazda (637 dealers) has no RATE_SKU table at all |
| Call-log evidence = SQL Server `dbo.BI_V_Ws_Call_log` | Snowflake copy is a single day (2026-05-11) |
| Legacy product = `SG_RSC_PLC` on the rate schedule | `SG_DRS_PLC` is the enrolment plan and `SG_DLR_PLC` a default; matching either reports the wrong product |
| Snowflake EAS is nightly | "Set up today" → re-run the EAS half live on SQL Server before saying "not configured" |

**Known open data gaps** (state them in a verdict when the case touches them): see `references/routing.md` §4 (G1–G7).

---

## Enforcement Checklist (Before Verdict)

Before finalizing the verdict, verify:

- [ ] **Step 0b ran completely** (both Probe 1 and Probe 2)
  - [ ] If Probe 2 didn't run, stated explicitly why
- [ ] **Rate table location verified** (searched Tier 1 or Tier 2, not both)
- [ ] **Step 7 ran** (if rates/classing failed, Step 7 is MANDATORY)
- [ ] **Eligibility matrix read** (not guessed)
- [ ] **Duplicate contracts classified** (status interpreted, not assumed)
- [ ] **All "before concluding" checkpoints passed** (verified, not guessed)
- [ ] **Routing came from the router (R1), not the dealer-code prefix** — the platform named in the verdict is the one where the product is *active today* (`references/routing.md`)
- [ ] **No read from `STAGING.RR.*`** (frozen 2024-08-13) — RoadRunner evidence is `RR_UTILITY` only
- [ ] **Rate path matches the program** — RATE_SKU table vs PRICE_HEADER per `routing.md` §2; SG Agents / Lithia / QualityGuard rates read on SQL Server
- [ ] **Every number in the verdict came from a query run in this case** (no counts carried over from memory or this file without re-running)

**If ANY of these are unchecked:** Mark verdict as **NEEDS REVIEW** and state what needs verification.

---

## The Golden Rule

**Verify before concluding. Never guess. Always read the source.**

If you can't verify, say so. If you guessed, correct it. If the source is unclear, escalate.
