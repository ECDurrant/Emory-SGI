# The rates layer — tables, SKU decode & live-fire

*Reference for the `emory` skill. Read this when SKILL.md points you here — it is the
full detail for that step, moved out so the main workflow stays readable.*

---

### Check 5 — Rates  (two parts; see the dedicated rates layer)

> For a case turning on `financeType`/`vehicleCondition`/`vehicleUsage`/`isAfterSale`/
> `financeAmount`/`odometer`/etc. — which platforms even take them at rating time, confirmed
> valid values, and which tables actually gate/price on them (`Program_Product_Eligibility`
> Exclusion_Type = FINANCETYPE / FINANCETYPEVEHICLECONDITION, per-OEM
> `Rate_SKU_Eligibility_<OEM>`, `Product_Plan_Sku_Price_Parameter`) — see
> `rating_attributes_reference.md`.

**5a. Rate system assigned?** (EAS, Snowflake)
```sql
SELECT rsa.RATE_SYSTEM_ID, rs.NAME AS rate_system_name, rsa.PROGRAM_ID,
       rs.PRODUCT_CODE_ID, rsa.DEALER_ID, rsa.AGENT_ID,
       rsa.SALES_EFFECTIVE_DATE, rsa.SALES_EXPIRATION_DATE,   -- informational only; DO NOT gate on these
       rs.IS_TIERED, rs.RATE_TIER, rs.IS_DEFAULT
FROM STAGING.EAS.RATE_SYSTEM_APPLICATION rsa
JOIN STAGING.EAS.RATE_SYSTEM rs ON rs.RATE_SYSTEM_ID = rsa.RATE_SYSTEM_ID
WHERE (rsa.DEALER_ID = {dealer_id} OR rsa.DEALER_ID IS NULL)   -- assignment can be dealer-, agent-, or program-level
  AND rsa.PROGRAM_ID = {program_id}
  AND rs.PRODUCT_CODE_ID = {product_code_id};                  -- product scope is on RATE_SYSTEM, NOT the application
```
> **⚠ Do NOT gate 5a on `SALES_EFFECTIVE/EXPIRATION_DATE`.** Verified 2026-08: **~35% of
> `RATE_SYSTEM_APPLICATION` rows carry stale windows** (2016 migration stubs / single-day dates)
> even when the dealer rates fine today — e.g. `AU422A33`/AUVS had rate system 134 but a
> 2016-12-12→22 window, while 211k SKUs were currently active. Filtering on the application date
> gives a **false "Rate System Missing."** The **row's existence** is the 5a signal; the
> **active-date truth is Check 5b** (the `RATE_SKU_*` sale window).
No row at all = **Rate System Missing (RC#4)** → Rates & Forms. (Some carriers, e.g. MOPAR,
assign at `AGENT_ID` level — widen the filter with the dealer's agent before concluding a gap.)

**5b. Rate SKU rows exist?** — use `STAGING.EMORY.V_RATE_SKU_ALL` (the union of the
replicated carrier tables; see `EMORY_SNOWFLAKE_LAYER.sql`). Until that view is
deployed, query the carrier table directly (`RATE_SKU_VCI` / `_BMW` / `_TFS` /
`_FFUN` / `_ONEPROTECT`):
```sql
SELECT CLASS, TERM_FROM, TERM_TO, ODOMETER_FROM, ODOMETER_TO,
       VEHICLE_CONDITION, START_SALE_DATE, END_SALE_DATE,
       DEALER_COST, RETAIL_COST
FROM STAGING.EAS.RATE_SKU_VCI
WHERE PROGRAM_ID = {program_id} AND PRODUCT_CODE_ID = {product_code_id}
  AND RATE_SYSTEM_ID = {rate_system_id}
  AND ('{as_of}' BETWEEN START_SALE_DATE AND END_SALE_DATE)
  {and_class_if_known}
LIMIT 50;
```
> **RATE_SKU gotcha:** `MSRP_FROM/TO`, `VEHICLE_CONDITION`, engine ranges are often
> BLANK/NULL (= unrestricted) — a `BETWEEN` on them silently excludes everything.
> Filter only on `CLASS`, sale-date window, term, odometer.

> **⚠ NEVER guess the rate-table name from the product code.** Added 2026-08-24 (INC1316449)
> after a first pass invented `dbo.RATE_SKU_SVSC` / `dbo.RATE_SKU_SGPC` — **neither exists**, the
> queries errored, and the run concluded "no rates" anyway. The tables are named **per program /
> carrier, not per product**. Enumerate them before querying, every time:
> ```sql
> SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
> WHERE TABLE_NAME LIKE 'RATE_SKU%' ORDER BY TABLE_NAME;   -- Tier 2
> ```
> **SG Agents (program 20376) → `dbo.Rate_sku_SG_Agents`** (rates) + **`dbo.Rate_sku_eligibility_SG_Agents`**
> (the eligibility gate). Join to `dbo.REF_PRODUCT_CODE` on `PRODUCT_CODE_ID` to filter by product code.

> **⚠ The eligibility table is a separate, silent gate — check it whenever a product returns NOTHING
> while its siblings return fine.** `Rate_sku_eligibility_<program>` carries `Odometer_From/To` **and
> `Vehicle_Age_From/To`** per product/plan. Rates can be fully loaded for the right class and the
> product still won't quote, because no eligibility band admits that odometer+age combination. This
> is invisible if you only check `Rate_sku_*`. Confirmed 2026-08-24 (INC1316449, SG Agents):
> | Product | Odometer bands | Vehicle age bands |
> |---|---|---|
> | `SVSC` (standard VSC) | 0–120,000 (12k steps) | **0–3 / 4–7 / 8–12** |
> | `SGPC` (Precision Care) | **0–10,000 only** | **0–12** |
> | `HMVS` (High Mileage VSC) | 120,001–200,000 for ages 0–7 and 8–12; **1–200,000 for ages 13–20** |
>
> **⚠ CORRECTED 2026-08-24 (full INC1316449 run).** An earlier partial pass on this same case wrote
> a "diagnostic pattern" here claiming that *"only High Mileage VSC returns on a low-mileage car"*
> proves the engine computed the vehicle's **age as ≥13** (because the only EAS `HMVS` band admitting
> 15 miles is age 13–20). **That inference was wrong and has been removed.** It silently assumed the
> returned HMVS came from EAS. It did not: the HMVS in that response came from **Legacy**
> (`BAKEHMVS`, carrier `ARFT`, class `C`), and **Legacy HMVS has a 0–48,000-mile band with no age
> gate at all** — so a 15-mile car matches it perfectly legitimately. There was no mis-computed age.
> The EAS bands in the table above are accurate; the inference drawn from them was not.
>
> **The real lesson — identify which PLATFORM served each returned product before reasoning about
> why the others are missing.** Don't infer the source from the product code: `HMVS`, `SGPC` and
> `SWTR` all exist on *both* EAS and Legacy for a dual-written dealer, so seeing "HMVS came back"
> tells you nothing about which system answered. **Match the response's `planSKU` + `vehicleClass`
> against the actual rate rows** — that is the only proof:
> - **Legacy:** `STAGING.CMS.SG_RSC_D2.SG_RSC2_KEY` is a fixed-width string —
>   `COVER(8) + COND(1: U/N/blank) + TERM(3) + ODO_FROM(6) + ODO_TO(6) + TERM_MILEAGE(6)`.
>   Key `POWERT  U003000000048000003000` ⇒ response `planSKU POWERT-3-0.0-3000`, minOdo 0,
>   maxOdo 48000. An exact match is conclusive. Class comes from `VSC_CLASS_M1` keyed on the
>   **rate-schedule carrier** (`SG_RSC_M1.SG_RSC_CARRIER`), not the dealer.
> - **EAS:** the class vocabulary is make-tiered (`MERZ1`–`MERZ5`, `ACUR1`…) or numeric (`1`–`5`);
>   a returned single-letter class like `C`/`A`/`D` is a **Legacy** class, never EAS.
>
> If the response contains **zero** rows matching the EAS rate SKUs while EAS config fully PASSes,
> the finding is *"EAS products are not being surfaced to this channel"* — an API/routing defect —
> **not** an eligibility or classing gap. Say that explicitly rather than hunting for a config cause
> that isn't there.
>
> **Also verify a suspected outage is real before reporting it.** Ruling the Legacy contract counts
> in/out took one query: compare the product's daily contract count against **total** daily contract
> volume over the same window (`SG_CON_M1` + `ECON_CONTRACT`, both platforms). A product at zero
> while overall volume holds at 8–13k/day is a genuine stoppage; everything sagging together is
> replica lag or a weekend, not an outage.

