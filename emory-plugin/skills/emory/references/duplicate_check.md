# Duplicate contract & prior-work probes

*Reference for the `emory` skill. Read this when SKILL.md points you here — it is the
full detail for that step, moved out so the main workflow stays readable.*

---

## Step 0b — Duplicate & prior-work check (run right after the profile, before the five checks)

Before investigating, check whether this VIN is **already contracted** or **already ticketed** — it
prevents redundant work and catches a common real root cause (a duplicate-sale block). Surface the
result as a **banner at the top of the verdict**. Classify, don't hard-block.

**Treat a Probe 1 hit as a root-cause candidate to actively test, not just a banner note.**
Confirmed 2026-08-18 on two consecutive cases where the duplicate *was* the story: Porsche
Beaverton's GAP was written twice under two different brand codes (QSPL then POPL, same VIN/day —
the wrong one was never cancelled), and Thompson Chevrolet's NOAP contract had **already been
written** before the case was even opened, which changed the recommended fix from "adjust the
quote" to "may need to correct/endorse an existing contract." Both times, the five checks alone
would have missed the real point. So: when Probe 1 returns more than one row, don't just log it —
ask "does this explain the symptom" *before* running Checks 1-6, and say explicitly in the verdict
whether a contract for this exact product already exists.

### ⚠️ MANDATORY EVERY CASE — DO NOT SKIP OR ASSUME

**This is a mandatory two-probe check, not optional.** Run both probes on every case without exception.
Confirmed 2026-08-12: Probe 2 got silently skipped with no caveat surfaced — the failure mode this rule exists to close.

**Enforcement:**
- **Probe 1 (contract dedup):** Always run. No excuses.
- **Probe 2 (SR dedup):** Always attempt. Do NOT assume Salesforce is unavailable without checking.

If either probe cannot run, state it EXPLICITLY in the verdict banner (e.g., "⚠ SR-dedup NOT checked — no Salesforce session").
A missing duplicate-check line reads as "checked, none found" — worse than not checking at all.

- **Probe 1 (contract dedup) has no excuse to skip** — it's a cheap Snowflake query, always available.
  Run it every time.
- **Probe 2 (SR dedup) must be actively attempted, not assumed unavailable.** Check
  `mcp__Claude_Browser__tabs_context` for an open Salesforce tab; if none exists, **navigate to
  Salesforce yourself** (`https://safe-guardproducts.my.salesforce.com/`) and try the global search for
  the VIN. Only if that lands on a login page do you pause for the analyst (never enter credentials) —
  and even then, that's a **stated blocker**, not a silent skip.
- **If Probe 2 genuinely could not run** (login required and analyst unavailable, browser tool itself
  down), the verdict banner MUST say so explicitly and visibly — e.g. `⚠ SR-dedup NOT checked this run
  — no Salesforce session; VIN may have a prior/duplicate SR`. Never simply omit the line. A missing
  duplicate-check line reads as "checked, none found" to whoever's skimming the card — that's worse
  than not checking at all.

**Probe 1 — existing contract on this VIN (Snowflake, all three platforms; VIN-indexed, cheap).**
Non-PII columns only — **never** select customer name/address/phone from `SG_CON_M1`.
```sql
-- Tier 1 (Snowflake). {vin} = full 17-char VIN.
WITH v AS (SELECT '{vin}' AS vin)
SELECT 'Legacy' AS src, CAST(SG_CON_CONTRACT AS VARCHAR) AS contract, CAST(SG_CON_DEALER AS VARCHAR) AS dealer,
       CAST(SG_CON_PLC AS VARCHAR) AS product, CAST(SG_CON_STATUS AS VARCHAR) AS status, CAST(SG_CON_SALEDATE AS VARCHAR) AS sale_date
FROM STAGING.CMS.SG_CON_M1 c, v WHERE c.SG_CON_VIN = v.vin
UNION ALL
SELECT 'EAS', CAST(ECON_CONTRACT_NUMBER AS VARCHAR), CAST(DEALER_NUMBER AS VARCHAR),
       CAST(PRODUCT_CODE AS VARCHAR), CAST(STATUS AS VARCHAR), CAST(CONTRACT_SALE_DATE AS VARCHAR)
FROM STAGING.EAS.ECON_CONTRACT e, v WHERE e.VIN = v.vin
UNION ALL
SELECT 'RoadRunner', CAST(CONTRACT_NUMBER AS VARCHAR), CAST(DEALER_NUMBER AS VARCHAR),
       CAST(PRODUCT_CODE AS VARCHAR), CAST(VEHICLE_CONDITION AS VARCHAR), CAST(SALE_DATE AS VARCHAR)
FROM STAGING.RR_UTILITY.API_CONTRACT_SKU r, v WHERE r.VIN = v.vin;
```
Verified 2026-08-11: new-sale VIN → 0 rows (no dup); a contracted VIN → Legacy 3 / EAS 3 (dual-written).

**Probe 2 — is this VIN already in another Case/SR in Salesforce?** The point: catch the case
where the same vehicle has a **different open (or recently closed) Case number** already being
worked, so nobody double-works it. The Case/SR object is **not in any DB** (checked 2026-08-11:
`SF_CLAIM`=claims, `SF_D2C`=orders; no Support_Request/Case anywhere) — this has to be a live
Salesforce lookup, not a query. Two ways to run it:
- **Preferred (once built):** the **Power Automate "Emory · SR Dedup by VIN" flow** (build-spec:
  `Downloads\Emory_SR_Dedup_Flow_BuildSpec.md`) — POST `{ "vin": "{vin}" }` to its HTTP trigger
  (same pattern as the Teams poster); it returns matching Cases/SRs (number, status, created,
  subject). URL lives in `Downloads\emory_sr_dedup_url.txt` (read at call-time; never hardcode).
- **Fallback (what actually runs today — the flow isn't deployed yet):** use the in-app browser's
  **global search** for the full 17-char VIN. Salesforce global search spans **both** the `Case`
  object and the `Support_Request__c` object in one query, so it surfaces a duplicate under either
  name — you don't need to search each separately. Scope to **open + last ~180 days**; a hit on a
  *different* Case/SR number than the one you're working is the signal. State it as "SR-dedup via
  browser (flow not yet wired)" so the analyst knows which path answered.

**Classify (surface at the top of the verdict):**
| Found | Handling |
|---|---|
| Active contract, **same VIN + same product/coverage** | 🎯 Likely **duplicate-sale block** — can't sell/rate a 2nd contract on a VIN already covered. Name the contract#, route there; don't chase config. |
| Contract, same VIN, **different product** | Context only (multiple products per vehicle is legit) — note & continue. |
| **Cancelled/expired** contract, same VIN | Note (explains history) & continue. |
| **Open SR**, same VIN | ⚠ **Duplicate ticket** — surface the other SR, recommend consolidate; don't double-work. |
| **Resolved SR**, same VIN | Surface its **resolution** as the probable answer. |
| Nothing | "No duplicate contract or prior SR on this VIN" — proceed; report as a clean signal. |
| **Probe 2 blocked** (no Salesforce session, login unavailable) | ⚠ State it plainly in the banner — **not** the same as "nothing found." Proceed with Probe 1's result only, and say so. |

- Match on the **full 17-char VIN** (contracts store it), not the squished classing pattern.
- Read-only + **PII-masked**. Confidence: same VIN + same product = high (likely block); VIN-only = medium (dupe/context).

---
