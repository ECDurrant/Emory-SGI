# Sibling-diff — reading a product against its family

*Reference for the `emory` skill. Read this when SKILL.md points you here — it is the
full detail for that step, moved out so the main workflow stays readable.*

---

### Sibling-diff — compare against the product/dealer family (run whenever one product looks anomalous)

The single highest-signal move across today's cases wasn't a new query — it was **pulling the
comparable family and diffing against it**, instead of judging one product in isolation:
- Porsche Beaverton only made sense once it was clear Porsche runs **parallel Porsche-branded /
  QualityShield-branded siblings** for the same coverage type (GAP Plus: POPL vs QSPL) — the
  "wrong brand for this VIN" finding came from knowing the sibling existed, not from POPL/QSPL
  config alone.
- Thompson Chevrolet's NOAP only looked like a real gap once compared against its Nomad siblings
  (NOKY/NODD/NOWS/NOTW) and found to be the only one missing a term ladder — NOAP's own rate table,
  read alone, just looked like "one flat band," which is ambiguous by itself.

**Run this whenever a product's structure (term bands, odometer bands, eligibility fields, or
branding) looks unusual, or the case symptom implies "shouldn't this look like the other ones."**
It's cheap — one extra query — and it's what turns "huh, that's odd" into a citable finding instead
of a guess:
1. **Find the family.** Same `PROGRAM_ID`/program + same `RISK_TYPE_CODE`/product type (GAP, VSC,
   Key, Dent, Windshield, Tire & Wheel, …) + ideally the same launch/effective date. For OEMs that
   run brand-paired product lines (Porsche PO*/QS*, VW/Audi/Ducati vs. QualityProtect — see Step 7),
   the sibling is the same coverage under the *other* brand code.
2. **Diff the structure, not just the value.** Term bands (`DISTINCT TERM_FROM, TERM_TO`), odometer
   bands, vehicle-condition coverage, and — per the rule above — **across full history**, not just
   the current window. A generic pattern (RoadRunner/GM shown; adapt table names for EAS/Legacy):
```sql
-- Tier 1 (Snowflake). {program_id} + the product family (adjust the IN-list to the sibling set).
SELECT p.PRODUCT_CODE, r.TERM_FROM, r.TERM_TO, r.START_SALE_DATE, r.END_SALE_DATE, COUNT(*) n
FROM STAGING.RR_UTILITY.RATE_SKU_GM r
JOIN STAGING.RR.PRODUCT p ON p.PRODUCT_ID = r.PRODUCT_ID
WHERE r.PROGRAM_ID = {program_id} AND p.PRODUCT_CODE IN ({sibling_codes})
GROUP BY p.PRODUCT_CODE, r.TERM_FROM, r.TERM_TO, r.START_SALE_DATE, r.END_SALE_DATE
ORDER BY p.PRODUCT_CODE, r.START_SALE_DATE, r.TERM_FROM;
```
3. **The product in question is the outlier, or it isn't.** If every sibling shares a structure and
   the one in question doesn't, that's a citable, differently-owned finding (a load gap, not a
   classing/eligibility question). If the "anomaly" turns out to match its actual sibling family
   (e.g. it's genuinely the competitive-brand product, correctly structured for that role), the
   sibling-diff is what proves it's working as designed instead of just asserting it.
4. **State the comparison explicitly in the verdict** — name the sibling set and what they share,
   not just "this looks off." That's the citable evidence, not a vibe.
