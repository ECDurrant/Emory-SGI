# Legacy / Forte (CMS) checks — fixed queries

*Reference for the `emory` skill. Read when the router (`references/routing.md`, R1) returns
LEGACY. Built and verified 2026-10-01 on Snowflake `STAGING.CMS` (same-day replica of Forte;
RECORDTIMESTAMP max = today). Written in portable SQL (CASE, COALESCE, no IFF/LISTAGG) so the
same text runs on **Forte Postgres (Tier 3)**: drop the `STAGING.CMS.` prefix and run with the
Forte search_path. Unquoted identifiers fold to lower case in Postgres, which matches Forte's
lower-case table names (`sg_dlr_m1`, …).*

> **Postgres status (2026-10-01): NOT re-verified live.** Forte needs GlobalProtect; TCP 5432
> timed out. The Snowflake replica is the default for Legacy reads; use live Postgres only when
> the case says the Legacy edit was made **today**, and confirm the schema name on first use.

**Sentinel:** Legacy open end-date = `1799-12-31` (not NULL, not 9999). Every "active" test is
`SDATE <= as_of AND (EDATE = '1799-12-31' OR EDATE >= as_of)`.

`1799-12-31` also appears as a **start** date (= "from the beginning"); the `<= as_of` test
handles it. **Make codes are 4-char CMS codes** (`ACUR`, `CHEV`, `MERZ`, `HYUN`), not names —
translate a decoded make with `STAGING.RR_UTILITY.MAKE.CMS_MAKE_CODE` (`MAKE_NAME` → code).
Models appear both bare and prefixed (`MDX` and `ACMDX`), so the token `LIKE` catches both.

**Two codes, never confuse them:**
- `SG_DRS_PLC` = the dealer's **enrolment plan** (e.g. `SAF1`, `PDK`, `ND`). One dealer has many.
- `SG_RSC_PLC` = the **product** a rate schedule sells (e.g. `UVPP`, `SAFE`, `HMVS`). This is what
  the case's product code matches.
- `SG_DLR_M1.SG_DLR_PLC` is only the dealer's primary/default plan — **never** use it to decide
  whether a product is enrolled (it repeats as `SAFE` across thousands of dealers).

---

## L0 — dealer status

```sql
SELECT SG_DLR_DEALER, SG_DLR_COMPANY, SG_DLR_AGENT, SG_DLR_CARRIER, SG_DLR_STATE,
       SG_DLR_SDATE, SG_DLR_EDATE, SG_DLR_OUTOFBUS,
       CASE WHEN SG_DLR_OUTOFBUS <> '1799-12-31' AND SG_DLR_OUTOFBUS <= {as_of} THEN 'OUT_OF_BUSINESS'
            WHEN SG_DLR_EDATE    <> '1799-12-31' AND SG_DLR_EDATE    <= {as_of} THEN 'END_DATED'
            WHEN SG_DLR_SDATE > {as_of} THEN 'NOT_YET_ACTIVE'
            ELSE 'ACTIVE' END AS dealer_status
FROM STAGING.CMS.SG_DLR_M1
WHERE SG_DLR_DEALER = '{code}';
```
A Legacy `OUT_OF_BUSINESS`/`END_DATED` does **not** make the dealer inactive if the router put the
case on EAS or RoadRunner — judge status on the platform that services the case.

## L1 — product enrolled + rate schedule + rates + forms + add-on classing (one query)

Checks 2, 4, 5 for Legacy in one round trip. One row per enrolment that sells `{product}`.