> **⚠ Full history, not just the current window, whenever a term/rate LOOKS wrong.**
> Don't filter to `END_SALE_DATE = '3000-01-01'` (current only) when the question is
> "why is this term/rate missing or different" — pull **every** historical revision.
> "Has this always been this way" vs. "did this just change" is what tells you whether
> you're looking at a long-standing load gap or a regression, and it changes the owner
> and urgency. Confirmed 2026-08-18 (Thompson Chevrolet NOAP): checking only the current
> window showed one flat term band and looked ambiguous (intentional pricing vs. a gap);
> pulling all 3 historical revisions back to the 2022-08-01 product launch — and doing the
> same for the sibling products (see **Sibling-diff** below) — proved the band had *never*
> existed, which is a materially stronger, differently-owned finding than "currently looks
> odd." Default to full history first; narrowing to "current" is the exception, not the rule.

> **⚠ Rates ceiling:** for **GM (Mule/EPS), Hyundai HCI 2.0 (`RATE_SKU_HCI2O`, not
> replicated), Kia PPES, PEN/FIE e-com** the quoted rate is **computed by the rating
> API at request time and not stored in EAS or the Snowflake replica.** For these,
> confirm the config (rate system assigned, program live) and report
> `RATE_SOURCE = API_COMPUTED` — never conclude "no rates" from an empty table in
> Tiers 1–3. **It may still exist in Mongo (Tier 4) — see below** before calling it
> unrecoverable.

