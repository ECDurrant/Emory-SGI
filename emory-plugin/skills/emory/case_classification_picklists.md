# Case Classification & Routing — SR-form picklists + mapping

Emory recommends a **complete SR classification** on every case so support can route it fast.
Five fields, matching the Salesforce SR form:

1. **Integration Partner** (API Request Information — "Search Accounts")
2. **Aggregator** (API Request Information — "Search Accounts")
3. **Inquiry Type** (single-select picklist)
4. **Inquiry Sub-Type** (single-select, dependent on Inquiry Type)
5. **SR Category** (multi-select Available→Chosen; values are platform-suffixed)

**Always recommend valid picklist values — never invent a label.** If the best fit is a
truncated label below, pick the closest real option and say "(verify exact label)". Base the
recommendation on: the symptom, the failing check / root cause, the platform (EAS vs Legacy vs
RoadRunner from Step 0), the integration source, error text, and precedent.

---

## Integration Partner + Aggregator
Read both off the request source (getProductsSGI / wsGetRatesByRest / saveEContract) and
normalize against `aggregator_integration_partners.md`. Recommend the account name to enter in
each "Search Accounts" box. Aggregator ∈ {F&I Express, PCMI Corporation (PCRS), Provider
Exchange Network}. If the case has no API payload (pure config question), say
"Integration Partner / Aggregator: N/A — no API request in this case."

---

## Inquiry Type (picklist — READ LIVE off the SR form 2026-09-28)
Cancellations · Claims · Marketing Materials · Other · Portal Credentials · Contracting · Enrollment ·
**Rating** · **Billing/Payments** · **Reporting** · Classing · VIN · File Processing · Form Setup ·
Dealer Activation · Dealer Inquiry/Troubleshooting · Program Inquiry · Production Bug
> "Rating" exists — use it for won't-rate / no-products / missing-term cases (the 09-25 run recommended
> "Dealer Inquiry/Troubleshooting" for those; "Rating" is the right bucket).

## Inquiry SubType (dependent picklist — confirmed sets, 2026-09-28)
- **Rating** → Portal Rating Issue · LGY · EAS · Roadrunner (= Step 0 platform)
- **Dealer Activation** → Dealer Product/Eligibility Inquiry · Dealer ID Request
- **Program Inquiry** → SG Team Inquiry · Partner Request
- **Dealer Inquiry/Troubleshooting** → Signature Coordinate Update · Rating Issue · Product Eligibility Inquiry · VIN Not Rating · Form Mapping · Contract Status Check · Pricing/Classing Issue (read live 2026-09-28; 'Form Mapping' used for a dealer-name-on-forms case)
- **Classing** → EAS · LGY
Other branches are unread — `python Downloads\EmorySF\sf_fill.py --discover` dumps the full dependent map to
`sf_describe_cache.json` when REST works. For an unlisted Inquiry Type leave `inquiry_subtype` empty rather than
inventing a descriptive label (the 09-25 run wrote "Rate system missing (verify)" etc. — not picklist values,
cannot be saved).

