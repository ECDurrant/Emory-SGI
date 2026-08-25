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

## First-time setup — the local database connectors (run once per machine)

**Installing this plugin does not create the database connections.** The skill is
instructions; the Postgres / SQL Server / Mongo connections are local MCP servers that
run on the analyst's own machine behind the Prompt Security wrapper. A new analyst who
installs the plugin without them will see the skill load and every data check fail.

Run this once, then fully quit and restart Claude Desktop:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Setup-SGI-MCP.ps1
```

Nothing to edit. It derives the analyst's DB login from `$env:USERNAME` + `@ETCH.COM`
(every platform uses the same first-initial + lastname identity), finds any Python
3.10-3.13, installs the Python dependencies, writes the wrapper sidecar, repairs a
config broken by the retired v1 installer, and verifies a real MCP handshake before it
returns. Add `-DryRun` to preview without changing anything, or `-Quiet` for unattended
rollout.

Passwords are never stored: Postgres uses SSPI/Kerberos, SQL Server uses
`Trusted_Connection`, and Mongo authenticates as the signed-in Azure AD identity.

Two things the installer cannot do, because they are not config:

- **Grant database access.** The analyst's Postgres role must exist and be granted on
  `forte`. If a server connects but a *query* fails with an auth error, that is the
  grant — it needs the database owner.
- **Install the Prompt Security wrapper, or the Microsoft ODBC Driver 18 for SQL
  Server.** The installer reports both as missing if they are; SQL Server queries need
  the driver, Postgres and Mongo do not.

Snowflake and Microsoft 365 are separate: Snowflake is a hosted connector configured in
the client, and MS365 uses an interactive device-code login.

## Notes

- These connections are provisioned centrally in the Safe-Guard environment — the plugin
  ships **no credentials or endpoints**. An installer connects them (or inherits them) in
  their own client.
- The skill **never blocks** on a missing connection: it works from the case facts it has,
  lists what's missing, and marks confidence accordingly.
- Read-only always — it recommends a data fix / DBCR; a human applies it.
