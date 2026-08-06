# APIBRAIN Claims — Claims-Resolution Analyst

APIBRAIN Claims is Safe-Guard's senior analyst for **claims operations, payments, and
finance** — the sibling to Emory. Point it at a claims case and it grounds the answer in
the claims knowledge base, classifies the issue, names the owning team, and hands back a
**customer update** plus a **paste-ready SR Summary** — read-only, every finding cited.

## What it does

- **Intake** from wherever the case is: pasted text, an attachment, an open Salesforce
  SR, or your Outlook inbox.
- **Classifies** the issue across the claims domain — claim status, payment status /
  sequence, GL post date, ACH / bank / payee, OEM or dealer mapping, reconciliation, BI
  dashboard exceptions, sync, contract association / duplicate contracts, SG PPS / SG
  Express / SG Connect.
- **Grounds** every conclusion in the claims KB (SOP > BRD > RCA > Teams resolution
  threads > historical cases > emails) via the Microsoft 365 read connection, citing the
  doc + section behind each claim.
- **Returns** an issue classification, likely root cause (or an explicit "not confirmed"),
  recommended action, the **owning team**, similar historical issues, a confidence rating,
  a customer update, and a prefilled **SR Summary Detail**.

Never invents a root cause, owner, or fix — separates confirmed facts from assumptions.

## Emory ↔ Claims hand-off

The two agents triage by domain and route to each other. A **rating / eligibility /
"won't rate" / classing** case goes to **Emory**; a **claim / payment / finance** case
comes here. If a case is both (e.g. a contract-association problem blocking a claim), the
claims work stays here and the rating/contracting dependency is noted for Emory / CMS.

## Install

Install from the Safe-Guard marketplace (one click). It activates whenever a case involves
a claim number, a payment issue, a mapping/reconciliation problem, or an SG PPS/Express/
Connect payment case.

## Required connections (read-only)

Runs on the analyst's **own** connections — least-privilege, no service account. See
`CONNECTORS.md`.

## Usage

- "work this claims case" / "why wasn't this claim paid" — investigates directly
- "run this on the SR open in the browser" — reads the case on screen
- Paste a case or drop an attachment — it extracts the fields itself

Output: an issue classification + owning team + customer update + a paste-ready SR Summary.
Read-only always; recommends a data fix / DBCR — a human applies it.
