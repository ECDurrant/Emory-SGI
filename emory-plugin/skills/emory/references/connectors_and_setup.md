# Connector setup, probes & reconnect procedures

*Reference for the `emory` skill. Read this when SKILL.md points you here — it is the
full detail for that step, moved out so the main workflow stays readable.*

---

## Step -2 — Setup check (first run, or when a connector doesn't answer)

Emory runs on **the analyst's own connections** — it sees only what that analyst is
already permitted to see, read-only. No service account, no copied data. **Enforce the
connection set at the start of every session**: confirm each is reachable before working
cases. The full set Emory expects: Snowflake, EAS SQL Server, Forte Postgres, Microsoft 365
(read), and the in-app Claude Browser (for the Salesforce queue).

Probe each connector with a trivial call and report a short checklist:

| Connector | Probe | Unlocks | If missing |
|---|---|---|---|
| **Snowflake** (Tier 1) | `SELECT 1` | Fast path for most checks, both platforms | **Prompt — see below.** Falls back to live DBs (slower) or can't run |
| **EAS SQL Server** (Tier 2) | `SELECT 1` | Classing, today's edits, name-based views | **Prompt — see below.** Classing → NEEDS REVIEW; EAS status limited |
| **Forte Postgres** (Tier 3) | `SELECT 1` | Legacy dealers, contracts | **Prompt — see below.** Legacy-dealer cases can't be fully worked |
| **Microsoft 365** (read-only) | `get_me` | **Use it every session** — reads the `APISupport@sgintl.com` shared inbox (`outlook_email_search` w/ `mailboxOwnerEmail`), the SharePoint KB, and Teams chat search. Lets Emory pull cases straight from email, not just Salesforce. | **Prompt — see below.** |
| **Teams post** | — | Delivering the verdict to a channel | **No send scope granted** — deliver via a Workflows webhook (`curl` the card) or paste the draft manually |

Report it like this, then keep going:
```
Emory setup —
  ✅ Snowflake (Tier 1) — connected
  ✅ EAS SQL Server (Tier 2) — connected
  ⬜ Forte Postgres (Tier 3) — NOT found. Legacy-dealer cases will be limited.
     Add the `postgresql-mcp` connector (see wrapped_servers.json) to enable.
  ⬜ Teams — not wired. I'll print the update for you to paste until it's added.
```
- **All four data/intake connectors (Snowflake, EAS SQL Server, Forte Postgres, MS365)
  get an active prompt on failure, not just a checklist line** — see "Connector-down
  protocol" below. Only Teams-post stays a passive note (there's genuinely nothing to
  reconnect — it's an unfulfilled scope grant, not a broken connection).
- Only surface this checklist on first run or on a failed probe — don't reprint it
  every case.

**Connector-down protocol — prompt, don't just log it, for all four.** If a needed
connector fails its probe, don't silently degrade past it: **tell the analyst plainly which
connector is down and what it costs, then ask if they want to try reconnecting now** before
proceeding on whatever's left. Diagnose first — don't assume the same fix applies to every
connector, they're different systems:

- **Microsoft 365** — confirmed 2026-08-19: correctly wired into both
  `claude_desktop_config.json` and `wrapped_servers.json` (server name `ms365`), so a
  failing `get_me` is almost always an **expired MSAL device-code token**. Confirm with:
  ```bash
  "/c/Program Files/nodejs/node.exe" "$APPDATA/npm/node_modules/@softeria/ms-365-mcp-server/dist/index.js" --verify-login --org-mode
  # {"success":false,"message":"Login failed: No valid token found"} = confirmed expired token
  ```
  If confirmed and the analyst says yes to reconnecting, kick off the device-code flow
  yourself (needs their interactive sign-in — you cannot complete it for them):
  ```bash
  "/c/Program Files/nodejs/node.exe" "$APPDATA/npm/node_modules/@softeria/ms-365-mcp-server/dist/index.js" --login --org-mode
  ```
  Run via Bash `run_in_background` (it blocks polling for the browser step) and redirect
  its own output to a file you can `Read` directly (the harness's implicit background-task
  capture has been observed to sit empty for a while even once the process has printed its
  device code — don't trust it alone; tail your own redirected log). Relay the code/URL to
  the analyst as soon as it appears.
- **EAS SQL Server / Forte Postgres** — both run through the Prompt Security wrapper
  (`C:\pgmcp\wrapped_servers.json`) using AD-integrated auth (no password in the wrapper
  config), against on-prem hosts (`QTSPRODEASDB3`, `awsprodpgforte-3...`). **Diagnose the
  layer before blaming the network.** Open `%APPDATA%\Claude\logs\mcp-server-<name>.log`:
  a healthy server logs `Message from server: id=0 result` right after `initialize`.
  - **That line is missing** → the MCP server never started. This is a *launch-chain*
    failure, **not** credentials, VPN, or the database — the server scripts only open a
    connection inside a tool call, so auth and network problems still let `initialize`
    succeed and fail later, at query time. The usual cause is the wrapper's inner
    `server` block sitting in `claude_desktop_config.json`, which Claude Desktop strips;
    the wrapper then exits with **rc=0 and empty stderr**, which is why nothing useful is
    logged. **Fix — run the installer bundled with this plugin, then fully quit and
    restart Claude Desktop:**
    ```bash
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Setup-SGI-MCP.ps1
    ```
    It is idempotent and safe to re-run: it derives the analyst's DB login from
    `$env:USERNAME` (+ `@ETCH.COM`), finds any Python 3.10-3.13, writes the inner
    definitions to the sidecar, repairs a config already broken this way, and verifies a
    real MCP `initialize` handshake before returning. `-DryRun` previews without changing
    anything. Exit 0 = verified, 2 = configured but handshake failed, 3 = missing
    prerequisite, 4 = existing config corrupt (refused to overwrite).
  - **That line is present but queries fail** → *now* it is genuinely the connection:
    VPN/network reachability, a stale Kerberos ticket, or a missing Postgres role grant.
    Re-run the `SELECT 1` probe once before concluding it's down (transient blips happen);
    if it still fails, tell the analyst plainly, ask whether they're on VPN / can check
    their AD session, and offer to re-probe. A missing role grant needs the Postgres
    owner — it is not a config change and the installer cannot fix it.
- **Snowflake** — a hosted connector (not a local wrapper script), so there's no local CLI
  re-auth flow to fall back to. If `SELECT 1` fails, tell the analyst plainly and ask them
  to check the connector's status wherever they manage it (e.g. Claude Desktop's connector
  settings) — Emory can re-probe once they say they've done that, but can't reconnect it
  directly.
