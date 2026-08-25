# Rating Request Attributes — domains, platform applicability, and how they actually gate/price

Covers the non-identifying attributes on a rates call (`financeType`, `financeAmount`,
`financeTerm`, `vehicleCondition`, `vehicleUsage`, `isAfterSale`, `customerState`, `odometer`,
`vehiclePurchaseDate`, `vehicleMSRP`, `vehiclePurchasePrice`) — what values are valid, which
platforms even accept them at rating time, and which DB tables enforce their effect. Built
2026-08-19 from (a) live Postman collections (VCI-PEN, FIE HCI MERCURY PROD, BMW PEN, PEN
LITHIA, GM PROD/UAT) and (b) direct SQL Server schema/data queries. Sourced from real data —
not vendor documentation (none exists in Postman/Confluence for this).

---

## 1. Which platforms even take these as rates-time inputs

**Not universal.** Only the Darwin/PEN-style `GET .../<product>/rates/v1` connectors expect the
caller to supply finance/vehicle context at rating time:

| Platform / vendorName | Rates call shape | Takes financeType/vehicleCondition/etc.? |
|---|---|---|
| PEN_VCI (Audi/Porsche/VW) | `GET .../vci/rates/v1` query string | **Yes** — full set confirmed incl. `vehicleUsage`, `customerState`, `financeTerm`, `financeAmount`, `vehicleMSRP`, `vehiclePurchasePrice` |
| FIE_HCI (Hyundai) | `GET .../hci/rates/v1` query string | **Yes** — identical field names to PEN_VCI, plus HCI-only `vehicleModel/Year/Make/Trim`, `vehicleCost`, `lienholderName`, `programName`, `programType`. `vehiclePurchasePrice` only reappears later in the contract POST body, not on the rates GET. |
| PEN_BMW | `GET .../bmw/rates/v1` query string | **Partially confirmed** — one saved example has `financeType`, `vehicleCondition`, `isAfterSale`; no saved example shows `vehicleUsage`/`customerState`/`financeTerm`/`financeAmount`/`vehicleMSRP`/`vehiclePurchasePrice` on the rates call itself (those only appear in the saveContract body). Don't assume BMW ignores them — only that no example proves it accepts them. |
| PEN_LITHIA | `GET .../lithia/rates/v1` query string | **No.** Only `saleDate`, `sellerId`, `vin`, `vendorName`, `channel`. Finance/vehicle-condition fields exist only in the later saveContract POST body — the rates step doesn't take them. |
| GM (RoadRunner, `gm-rates.sgproductsapis.com/api/v1/rates`) | `GET` query string | **No.** Only `saleDate`, `dealer`, `odometer`, `vin`, `vendorName`, `channel`. No finance/vehicle-condition equivalent anywhere in the saved requests — resolved server-side from VIN/dealer/program, not caller-supplied. |

**Implication for Emory:** before telling a case owner "check whether financeType=X is the
issue," confirm the case is on a PEN_VCI/FIE_HCI-style connector. On Lithia/GM/RoadRunner cases
that attribute isn't even in play at the rates step — look at eligibility/classing instead.

---

## 2. Confirmed valid domains (from live SQL Server data, not guessed)

| Attribute | Confirmed values | Notes |
|---|---|---|
| `financeType` / `Finance_Type` | `CASH`, `FINANCE`, `LEASE`, `BALLOON`, `REVOLVING` (blank = unspecified/unrestricted) | Case varies across systems (`Cash`, `CASH`, `Finance` all seen) — normalize to uppercase when comparing. |
| `vehicleCondition` / `Vehicle_Condition` | `NEW`, `USED`, `CPO`, `DEMO`, `*` (wildcard = applies to all conditions), blank | `*` and blank both mean "unrestricted," not "no condition" — don't treat as a data gap. |
| `isAfterSale` | `Y` / `N` (or `TRUE`/`FALSE` string depending on API vs DB layer), blank = not gated | API payload uses `TRUE`/`FALSE`; DB eligibility tables use `Y`/`N`. |
| `vehicleUsage` | `PERSONAL`, `COMMERCIAL` | Raw contract data (`eCon_Contract.usage_type`) also contains `Residential`, `Commerical` (typo), and junk (`true`/`false`/`A`/`ABC`) — these are data-entry noise, not real domain values. Treat the real domain as PERSONAL/COMMERCIAL only. |
| `financeTerm` / `financeAmount` / `vehicleMSRP` / `vehiclePurchasePrice` / `odometer` | Numeric, no fixed enum | These select **price bands**, not eligibility categories — see §3. `999` is a seen `financeTerm` sentinel (likely "not applicable"/open-ended, same pattern as other SGI date/term sentinels — verify per-case, don't assume it's a real 999-month term). |

---

## 3. How they actually affect what comes back (DB evidence)

Two different mechanisms, in two different table families — don't conflate them:

**a) Hard exclusion (product doesn't appear at all)** — `Program_Product_Eligibility.Exclusion_Type`
has literal values keyed on these exact attributes:
- `FINANCETYPE` — excludes a program/product for a specific `Finance_Type` alone (confirmed rows
  keyed on BALLOON, LEASE, REVOLVING, CASH, FINANCE).
- `FINANCETYPEVEHICLECONDITION` — excludes for a **combination** of `Vehicle_Condition` +
  `Finance_Type` (e.g., confirmed rows excluding DEMO+FINANCE, NEW+LEASE, CPO+LEASE).
- Same pattern repeats per-OEM in `Rate_SKU_Eligibility_<OEM>` (VCI, BMW, HCI2O, PBL, MOPAR,
  Subaru, Yamaha, Harley-Davidson, etc.) — each carries its own `finance_type` /
  `vehicle_condition_id` / `IS_ELIGIBLE_AFTER_SALE` columns, gated independently per OEM.
- Also gated (broader rule engine): `program_product_eligibility_rule` — adds `vehicle_usage`,
  `Finance_term_from/to`, `odometer_from/to`, `vehicle_age_from/to` on top of the same
  finance_type/aftersale/vehicle_condition trio, per program+product+plan.

**b) Price banding (product appears, but at a different rate)** —
`Product_Plan_Sku_Price_Parameter` keys the regulated/retail rate off `Finance_amount_from/to`,
`Finance_type_id`, `Vehicle_Condition_ID`, `MSRP_from/to`, `Odometer_from/to`,
`Vehicle_Age_From/To`. So `financeAmount`, `vehicleMSRP`, and `odometer` aren't just pass-through
— they select which price-parameter row (and therefore which rate) applies.

**Most rows are blank/wildcard = unrestricted.** This matches the existing Check 5b caveat in
`SKILL.md` for `RATE_SKU_<OEM>` term/class bands — don't read a blank `Vehicle_Condition` or
`finance_type` as "broken," it means "not gated on this dimension." Only when a specific
exclusion or price-parameter row exists for the case's program+product does the attribute
actually change the outcome — **check the OEM's own `Rate_SKU_Eligibility_<OEM>` and
`Product_Plan_Sku_Price_Parameter` rows for the specific program_id/product_code**, don't assume
from the global domain list above.

---

## 3b. Product × financeType exclusions are real, per-OEM-program, and usually just common sense

Pulled all 663 `FINANCETYPE`/`FINANCETYPEVEHICLECONDITION` exclusion rows in
`Program_Product_Eligibility` and joined to `Program.Name`. **29 OEM/carrier programs** have at
least one such rule — confirmed real names include: Hyundai Protection Plan, Genesis Protection
Plan, BMW US (Group) Financial Services, BMW US MINI Group Financial Services, Land Rover,
Jaguar, Aston Martin North America, Harley Davidson Services USA, Yamaha Protection Plan,
PowerProtect Extended Services, Honda/Acura - American Honda Finance Corp, MOPAR Vehicle
Protection - Canada, and others.

**This is not arbitrary — it mostly encodes obvious product logic**, confirmed by joining to
`Ref_Product_Code.Description` for Hyundai Protection Plan (program 20379-equivalent):

| Product (code) | Excluded Finance_Type(s) | Reading |
|---|---|---|
| HPP GAP (`HFGP`) | BALLOON, CASH, LEASE | GAP only makes sense on a **financed** loan — cash buyers and lease customers don't have a loan-value gap to cover. |
| HPP GAP Circle (`HFEG`) / GAP Plus Circle (`HFES`) | BALLOON, CASH, LEASE | Same GAP logic — FINANCE only. |
| HPP Lease Protection (`HFLP`) | BALLOON, CASH, FINANCE | Inverse of GAP — it's a lease-specific product, so only **LEASE** is allowed. |
| HPP EV VSP (`HFVE`) | BALLOON, LEASE | Narrower — allowed on CASH/FINANCE only. |

**So the practical rule of thumb for Emory:** a GAP-family product missing on a lease deal, or a
Lease-Protection-family product missing on a financed/cash deal, is very likely this exclusion
working as designed — not a bug. Confirm by name/description before calling it a defect.

**Don't build this into a static master table — query it live per case instead**, because the
rule set is scoped to the case's actual `program_id` + `product_code` (the same 4-letter product
code repeats across dozens of unrelated programs with different exclusion sets each), and the
663 rows change over time as programs are added/edited:

```sql
-- Is {product_code} excluded for {finance_type} (and optionally {vehicle_condition}) under this case's program?
SELECT e.Exclusion_Type, e.Vehicle_Condition, e.Finance_Type, e.Is_Excluded,
       rpc.Description AS Product_Description
FROM Program_Product_Eligibility e
LEFT JOIN Ref_Product_Code rpc
       ON rpc.Product_Code = e.Product_Code AND rpc.Program_ID = e.Program_ID
WHERE e.Program_ID = {program_id}
  AND e.Product_Code = '{product_code}'
  AND e.Exclusion_Type IN ('FINANCETYPE','FINANCETYPEVEHICLECONDITION')
  AND (e.Finance_Type = '{finance_type}' OR e.Finance_Type = '')
  AND ('{as_of}' BETWEEN e.Sales_Effective_Date AND e.Sales_Expiration_Date);
```
A row with `Is_Excluded = True` matching the case's finance type = the product is correctly
absent, not a config gap. No matching row = not gated on finance type at all for this
program/product — look elsewhere (rate SKU, classing, forms).

---

## 4. What we still can't prove from existing data — and how to get it

Every saved Postman example (except VCI-PEN) has **zero saved response bodies** — collections are
request-templates only. Even VCI-PEN's three saved responses each vary VIN, MSRP, term, *and*
financeType/vehicleCondition simultaneously, so you can't isolate which input caused a given
product/SKU count to differ (7–13 products / ~200–660 SKU rows across the three examples, no
single-variable comparison).

**To get a controlled before/after** (e.g., "does switching only financeType from FINANCE to
LEASE drop coverage X"), someone needs to live-fire the rates endpoint twice with every other
field held constant — via the analyst's own Postman app, or replicated `curl`/`Invoke-RestMethod`
per the live-fire method in `emory-postman-verification` memory (mint a fresh bearer token each
time; there's no execute tool on the Postman MCP). Save the resulting request+response pairs back
into the relevant Postman collection so this reference can be extended with real before/after
evidence instead of DB-schema inference alone.