> **GM + HCI 2.0 Mongo fallback (connector wired 2026-08-19, awaiting a client restart
> to register — see Tier 4 above).** Confirmed via a direct Compass OIDC login that
> `sg-prod-mg-atlas-clst-pl-0` (not a cache of EAS/Forte — a separate source system)
> holds databases for **both** platforms named in the Rates ceiling note above, not
> just GM: `GM`, `GM_Amazon`, `GM_D2C`, `HCI`, `HCI20`, `HCI2O`, `HCI2O_Amazon`,
> `HCI_Amazon` (also `BMW_Amazon`, `Honda`/`HONDA`/`Honda_Amazon`, `ECOM_AUTO`,
> `ExtraProtect_Amazon`, `AOD`, `Autos_Amazon`, `RECREATION` — contents/schema of any
> of these not yet explored). Routing once the tool is live: check EAS/Forte first (as
> above); **if neither has it, check Mongo (Tier 4)**; then reconcile against Snowflake
> as a backdrop (a final cross-check before concluding, not the first stop). **Not
> usable until a restart** — `ToolSearch` confirmed no mongodb tool registered yet as
> of 2026-08-19. Read-only enforced at the process level (`--readOnly` correctly
> disables every create/update/delete tool). Auth is a Workforce (human/browser) OIDC
> flow — expect a Microsoft sign-in prompt on first real query, not a silent
> background connection.

