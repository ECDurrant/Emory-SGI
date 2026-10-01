# RoadRunner (RR) platform checks

*Reference for the `emory` skill. Read when the router (`references/routing.md`, R1) returns
ROADRUNNER. Rebuilt and verified 2026-10-01.*

---

> ### ⚠ Use `STAGING.RR_UTILITY.*` only — `STAGING.RR.*` is dead
> The `STAGING.RR` schema stopped syncing on **2024-08-13** (`SR_PROCESS_TIME` max). On
> 2026-10-01 it held 331,882 dealer-product rows vs **457,750** live in `RR_UTILITY`, 17,516 form
> rows vs **34,139**, and 2,600 active GMF dealers vs **3,307**. Every earlier Emory RR check read the
> dead copy. `RR_UTILITY` is synced daily (RECORDTIMESTAMP = today). Same table names, same keys;
> audit columns are `CREATED_*` / `MODIFIED_*` instead of `RR_CREATED_*` / `RR_CHANGED_*`.
> (This also supersedes the older "RR forms table is stale" note — the whole schema is stale.)

When R1 routes to **RoadRunner** (GM, CarBravo, ACF, GM D2C, HCI 1.0 Hyundai/Kia/Genesis), run the
checks against `RR_UTILITY`. Spine: `DEALER.DEALER_ID → DEALER_PRODUCT → PRODUCT` / `PROGRAM`;
product-in-program `PRODUCT_PROGRAM`; forms `FORM_PRODUCT_STATE` (+ `FORM_PRODUCT_DEALER`
overrides); classing `VIN_DETAIL → PRODUCT_CLASS → CLASS`; eligibility `PRODUCT_ELIGIBILITY`;
rates in the per-OEM `RATE_SKU_*`. **RR open-date sentinel = `3000-01-01` or NULL.**

**Rate table by program** (`RR_UTILITY.PROGRAM.ECOM_DB`):

| ECOM_DB | Programs | Rate table | Active rows (2026-10-01) |
|---|---|---|---|
| `HCI` | 1 Hyundai, 2 Genesis, 3 Kia (HCI 1.0) | `RATE_SKU_HCI` | 2.42M / 2.32M / 2.36M |
| `GM` | 4 CarBravo, 9 GMF, 10 White Label, 41 GMF Canada, 74 ACF | `RATE_SKU_GM` | 626k / 1.49M / 648 / 4 / 1.47M |
| `GM_D2C` | 5-8 D2C GMC/Chevy/Buick/Cadillac | `RATE_SKU_D2C` | 804–1,920 each |
| `HONDA` | 39 Acura US, 40 Honda US | `RATE_SKU_HONDA` | **0** — Honda/Acura rate on EAS `RATE_SKU_HONDA2O` (20350/20351) |

---

## RR1 — the whole RR check in one query (Checks 1, 2, 4, 5, 6)