- **If the analyst declines, or isn't available to act** on any of the above: proceed on
  whatever connectors *are* live and say so plainly (NEEDS REVIEW on anything the missing
  connector would have answered) — same "never block forever" principle as before, just
  after asking first instead of silently degrading.

### Knowledge base (SharePoint) — the same brain as the cloud Emory agent

The Copilot Studio "Emory - SGI Enterprise Support Agent" is grounded on the SharePoint
site **`RatesTeamBAs`** — `safeguardproducts.sharepoint.com/sites/RatesTeamBAs/Shared Documents/`
with 9 subfolders (each a Copilot **SharePoint** knowledge source, verified 2026-08-05):
`Tools · SGI Portals (Phoenix Davinci) · SGI · SG DB Dictionaries + Core Table Details ·
OEM Eligibility Matrix · OEMs · General · File Feeds Ingestion - SOP and Docs · Documentation`.

**Read the same docs directly via the MS365 connection — no separate MCP:**
- `sharepoint_search(query=…)` finds KB docs (returns `webUrl` + a `uri`), then
  `read_resource(uri)` pulls full content.
- Use it for **definitions and procedure**, not live facts: table/column meanings
  (`SG DB Dictionary Edited.xlsx`), program runbooks — to ground a verdict or explain a
  field. Live DB checks remain the source of truth for current config.
- **For eligibility rules specifically, use the local Master Eligibility Matrix
  instead (Step 7 below) — it's cleaner and more complete than this SharePoint
  folder right now.** The "OEM Eligibility Matrix" knowledge source here only covers
  5 OEMs (BMW, GM, Honda, Nissan Canada, TFS) as of 2026-08-11; treat it as thin/stale
  until it's refreshed from the master workbook.

---

## Emory as an MCP server (stdio, per-analyst) — added 2026-09-16

Emory also runs as its own MCP server: `Downloads\emory-agent\emory_agent\mcp_server.py`,
registered as **`emory`** behind the Prompt Security wrapper (`C:\pgmcp\wrapped_servers.json`
inner definition + pointer in `claude_desktop_config.json`). Any MCP client gets:

| Surface | Purpose |
|---|---|
| `emory_investigate(dealer_code, vin?, product_code?, symptom?, sr?)` | the whole headless investigation → rich verdict JSON incl. `verification[]`. Delivers nothing. |
| `emory_post_verdict(verdict_json, confirm=false)` | renders through `emory_post.ps1`; `confirm=true` posts — **refused** without a valid `verification` array (INC1320603 gate, enforced in code). |
| `emory_connector_check()` | probes Tier 1/2/3 + delivery wiring. |
| `emory://skill`, `emory://guardrails`, `emory://reference/{name}` | this brain, read from `~/.claude/skills/emory/` (never vendored). |

Connector facts learned wiring it (apply to any Python-side Snowflake access):
- Snowflake SSO login is the **UPN** `you@sgintl.com`; role `SDA_ROLE`; warehouse **`SDA_WH`**
  (`EMORY_WH` does not exist). `STAGING.EAS` has `PROGRAM_VEHICLE_CLASS` (table) but **not** the
  `V_PROGRAM_VEHICLE_CLASS` view — classing stays Tier 2, as this SOP already says.
- Python HTTPS on SGI laptops goes through Prompt Security → Zscaler (`HTTPS_PROXY=127.0.0.1:9000`);
  the Snowflake connector needs the Windows-store roots (`db.ensure_ca_bundle()` handles it).
- Forte Postgres requires **GlobalProtect** (`vpn.sgintl.com`); on the office LAN alone TCP 5432
  times out and the interactive `postgresql-mcp` connector fails the same way.
Full setup: `Downloads\emory-agent\README.md`.