**Live-fire verification (automatic — closes the loop DB checks can't).**
For API-computed rates (GM/HCI 2.0/Kia PPES/PEN/FIE, above), the database can confirm
config is correct but can't prove what the live rating API actually returns right now.
**When Checks 1-6 all PASS on one of these platforms yet the case's reported symptom
(missing product, wrong term, wrong price) seems to contradict a clean config — or the
case is confirming a fix "actually returns" the right rate post-DCR — fire the live call
yourself, automatically, no need to ask first.** This is exactly how the Audi AUTP case
closed 2026-08-17: config was clean, but only firing the live request confirmed the
72-month term was really returning. Still don't use it in place of the five checks — it's
a confirmation step, not a substitute, and it's a last-mile check, not a first move.

- **How:** run `~/.claude/skills/emory/live_fire/Invoke-EmoryLiveRate.ps1 -Vendor <X>
  -QueryParams @{...}` via the PowerShell tool. It mints a fresh Okta bearer token and
  fires the GET rates call **in one invocation** (see gotchas below for why), reading
  per-vendor token URL/client id+secret/rates base URL/vendorName/channel from
  `live_fire/secrets.json` next to it. `-Vendor` ∈ `VCI_PROD`, `VCI_UAT`, `BMW`, `HCI`,
  `LITHIA_PROD`, `LITHIA_UAT`, `GM_PROD`, `GM_UAT`. Pass the case's actual
  saleDate/sellerId-or-dealer/vin/odometer plus whichever of financeType/vehicleCondition/
  vehicleUsage/isAfterSale/financeTerm/financeAmount/vehicleMSRP/vehiclePurchasePrice
  apply on that platform (see `rating_attributes_reference.md` §1 for which platforms even
  accept which params — Lithia/GM take almost none of them).
- **Per-vendor readiness (as of 2026-08-19) — check `secrets.json`'s `_note` field before
  trusting a vendor blindly:**
  | Vendor | Status |
  |---|---|
  | `VCI_PROD`, `BMW` | **Verified working** — live-fired successfully, real 200 SUCCESS responses. |
  | `LITHIA_PROD` | **Auth confirmed** (token mint + Okta introspection both succeed), but the rates call itself 404'd against the one saved example VIN — likely stale test data, not a plumbing problem. Needs a fresh live case to confirm the response shape end-to-end. |
  | `VCI_UAT`, `LITHIA_UAT` | Credentials complete, but **untested end-to-end** — first live use should be treated as a trial run, watch for surprises. |
  | `HCI` | **Blocked** — token client_secret is stored as a Postman collection variable marked `secret:true` and isn't retrievable via the API. Ask Ed to pull the real value from the Postman UI (`FIE HCI MERCURY PROD` collection → variables → `auth_password_01v8`) and fill it into `secrets.json`. |
  | `GM_PROD`, `GM_UAT` | **Blocked** — no token credentials exist anywhere in either Postman collection (both are empty stubs, no linked environment), even though GM live-fire was confirmed working manually on 2026-08-18. Whatever client_id/secret was used that session was never saved back to Postman — ask Ed to resupply it (rates URL/query-param shape for GM_PROD IS confirmed and ready; GM_UAT's rates host isn't even confirmed). |
  If a vendor is blocked, say so plainly in the verdict rather than guessing at credentials
  or skipping the live-fire step silently.
- **Historical gotchas (confirmed 2026-08-18, GM UAT Backend flow — still apply, the
  script above already codes around all of these):**
     - **Mint the token and call the rates endpoint in the *same* PowerShell invocation.**
       Shell state (`$env:`/`$var`) does **not** persist between separate tool calls — minting
       a token in one call and using it in the next sends an empty `Authorization: Bearer `
       header, which the API reports back as `"Authorization token header was null"`
       (misleading — the header IS being sent, just empty).
     - **Always pass `-UseBasicParsing`** to `Invoke-WebRequest`/`Invoke-RestMethod` on Windows
       PowerShell 5.1. Without it, the cmdlet defaults to an IE-based parsing engine that
       throws `PSInvalidOperationException: "...NonInteractive mode. Read and Prompt
       functionality is not available"` in this non-interactive shell — a red herring that
       looks like an auth failure but is really a parser-engine issue.
     - **Call `https://` directly, never `http://`, on GM's backend rates endpoint**
       (`gm-rates.sgproductsapis.com`). The `http://` URL 301-redirects to `https://`, and
       PowerShell's automatic redirect handling **strips the `Authorization` header on that
       cross-scheme redirect** (standard secure-by-default behavior) — you'll see
       `"Authorization token header was null"` even though the header was sent on the
       original request; it just didn't survive the hop.
     - **GM Backend's `/api/v1/rates` requires `vendorName` and `channel`** in the query
       string in addition to `saleDate`/`dealer`/`odometer`/`vin` — confirmed 2026-08-18 (the
       collection's originally-saved example was missing both and 400'd with
       `"vendorName is required"` then `"channel is required"`). Fixed in the saved `GM
       PROD → GM Backend → rates` request (now includes `vendorName=GM&channel=GMF`); apply
       the same params if replicating the GM UAT Backend flow too.
- **Security:** both the Postman collections and `live_fire/secrets.json` carry live Okta
  client_id/secret pairs in plaintext. **Never echo full secret/token values** in a
  verdict, SR summary, Teams post, or chat reply — mask them (first 4/last 4 chars), same
  rule as a payload's plaintext `<password>`. `secrets.json` is local-only (never commit it
  anywhere shared); treat it with the same care as the Postman collections it was sourced
  from.

**Legacy rates:** the dealer→rate-system link is `SG_DRS_M1` (`SG_DRS_DEALER` → `SG_DRS_RS`);
join it to the schedule master `STAGING.CMS.SG_RSC_M1` on `SG_DRS_RS = SG_RSC_RS` (`SG_RSC_RS` =
rate system, `SG_RSC_PLC`, `SG_RSC_CARRIER`, `SG_RSC_SDATE/EDATE`, `SG_RSC_METHOD`,
`SG_RSC_BASERATE`), tiers `SG_RSC_D1/D2/D3`. Forms: `SG_FORM_M1` keyed by `SG_FORM_PLC` +
`SG_FORM_CARRIER` (`SG_FORM_SDATE/EDATE`). Classing: `VSC_CLASS_M1` (`VSC_CLASS_CAR` = carrier,
`VSC_CLASS_MAKE`/`_MODEL` token-matched, `VSC_CLASS_SYEAR/EYEAR`, `VSC_CLASS_CLASS`,
`VSC_CLASS_RGROUP`). Verified live 2026-08 (`00SG1055`): all resolve.