```sql
-- Tier 1 (Snowflake). {code} = DEALER_CODE as resolved by R1 (e.g. GMF11145, not the bare BAC).
-- {vin_pattern} = LEFT(vin,8) || SUBSTR(vin,10,2). {rate_table} from the table above.
WITH p AS (SELECT '{code}' code, '{product}' product, CURRENT_DATE as_of, {year} yr, '{vin_pattern}' vinpat),
d AS (SELECT d.DEALER_ID, d.DEALER_CODE, d.DEALER_NAME, d.DEALER_STATE, d.OUT_OF_BUSINESS_DATE,
             d.EFFECTIVE_DATE_END AS dealer_end, dp.PROGRAM_ID, dp.PRODUCT_ID,
             dp.EFFECTIVE_DATE_START AS dp_start, dp.EFFECTIVE_DATE_END AS dp_end
      FROM STAGING.RR_UTILITY.DEALER d JOIN p ON d.DEALER_CODE = p.code
      JOIN STAGING.RR_UTILITY.DEALER_PRODUCT dp ON dp.DEALER_ID = d.DEALER_ID
      JOIN STAGING.RR_UTILITY.PRODUCT pr        ON pr.PRODUCT_ID = dp.PRODUCT_ID
      WHERE pr.PRODUCT_CODE = p.product
        AND p.as_of BETWEEN dp.EFFECTIVE_DATE_START AND COALESCE(dp.EFFECTIVE_DATE_END,'3000-01-01'))
SELECT d.DEALER_CODE, d.DEALER_NAME, d.DEALER_STATE, d.OUT_OF_BUSINESS_DATE, d.dealer_end,
       d.PROGRAM_ID, d.PRODUCT_ID, d.dp_start, d.dp_end,
       (SELECT COUNT(*) FROM STAGING.RR_UTILITY.PRODUCT_PROGRAM pp
         WHERE pp.PRODUCT_ID = d.PRODUCT_ID AND pp.PROGRAM_ID = d.PROGRAM_ID) AS in_program,
       (SELECT COUNT(*) FROM STAGING.RR_UTILITY.FORM_PRODUCT_STATE f, p
         WHERE f.PRODUCT_ID = d.PRODUCT_ID AND f.PROGRAM_ID = d.PROGRAM_ID AND f.STATE_CODE = d.DEALER_STATE
           AND p.as_of BETWEEN f.EFFECTIVE_DATE_START AND COALESCE(f.EFFECTIVE_DATE_END,'3000-01-01')) AS state_forms,
       (SELECT COUNT(*) FROM STAGING.RR_UTILITY.FORM_PRODUCT_DEALER f
         WHERE f.PRODUCT_ID = d.PRODUCT_ID AND f.DEALER_ID = d.DEALER_ID) AS dealer_form_overrides,
       (SELECT COUNT(*) FROM STAGING.RR_UTILITY.{rate_table} r, p
         WHERE r.PROGRAM_ID = d.PROGRAM_ID AND r.PRODUCT_ID = d.PRODUCT_ID
           AND p.as_of BETWEEN r.START_SALE_DATE AND r.END_SALE_DATE) AS active_rate_rows,
       (SELECT LISTAGG(DISTINCT c.CLASS_NAME, ',')
          FROM STAGING.RR_UTILITY.VIN_DETAIL v
          JOIN STAGING.RR_UTILITY.PRODUCT_CLASS pc ON pc.MODEL_ID = v.MODEL_ID
          JOIN STAGING.RR_UTILITY.CLASS c          ON c.CLASS_ID = pc.CLASS_ID, p
         WHERE v.VIN_PATTERN = p.vinpat AND pc.PROGRAM_ID = d.PROGRAM_ID AND pc.PRODUCT_ID = d.PRODUCT_ID
           AND p.yr BETWEEN pc.MODEL_YEAR_START AND pc.MODEL_YEAR_END
           AND p.as_of BETWEEN COALESCE(pc.EFFECTIVE_DATE_START,'1900-01-01')
                           AND COALESCE(pc.EFFECTIVE_DATE_END,'3000-01-01')) AS vin_class
FROM d;
```

**Verified 2026-10-01** — `GMF18645` (Paradise Chevrolet, CA) + `BUVS`, 2024 Buick Envision
(pattern `LRBFZSE4RD`), `RATE_SKU_GM`: program 9, product 189, `in_program` 1, `state_forms` 1,
`dealer_form_overrides` 0, `active_rate_rows` 47,385, `vin_class` **B2**.

**Reading it:**

| Result | Verdict | Owner |
|---|---|---|
| zero rows | product not active for this dealer on RR → run R2 in `routing.md` (end-dated vs never) | Acct Mgmt |
| `OUT_OF_BUSINESS_DATE` or `dealer_end` ≤ today | dealer inactive on RR | Acct Mgmt |
| `in_program = 0` | product not attached to the program | Rates & Forms |
| `state_forms = 0` and `dealer_form_overrides = 0` | no form for the dealer's state | Rates & Forms (forms) |
| `active_rate_rows = 0` | no rates for the sale date | Rates & Forms |
| `vin_class` NULL | VIN pattern or model not classed for this product → NEEDS REVIEW (nomenclature vs real gap) | Pricing / Risk |
| `vin_class` has several values | narrow by `DRIVE_TYPE_ID` / `FUEL_TYPE_ID` / `ENGINE_SIZE` / `MODEL_TRIM_ID` on `PRODUCT_CLASS` | — |