```sql
WITH p AS (SELECT '{code}' AS dealer, '{product}' AS product, {as_of} AS as_of),
enr AS (SELECT d.SG_DRS_DEALER, d.SG_DRS_PLC, d.SG_DRS_RS, d.SG_DRS_SDATE, d.SG_DRS_EDATE
        FROM STAGING.CMS.SG_DRS_M1 d, p
        WHERE d.SG_DRS_DEALER = p.dealer
          AND d.SG_DRS_SDATE <= p.as_of AND (d.SG_DRS_EDATE = '1799-12-31' OR d.SG_DRS_EDATE >= p.as_of)),
rs AS (SELECT e.SG_DRS_PLC, e.SG_DRS_RS, r.SG_RSC_PLC, r.SG_RSC_CARRIER, r.SG_RSC_RSTYPE,
              r.SG_RSC_SDATE, r.SG_RSC_EDATE,
              CASE WHEN r.SG_RSC_SDATE <= p.as_of
                    AND (r.SG_RSC_EDATE = '1799-12-31' OR r.SG_RSC_EDATE >= p.as_of) THEN 1 ELSE 0 END AS rs_active
       FROM enr e JOIN STAGING.CMS.SG_RSC_M1 r ON r.SG_RSC_RS = e.SG_DRS_RS, p
       WHERE r.SG_RSC_PLC = p.product)
SELECT rs.SG_DRS_PLC AS enrol_plc, rs.SG_DRS_RS AS rate_system, rs.SG_RSC_PLC AS product,
       rs.SG_RSC_CARRIER AS carrier, rs.SG_RSC_RSTYPE AS rstype, rs.SG_RSC_SDATE, rs.SG_RSC_EDATE, rs.rs_active,
       (SELECT COUNT(*) FROM STAGING.CMS.SG_RSC_D1 d1, p
         WHERE d1.SG_RSC1_RS = rs.SG_DRS_RS AND d1.SG_RSC1_SDATE <= p.as_of
           AND (d1.SG_RSC1_EDATE = '1799-12-31' OR d1.SG_RSC1_EDATE >= p.as_of)) AS d1_active_versions,
       (SELECT COUNT(*) FROM STAGING.CMS.SG_RSC_D2 d2 WHERE d2.SG_RSC2_RS = rs.SG_DRS_RS) AS d2_rate_rows,
       (SELECT COUNT(*) FROM STAGING.CMS.SG_FORM_M1 f, p
         WHERE f.SG_FORM_PLC = rs.SG_RSC_PLC AND f.SG_FORM_CARRIER = rs.SG_RSC_CARRIER
           AND f.SG_FORM_SDATE <= p.as_of AND (f.SG_FORM_EDATE = '1799-12-31' OR f.SG_FORM_EDATE >= p.as_of)) AS active_forms,
       (SELECT COUNT(*) FROM STAGING.CMS.SG_PLC_D1 c, p
         WHERE c.SG_PLC1_PLC = rs.SG_RSC_PLC AND c.SG_PLC1_SDATE <= p.as_of
           AND (c.SG_PLC1_EDATE = '1799-12-31' OR c.SG_PLC1_EDATE >= p.as_of)) AS addon_class_rows
FROM rs;
```

**Verified 2026-10-01** — `00SG1055` (Hinshaws Acura) + `UVPP`:

| enrol_plc | rate_system | carrier | rs_active | d1_active_versions | d2_rate_rows | active_forms | addon_class_rows |
|---|---|---|---|---|---|---|---|
| PDK | 60 PDK | VSSG | 1 | 1 | 112 | 946 | 18,108 |
| ND | 60 PDKND | VSSG | 1 | 1 | 168 | 946 | 18,108 |

**Reading it:**

| Result | Verdict | Owner |
|---|---|---|
| zero rows | product not enrolled for this dealer on Legacy (re-run without the date filter on `enr` to tell never-enrolled from end-dated) | Acct Mgmt |
| `rs_active = 0` on every row | enrolment points at an end-dated rate schedule (normal history if another row is active) | Rates & Forms |
| `d1_active_versions = 0` | rate schedule has no active version for the sale date | Rates & Forms |
| `d2_rate_rows = 0` | schedule exists but carries no rate rows | Rates & Forms |
| `active_forms = 0` | no active form for product × carrier | Rates & Forms (forms) |
| `addon_class_rows = 0` and the product is an add-on (classed via `SG_PLC_D1`) | product silently drops from a successful response | Pricing / Risk |

