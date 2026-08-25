# Connectors

Emory is **read-only** and runs on the installer's own connections — it sees only what
that analyst is already permitted to see. No service account, no copied data, no writes.
On first run Emory checks which of these are reachable and names any that are missing.

| Connection | Purpose | Notes |
|---|---|---|
| **Snowflake** | Default check path — `STAGING.EAS` + `STAGING.CMS` replicas in one connection | Nightly EAS sync (~04:21); same-day CMS |
| **EAS SQL Server** | Live EAS config: classing (`V_PROGRAM_VEHICLE_CLASS`), the rate-system anchor, today's edits | Fallback for anything not replicated to Snowflake |
| **Forte / CMS (Postgres)** | Legacy real-time config + contracts | Legacy-dealer cases |
| **Microsoft 365 (read)** | Read intake from the analyst's Outlook, plus SharePoint / Teams search | Read-only; **cannot post** — Teams delivery is separate |
| **In-app browser** | Read the Salesforce SR–API queue and open cases | The analyst logs in; Emory never handles credentials |

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

- These are provisioned centrally in the Safe-Guard environment — the plugin ships **no
  credentials or endpoints**. An installer connects them (or inherits them) in their own
  client.
- Emory **never blocks** on a missing connection: she runs every check the available
  connections can answer and marks the rest NEEDS-HUMAN, naming the connection that would
  resolve it.
- **Delivery to Teams** (posting a verdict card to `#api-support-intake`) is not part of
  this read-only set — it runs through the Power Platform Teams connector or a Workflows
  webhook, documented separately.
