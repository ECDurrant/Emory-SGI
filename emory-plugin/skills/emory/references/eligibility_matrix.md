# Step 7 — the Master Eligibility Matrix

*Reference for the `emory` skill. Read this when SKILL.md points you here — it is the
full detail for that step, moved out so the main workflow stays readable.*

---

## Step 7 — Eligibility knowledge-base cross-check (SOP RAG)

### ⚠️ MANDATORY — DO NOT SKIP

After the five checks, **before finalizing the verdict**, cross-check eligibility
against the knowledge base. This catches what config tables don't encode — exotic-make
exclusions, EV/ICE product splits, state restrictions, CPO/finance-type rules.

**Run Step 7 in ALL these cases (non-negotiable):**
- ✅ Check 5 (rates) came back FAIL or NEEDS REVIEW
- ✅ Check 6 (classing) came back FAIL or NEEDS REVIEW
- ✅ The case symptom is an eligibility question ("not eligible", "excluded make", "won't rate on CPO/lease/EV")
- ✅ A product didn't return rates (may be eligibility, not config)
- ✅ A vehicle didn't rate (may be eligibility, not classing)

**Skippable ONLY when:**
- Checks 1-6 all PASS cleanly, AND
- Eligibility was never in question (no "why didn't it rate" in the case)

**DO NOT say "SKIPPED — checks all pass"** if rates/classing failed. That is an eligibility question by definition.

**Preferred source — the local Master Eligibility Matrix**
(`Downloads\Emory OEM Knowledge Base\Master Eligibility Matrix.xlsx`, built 2026-08-11):
one tab per OEM/product-line. **Schema grew from ~22 to 24 fields on 2026-08-19** — a
schema-wide pass added **`Minimum Term (Months)`** and **`Minimum Mileage`** (between
`Maximum Odometer` and `Maximum Term (Months)`) across all 32 OEM/product-line tabs, alongside
the existing After-Sale Eligible, Model Year/Odometer/Term/Mileage limits, New/Used/CPO,
Finance/Lease/Cash/Balloon, Excluded Makes, State Exclusions, and Other Requirements fields.
**Population is uneven, not automatic just because the column exists:** as of 2026-08-19 most
tabs (Subaru, GM, PBL, Harley-Davidson, …) carry "Not stated in source — verify" in the two new
fields for every row — the column was added ahead of the sourcing. **Audi (Pure Protection)** is
a confirmed exception with real per-product minimum term/mileage values already populated (its
Ops Manual apparently already had the field). **Treat the matrix as a live document that may be
mid-edit** — this file is being actively re-passed (confirmed via its own `.bak.xlsx` timestamped
snapshots in the same folder, several within a single morning); if a tab's answer matters to a
verdict, note the file's current modified-time alongside the citation, the same way the nightly
EAS replica's freshness gets called out. Read it directly (Read tool / openpyxl/pandas) — no
SharePoint round-trip needed. Covers: **Subaru, Hyundai (HPP), Genesis (GPP), Kia (PPES),
HCI-PPWL, BMW-MINI, GM, Honda-Acura, VWFS (VW-Audi-Porsche), Nissan Canada, Mazda (via
TFS-TMIS), Ford, Mercedes-Benz.**