The classing PLC for add-ons comes from the **rate system** (`SG_RSC_PLC`), not the enrolment
PLC — see the `legacy-addon-classing-sg-plc-d1` memory.

## L2 — VSC classing for the VIN (carrier from L1)

```sql
SELECT VSC_CLASS_CAR, VSC_CLASS_MAKE, VSC_CLASS_MODEL, VSC_CLASS_SYEAR, VSC_CLASS_EYEAR,
       VSC_CLASS_CLASS, VSC_CLASS_RGROUP, VSC_CLASS_WTERM, VSC_CLASS_WMILES
FROM STAGING.CMS.VSC_CLASS_M1
WHERE VSC_CLASS_CAR = '{carrier}'
  AND VSC_CLASS_MAKE = '{make}'
  AND {year} BETWEEN VSC_CLASS_SYEAR AND VSC_CLASS_EYEAR
  AND UPPER(VSC_CLASS_MODEL) LIKE '%' || UPPER('{model_token}') || '%';
```
Token-match the model (never `=`). Several rows → narrow by `VSC_CLASS_RGROUP`. A capped class
(e.g. GM trucks to `G9`) limits term/miles — see the `vsc-g9-capped-class` memory.

## L3 — add-on classing rows for the VIN's make/model

```sql
SELECT SG_PLC1_PLC, SG_PLC1_MAKE, SG_PLC1_MODEL, SG_PLC1_GROUP, SG_PLC1_CLASS, SG_PLC1_CPO,
       SG_PLC1_SDATE, SG_PLC1_EDATE
FROM STAGING.CMS.SG_PLC_D1
WHERE SG_PLC1_PLC = '{product}'
  AND SG_PLC1_MAKE = '{make}'
  AND UPPER(SG_PLC1_MODEL) LIKE '%' || UPPER('{model_token}') || '%'
  AND SG_PLC1_SDATE <= {as_of} AND (SG_PLC1_EDATE = '1799-12-31' OR SG_PLC1_EDATE >= {as_of});
```
No row for the model → "No coverage for this vehicle" even though the call returns 200.

## L4 — contracts for the VIN (Legacy side of the duplicate sweep)

```sql
SELECT SG_CON_CONTRACT, SG_CON_DEALER, SG_CON_PLC, SG_CON_FORM, SG_CON_STATUS,
       SG_CON_SALEDATE, SG_CON_BUSDATE, SG_CON_TERM, SG_CON_ODOM, SG_CON_RS
FROM STAGING.CMS.SG_CON_M1
WHERE SG_CON_VIN = '{vin}'
ORDER BY SG_CON_SALEDATE DESC;
-- Unremitted / pending contracts are NOT here — check STAGING.CMS.QUOTES_CONTRACTS too
-- (CONTRACT_STATUS 'P' never remits but is not void; 'V' is the real void).
```
`SG_CON_M1` holds customer PII (name, address, phone). Select only the columns above; never
put names or addresses in a verdict.

## Plan / coverage lookups (labels for the verdict)

```sql
SELECT SG_PLC_PLC, SG_PLC_DESC, SG_PLC_RSTYPE, SG_PLC_SSDATE, SG_PLC_ESDATE
FROM STAGING.CMS.SG_PLC_M1 WHERE SG_PLC_PLC IN ('{product}', '{enrol_plc}');

SELECT SG_COV_COVER, SG_COV_DESC, SG_COV_SDATE, SG_COV_EDATE
FROM STAGING.CMS.SG_COV_M1 WHERE SG_COV_COVER = '{coverage}';

SELECT SG_CAR_CARRIER, SG_CAR_DESC FROM STAGING.CMS.SG_CAR_M1 WHERE SG_CAR_CARRIER = '{carrier}';
```
