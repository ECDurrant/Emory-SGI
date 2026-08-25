# Emory Analysis Guardrails — Lessons from INC1315776

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

## Enforcement Checklist (Before Verdict)

Before finalizing the verdict, verify:

- [ ] **Step 0b ran completely** (both Probe 1 and Probe 2)
  - [ ] If Probe 2 didn't run, stated explicitly why
- [ ] **Rate table location verified** (searched Tier 1 or Tier 2, not both)
- [ ] **Step 7 ran** (if rates/classing failed, Step 7 is MANDATORY)
- [ ] **Eligibility matrix read** (not guessed)
- [ ] **Duplicate contracts classified** (status interpreted, not assumed)
- [ ] **All "before concluding" checkpoints passed** (verified, not guessed)

**If ANY of these are unchecked:** Mark verdict as **NEEDS REVIEW** and state what needs verification.

---

## The Golden Rule

**Verify before concluding. Never guess. Always read the source.**

If you can't verify, say so. If you guessed, correct it. If the source is unclear, escalate.
