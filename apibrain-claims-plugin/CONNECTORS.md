# Connectors

APIBRAIN Claims is **read-only** and runs on the installer's own connections — it sees
only what that analyst is already permitted to see. No service account, no copied data, no
writes. It is **knowledge-driven** (grounds answers in the claims KB), not DB-driven.

| Connection | Purpose | Notes |
|---|---|---|
| **Microsoft 365 (read)** | **Primary.** Reads the claims KB on SharePoint (`sharepoint_search` → `read_resource`), plus the Claims / App-Support inboxes and Teams resolution threads | Read-only; cite the doc + section behind each finding |
| **Snowflake / EAS SQL Server / Forte (Postgres)** | Optional corroboration of a fact when the KB points to config or contract data | Read-only; the KB remains the source of reasoning |
| **In-app browser** | Read the Salesforce SR / case open on screen | The analyst logs in; the skill never handles credentials |

## Knowledge base

The claims KB lives on a SharePoint site (Claims SOPs, BRDs, Claims Flow docs, RCA
library, Audit docs), read via the Microsoft 365 connection with the same
`sharepoint_search` → `read_resource` pattern Emory uses for `RatesTeamBAs`. The priority
order on conflict is **SOP > BRD > RCA > Teams resolution threads > historical cases >
emails / chats**.

> **Wiring status:** the exact Claims SharePoint site/folders are set in the skill's
> *"Connections & knowledge base"* section. Until they are confirmed, the skill says
> "KB source not yet wired" and marks Confidence Low wherever a citation would be required.

## Notes

- These connections are provisioned centrally in the Safe-Guard environment — the plugin
  ships **no credentials or endpoints**. An installer connects them (or inherits them) in
  their own client.
- The skill **never blocks** on a missing connection: it works from the case facts it has,
  lists what's missing, and marks confidence accordingly.
- Read-only always — it recommends a data fix / DBCR; a human applies it.
