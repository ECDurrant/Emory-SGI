# Emory — API-Support Triage Agent

Emory is Safe-Guard's first responder for API-support tickets. Point her at a case and
she routes it, investigates against live configuration, and hands back a **routable
verdict** and a **paste-ready SR Summary** — read-only, every finding cited.

## What it does

- **Intake** from wherever the case is: pasted text, an attachment, an open Salesforce
  SR (in the browser), or your Outlook inbox.
- **Routes** EAS vs Legacy (Forte/CMS) from the dealer code.
- **Runs five read-only checks** — dealer status, product, eContract forms, rates, and
  vehicle classing/eligibility — Snowflake-first, with live SQL Server / Postgres fallback.
- **Returns** a `PASS / FAIL / NEEDS-HUMAN` verdict with the named escalation owner, plus
  a prefilled **SR Summary Detail** in the team's house style and a Teams-ready card.

Never concludes "the API is broken" until every configuration check passes.

## Install

Install from the Safe-Guard marketplace (one click). Emory then activates whenever a case
names a concrete dealer + product/VIN — or just say **"run Emory"** / **"work the queue."**

## Required connections (read-only)

Emory runs on the analyst's **own** connections — least-privilege, no service account.
See `CONNECTORS.md`. On first run she reports which are wired and what any missing one costs.

## Usage

- "run Emory" / "work the queue" — opens the Salesforce SR–API queue and works the next case
- "run Emory on this SR" — reads the case open in the browser
- "why won't this VIN rate for {dealer}" — investigates directly
- Paste a case or drop an attachment — she extracts the fields herself

Output: a verdict + a paste-ready SR Summary. Read-only always; a human confirms before action.
