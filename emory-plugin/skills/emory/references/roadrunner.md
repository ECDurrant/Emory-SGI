# RoadRunner (RR) platform checks

*Reference for the `emory` skill. Read this when SKILL.md points you here — it is the
full detail for that step, moved out so the main workflow stays readable.*

---

### RoadRunner (RR) checks — Snowflake `STAGING.RR` / `RR_UTILITY` (Tier 1, no extra connector)

When Step 0 routes to **RoadRunner** (GM + e-com Hyundai/Kia/Genesis/Honda), run the checks
against RR. Spine: `DEALER.DEALER_ID → DEALER_PRODUCT → PRODUCT`/`PROGRAM`; classing in `CLASS`,
forms in `FORM_PRODUCT_STATE` (+ `FORM_PRODUCT_DEALER` overrides), rates in the per-carrier
`RR_UTILITY.RATE_SKU_*`. **RR open-date sentinel = `3000-01-01`** (not EAS `9999-12-31` /
Legacy `1799-12-31`). Verified end-to-end 2026-08 on `GMF18645` (Paradise Chevrolet, program
`GMF`=9): 100 active products incl. `BUVS`, 269 in-program classes, CA forms present, GM rate SKUs present.

**Anchor — dealer + assigned products + program (Checks 1 & 2 in one hop):**
```sql
-- Tier 1 (Snowflake). {code} = DEALER_CODE.
SELECT d.DEALER_CODE, d.DEALER_NAME, d.DEALER_STATE, d.OUT_OF_BUSINESS_DATE, d.EFFECTIVE_DATE_END,
       dp.PROGRAM_ID, pg.PROGRAM_NAME, p.PRODUCT_ID, p.PRODUCT_CODE, p.PRODUCT_NAME, p.RISK_TYPE_CODE,
       dp.EFFECTIVE_DATE_START, dp.EFFECTIVE_DATE_END
FROM STAGING.RR.DEALER d
JOIN STAGING.RR.DEALER_PRODUCT dp ON dp.DEALER_ID = d.DEALER_ID
JOIN STAGING.RR.PRODUCT p         ON p.PRODUCT_ID  = dp.PRODUCT_ID
LEFT JOIN STAGING.RR.PROGRAM pg   ON pg.PROGRAM_ID = dp.PROGRAM_ID
WHERE d.DEALER_CODE = '{code}'
  AND ('{as_of}' BETWEEN dp.EFFECTIVE_DATE_START AND COALESCE(dp.EFFECTIVE_DATE_END,'3000-01-01'))
  {AND p.PRODUCT_CODE = '{product_code}'};
```
- Zero product rows in the window → not assigned on RR for that date (RC#1/#2). **Dealer status:** an
  `OUT_OF_BUSINESS_DATE` or past `EFFECTIVE_DATE_END` on `DEALER` = inactive. Carries `{program_id}` + `{product_id}` forward.

**Check 4 — forms:**
```sql
SELECT COUNT(*) AS state_forms
FROM STAGING.RR.FORM_PRODUCT_STATE
WHERE PRODUCT_ID = {product_id} AND PROGRAM_ID = {program_id} AND STATE_CODE = '{state}'
  AND '{as_of}' BETWEEN EFFECTIVE_DATE_START AND COALESCE(EFFECTIVE_DATE_END,'3000-01-01');
-- dealer-specific overrides live in STAGING.RR.FORM_PRODUCT_DEALER (same keys + DEALER_ID)
```

**Check 5 — rates (per-carrier `RR_UTILITY.RATE_SKU_*`):** pick the table by OEM —
**GM → `RATE_SKU_GM`**, **Hyundai/Kia e-com → `RATE_SKU_HCI`** (the HCI rates ARE in Snowflake here,
unlike EAS's un-replicated `RATE_SKU_HCI2O`), **Honda → `RATE_SKU_HONDA`**; SKU↔product catalog =
`RR_UTILITY.PRODUCT_SKU`. All share EAS's rate-SKU shape **and its gotcha** — `MSRP_*`,
`VEHICLE_CONDITION`, engine ranges are often NULL (= unrestricted); filter only on `CLASS` +
sale window + term/odometer:
```sql
SELECT CLASS, TERM_FROM, TERM_TO, ODOMETER_FROM, ODOMETER_TO, VEHICLE_CONDITION,
       START_SALE_DATE, END_SALE_DATE, DEALER_COST, RETAIL_COST
FROM STAGING.RR_UTILITY.RATE_SKU_GM          -- or _HCI / _HONDA per OEM
WHERE PROGRAM_ID = {program_id} AND PRODUCT_ID = {product_id}
  AND '{as_of}' BETWEEN START_SALE_DATE AND END_SALE_DATE
  {AND CLASS = '{class}'}
LIMIT 50;
```

**Check 6 — classing (VIN → class, fully resolvable in Snowflake — RR's dictionaries ARE
replicated, unlike EAS).** Two methods; pick by the vocabulary the program's `RATE_SKU_*.CLASS`
uses:

- **VSC / CPO programs → name-based** `RR_UTILITY.VIN_VASUR_CLASS_CODE`: match the 10-char
  squished pattern → `VSC_CLASS1/2` (or `CPO_CLASS1/2` for CPO). Name-based (`VIN_PATTERN`,
  `MAKE`, `MODEL` text; `START_DATE`/`END_DATE`, `STATUS`) — no id normalization needed.
- **GM / OEM make-tier programs → id-based chain** (class differs **per product** — always
  filter `PRODUCT_ID`):
```sql
-- VIN -> VIN_DETAIL -> PRODUCT_CLASS -> CLASS.CLASS_NAME (= the RATE_SKU_* CLASS text)
WITH v AS (
  SELECT MODEL_ID, MODEL_YEAR, DRIVE_TYPE, FUEL_TYPE, ENGINE_SIZE
  FROM STAGING.RR_UTILITY.VIN_DETAIL
  WHERE VIN_PATTERN = LEFT('{vin}',8) || SUBSTR('{vin}',10,2)
)
SELECT DISTINCT c.CLASS_NAME
FROM v
JOIN STAGING.RR_UTILITY.PRODUCT_CLASS pc
  ON pc.MODEL_ID = v.MODEL_ID AND pc.PROGRAM_ID = {program_id} AND pc.PRODUCT_ID = {product_id}
 AND {year} BETWEEN pc.MODEL_YEAR_START AND pc.MODEL_YEAR_END
JOIN STAGING.RR_UTILITY.CLASS c ON c.CLASS_ID = pc.CLASS_ID;
```
  The `CLASS_NAME` feeds Check 5's `RATE_SKU_*.CLASS` filter. One class → PASS; several after the
  `PRODUCT_ID` filter → narrow by `DRIVE_TYPE`/`FUEL_TYPE`/`ENGINE_SIZE`/`MODEL_TRIM_ID`; zero →
  NEEDS REVIEW (nomenclature vs. genuine gap). `CLASS.CLASS_NAME` = the rate vocabulary
  (e.g. `BUIC1`); `PRODUCT_CLASS.EXTERNAL_CLASS` is a separate OEM code — join on `CLASS_ID`, not
  `EXTERNAL_CLASS`. Verified 2026-08: 2024 Buick Envision (pattern `LRBFZSE4RD`, MODEL_ID 613,
  program 9) → `BUIC1`.