Class differs **per product** (the same Envision is `B2` on BUVS; other GM products use other
class vocabularies such as `BUIC1`) — always filter `PRODUCT_ID`. `CLASS.CLASS_NAME` is the
`RATE_SKU_*.CLASS` text; `PRODUCT_CLASS.EXTERNAL_CLASS` is a separate OEM code — join on `CLASS_ID`.

## RR2 — rate rows for a class (only when RR1 shows a rate problem)

```sql
SELECT CLASS, TERM_FROM, TERM_TO, TERM_MILEAGE, ODOMETER_FROM, ODOMETER_TO, VEHICLE_CONDITION,
       FINANCE_TYPE, START_SALE_DATE, END_SALE_DATE, DEALER_COST, RETAIL_COST
FROM STAGING.RR_UTILITY.{rate_table}
WHERE PROGRAM_ID = {program_id} AND PRODUCT_ID = {product_id}
  AND CURRENT_DATE BETWEEN START_SALE_DATE AND END_SALE_DATE
  AND CLASS = '{class}'
ORDER BY TERM_FROM, ODOMETER_FROM
LIMIT 50;
```
`MSRP_*`, `VEHICLE_CONDITION`, engine ranges and `FINANCE_TYPE` are often NULL (= unrestricted);
filter only on class, sale window, term and odometer unless the case is about one of those.

## RR3 — VSC / CPO name-based classing (VASUR)

For VSC and CPO programs whose rate `CLASS` uses the VASUR vocabulary:
```sql
SELECT VIN_PATTERN, MAKE, MODEL, VSC_CLASS1, VSC_CLASS2, CPO_CLASS1, CPO_CLASS2, STATUS, START_DATE, END_DATE
FROM STAGING.RR_UTILITY.VIN_VASUR_CLASS_CODE
WHERE VIN_PATTERN = '{vin_pattern}'
  AND CURRENT_DATE BETWEEN COALESCE(START_DATE,'1900-01-01') AND COALESCE(END_DATE,'3000-01-01');
```

## RR4 — vehicle eligibility (exclusions)

```sql
SELECT pe.IS_ELIGIBLE, pe.MAKE_ID, pe.MODEL_ID, pe.MODEL_YEAR_START, pe.MODEL_YEAR_END,
       pe.ENGINE_TYPE_ID, pe.FUEL_TYPE_ID, pe.EFFECTIVE_DATE_START, pe.EFFECTIVE_DATE_END
FROM STAGING.RR_UTILITY.PRODUCT_ELIGIBILITY pe
WHERE pe.PROGRAM_ID = {program_id} AND pe.PRODUCT_ID = {product_id}
  AND (pe.MAKE_ID = {make_id} OR pe.MAKE_ID IS NULL)
  AND (pe.MODEL_ID = {model_id} OR pe.MODEL_ID IS NULL)
  AND {year} BETWEEN COALESCE(pe.MODEL_YEAR_START,1900) AND COALESCE(pe.MODEL_YEAR_END,3000)
  AND CURRENT_DATE BETWEEN COALESCE(pe.EFFECTIVE_DATE_START,'1900-01-01') AND COALESCE(pe.EFFECTIVE_DATE_END,'3000-01-01');
```
Rules with `MODEL_ID` NULL are **make-wide** (e.g. CarBravo excludes all electric GM vehicles by
make + engine type) — a model-scoped query alone looks clean. `MAKE_ID 52` = GMC.
`make_id`/`model_id` come from `VIN_DETAIL.MODEL_ID` → `RR_UTILITY.MODEL.MAKE_ID`.
