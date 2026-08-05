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
