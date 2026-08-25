# VIN decode & vehicle classing

*Reference for the `emory` skill. Read this when SKILL.md points you here — it is the
full detail for that step, moved out so the main workflow stays readable.*

---

### Check 6 — Vehicle classing / eligibility

**VIN decode** (Snowflake `STAGING.CMS.VIN_DETAILS`; squished pattern = positions
1–8 + 10–11, check digit dropped):
```sql
SELECT YEAR, MAKE, MODEL, TRIM, DRIVE_TYPE, VEHICLE_TYPE, FUEL_TYPE,
       ENGINE_ASPIRATION, ENGINE_SIZE
FROM STAGING.CMS.VIN_DETAILS
WHERE VIN_PATTERN = LEFT('{vin}',8) || SUBSTR('{vin}',10,2)
  AND IS_ACTIVE = 'Y'
  AND '{as_of}' BETWEEN EFFECTIVE_FROM AND COALESCE(EFFECTIVE_TO,'{as_of}');
```

**Legacy classing** (Snowflake `STAGING.CMS.VSC_CLASS_M1`; trim/drivetrain are
embedded in `VSC_CLASS_MODEL` — match with tokens/`LIKE`, not equality; class can
differ by `VSC_CLASS_RGROUP`, and the dealer's rate group breaks the tie):
```sql
SELECT VSC_CLASS_CAR, VSC_CLASS_MAKE, VSC_CLASS_MODEL, VSC_CLASS_SYEAR,
       VSC_CLASS_EYEAR, VSC_CLASS_CLASS, VSC_CLASS_RGROUP
FROM STAGING.CMS.VSC_CLASS_M1
WHERE VSC_CLASS_CAR = '{carrier}' AND VSC_CLASS_MAKE = '{make}'
  AND {year} BETWEEN VSC_CLASS_SYEAR AND VSC_CLASS_EYEAR
  AND UPPER(VSC_CLASS_MODEL) LIKE '%'||UPPER('{model_token}')||'%';
```

**EAS classing:** **Always search Tier 2 first, then confirm with Snowflake.**
- **Primary (Tier 2 — live SQL Server):** `dbo.V_PROGRAM_VEHICLE_CLASS` is the
  authoritative name-based view (`Make`, `Model`, `TrimLevel`, `ClassingMethod`,
  `Is_Exclusion`, `Product_Code`, `Effective_Date`, `Expiration_Date`). Query this
  **first** to get the definitive match and cite the exact row. This ensures you have
  the latest classing data (no nightly sync delay) and correct nomenclature.
- **Secondary (Tier 1 — Snowflake fallback/confirm):** Snowflake has `PROGRAM_VEHICLE_CLASS`
  (class list) + `PROGRAM_VEHICLE_CLASS_MAPPING` (eligibility rows), but the mapping is
  **ID-normalized** and the reference dictionaries are **not replicated** — only use
  Snowflake *after* you've found a row in Tier 2, as a final confirmation that the row
  is present and active. **Never search Snowflake first for classing or rely on
  `RR_UTILITY` id chains** — they return WRONG makes (~42% accuracy).
- **Automated Flow path:** once the replication owner materializes `STAGING.EMORY.PROGRAM_VEHICLE_CLASS`
  (spec: `Downloads\EMORY_CLASSING_LAYER.sql`, ~166k rows), the Flow can use that. Until then,
  the Flow marks Check 6 **NEEDS REVIEW** and the interactive skill runs Tier 2.

**EAS classing query (Tier 2, run this first):
```sql
-- Tier 2 (SQL Server, PRIMARY — run this first). {program_id} from V_Rate_System_Application anchor.
-- Match make/model by TOKEN, never by '=' — table stores MERCEDES-BENZ (not 'MERZ'/'MB'),
-- GLA / GLA-CLASS (not 'GLA250'). Equality silently returns zero rows.
SELECT DISTINCT Class_Code, ClassingMethod, Model_Year_From, Model_Year_To,
       Make, Model, TrimLevel, Is_Exclusion, Effective_Date, Expiration_Date
FROM dbo.V_PROGRAM_VEHICLE_CLASS
WHERE program_id = {program_id}
  AND (Product_Code = '{product_code}' OR Product_Code IS NULL)
  AND (Make = '{make_normalized}' OR Make = 'ALL MAKES')
  AND (Model LIKE '%'+'{model_token}'+'%' OR '{model_token}' LIKE '%'+Model+'%'
       OR Model = 'ALL MODELS')
  AND {year} BETWEEN ISNULL(NULLIF(Model_Year_From,0),1900)
                 AND ISNULL(NULLIF(Model_Year_To,0),9999)
  AND GETDATE() BETWEEN ISNULL(Effective_Date, GETDATE())
                    AND ISNULL(Expiration_Date, GETDATE());
```

**Then confirm with Tier 1 (Snowflake) if the EAS query returned results:**
```sql
-- Tier 1 (Snowflake, SECONDARY CONFIRMATION). Run only after finding a match in Tier 2 above.
SELECT DISTINCT Class_Code, ClassingMethod, Model_Year_From, Model_Year_To,
       Make, Model, TrimLevel, Is_Exclusion, Effective_Date, Expiration_Date
FROM STAGING.EAS.PROGRAM_VEHICLE_CLASS
WHERE PROGRAM_ID = {program_id}
  AND (PRODUCT_CODE = '{product_code}' OR PRODUCT_CODE IS NULL)
  AND (MAKE = '{make_normalized}' OR MAKE = 'ALL MAKES')
  AND (MODEL LIKE '%' || UPPER('{model_token}') || '%' OR UPPER('{model_token}') LIKE '%' || MODEL || '%'
       OR MODEL = 'ALL MODELS')
  AND {year} BETWEEN COALESCE(MODEL_YEAR_FROM, 1900) AND COALESCE(MODEL_YEAR_TO, 9999)
  AND CURRENT_DATE BETWEEN COALESCE(EFFECTIVE_DATE, CURRENT_DATE)
                       AND COALESCE(EXPIRATION_DATE, CURRENT_DATE);
```
**Cite both the Tier 2 result (primary) and note if Snowflake confirmation succeeded.** If Tier 2 returns nothing, state that explicitly in the verdict rather than retrying with alternate clauses — a genuine classing gap is worth flagging as NEEDS REVIEW.
- **Normalize before matching** (this is where classing lookups fail):
  - Make: map the VIN-decoded make to the classing vocabulary
    (`MERZ`/`MB` → `MERCEDES-BENZ`, `CHEV` → `CHEVROLET`, …). When unsure, widen with
    `Make LIKE` on a distinctive token and confirm against the `ALL MAKES` fallback.
  - Model: strip the trim/engine digits — VIN `GLA250` → token `GLA` (also matches
    `GLA-CLASS`); match by substring **both directions** as above.
  - Trim: Audi `45 TFSI` ↔ `2.0T`, `55 TFSI` ↔ `3.0T`.
- `Is_Exclusion = 'Y'` on the matching row → **not eligible** (FAIL, OEM Program Team).
- Exactly one eligible match → report `Class_Code` and cite the row (PASS).
- Zero rows after normalization + catch-alls → **NEEDS REVIEW** (genuine classing gap,
  e.g. the SQ8 e-tron missing on the CPO Term product) — state the make/model/program
  you searched so a human can confirm nomenclature vs. a real gap.
- Several conflicting classes → **NEEDS REVIEW** (trim/rate-group tiebreak).
