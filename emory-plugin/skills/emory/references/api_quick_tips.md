# API Quick Tips — partner-facing self-service guide

**Source:** `API Quick Tips.docx` (IT Client Support, distributed to PEN).
**Provenance:** built from a review of PEN-submitted API support tickets.
**Added to Emory:** 2026-09-16.

## What this file is — and is not

This is the guide **the integration partner was given**, telling them what to check
*before* opening a ticket. It is therefore useful to Emory in two distinct ways:

1. **Triage shortcut.** Most rows below are *caller-side* — a wrong value in the
   submitted XML, correctable by the partner without any Safe-Guard config change.
   When a case matches one of those rows, Emory should say so plainly and name the
   field, rather than running the full five checks against config that is fine.
2. **Reply leverage.** Because PEN already has this document, Emory can reference it
   in an SR summary ("this is the `sellerId must be 8 characters long` case in the
   Quick Tips guide") instead of re-explaining from scratch.

> **Not an authority for config truth.** The prefix table in Section B is a *routing
> hint* the partner was given ("generally identify"). Emory still resolves the dealer
> the normal way — `V_DEALER` / `cms_dealer_number`, Step 0 platform routing — and the
> resolved value wins over any prefix inference.

---

## Section A — Error message → field → meaning

The first three columns are the source document verbatim. **"Emory's read"** is added
for this skill: where the case actually lands, and who owns it.

| What the partner sees | Field to check in the XML | What it usually means | Emory's read |
|---|---|---|---|
| "No products were available for this dealer." | Dealer ID, Product, Sale Date, VehicleType, vehicle condition, Odometer | Dealer isn't enrolled to sell that product, or the VIN doesn't meet eligibility (in-warranty vs out-of-warranty, CPO, model year, mileage). Could also be a wrong Dealer ID or date parameter, vehicle condition, odometer. | **The main config case.** Run the five checks in full — Checks 1/2 (enrolment) then Check 6 + Step 7 (eligibility). Also the `financeType=CASH` / condition-gate family — see `rating_attributes_reference.md`. |
| "The dealer number provided has not been set up. There must first be a Safe-Guard CMSID…" | Dealer ID | The dealer's Safe-Guard code / CMS ID hasn't been created yet — a setup request, not a rating error. | **Check 1 fails at the door.** Owner: Account Management / FDP. Also check the Kia PPES onboarding-cohort pattern (dealer shells created with zero products). |
| "Product rate not found as retail price is not matching" | RetailPrice / SellingPrice | Submitted price doesn't match the rated price — recheck the value sent. | **Caller-side.** No config change. |
| "Dealer mapping not found" | Dealer ID (incorrect) | Code mistyped, or dealer isn't mapped for the requested product. | Usually caller-side, **but** confirm it isn't a genuine cross-reference gap (Root Cause #5) before bouncing it back. |
| "Vin does not exist", "vin details do not exist in the system", "vin not …" | VIN | VIN mistyped or doesn't decode — reverify before resubmitting. | Caller-side unless the VIN *is* valid and simply has no decode pattern — then it's Check 6 / classing. |
| "Format is invalid" | Whichever field the message names (VIN, date, price…) | Field doesn't match expected format or length. | **Caller-side.** Do not confuse with the Porsche POTW `.NET Input string was not in a correct format` contracting defect, which is ours. |
| "sellerId must be 8 characters long" | SellerID | Value submitted isn't the correct length. | **Caller-side.** |
| "The contract number/id is invalid" / "Existing contract found" | ContractNumber | Often a duplicate or reused contract number for a VIN already contracted. | Run the Step 0b duplicate probe; remember Pending ≠ Void — sweep the whole VIN. |
| 500 error / "rate could not be calculated" | VIN, Product, Term, Sale Date | Generic rating failure — check these three fields together before escalating. | **Genuinely ambiguous.** This is the one that earns a full investigation plus live-fire (Check 5). |
| "Endpoint request timed out" | N/A | Not a data issue — likely transient connectivity. Retry before opening a ticket. | Not a config case. Don't run the five checks. |
| Wrong form returned (e.g. an EV form on a gas vehicle) | VIN | Usually a VIN decode issue, not a form-mapping bug — reverify before resubmitting. | Confirm with the VIN decode before accepting it. The Mercedes MBED/MBDD EV-vs-ICE split is a real product-level counter-example where the form *is* the config. |

---

## Section B — Dealer / provider code prefix → program

Partner-facing routing hint. Verify against `V_DEALER` / `cms_dealer_number` before relying on it.

| Prefix | Manufacturer / program |
|---|---|
| `HYU…` | Hyundai Motor Finance |
| `0KM…` | Kia Motors Finance |
| `0GF…` | Genesis Finance |
| `AU4…` | Audi Financial Services |
| `VW4…` | Volkswagen Credit |
| `PORS…` | Porsche Financial Services |
| `BENT…` | Bentley |
| `LAMB…` | Lamborghini |
| `HN…` | Honda Financial Services |
| `AC…` | Acura Financial Services |
| `SU4…` | Subaru Motors Finance |
| `MAZ…` | Mazda Financial Services |
| `JAG…` | Jaguar Financial |
| `000MB…` | Mercedes-Benz Financial Services |
| `G012…` / `H012…` (e.g. `G0461811`, `H0449714`) | BMW / MINI Group Financial Services |
| Numeric only, 5–6 digits, no letters (e.g. `161424`) | GM Financial — "BAC" number |
| `GMF…` | GM Financial — **but the numeric BAC number is used for rating** |
| `LTH…` | Lithia Motors dealer group |
| `00S…` / `0LD…` | Safe-Guard Agents |
| `AMZ…` | Amazon Autos program |

**Cross-checks against what Emory already knows:**
- `HYU*` is the **VSC** code at a Hyundai rooftop; the HPP program uses a parallel `HPP*`
  code at the same rooftop. Quote HPP on the `HPP*` code.
- `0KM*` resolves to a `PKM*` seller for Kia PPES (EAS program 20380).
- `GMF…` vs the numeric BAC matters for rating — consistent with the `GMF…` / `CB…`
  GM dealer-number prefixes already recorded.
- `00S…` Safe-Guard Agents rates live in `dbo.Rate_sku_SG_Agents`, **not replicated to Snowflake**.

---

## Section C — The partner's pre-ticket self-check

What PEN was told to do first. If the SR shows none of this was done, say so in the reply.

1. Re-read the exact error message or response code — it usually names the field or reason directly.
2. Confirm the VIN in the XML is correct and fully decodes (year, make, model).
3. Confirm the dealer's provider/dealer code matches the Section B table — this names the
   owning program and team.
4. Verify the product is listed as available in the initial request/response — **if it isn't
   listed there it won't rate**, unless there's a dealer product configuration issue on our
   side, which does need a ticket.
5. Confirm field values (retail price, APR, Dealer ID, dealer name) match exactly what's
   expected — many "not matching" / "invalid format" errors are request-value issues.
6. If it's a new dealer, confirm whether there was a recent buy/sell or a recent dealer name
   update, and flag it up front.

> Item 6 is the "wrong dealer name on the contract" family — the seller name is pulled from
> the SG dealer master by dealer code, not from the request's `dealerName`.

---

## Section D — What a well-formed ticket must contain

Use this as the intake completeness check. Anything missing is what Emory asks for.

- Dealer name and provider/dealer code
- VIN
- Product name
- Full XML request and the exact error message / response code returned
- Whether the issue is on **Rating** or **Contracting**
- The sending system generating the request (Darwin, Tekion, Reynolds & Reynolds, MaximTrak…)

> The sending system maps to the integration partner / aggregator fields —
> see `aggregator_integration_partners.md`.
