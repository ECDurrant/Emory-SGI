# Routing — which platform services this case (evidence, not prefix guessing)

*Reference for the `emory` skill, Step 0. Built and verified live 2026-10-01 against
Snowflake `STAGING.EAS` / `STAGING.CMS` / `STAGING.RR_UTILITY` and EAS SQL Server. Every
number here was read from the data on that date; re-run the census queries at the bottom
to refresh it.*

---

## The rule (in order — stop at the first that decides)

1. **Run the router query (R1).** It returns every platform on which this dealer code
   (plus GM BAC variants) has this product **active today**. One row-set per platform.
2. **Exactly one platform returned → that platform services the case.** Run that
   platform's checks. Done.
3. **More than one platform returned →** decide by the **product-code family** table (§2)
   — product codes are disjoint between HCI 1.0 (RR) and HCI 2.0 (EAS), GM is RR-only,
   Honda/Acura rates are EAS-only. If still ambiguous, read the **call log (R3)** for the
   dealer/VIN: the application that answered is the platform that rated it.
4. **Zero rows →** the product is not active for that dealer on any platform. Run R2
   (dealer presence + history) to say *which* of these it is:
   - dealer present, product row exists but end-dated → **Product end-dated** (RC#2);
   - dealer present with **0 product rows ever** → **onboarding shell** (see §4 gap G3);
   - dealer present, never had this product → **Not enrolled** (RC#1);
   - dealer absent everywhere → **Unknown dealer** → resolve by name/phone, else NEEDS REVIEW.

**Never** route on dealer-code prefix alone. Codes are written to several platforms
(EAS∩Legacy ≈ 45.7k, RR∩Legacy ≈ 40.4k dealers). The prefix table in §2 is only a
tie-breaker after R1.

**Never** read `STAGING.RR.*` — that schema stopped syncing in **August 2024** (gap G1).
RoadRunner = `STAGING.RR_UTILITY.*` only.

---

## R1 — router query (Tier 1, Snowflake; one round trip)

```sql
-- {code} = dealer code as given on the case (a bare 5-6 digit GM BAC is expanded to GMF/CB forms)
-- {product} = product code. Returns one row per (platform, enrollment) ACTIVE on {as_of}.
WITH p AS (SELECT UPPER(TRIM('{code}')) code, UPPER(TRIM('{product}')) product, CURRENT_DATE as_of),
k AS (SELECT code c FROM p
      UNION SELECT 'GMF'||RIGHT(code,5) FROM p WHERE code RLIKE '[0-9]{5,6}'
      UNION SELECT 'CB'||code           FROM p WHERE code RLIKE '[0-9]{5,6}'),
eas AS (SELECT 'EAS' platform, v.CMS_DEALER_NUMBER resolved_code, v.DEALER_NAME dealer_name,
               rpc.PROGRAM_ID::varchar program_or_enrol, pg.NAME program_name, rpc.PRODUCT_CODE product,
               dpc.EFFECTIVE_SALE_DATE start_d, dpc.EXPIRATION_SALE_DATE end_d, rpc.CMS_PLC legacy_plc
        FROM STAGING.EAS.V_DEALER v JOIN k ON v.CMS_DEALER_NUMBER = k.c
        JOIN STAGING.EAS.DEALER_PRODUCT_CODE dpc ON dpc.DEALER_ID = v.DEALER_ID
        JOIN STAGING.EAS.REF_PRODUCT_CODE rpc   ON rpc.PRODUCT_CODE_ID = dpc.PRODUCT_CODE_ID
                                               AND rpc.PROGRAM_ID = v.PROGRAM_ID
        JOIN STAGING.EAS.PROGRAM pg ON pg.PROGRAM_ID = rpc.PROGRAM_ID, p
        WHERE rpc.PRODUCT_CODE = p.product
          AND p.as_of BETWEEN dpc.EFFECTIVE_SALE_DATE AND dpc.EXPIRATION_SALE_DATE),
rr AS (SELECT 'ROADRUNNER', d.DEALER_CODE, d.DEALER_NAME, dp.PROGRAM_ID::varchar, pg.PROGRAM_NAME,
              pr.PRODUCT_CODE, dp.EFFECTIVE_DATE_START::date, COALESCE(dp.EFFECTIVE_DATE_END,'3000-01-01')::date, NULL
       FROM STAGING.RR_UTILITY.DEALER d JOIN k ON d.DEALER_CODE = k.c
       JOIN STAGING.RR_UTILITY.DEALER_PRODUCT dp ON dp.DEALER_ID = d.DEALER_ID
       JOIN STAGING.RR_UTILITY.PRODUCT pr        ON pr.PRODUCT_ID = dp.PRODUCT_ID
       JOIN STAGING.RR_UTILITY.PROGRAM pg        ON pg.PROGRAM_ID = dp.PROGRAM_ID, p
       WHERE pr.PRODUCT_CODE = p.product
         AND p.as_of BETWEEN dp.EFFECTIVE_DATE_START AND COALESCE(dp.EFFECTIVE_DATE_END,'3000-01-01')),
lgy AS (SELECT 'LEGACY', d.SG_DRS_DEALER, m.SG_DLR_COMPANY, d.SG_DRS_PLC||'/'||d.SG_DRS_RS, r.SG_RSC_CARRIER,
               r.SG_RSC_PLC, d.SG_DRS_SDATE, d.SG_DRS_EDATE, r.SG_RSC_PLC
        FROM STAGING.CMS.SG_DRS_M1 d JOIN k ON d.SG_DRS_DEALER = k.c
        JOIN STAGING.CMS.SG_RSC_M1 r ON r.SG_RSC_RS = d.SG_DRS_RS
        LEFT JOIN STAGING.CMS.SG_DLR_M1 m ON m.SG_DLR_DEALER = d.SG_DRS_DEALER, p
        WHERE (r.SG_RSC_PLC = p.product
               OR r.SG_RSC_PLC IN (SELECT CMS_PLC FROM STAGING.EAS.REF_PRODUCT_CODE WHERE PRODUCT_CODE = p.product))
          AND d.SG_DRS_SDATE <= p.as_of AND (d.SG_DRS_EDATE = '1799-12-31' OR d.SG_DRS_EDATE >= p.as_of)
          AND r.SG_RSC_SDATE <= p.as_of AND (r.SG_RSC_EDATE = '1799-12-31' OR r.SG_RSC_EDATE >= p.as_of))
SELECT * FROM eas UNION ALL SELECT * FROM rr UNION ALL SELECT * FROM lgy;
```

**Verified 2026-10-01** (each returned exactly the expected platform):

| Case input | Router result |
|---|---|
| `111145` + `CHVS` (bare GM BAC) | ROADRUNNER · `GMF11145` Richard Chevrolet · program 9 GMF |
| `GMF18645` + `BUVS` | ROADRUNNER · program 9 GMF |
| `00SG1055` + `UVPP` | LEGACY · enrolments `PDK/60 PDK` and `ND/60 PDKND`, carrier `VSSG` |
| `AU422A33` + `AUVS` | EAS · 20285 AUDI (dealer is `OOB` in Legacy — status judged on EAS). **Rates FAIL**: only rate system 134 applied (gap G8) |
| `HPPNM027` + `HFCI` | **no rows** → R2 shows an EAS shell with 0 products (gap G3) |

Notes that keep it correct:
- **Legacy has two codes.** `SG_DRS_PLC` is the dealer's *enrolment* plan (e.g. `SAF1`, `PDK`);
  `SG_RSC_PLC` on the rate schedule is the *product* (e.g. `UVPP`, `SAFE`). Match the case's
  product on `SG_RSC_PLC`. `REF_PRODUCT_CODE.CMS_PLC` bridges an EAS product code to its Legacy PLC.
- Legacy open-date sentinel = `1799-12-31`; EAS = `9999-12-31`; RR = `3000-01-01` / NULL.
- An enrolment whose rate schedule is end-dated is filtered out (e.g. `GAIG60` ended 2004).

## R2 — dealer presence + history (when R1 is empty)

```sql
WITH p AS (SELECT UPPER(TRIM('{code}')) code, UPPER(TRIM('{product}')) product),
k AS (SELECT code c FROM p UNION SELECT 'GMF'||RIGHT(code,5) FROM p WHERE code RLIKE '[0-9]{5,6}'
      UNION SELECT 'CB'||code FROM p WHERE code RLIKE '[0-9]{5,6}')
SELECT 'EAS' platform, v.CMS_DEALER_NUMBER code, v.PROGRAM_NAME,
       (SELECT COUNT(*) FROM STAGING.EAS.DEALER_PRODUCT_CODE x WHERE x.DEALER_ID = v.DEALER_ID) products_ever,
       (SELECT MAX(x.EXPIRATION_SALE_DATE) FROM STAGING.EAS.DEALER_PRODUCT_CODE x
          JOIN STAGING.EAS.REF_PRODUCT_CODE r ON r.PRODUCT_CODE_ID = x.PRODUCT_CODE_ID, p
         WHERE x.DEALER_ID = v.DEALER_ID AND r.PRODUCT_CODE = p.product)::varchar this_product_last_end
FROM STAGING.EAS.V_DEALER v JOIN k ON v.CMS_DEALER_NUMBER = k.c
UNION ALL
SELECT 'ROADRUNNER', d.DEALER_CODE, d.DEALER_NAME,
       (SELECT COUNT(*) FROM STAGING.RR_UTILITY.DEALER_PRODUCT x WHERE x.DEALER_ID = d.DEALER_ID),
       (SELECT MAX(COALESCE(x.EFFECTIVE_DATE_END,'3000-01-01')) FROM STAGING.RR_UTILITY.DEALER_PRODUCT x
          JOIN STAGING.RR_UTILITY.PRODUCT r ON r.PRODUCT_ID = x.PRODUCT_ID, p
         WHERE x.DEALER_ID = d.DEALER_ID AND r.PRODUCT_CODE = p.product)::varchar
FROM STAGING.RR_UTILITY.DEALER d JOIN k ON d.DEALER_CODE = k.c
UNION ALL
SELECT 'LEGACY', m.SG_DLR_DEALER, m.SG_DLR_COMPANY,
       (SELECT COUNT(*) FROM STAGING.CMS.SG_DRS_M1 x WHERE x.SG_DRS_DEALER = m.SG_DLR_DEALER),
       (SELECT MAX(x.SG_DRS_EDATE) FROM STAGING.CMS.SG_DRS_M1 x JOIN STAGING.CMS.SG_RSC_M1 r ON r.SG_RSC_RS = x.SG_DRS_RS, p
         WHERE x.SG_DRS_DEALER = m.SG_DLR_DEALER AND r.SG_RSC_PLC = p.product)::varchar
FROM STAGING.CMS.SG_DLR_M1 m JOIN k ON m.SG_DLR_DEALER = k.c;
```
`products_ever = 0` → shell (G3). `this_product_last_end` in the past → end-dated (RC#2).
NULL → never enrolled for this product on that platform (RC#1). Snowflake is a nightly copy:
if the case says "set up today", re-run the EAS half live on SQL Server (Tier 2).

## R3 — call-log evidence: which platform actually answered (Tier 2, SQL Server)

`dbo.BI_V_Ws_Call_log` (live, ~2 months). **Do not use `STAGING.EAS.BI_V_WS_CALL_LOG`** — it
is a one-day snapshot from 2026-05-11 (gap G4). Column names have no underscores
(`WsName`, `ApplicationName`, `Dealer`, `Vin`, `statusCode`, `ErrorCode`, `durationinms`).

```sql
SELECT TOP 50 EntryDate, ApplicationName, WsName, Dealer, Product, Vin, statusCode, ErrorCode,
       LEFT(ErrorDescription, 120) err, durationinms,
       CASE WHEN ApplicationName LIKE 'ContractService3.%'           THEN 'FRONT DOOR (CS3.x SOAP: Legacy rating + EAS fan-out)'
            WHEN ApplicationName IN ('VehicelServiceContract','VSC','eContracting') THEN 'EAS'
            WHEN ApplicationName = 'contractservice3.2'              THEN 'EAS (CS3.2 REST: TOY/LEX/BMW DTC)'
            WHEN ApplicationName LIKE 'gm-save-api%' OR WsName LIKE '%RR' THEN 'ROADRUNNER'
            ELSE 'OTHER' END platform_hit
FROM dbo.BI_V_Ws_Call_log WITH (NOLOCK)
WHERE EntryDate >= DATEADD(day, -14, GETDATE())
  AND (Dealer = '{code}' OR Vin = '{vin}')
  AND WsName IN ('getProductsSGI','getProducts','getRates','geteverything','getEverything',
                 'getRateFromMule','getSpecificRateRR','saveContract','saveEContract','saveContractWithMule')
ORDER BY EntryDate DESC;
```

**How one deal appears (verified on `HN206688`, 2026-10-01):** three rows ~20 ms apart whose
durations nest — `ContractService3.1 getProductsSGI` (outer, longest) → `VehicelServiceContract
getProducts` → `VSC geteverything` (inner). CS3.1 is the partner-facing SOAP front door; the
VehicelServiceContract child row means **EAS was asked**. Read every row of the chain before
blaming a partner. GM traffic is separate (`gm-save-api.sgproductsapis.co` → `getRateFromMule`
/ `saveContractWithMule`), and RR e-form quotes appear as `getSpecificRateRR`.

---

## §2 — OEM / program → platform → rate source (census 2026-10-01)

"Active dealers" = dealers with ≥1 product active today on that platform/program.

### RoadRunner (`STAGING.RR_UTILITY`)

| RR prog | Program | Active dealers | Product-code family | Dealer-code prefixes | Rate table (active rows) |
|---|---|---|---|---|---|
| 1 | HYUNDAI (HCI 1.0) | 1,067 | `HY**` `EH**` `ED**` `HS**` `HD**` `GE**` `PP**` | `HYU` `HYN` `0HY` `0PP` | `RATE_SKU_HCI` (2.42M) |
| 2 | GENESIS (HCI 1.0) | 348 | `GE**` `GD**` `EG**` `ED**` `PP**` | `GEN` `0GF` | `RATE_SKU_HCI` (2.32M) |
| 3 | KIA (HCI 1.0) | 338 | `PK**` `EK**` `KI**` `PP**` | `0KM` | `RATE_SKU_HCI` (2.36M) |
| 4 | CARBRAVO | 3,315 | `CB**` | `CB*` `GMF` `GM9` | `RATE_SKU_GM` (626k) |
| 5–8 | D2C GMC / CHEVY / BUICK / CADILLAC | 51 each | `GMVD` `CHVD` `BUVD` `CAVD` | `GMC` `CHE` `BUI` `CAD` | `RATE_SKU_D2C` |
| 9 | GMF | 3,307 | `BU**` `CA**` `CH**` `GM**` `NO**` | `GMF` `GMJ` | `RATE_SKU_GM` (1.49M) |
| 10 | GM WHITE LABEL | 0 | — | — | `RATE_SKU_GM` (648) |
| 39 | Acura US | 205 | `AR**` | `ACC` `AC2` | `RATE_SKU_HONDA` — **0 active** (G5) |
| 40 | Honda US | 764 | `HN**` | `HN1` `HN2` `HNB` | `RATE_SKU_HONDA` — **0 active** (G5) |
| 41 | GMF CANADA | 21 | `GCWC` | `GC1-3` | `RATE_SKU_GM` (4) |
| 74 | ACF | 34 | GM family | `ACF` | `RATE_SKU_GM` (1.47M) |

Pick the RR rate table from `RR_UTILITY.PROGRAM.ECOM_DB`: `HCI`→`RATE_SKU_HCI`, `GM`→`RATE_SKU_GM`,
`GM_D2C`→`RATE_SKU_D2C`, `HONDA`→`RATE_SKU_HONDA`.

### EAS — programs with active dealers, and where their rates live

EAS prices **two ways**. Check 5b must use the right one (see `rates_layer.md`):
- **RATE_SKU path** — a per-program/carrier table `RATE_SKU_<x>` (+ `RATE_SKU_ELIGIBILITY_<x>`).
- **PRICE_HEADER path** — `PRODUCT_PLAN → PRODUCT_PLAN_SKU → PRODUCT_PLAN_SKU_PRICE_HEADER`
  (keyed by `RATE_SYSTEM_ID`, own sale window) → `PRODUCT_PLAN_SKU_PRICE` (284M rows).
  Programs with no RATE_SKU table use this (Mazda, RPM, Fuel Capital, Rolls-Royce, Cover My Car…).

| EAS prog | Program | Active dealers | Rate source (Snowflake unless noted) |
|---|---|---|---|
| 20307 | MOPAR Vehicle Protection | 3,575 | `RATE_SKU_MOPAR` + PRICE_HEADER (121 active) |
| 20377 | Amazon Autos | 1,725 | `RATE_SKU_AMAZON` |
| 20268 | Toyota (TFS) | 1,533 | `RATE_SKU_TFS` |
| 20284 | VOLKSWAGEN | 1,244 | `RATE_SKU_VCI` + PRICE_HEADER (1,409 active) |
| 20350 | Honda (AHFC) | 794 | `RATE_SKU_HONDA2O` (3.0M active) |
| 20276 | Harley-Davidson US | 775 | `RATE_SKU_HARLEYDAVIDSON` |
| 20378 | HYUNDAI PROTECTION PLAN (HCI 2.0) | 747 | `RATE_SKU_HCI2O` (330k active) |
| 20285 | AUDI | 726 | `RATE_SKU_VCI` |
| 20320 | MAZDA | 637 | PRICE_HEADER (16,422 active) — `RATE_SKU_MAZDA` exists only as an empty `_Archive` |
| 20376 | SG Agents | 605 | **SQL Server only** `dbo.Rate_sku_SG_Agents` (1.77M active) |
| 20324 | Fuel Capital Protect | 542 | PRICE_HEADER (206 active) |
| 20330 / 20329 | RPMPlusSport / RPMPlus | 519 / 257 | PRICE_HEADER (856 / 7,253) |
| 20336 | YAMAHA | 479 | `RATE_SKU_YAMAHA` |
| 20316 / 20317 | BMW / MINI US | 414 / 143 | `RATE_SKU_BMW` |
| 20372 | MOPAR Canada | 402 | `RATE_SKU_MOPAR` |
| 20265 | PORSCHE US | 328 | `RATE_SKU_PBL` |
| 20389 | LITHIA DRIVEWAY (NVR) | 321 | **SQL Server only** `dbo.RATE_SKU_LITHIA_NVR` (15 active) |
| 20282 / 20283 | DUCATI / QUALITY PROTECT | 299 / 262 | `RATE_SKU_VCI` |
| 20310 | SUBARU | 299 | `RATE_SKU_SUBARU` |
| 20343 | GOOD SAM / CAMPING WORLD | 286 | `RATE_SKU_CAMPING_WORLD` |
| 20380 | POWERPROTECT (Kia PPES, HCI 2.0) | 262 | `RATE_SKU_HCI2O` |
| 20298 / 20299 | HONDA / ACURA CANADA | 260 / 59 | `RATE_SKU_HONDACANADA` |
| 20273 | QualityGuard (Nissan/Infiniti CA) | 247 | **SQL Server only** `dbo.RATE_SKU_NISSAN_CA` (1,982 active) |
| 20351 | Acura (AHFC) | 217 | `RATE_SKU_HONDA2O` |
| 20379 | GENESIS PROTECTION PLAN (HCI 2.0) | 210 | `RATE_SKU_HCI2O` |
| 20346 | ExtraProtect US | 206 | `RATE_SKU_CAG_EXTRAPROTECT` + `RATE_SKU_SG_NVR` |
| 20296 | BMW/MINI CANADA | 87 | PRICE_HEADER — **0 active; every header expired 2022-12-31** (G6) |
| 10240 | SG US | 43 | PRICE_HEADER (66,275) |
| GM 20345 / 20348 / 20371 | CARBRAVO / GM / ACF on EAS | **0** | none — GM lives on RoadRunner |

Full 120-program census (product lists included): re-run C1 / C1b below.

### OEM → where to look first (tie-breaker after R1)

| OEM / channel | Platform | Decided by |
|---|---|---|
| GM (Chevrolet, Buick, GMC, Cadillac, CarBravo, ACF, GM D2C) | **RoadRunner** | EAS GM programs have 0 active dealers |
| Hyundai / Kia / Genesis — product `HF**` `KF**` `GF**` `WF**` `HCV*` `KCV*` `GCV*` `HP**` `GP**` | **EAS** (HCI 2.0, 20378-20381, 20391-20392) | product code |
| Hyundai / Kia / Genesis — product `HY**` `EH**` `GE**` `PK**` `PP**` `ED**` `HS**` `EK**` | **RoadRunner** (HCI 1.0, prog 1-3) | product code |
| Honda / Acura US | **EAS** 20350 / 20351 | RR Honda rate tables have 0 active rows since 2025-12-24 |
| VW / Audi / Ducati / Quality Protect | EAS (`RATE_SKU_VCI`) | — |
| BMW / MINI / Motorrad, Porsche / Bentley / Lamborghini, Toyota / Lexus, Subaru, Mopar, Harley, Yamaha, Aston Martin, Amazon | EAS | — |
| SG Agents (`00S*`) | EAS 20376 (rates SQL Server only) — Legacy plans ended 2026-09-18 | see memory note on the cut-over |
| Anything else with only Legacy presence | Legacy / Forte | R1 returns LEGACY only |

---

## §4 — Gaps found while building this (2026-10-01) — status OPEN unless noted

| # | Gap | Evidence | Effect on Emory | Owner |
|---|---|---|---|---|
| G1 | `STAGING.RR.*` is frozen: last sync 2024-08-13 (DEALER_PRODUCT 331,882 vs live 457,750; FORM_PRODUCT_STATE 17,516 vs 34,139) | `SR_PROCESS_TIME` / `RR_CHANGED_DATE` maxima | Every RR check that read `STAGING.RR` was up to 2 years stale. **Fixed in the skill: all RR reads now use `RR_UTILITY`.** Ask data eng to drop or label the dead schema. | Data Eng (Snowflake) |
| G2 | Three EAS rate tables are not replicated to Snowflake: `Rate_sku_SG_Agents`, `RATE_SKU_LITHIA_NVR`, `RATE_SKU_NISSAN_CA` | SQL Server `INFORMATION_SCHEMA` vs Snowflake | Rates for programs 20376 / 20389 / 20273 must be read on SQL Server | Data Eng |
| G3 | 2026-07-24 HCI 2.0 onboarding shells still have **no products**: PPES 20380 559/560, HPP 20378 235/292, GPP 20379 48/105, Power Protect 20381 16/17 | SQL Server `V_DEALER` LEFT JOIN `Dealer_Product_Code` | Any request on those codes → 404 / empty products; config, not API | Acct Mgmt / HCI onboarding |
| G4 | `STAGING.EAS.BI_V_WS_CALL_LOG` is a one-day snapshot (2026-05-11) | `MIN/MAX(ENTRYDATE)` | Call-log evidence must come from SQL Server `dbo.BI_V_Ws_Call_log` | Data Eng |
| G5 | RR Honda/Acura (prog 39/40): 969 dealers enrolled, `RATE_SKU_HONDA` 0 active rows (last change 2025-12-24) | RR census | Expected if Honda moved to EAS HONDA2O; confirm the RR enrolments are retired, not a live outage | Rates & Forms |
| G6 | BMW/MINI Canada (20296): 86-87 dealers actively enrolled on 8 products, every price header expired 2022-12-31 | SQL Server PRICE_HEADER | Any BMBC/BMCV/MNCC… quote on EAS cannot rate. Confirm whether the program moved; if so end-date the enrolments | Rates & Forms / BMW CA program |
| G8 | 143 Audi dealers (program 20285) are applied only to the retired AUVS rate system **134**; the live rates moved to the tiered systems 3403-3414 (T1/T2/T3) on 2024-08-08 | 143 "134-only" dealers sold **0** AUVS since 2025-01-01 vs 310 of 469 tiered dealers (22,533 contracts); e.g. `AU422A33` | AUVS cannot rate for those dealers; many may be closed (AU422A33 is OOB in Legacy) — confirm and either re-apply the tiered rate system or end-date the product | Rates & Forms / Acct Mgmt |
| G7 | Forte Postgres unreachable without GlobalProtect (TCP 5432 timeout) | psycopg2 timeout 2026-10-01 | Legacy checks run on `STAGING.CMS` (same-day replica); live Postgres only for same-day edits | Analyst (VPN) |

---

## Census queries (re-run to refresh §2)

- **C1 — EAS programs × active dealers × products (Snowflake):**
```sql
SELECT p.PROGRAM_ID, p.NAME, p.CMS_AGENT, p.BRANDED_MAKE,
       (SELECT COUNT(DISTINCT dpc.DEALER_ID) FROM STAGING.EAS.DEALER_PRODUCT_CODE dpc
          JOIN STAGING.EAS.REF_PRODUCT_CODE rpc ON rpc.PRODUCT_CODE_ID = dpc.PRODUCT_CODE_ID
         WHERE rpc.PROGRAM_ID = p.PROGRAM_ID
           AND CURRENT_DATE BETWEEN dpc.EFFECTIVE_SALE_DATE AND dpc.EXPIRATION_SALE_DATE) AS active_dealers,
       (SELECT LISTAGG(DISTINCT x.PRODUCT_CODE, ',') WITHIN GROUP (ORDER BY x.PRODUCT_CODE)
          FROM STAGING.EAS.REF_PRODUCT_CODE x WHERE x.PROGRAM_ID = p.PROGRAM_ID) AS products
FROM STAGING.EAS.PROGRAM p ORDER BY active_dealers DESC;
```
  Rate source per program: `SELECT DISTINCT PROGRAM_ID FROM STAGING.EAS.RATE_SKU_<x>` for each
  `RATE_SKU_%` table (list them from `STAGING.INFORMATION_SCHEMA.TABLES`), plus C1b for price headers:
```sql
SELECT pp.PROGRAM_ID, COUNT(DISTINCT h.RATE_SYSTEM_ID) rate_systems,
       SUM(CASE WHEN CURRENT_DATE BETWEEN h.SALES_EFFECTIVE_DATE AND h.SALES_EXPIRATION_DATE THEN 1 ELSE 0 END) active_headers
FROM STAGING.EAS.PRODUCT_PLAN pp
JOIN STAGING.EAS.PRODUCT_PLAN_SKU s ON s.PRODUCT_PLAN_ID = pp.PRODUCT_PLAN_ID
JOIN STAGING.EAS.PRODUCT_PLAN_SKU_PRICE_HEADER h ON h.PRODUCT_PLAN_SKU_ID = s.PRODUCT_PLAN_SKU_ID
GROUP BY 1 ORDER BY 1;
```
- **C2 — RR programs × active dealers × products × prefixes (Snowflake):**
```sql
SELECT dp.PROGRAM_ID, pg.PROGRAM_NAME, pg.ECOM_DB, COUNT(DISTINCT dp.DEALER_ID) active_dealers,
       LISTAGG(DISTINCT pr.PRODUCT_CODE, ',') WITHIN GROUP (ORDER BY pr.PRODUCT_CODE) products,
       LISTAGG(DISTINCT LEFT(d.DEALER_CODE, 3), ',') code_prefixes
FROM STAGING.RR_UTILITY.DEALER_PRODUCT dp
JOIN STAGING.RR_UTILITY.PRODUCT pr ON pr.PRODUCT_ID = dp.PRODUCT_ID
JOIN STAGING.RR_UTILITY.PROGRAM pg ON pg.PROGRAM_ID = dp.PROGRAM_ID
JOIN STAGING.RR_UTILITY.DEALER d   ON d.DEALER_ID  = dp.DEALER_ID
WHERE CURRENT_DATE BETWEEN dp.EFFECTIVE_DATE_START AND COALESCE(dp.EFFECTIVE_DATE_END,'3000-01-01')
GROUP BY 1, 2, 3 ORDER BY 1;
```
- **C3 — onboarding shells (G3), SQL Server:**
```sql
WITH d AS (SELECT v.Program_ID, v.Program_Name, CAST(v.Dealer_Start_Date AS date) start_d,
                  CASE WHEN p.Dealer_ID IS NULL THEN 1 ELSE 0 END zero
           FROM dbo.V_DEALER v
           LEFT JOIN (SELECT DISTINCT Dealer_ID FROM dbo.Dealer_Product_Code) p ON p.Dealer_ID = v.Dealer_ID
           WHERE v.Dealer_End_Date > GETDATE() AND v.Out_of_Business_Date > GETDATE())
SELECT Program_ID, Program_Name, start_d, COUNT(*) dealers, SUM(zero) zero_products
FROM d GROUP BY Program_ID, Program_Name, start_d HAVING SUM(zero) >= 10 ORDER BY zero_products DESC;
```

---

## Calibration log

| Date | Test | Result |
|---|---|---|
| 2026-10-01 | 300 dealers that sold a contract in the previous 2 days (`dbo.BI_V_Ws_Call_log`, statusCode 200): 150 via EAS (`VehicelServiceContract` / `contractservice3.2` `saveContract`), 150 via RoadRunner (`gm-save-api*` `saveContractWithMule`), random sample, seed 20261001 | **Updated router: 300 / 300** active on the platform that served them. **Old RR source (`STAGING.RR`): 127 / 150** — 23 selling GM dealers (15%) would have been reported "not enrolled". |
| 2026-10-01 | Six known cases (`111145`/`CHVS`, `GMF18645`/`BUVS`, `00SG1055`/`UVPP`, `AU422A33`/`AUVS`, `HPPNM027`/`HFCI`, `MAZ42024`/`MZSP`) | All six routed and checked as expected |

Re-run monthly (or after any platform migration) with the same method; product-level calibration needs the
product parsed from `RequestText`, because the log's `Product` column is empty for these calls.
