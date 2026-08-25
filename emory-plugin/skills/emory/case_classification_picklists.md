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

## Inquiry Type (picklist — from the SR form)
`--None--` · Cancellations · Claims · Marketing Materials · Other · Portal Credentials ·
Contracting · Enrollment · Classing · VIN · File Processing · Form Setup · Dealer Activation ·
Dealer Inquiry/Troubleshooting · Program Inquiry · Production Bug
> (List may contain a few values between "Enrollment" and "Classing" not visible in the source
> screenshots — if none fit, use "Dealer Inquiry/Troubleshooting".)

## Inquiry Sub-Type
Dependent on Inquiry Type. **The exact Sub-Type picklist was not provided** — recommend a
descriptive value that matches the chosen Inquiry Type and flag "(confirm against the dependent
Sub-Type picklist)". (Ask Ed to share the Sub-Type values to hard-wire them.)

## SR Category (multi-select — from the SR form; platform-suffixed)
Account Configuration · Adjustment · All Integration… (All Integrations) · API Error ·
API Whitelist · Application Bug · BI Access · BI Defect · BI Enhancement · BI Request ·
Bucket Mismatch · Cancellation · Claim Status · **Classing - EAS** · **Classing - LGY** ·
CMS Rights · Contract Remi… (Reminder/Remittance) · Contract Update · Coverage Missing ·
Data Load · **DB Update - EAS** · **DB Update - PG** · Dealer Enrollment · eContracting Setup ·
File Processing · Form Setup · Lock date update · Setup New/Migration · Solutioning ·
Training Issue · UI Issues · User management · **VIN - EAS** · **VIN - LGY** · Mulesoft ·
RoadRunner · Split Percentage
> "…" = label truncated in the UI; match the closest real option. Several categories carry a
> **platform suffix** — pick the one matching Step 0's platform: **EAS → "- EAS"**,
> **Legacy/Forte → "- LGY"** (note the *DB Update* Legacy variant is **"DB Update - PG"** because
> Forte = Postgres), **RoadRunner → the "RoadRunner" category**.

---

## Finding → classification map (recommendations; platform-aware)
| Emory finding / root cause | Inquiry Type | SR Category (pick platform variant) |
|---|---|---|
| Dealer not enrolled / inactive (Check 1) | Enrollment *or* Dealer Activation | Dealer Enrollment |
| Product not assigned / end-dated (Check 2) | Program Inquiry | Coverage Missing *or* Setup New/Migration |
| eContract form missing / wrong (Check 3) | Form Setup | Form Setup |
| Rate system / SKU missing (Check 4) | Dealer Inquiry/Troubleshooting | Solutioning *or* Setup New/Migration (no explicit "Rates" category — verify) |
| Classing gap / exclusion (Check 5/6) | Classing | Classing - EAS \| Classing - LGY |
| VIN decode / pattern (Check 6) | VIN | VIN - EAS \| VIN - LGY |
| XRef missing / bad mapping | Dealer Inquiry/Troubleshooting | Mulesoft *or* DB Update - EAS\|PG |
| OEM eligibility rule (Step 7) | Program Inquiry | Coverage Missing |
| Config change needed (DCR/DBCR) | (per area) | DB Update - EAS \| DB Update - PG |
| **All config PASSES → API layer** | Production Bug | **API Error** (name the Aggregator + Integration Partner) |
| RoadRunner platform issue | Dealer Inquiry/Troubleshooting | RoadRunner |
| New integration / whitelist | Production Bug *or* Other | API Whitelist *or* All Integrations |
| Contracting / eContract submit error | Contracting | eContracting Setup *or* Contract Update |
| Duplicate contract (Step 0b) | Production Bug | Contract Update |
| Split percentage | Program Inquiry | Split Percentage |
| Lock-date issue | File Processing | Lock date update |
| File feed / data load | File Processing | File Processing *or* Data Load |
| BI / reporting | Other | BI Access \| BI Defect \| BI Request \| BI Enhancement |
| **Claim / payment / bucket** | Claims | Claim Status \| Bucket Mismatch → **route to `apibrain-claims`** |
| Cancellation | Cancellations | Cancellation |
| Portal login / credentials | Portal Credentials | CMS Rights *or* User management |

Multiple checks can fail → SR Category is multi-select, so recommend **all** that apply
(e.g. a Legacy classing case that also needs a form fix → "Classing - LGY" + "Form Setup").