**⭐ The live `Downloads\Emory OEM Knowledge Base\Master Eligibility Matrix.xlsx` now has 40 tabs** (verified 2026-08-25 by parsing the live file; the 38-tab merge was adopted 2026-08-18 and `CarMax` + `Voltswitch` were added after — **both are empty stubs with zero product columns**, so don't expect content there. The pre-merge 20-tab version is preserved as `Master Eligibility Matrix.20260818_115628.bak.xlsx`). Read the live master directly. Beyond the original 20 tabs it now includes: Rolls-Royce, Aston Martin, JLR, Toyota-Lexus (TFS-LFS), MarineMax, Volkswagen (Drive Easy), Audi (Pure Protection), Ducati (Ever Red), **Harley-Davidson (HDFS: HDUP/HDUO/HDUG/HDUT)**, **Good Sam/Camping World (9 products GSGP…FRCF)**, **Honda Canada Lease-Guard (HCLS/ACLS/HCLP/ACLP)**, **Stellantis US Mopar (8 GAP: MO**/EV** branded vs white-label)**, **Stellantis Canada (GAP MCGI; ex-BC/QC)**, **One Protect Powersports (OPPV, per-class max age)**, **Maserati Ally ELITE T&W**, **TLS Canada (Toyota 006600/Lexus 006700/Subaru 006800; Assurant)**, **GM Canada PowerUp (Ultium charger — thin)**, **Yamaha Canada** (BRD-derived: YMGP/YMBG/YMTP/YMBT/YMTW + Adventure Protect AP** white-label; Credit Insurance via UMU — numeric eligibility 'verify'). Mopar US tab (10) also carries **FlexCare Lease Excess W&T (MOLS)** + **TireWorks Road Hazard** + GAP caps (≤$50k, MSRP ≤$120k, 150% LTV, 84mo; GAP Plus barred CO/FL/GA/IL/MT/NE/NY/OK/RI/TX/VT/WI/WV) — but the FlexCare **mechanical VSC** ('Maximum/Added Care') is NOT in the SGI export (separate Stellantis program). **Stellantis Canada expanded to 12 products** (MCGI GAP, MCTR Term, MCMC Multi-Coverage, MCTW T&W+Cosmetic, MCKY Key, MCWS Windshield, MCDD Dent, MCAP Interior, MCVS Off-Make MBI [SK/AB/QC], MCCP Corrosion, MCTP SG-Connect-Theft, MCGP Quebec LDW; agent 007310, underwriter Arch). Everything local is now mined.

**Per-OEM notes for the newly-added tabs** (the standalone `*_forMatrix.xlsx` files were
folded into the live master and deleted — read the live-master tab, not a loose file):
**PBL** = Porsche/Bentley/Lambo (replaced the old "no matrix found" stub; raw Ops Manuals
at `…\Emory OEM Knowledge Base\PBL\*.pdf` + `dbo.PBL_CPO`/classing still back it up).
**Toyota-Lexus (TFS/LFS)** = ancillary/motor-club (Tire&Wheel±Key + standalone Key), so
term & mileage come from the TFS/LFS Rate Guide, not hard caps — and it's **distinct from
"Mazda (via TFS-TMIS)"** even though Mazda's US F&I also rides TFS. **VW/Audi/Ducati** are
the VCI family and **QualityProtect is their COMPETITIVE-make sibling brand** (VW/Audi/Ducati
vehicles are ineligible for QualityProtect and vice-versa); confirmed codes VWEV (VW EV VSP),
VWCP (VW CPO VSP), AUCT (Audi CPO Term, prog 20285) — others need product-master lookup.
Audi VSP caps at 120k mi vs VW 150k; Audi CPO VSP 148k & at-sale-only; **Ducati Superleggera
excluded from every Ducati product**. **MarineMax** = marine (age/hours-based, not miles).
- Some tabs (VWFS, Nissan Canada) only have partial fields — cells read "Not stated in
  source — verify" where the underlying doc didn't have that field. Don't treat that
  string as a real value; it means ask a human, not that the field is blank/N-A.

---

### How the workbook is actually laid out (verified 2026-08-25)

**The tabs are TRANSPOSED — a rule is a COLUMN, not a row.** Column A holds the 24 field
labels (rows 4–27, identical on every standard tab); each column to its right is one
product. Reading it row-wise gets the wrong answer, so when parsing programmatically,
iterate columns.

- Row 0 = `Source:` (the originating Ops Manual, often with version + date — the closest
  thing the workbook has to an effective date). Row 1 = `Note:`. Row 3 = the `Field` header.
- **35 standard tabs → 385 rule records total.** Biggest: GM 74, VWFS 30, Nissan Canada 24,
  Hyundai (HPP) 22, Volkswagen (Drive Easy) 20, Genesis (GPP) 20, Audi (Pure Protection) 19.
- **5 tabs are ordinary row-oriented tables, not the 24-field shape** — read these normally:
  `State Rules (All OEMs)` (77 rows), `GM Carrier-CLIP-Fee Ref` (76), `GM Warranty Ref`,
  `GM New Channel Codes (TODO)`, `BMW SharePoint TODO`.
- **`CarMax` and `Voltswitch` are empty** — 0 product columns.

**Watch for repeated product labels within a tab.** `VWFS` has two separate `VWEV` columns
and two `AUEV` columns **with different content**. Identify a rule by tab + column position,
not by label alone, or you will silently conflate two different rules.

### How much of the matrix is actually populated (verified 2026-08-25)

- **23% of rules (87 of 385) have no product code** — the cell reads "Not in manual — verify."
  Don't conclude a product doesn't exist because the matrix has no code for it; resolve by
  product *name* against the product master instead.
- **96% of rules (371 of 385) carry at least one "Not stated in source — verify" field.**
  This is the norm, not the exception — so when citing a matrix row, routinely state which
  fields are unverified rather than treating it as a rare caveat.
- Only **51%** have a parseable version/date in their `Source:` cell. For the rest there is
  no date evidence at all in the workbook; fall back to the file's modified time and say so.

**Fallback — SharePoint `RatesTeamBAs` knowledge base** (same brain as the cloud
Copilot Studio agent, 9 subfolders under
`safeguardproducts.sharepoint.com/sites/RatesTeamBAs/Shared Documents/`): use when the
OEM isn't in the local master workbook yet, or you need the raw source doc (Ops Manual,
Dealer Guide) behind a matrix row. `sharepoint_search(query=…)` → `read_resource(uri)`.
**⚠️ Note (verified 2026-08-25): its "OEM Eligibility Matrix" folder is not just thinner —
it is a 2024 snapshot.** It holds exactly 5 files (`BMW Product Matrix 01-18-24.xlsx`,
`Eligibility Matrix_Nissan Canada.xlsx`, `GM Eligibilityv2.xlsx`,
`Honda Eligibility Matrix V1.1.xlsx`, `TFS Eligibility.xlsx`) and the folder was **last
modified 2024-06-06**. The local master covers 35 populated OEM tabs and was modified
2026-08-19. **Always prefer the local file.** Treat this folder as last-resort only, and
if you do cite it, say the date out loud — a 2024 rule may since have changed.

