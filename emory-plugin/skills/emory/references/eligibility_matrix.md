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

**⭐ The live `Downloads\Emory OEM Knowledge Base\Master Eligibility Matrix.xlsx` now has 38 tabs** (adopted 2026-08-18 — the 38-tab merge was copied over the live master; the pre-merge 20-tab version is preserved as `Master Eligibility Matrix.20260818_115628.bak.xlsx`). Read the live master directly. Beyond the original 20 tabs it now includes: Rolls-Royce, Aston Martin, JLR, Toyota-Lexus (TFS-LFS), MarineMax, Volkswagen (Drive Easy), Audi (Pure Protection), Ducati (Ever Red), **Harley-Davidson (HDFS: HDUP/HDUO/HDUG/HDUT)**, **Good Sam/Camping World (9 products GSGP…FRCF)**, **Honda Canada Lease-Guard (HCLS/ACLS/HCLP/ACLP)**, **Stellantis US Mopar (8 GAP: MO**/EV** branded vs white-label)**, **Stellantis Canada (GAP MCGI; ex-BC/QC)**, **One Protect Powersports (OPPV, per-class max age)**, **Maserati Ally ELITE T&W**, **TLS Canada (Toyota 006600/Lexus 006700/Subaru 006800; Assurant)**, **GM Canada PowerUp (Ultium charger — thin)**, **Yamaha Canada** (BRD-derived: YMGP/YMBG/YMTP/YMBT/YMTW + Adventure Protect AP** white-label; Credit Insurance via UMU — numeric eligibility 'verify'). Mopar US tab (10) also carries **FlexCare Lease Excess W&T (MOLS)** + **TireWorks Road Hazard** + GAP caps (≤$50k, MSRP ≤$120k, 150% LTV, 84mo; GAP Plus barred CO/FL/GA/IL/MT/NE/NY/OK/RI/TX/VT/WI/WV) — but the FlexCare **mechanical VSC** ('Maximum/Added Care') is NOT in the SGI export (separate Stellantis program). **Stellantis Canada expanded to 12 products** (MCGI GAP, MCTR Term, MCMC Multi-Coverage, MCTW T&W+Cosmetic, MCKY Key, MCWS Windshield, MCDD Dent, MCAP Interior, MCVS Off-Make MBI [SK/AB/QC], MCCP Corrosion, MCTP SG-Connect-Theft, MCGP Quebec LDW; agent 007310, underwriter Arch). Everything local is now mined.

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

**Fallback — SharePoint `RatesTeamBAs` knowledge base** (same brain as the cloud
Copilot Studio agent, 9 subfolders under
`safeguardproducts.sharepoint.com/sites/RatesTeamBAs/Shared Documents/`): use when the
OEM isn't in the local master workbook yet, or you need the raw source doc (Ops Manual,
Dealer Guide) behind a matrix row. `sharepoint_search(query=…)` → `read_resource(uri)`.
**Note (2026-08-11): its "OEM Eligibility Matrix" folder only has 5 OEMs (BMW, GM,
Honda, Nissan Canada, TFS)** — thinner than the local master workbook; prefer the local
file when both exist.

**What this step is NOT:** it doesn't replace Check 5/6 — those remain the source of
truth for "is this dealer/product/rate actually set up." This step answers a different
question: "does this vehicle/deal qualify for the product at all," independent of
whether the config is wired correctly.