## SR Category (multi-select — 51 values, READ LIVE 2026-09-28)
Account Configuration · Adjustment · All Integration Partners · API Error · API Whitelist ·
Application Bug · BI Access · BI Defect · BI Enhancement · BI Request · Bucket Mismatch · Cancellation ·
Claim Status · **Classing - EAS** · **Classing - LGY** · CMS Rights · Contract Remittance · Contract Update ·
Coverage Missing · Data Load · **DB Update - EAS** · **DB Update - PG** · Dealer Enrollment ·
eContracting Setup · File Processing · Form Setup · Lock date update · Marketing Material · Mobile ·
Model Missing/Incorrect · New/Missing Product · New Feature · Not Able To Replicate · Payment Type ·
Permission Error · PPM · Proactive Action · **Rating - EAS** · **Rating - LGY** · Reconciliation · Reports ·
**Setup New/Missing Benefit** · Solutioning · Training Issue · UI Issues · User management ·
**VIN - EAS** · **VIN - LGY** · Mulesoft · RoadRunner · Split Percentage Issue
> Corrections to the old truncated list: there is NO "Setup New/Migration" (it is "Setup New/Missing
> Benefit"); "Split Percentage" is "Split Percentage Issue"; "All Integration…" is "All Integration
> Partners"; "Contract Remi…" is "Contract Remittance". New since the screenshots: **Rating - EAS / Rating -
> LGY** (use these for rate/SKU problems instead of Solutioning), Model Missing/Incorrect, New/Missing
> Product, Not Able To Replicate, Proactive Action, Permission Error, PPM, Mobile, Reports, Payment Type.
> Platform suffix rule unchanged: EAS → "- EAS", Legacy/Forte → "- LGY" (DB Update Legacy = "- PG"),
> RoadRunner → "RoadRunner".

## Other SR-form picklists (read live 2026-09-28)
- **Brand:** Hyundai · GM · Honda · Agent · Aston Martin · BMW · Ford · JLR · Marine Max · Mazda · Mercedes ·
  MVP · PBL · Subaru · Toyota · VCI · NVR · NonAuto · Lithia · Amazon. (Audi/VW/Porsche-VCI → VCI;
  Porsche Financial → PBL; 00S/0LD agent codes → Agent; ExtraProtect NCG codes → NVR; Yamaha → NonAuto.)
- **Status (path):** New · In Progress · Waiting on Internal Team · Waiting on Client · Closed.
- **Error Code:** 404 SSO Error · OKTA 400 Error · Oops! Failed to login… · Dealer is not enrolled · Other ·
  400 - Request Validation Error · 400 - Unable to decode VIN · 400 - modelId cannot be null · 400 - PDF
  Template is not available · 400 - Sell does not have permission to update contract · 400 - Form
  Combination does not exist · 400 - Cannot Update Contract in REMIT State · 400 - Cannot Remit Voided
  Contract · 400 - Classing not found for Dealer · 401 - Unauthorized · 403 - … explicit deny · 404 - VIN
  Detail not Found · 404 - Dealer Data not Found · 404 - No Product Class Found · 404 - Dealer not assigned
  Product · 404 - Dealer Not Found · 404 - Form Not Found · 404 - Contract Not Found · 405 - Method Not
  Allowed · 500 - Error fetching Rates · 500 - Backend Response Null/Empty · 500 - Internal Error · 500 -
  Application Error: Can't Save Contract · 500 - … Can't Update Contract · 502 - Bad Gateway · 503 - Service
  Unavailable. Set it when the payload carries one of these exact strings.
- **Portal:** Dealer Portal · Cancellation Portal · SG Express · Dealer Management Portal · Incentives Portal ·
  Other · PPM Portal · SG Media Page.
- **Integration Partner / Aggregator** are Account lookups; names confirmed to resolve: "Reynolds and Reynolds", "Line5",
  "Darwin Menu", "Darwin Online", "RouteOne Menu / MaximTrak", "Provider Exchange Network", "F&I Express". Darwin-sourced
  SRs often arrive with both already populated by the intake flow.
- Plain text fields with known API names: `VIN__c`, `Dealer_Number__c`, `Dealer_Name__c`, `BAC__c`.
- **SR Summary Detail** is a plain textarea (put the dated `[MM/DD/YY]` write-up there). **Description** is
  the partner's original email in a rich-text editor — never write into it.

---

## Finding → classification map (recommendations; platform-aware)
| Emory finding / root cause | Inquiry Type | SR Category (pick platform variant) |
|---|---|---|
| Dealer not enrolled / inactive (Check 1) | Enrollment *or* Dealer Activation | Dealer Enrollment |
| Product not assigned / end-dated (Check 2) | Program Inquiry | Coverage Missing *or* New/Missing Product |
| eContract form missing / wrong (Check 3) | Form Setup | Form Setup |
| Rate system / SKU missing (Check 4) | **Rating** (Sub-Type = platform: EAS / LGY / Roadrunner) | **Rating - EAS \| Rating - LGY** (+ Coverage Missing if the product is invisible) |
| Classing gap / exclusion (Check 5/6) | Classing | Classing - EAS \| Classing - LGY |
| VIN decode / pattern (Check 6) | VIN | VIN - EAS \| VIN - LGY |
| XRef missing / bad mapping | Dealer Inquiry/Troubleshooting | Mulesoft *or* DB Update - EAS\|PG |
| OEM eligibility rule (Step 7) | Program Inquiry | Coverage Missing |
| Config change needed (DCR/DBCR) | (per area) | DB Update - EAS \| DB Update - PG |
| **All config PASSES → API layer** | Production Bug | **API Error** (name the Aggregator + Integration Partner) |
| RoadRunner platform issue | Dealer Inquiry/Troubleshooting | RoadRunner |
| New integration / whitelist | Production Bug *or* Other | API Whitelist *or* All Integration Partners |
| Contracting / eContract submit error | Contracting | eContracting Setup *or* Contract Update |
| Duplicate contract (Step 0b) | Production Bug | Contract Update |
| Split percentage | Program Inquiry | Split Percentage Issue |
| Lock-date issue | File Processing | Lock date update |
| File feed / data load | File Processing | File Processing *or* Data Load |
| BI / reporting | Other | BI Access \| BI Defect \| BI Request \| BI Enhancement |
| **Claim / payment / bucket** | Claims | Claim Status \| Bucket Mismatch → **route to `apibrain-claims`** |
| Cancellation | Cancellations | Cancellation |
| Portal login / credentials | Portal Credentials | CMS Rights *or* User management |

Multiple checks can fail → SR Category is multi-select, so recommend **all** that apply
(e.g. a Legacy classing case that also needs a form fix → "Classing - LGY" + "Form Setup").

---

## Filling the SR itself — automatic hand-off, do not drive the form
Emory's job ends at the verdict JSON. Put the structured classification in its **`salesforce` block** (schema in
`references/verdict_and_delivery.md`); `emory_post.ps1` drops it into `Downloads\EmorySF\inbox\<SR>.json` and
`sf_fill\sf_fill.py` (launcher `Downloads\EmorySF\watch.cmd`) writes it into Salesforce with zero model tokens.
```json
"salesforce": {"record_id":"a03Ux00000tfAF8IAM","brand":"VCI","inquiry_type":"Rating","inquiry_subtype":"EAS",
 "sr_category":["Rating - EAS","Coverage Missing"],"integration_partner":"Reynolds and Reynolds",
 "aggregator":"Provider Exchange Network","vin":"WA125AGU6T2021477","dealer_number":"AU423D75",
 "dealer_name":"Audi Tri-Cities","summary":"<SR Summary Detail paragraph, no date prefix>","accept":true}
```
Only real picklist values from this file — the script validates and SKIPs anything else (reason in
`EmorySF\sf_fill_log.csv`). Why: the 09-28 manual fill cost ~95 browser tool calls for six SRs and typed a summary into
Description. Details: `sf_fill\README.md`, `references/browser_and_intake.md` → "Filling the SR".