**Consequence worth knowing:** the cloud Copilot Studio agent is grounded on this same
folder, so its eligibility answers come from that 2024 snapshot at ~13% of the OEM
coverage Emory sees locally. If a Teams answer disagrees with Emory on eligibility,
this is the most likely reason — Emory is not wrong by default, but check both.

**Where the OEM source docs actually live:** `…/Shared Documents/OEMs/` (22 subfolders),
but **~10 are empty (0 bytes)** — Aston Martin, Ford, Harley Davidson, Jaguar/Land Rover,
MarineMax, Mercedes-Benz, Rolls Royce, Camping World, AutoTrader, VROOM. For those OEMs
there is no raw source doc to fall back to; the local workbook tab is all there is.

**VW/Audi/QualityProtect/Ducati Ops Manuals ARE local** (added 2026-08-25, from
`Downloads\VOLKSWAGEN.zip` — this closed the `__VOLKSWAGEN_Error.txt` download gap):
`Emory OEM Knowledge Base\VWFS\Operations Manuals\` — Audi v.11 (05/06/2026),
Volkswagen v.13 (05/07/2026), QualityProtect v.7, Ducati v.6. Read them with `pdfplumber`.

> ⚠ **The `VWFS PS Eligibility Matrix` spreadsheet is NOT reliable on numeric caps — the Ops
> Manual wins.** Verified 2026-08-25: it states QualityProtect VSP max mileage as 150,000 when
> both the QualityProtect manual (v.7 p.9) and the VW manual (v.13 p.31) say **120,000**, and
> Audi CPO VSP as 130,000 when the Audi manual (v.11 p.52) says **148,000**. It also has product
> codes pasted into mileage fields (`AUCP`, `AU`). Both caps are corrected in the master with a
> `Note:` on the VWFS tab. Check a cap against the manual before trusting that spreadsheet.

---

### The Copilot Studio copy — generated, not a second source (added 2026-08-25)

The cloud Copilot Studio agent can't read Ed's local disk, so it is fed a **generated
export** of the same workbook:

`SGIEnterpriseAppSupportTeam / Shared Documents / SGI Agent / Emory_Eligibility_Rules.xlsx`

- **This is NOT a second knowledge base.** It is produced from the same
  `Master Eligibility Matrix.xlsx`. **Never hand-edit it** — edit the workbook
  and regenerate, or the two silently diverge again, which is the exact problem this
  replaced.
- **Emory (this skill) keeps reading the local workbook**, not the export. The local file
  is faster and carries everything; the export exists only because Copilot Studio needs a
  cloud-reachable copy.
- **A FLAT .xlsx — one row per product** (superseded the .docx on 2026-08-25). The hazard
  was never the file format, it was the master being **transposed**: a generic indexer
  chunks row-wise, so a transposed sheet yields `Maximum Odometer | 120,000 | 150,000 | …`
  with no product attached and answers confidently about the wrong product. Flattening to
  one row per product fixes that directly, and beats the .docx on size — ~127k tokens vs
  ~187k (**−32%**), because field labels appear once in the header instead of repeating in
  every product section.
- **The export also DE-CONFLATES combined columns.** 24 columns pack several products into
  one column (`VWVS/AUVS/QPVS`) with cells like `100,000(VW)/100,000(AU)/150,000(QP)` —
  that single cell is what makes a retriever answer 150,000 for an Audi product. Each
  becomes one row per code, brand-tagged segment resolved. Splitting is deliberately
  conservative: prose containing slashes (Ford coverage codes, JLR dual-brand notes) is
  never split, and anything unresolvable keeps the full value and is flagged in
  `Needs Review (could not de-conflate)` rather than guessed. Exact-duplicate and
  content-free rows are dropped so identical chunks don't compete at retrieval.
- **Regenerate** (from `Downloads\emory-rag\`) after any workbook change, then re-upload:
  ```
  python -m emory_rag.ingest.export_xlsx
  ```
  Writes `dist/Emory_Eligibility_Rules.xlsx` (for SharePoint). Run
  `python -m emory_rag.ingest.export` as well if `dist/rules.jsonl` is needed for the RAG
  ingestion job. `build_docx.js` is retired — don't run it.
- **Citing it:** every row carries a `Record ID` column
  (`matrix::<oem>-<product>::c<column>`, suffixed `::<CODE>` when the row came from a
  de-conflated combined column) — the same id the RAG index will use, so a Teams answer
  and an Emory verdict can be traced to the same rule.
- **Two columns to read before trusting a row:** `Unverified Fields` (the
  "Not stated in source — verify" fields on that rule) and `Needs Review (could not
  de-conflate)`. A value in either means state the caveat in the verdict rather than
  quoting the number flat.

**If a Teams answer disagrees with Emory on eligibility**, check whether the Copilot Studio
agent still has the stale `RatesTeamBAs/OEM Eligibility Matrix` folder attached as a second
knowledge source. Until that is removed, it can answer from the 2024 files instead of this
export, and the two will not agree.

---

**What this step is NOT:** it doesn't replace Check 5/6 — those remain the source of
truth for "is this dealer/product/rate actually set up." This step answers a different
question: "does this vehicle/deal qualify for the product at all," independent of
whether the config is wired correctly.
