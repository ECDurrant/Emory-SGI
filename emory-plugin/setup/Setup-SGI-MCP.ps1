<#
    Setup-SGI-MCP.ps1   (v2.1)

    One-shot, unattended setup of Safe-Guard's read-only database MCP servers
    for Claude Desktop, behind the Prompt Security DLP wrapper.

    Configures: postgresql-mcp (Forte), sqlserver (SGEAS), mongodb-gm (Atlas),
                and preserves any existing github / ms365 entries.
                Snowflake has a ready-to-fill slot - see SNOWFLAKE below.
                -WithEmory (v2.1) also installs the Emory MCP server: copies the
                emory-agent code, builds its own venv, writes a per-user .env,
                registers it behind the wrapper and installs the claude-CLI
                login keep-alive task. Idempotent; never overwrites an existing .env.

    WHY v2 EXISTS
    -------------
    v1 (Setup-DB-MCP.ps1 + merge_claude_config.py) wrote each server's inner
    "server" block INTO claude_desktop_config.json, and pointed the wrapper at
    that same file. Claude Desktop STRIPS the "server" key out of that file, so
    the wrapper launches with nothing behind it and exits silently right after
    the initialize handshake - the server appears to start, then disconnects.

    v2 writes the inner definitions to a SEPARATE sidecar file
    (C:\pgmcp\wrapped_servers.json) that Claude Desktop never rewrites, and
    leaves only {command, args} in claude_desktop_config.json.

    NO HAND-EDITING. Every per-user value is derived at run time:
      DB login      <- $env:USERNAME  (first initial + last name)
                       edurrant -> edurrant@ETCH.COM
                       mkouassi -> mkouassi@ETCH.COM
      python.exe    <- discovered (any 3.10 - 3.13)
      node.exe      <- discovered
      script paths  <- $env:USERPROFILE

    USAGE
      Interactive, one machine:
        .\Setup-SGI-MCP.ps1

      Unattended / background (login script, Intune, GPO):
        powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\Setup-SGI-MCP.ps1 -Quiet

      Self-healing (re-asserts config at every logon; idempotent, fast no-op):
        .\Setup-SGI-MCP.ps1 -RegisterLogonTask

      Emory MCP for an API-support analyst (source = the emory-agent folder
      shipped next to this script, or -EmorySource <path>):
        .\Setup-SGI-MCP.ps1 -WithEmory
      Also re-asserts the Emory pointer at logon (Claude Desktop drops entries
      added while it is running unless it is restarted):
        .\Setup-SGI-MCP.ps1 -WithEmory -RegisterLogonTask

    EXIT CODES
      0 = configured, handshake verified
      2 = configured, but a server failed the handshake self-test
      3 = missing prerequisite (no wrapper / no Python / pip failed)
#>

[CmdletBinding()]
param(
    [string]   $SgiUser = $env:USERNAME,
    [string[]] $Servers = @("postgresql-mcp", "sqlserver", "mongodb-gm"),
    [string]   $SidecarPath = "C:\pgmcp\wrapped_servers.json",
    [switch]   $Quiet,
    [switch]   $SkipDeps,
    [switch]   $NoSelfTest,
    [switch]   $RegisterLogonTask,
    # Emory MCP server (see header). Source defaults to <script dir>\emory-agent,
    # then %USERPROFILE%\Downloads\emory-agent. Dest is where it runs from.
    [switch]   $WithEmory,
    [string]   $EmorySource = "",
    [string]   $EmoryDest   = (Join-Path $env:USERPROFILE "emory-agent"),
    # Writes the sidecar and Claude config into a throwaway folder and prints
    # them, touching nothing real. Validate here before any rollout.
    [switch]   $DryRun
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------- logging ----
$logDir = Join-Path $env:LOCALAPPDATA "SGI-MCP-Setup"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("setup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

function Say {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Msg
    Add-Content -Path $logFile -Value $line -Encoding utf8
    if (-not $Quiet) {
        $color = "Gray"
        if ($Level -eq "OK")   { $color = "Green"  }
        if ($Level -eq "WARN") { $color = "Yellow" }
        if ($Level -eq "FAIL") { $color = "Red"    }
        if ($Level -eq "STEP") { $color = "Cyan"   }
        Write-Host $line -ForegroundColor $color
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

Say "Setup-SGI-MCP v2.1 starting for user '$SgiUser'" "STEP"
Say "Log file: $logFile"

# ------------------------------------------------- optional: logon task ------
if ($RegisterLogonTask) {
    $stableDir = "C:\pgmcp"
    if (-not (Test-Path $stableDir)) { New-Item -ItemType Directory -Path $stableDir -Force | Out-Null }
    $stablePath = Join-Path $stableDir "Setup-SGI-MCP.ps1"
    Copy-Item -Path $PSCommandPath -Destination $stablePath -Force
    $psArgs  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " + [char]34 + $stablePath + [char]34 + " -Quiet"
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    try {
        Register-ScheduledTask -TaskName "SGI MCP Setup (self-heal)" -Action $action -Trigger $trigger `
            -Settings $set -Description "Re-asserts Claude Desktop MCP sidecar config at logon." -Force | Out-Null
        Say "Registered logon task; script copied to $stablePath" "OK"
    } catch {
        Say "Could not register scheduled task: $($_.Exception.Message)" "WARN"
    }
}

# --------------------------------------------- prerequisite: PS wrapper ------
$wrapperLong = "C:\Program Files\PromptSecurity\prompt_security_mcp.exe"
if (-not (Test-Path $wrapperLong)) {
    Say "Prompt Security MCP wrapper not found at $wrapperLong - install Prompt Security first." "FAIL"
    exit 3
}
Say "Wrapper present" "OK"

# --------------------------------------------------- prerequisite: Python ----
Say "Locating Python 3.10+ ..." "STEP"
$pyCandidates = @(
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "C:\Program Files\Python313\python.exe",
    "C:\Program Files\Python312\python.exe",
    "C:\Program Files\Python311\python.exe",
    "C:\Program Files\Python310\python.exe"
)
$PY = $null
foreach ($c in $pyCandidates) { if (Test-Path $c) { $PY = $c; break } }
if (-not $PY) {
    try {
        $probe = (& py -3 -c "import sys; print(sys.executable)" 2>$null)
        if ($probe) { $PY = ($probe | Select-Object -First 1).Trim() }
    } catch { }
}
if (-not $PY) {
    try { $PY = (Get-Command python -ErrorAction Stop).Source } catch { }
}
if (-not $PY -or -not (Test-Path $PY)) {
    Say "No Python 3.10+ found. Install Python (3.10-3.13) and re-run." "FAIL"
    exit 3
}
$pyVer = (& $PY -c "import sys;print('%d.%d'%sys.version_info[:2])").Trim()
Say "Using Python $pyVer at $PY" "OK"

# ----------------------------------------------------- prerequisite: Node ----
$NODE = ""
$wantMongo = $Servers -contains "mongodb-gm"
if ($wantMongo) {
    foreach ($c in @("C:\Program Files\nodejs\node.exe", "C:\Program Files (x86)\nodejs\node.exe")) {
        if (Test-Path $c) { $NODE = $c; break }
    }
    if (-not $NODE) {
        Say "node.exe not found - skipping mongodb-gm (Postgres/SQL Server unaffected)." "WARN"
        $Servers = @($Servers | Where-Object { $_ -ne "mongodb-gm" })
        $wantMongo = $false
    } else {
        Say "Using Node at $NODE" "OK"
    }
}

# ------------------------------------------------------------ dependencies ---
if (-not $SkipDeps) {
    Say "Installing Python dependencies (mcp<2, psycopg2-binary, pyodbc) ..." "STEP"
    # Two fixes (v2.1): (1) pin mcp<2 - the connector scripts import mcp.server.fastmcp,
    # which mcp 2.x renamed; an unpinned --upgrade would break sqlserver/postgresql-mcp on
    # the next restart. (2) run pip through cmd so its stderr chatter (pip's own upgrade
    # notice, wheel warnings) cannot become a terminating NativeCommandError under
    # $ErrorActionPreference = Stop - which is how a healthy install died silently before.
    $pipPkgs = '"mcp<2" psycopg2-binary pyodbc'
    $pipOut = & cmd /c "`"$PY`" -m pip install --upgrade --quiet $pipPkgs 2>&1"
    $pipOut | ForEach-Object { Say $_ }
    if ($LASTEXITCODE -ne 0) {
        Say "Machine-wide pip install failed (likely no admin) - retrying with --user" "WARN"
        $pipOut = & cmd /c "`"$PY`" -m pip install --upgrade --user --quiet $pipPkgs 2>&1"
        $pipOut | ForEach-Object { Say $_ }
        if ($LASTEXITCODE -ne 0) { Say "pip install failed - see log." "FAIL"; exit 3 }
    }
    Say "Python dependencies OK" "OK"

    if ($wantMongo) {
        $mongoModule = Join-Path $env:APPDATA "npm\node_modules\mongodb-mcp-server\dist\index.js"
        if (-not (Test-Path $mongoModule)) {
            Say "Installing mongodb-mcp-server globally via npm ..." "STEP"
            & cmd /c "npm install -g mongodb-mcp-server" 2>&1 | ForEach-Object { Say $_ }
            if (-not (Test-Path $mongoModule)) {
                Say "mongodb-mcp-server did not install - dropping mongodb-gm from this run." "WARN"
                $Servers = @($Servers | Where-Object { $_ -ne "mongodb-gm" })
                $wantMongo = $false
            }
        } else {
            Say "mongodb-mcp-server already present" "OK"
        }
    }
} else {
    Say "Skipping dependency install (-SkipDeps)" "WARN"
}

# ---------------------------------------------------------- Emory MCP -------
$EMORY_PY = ""; $EMORY_SKILL = ""
if ($WithEmory) {
    if ($Servers -notcontains "emory") { $Servers = @($Servers) + "emory" }
    Say "Setting up the Emory MCP server ..." "STEP"

    # emory-agent needs Python 3.11+ (claude-agent-sdk, mcp 1.x)
    $pyMinor = [int]($pyVer.Split(".")[1])
    if ($pyMinor -lt 11) { Say "Emory needs Python 3.11+ (found $pyVer). Install 3.13 and re-run." "FAIL"; exit 3 }

    # 1. locate source
    if (-not $EmorySource) {
        foreach ($cand in @((Join-Path $PSScriptRoot "emory-agent"),
                            (Join-Path $env:USERPROFILE "Downloads\emory-agent"))) {
            if (Test-Path (Join-Path $cand "emory_agent\mcp_server.py")) { $EmorySource = $cand; break }
        }
    }
    if (-not $EmorySource -or -not (Test-Path (Join-Path $EmorySource "emory_agent\mcp_server.py"))) {
        Say "emory-agent source not found (looked next to this script and in Downloads). Pass -EmorySource <folder>." "FAIL"; exit 3
    }
    Say "Emory source    : $EmorySource" "OK"

    # 2. copy code to dest (code only - never .env, .venv or caches); skip when source == dest
    $srcFull = (Resolve-Path $EmorySource).Path.TrimEnd('\')
    $dstFull = [System.IO.Path]::GetFullPath($EmoryDest).TrimEnd('\')
    $EmoryDest = $dstFull
    if ($srcFull -ieq $dstFull) {
        Say "Emory dest = source; using it in place" "OK"
    } elseif (-not $DryRun) {
        New-Item -ItemType Directory -Path $dstFull -Force | Out-Null
        & robocopy $srcFull $dstFull /E /XD .venv __pycache__ .git /XF .env "*.log" /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Say "robocopy failed (rc=$LASTEXITCODE) copying emory-agent" "FAIL"; exit 3 }
        Say "Emory code copied -> $dstFull" "OK"
    } else {
        Say "DRY RUN - would copy $srcFull -> $dstFull" "WARN"
    }

    # 3. venv + requirements
    $EMORY_PY = Join-Path $dstFull ".venv\Scripts\python.exe"
    if (-not $DryRun) {
        if (-not (Test-Path $EMORY_PY)) {
            Say "Creating Emory venv with $PY ..." "STEP"
            & cmd /c "`"$PY`" -m venv `"$(Join-Path $dstFull '.venv')`" 2>&1" | ForEach-Object { Say $_ }
            if (-not (Test-Path $EMORY_PY)) { Say "venv creation failed" "FAIL"; exit 3 }
        }
        if (-not $SkipDeps) {
            Say "Installing Emory requirements (claude-agent-sdk, mcp, DB drivers) ..." "STEP"
            $req = Join-Path $dstFull "requirements.txt"
            & cmd /c "`"$EMORY_PY`" -m pip install --quiet --upgrade pip 2>&1" | Out-Null
            $pipOut = & cmd /c "`"$EMORY_PY`" -m pip install --quiet -r `"$req`" 2>&1"
            $pipOut | ForEach-Object { Say $_ }
            if ($LASTEXITCODE -ne 0) { Say "Emory pip install failed - see log." "FAIL"; exit 3 }
            & cmd /c "`"$EMORY_PY`" -m pip install --quiet `"snowflake-connector-python[secure-local-storage]`" 2>&1" | Out-Null
        }
        Say "Emory venv ready: $EMORY_PY" "OK"
    }

    # 4. canonical brain: the skill must exist for this user
    $EMORY_SKILL = Join-Path $env:USERPROFILE ".claude\skills\emory\SKILL.md"
    if (-not (Test-Path $EMORY_SKILL)) {
        $pluginSkill = @((Join-Path $PSScriptRoot "emory-plugin\skills\emory"),
                         (Join-Path $env:USERPROFILE "Downloads\emory-plugin\skills\emory")) |
                       Where-Object { Test-Path (Join-Path $_ "SKILL.md") } | Select-Object -First 1
        if ($pluginSkill -and -not $DryRun) {
            New-Item -ItemType Directory -Path (Split-Path $EMORY_SKILL) -Force | Out-Null
            & robocopy $pluginSkill (Split-Path $EMORY_SKILL) /E /XF "secrets.json" /NFL /NDL /NJH /NJS /NP | Out-Null
            Say "Emory skill installed from plugin -> $(Split-Path $EMORY_SKILL)" "OK"
        } else {
            Say "Emory skill not found at $EMORY_SKILL - install the emory plugin/skill first; the MCP refuses to start without it." "WARN"
        }
    } else { Say "Emory skill present : $EMORY_SKILL" "OK" }

    # 5. per-user .env - written once, never overwritten
    $envPath = Join-Path $dstFull ".env"
    if (Test-Path $envPath) {
        Say "Emory .env already exists - left untouched" "OK"
    } elseif (-not $DryRun) {
        $rand = { param($n) $b = New-Object byte[] ($n * 2); [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); (([Convert]::ToBase64String($b)) -replace '[^A-Za-z0-9]','').Substring(0, $n) }
        $urlFile = Join-Path $env:USERPROFILE "Downloads\emory_verdict_delivery_url.txt"
        $envText = @(
            "# Emory Agent - generated by Setup-SGI-MCP.ps1 for $SgiUser on $(Get-Date -Format 'yyyy-MM-dd'). Your own identity; no shared passwords.",
            "EMORY_SKILL_PATH=$EMORY_SKILL",
            "EMORY_MAX_TURNS=60",
            "EMORY_SHARED_SECRET=$(& $rand 40)",
            "EMORY_DELIVERY_URL_FILE=$urlFile",
            "EMORY_AUTOPOST=off",
            "",
            "SNOWFLAKE_ACCOUNT=GQA62108",
            "SNOWFLAKE_USER=$SgiUser@sgintl.com",
            "SNOWFLAKE_AUTHENTICATOR=externalbrowser",
            "SNOWFLAKE_WAREHOUSE=SDA_WH",
            "SNOWFLAKE_DATABASE=STAGING",
            "",
            "SQLSERVER_HOST=QTSPRODEASDB3",
            "SQLSERVER_DATABASE=SGEAS_DIFF",
            "ODBC_DRIVER=ODBC Driver 18 for SQL Server",
            "",
            "PGHOST=awsprodpgforte-3.cmrjwlo0vmya.us-east-1.sgintlnet.com",
            "PGPORT=5432",
            "PGDATABASE=forte",
            "PGUSER=$SgiUser@ETCH.COM",
            "",
            "# HTTP transport (only if this machine hosts the SIA pilot): python -m emory_agent.http_server",
            "EMORY_HTTP_TOKEN=$(& $rand 43)",
            "EMORY_HTTP_HOST=127.0.0.1",
            "EMORY_HTTP_PORT=8790"
        ) -join "`n"
        Write-Utf8NoBom -Path $envPath -Text $envText
        Say "Emory .env written (Snowflake user $SgiUser@sgintl.com, Forte user $SgiUser@ETCH.COM)" "OK"
        if (-not (Test-Path $urlFile)) { Say "Teams delivery URL file not present ($urlFile) - posting to Teams stays disabled until the analyst receives it (it is a secret, not shipped)." "WARN" }
    } else { Say "DRY RUN - would write $envPath" "WARN" }
}

# ---------------------------------------------- deploy inner server scripts --
Say "Deploying MCP server scripts ..." "STEP"
if (-not (Test-Path "C:\pgmcp")) { New-Item -ItemType Directory -Path "C:\pgmcp" -Force | Out-Null }

$pgServerPy = @'
r"""
PostgreSQL MCP server for Claude Desktop.
Read-only: only SELECT / WITH / EXPLAIN / SHOW / TABLE queries are allowed.
Auth uses your Windows login (SSPI/Kerberos) when no password is supplied,
the same way pgAdmin connects.

Connection details come from environment variables set in the wrapper sidecar
(C:\pgmcp\wrapped_servers.json -> this server's "env" block):
    PGHOST      - database host           (required)
    PGDATABASE  - database name           (required)
    PGPORT      - port (default 5432)
    PGUSER      - login user (default: your Windows user)

Dependencies:  pip install mcp psycopg2-binary
"""

import os
import psycopg2
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("postgresql-mcp")

READ_ONLY_PREFIXES = ("select", "with", "explain", "show", "table")


def _connect():
    return psycopg2.connect(
        host=os.environ["PGHOST"],
        dbname=os.environ["PGDATABASE"],
        port=int(os.environ.get("PGPORT", 5432)),
        user=os.environ.get("PGUSER") or os.environ.get("USERNAME"),
        # no password -> libpq uses Windows SSPI/Kerberos automatically
        connect_timeout=10,
    )


def _is_read_only(sql: str) -> bool:
    return sql.strip().lower().startswith(READ_ONLY_PREFIXES)


@mcp.tool()
def list_tables(schema: str = "public") -> str:
    """List tables in a schema (default 'public')."""
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema = %s ORDER BY table_name",
            (schema,),
        )
        rows = [r[0] for r in cur.fetchall()]
    return "\n".join(rows) if rows else f"(no tables in schema '{schema}')"


@mcp.tool()
def describe_table(table: str, schema: str = "public") -> str:
    """Show column names and types for a table."""
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT column_name, data_type, is_nullable "
            "FROM information_schema.columns "
            "WHERE table_schema = %s AND table_name = %s "
            "ORDER BY ordinal_position",
            (schema, table),
        )
        rows = cur.fetchall()
    if not rows:
        return f"(table '{schema}.{table}' not found)"
    return "\n".join(f"{c}\t{t}\t{'NULL' if n == 'YES' else 'NOT NULL'}"
                     for c, t, n in rows)


@mcp.tool()
def run_query(sql: str, max_rows: int = 200) -> str:
    """Run a read-only SQL query (SELECT/WITH/EXPLAIN/SHOW) and return rows."""
    if not _is_read_only(sql):
        return "ERROR: only read-only queries are allowed."
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(sql)
        cols = [d[0] for d in cur.description] if cur.description else []
        rows = cur.fetchmany(max_rows)
    if not cols:
        return "(query returned no columns)"
    out = ["\t".join(cols)]
    out += ["\t".join("" if v is None else str(v) for v in row) for row in rows]
    if len(rows) == max_rows:
        out.append(f"... (truncated at {max_rows} rows)")
    return "\n".join(out)


if __name__ == "__main__":
    mcp.run()
'@

$mssqlServerPy = @'
r"""
SQL Server MCP server for Claude Desktop.
Read-only: only SELECT / WITH / EXPLAIN queries are allowed.
Auth uses your Windows login (Trusted_Connection) - no password stored.

Connection details come from environment variables set in the wrapper sidecar
(C:\pgmcp\wrapped_servers.json -> this server's "env" block):
    SQLSERVER_HOST      - server name        (required)
    SQLSERVER_DATABASE  - database name      (required)
    ODBC_DRIVER         - e.g. "ODBC Driver 18 for SQL Server"

Dependencies:  pip install mcp pyodbc
(plus the Microsoft ODBC Driver 18 for SQL Server installed on Windows)
"""

import os
import pyodbc
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("sqlserver")

READ_ONLY_PREFIXES = ("select", "with", "explain", "show")


def _connect():
    driver = os.environ.get("ODBC_DRIVER", "ODBC Driver 18 for SQL Server")
    conn_str = (
        f"DRIVER={{{driver}}};"
        f"SERVER={os.environ['SQLSERVER_HOST']};"
        f"DATABASE={os.environ['SQLSERVER_DATABASE']};"
        "Trusted_Connection=yes;"      # Windows auth, no password
        "Encrypt=yes;"
        "TrustServerCertificate=yes;"  # common for internal servers
    )
    return pyodbc.connect(conn_str, timeout=10)


def _is_read_only(sql: str) -> bool:
    return sql.strip().lower().startswith(READ_ONLY_PREFIXES)


@mcp.tool()
def list_tables(schema: str = "dbo") -> str:
    """List tables in a schema (default 'dbo')."""
    with _connect() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES "
            "WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'BASE TABLE' "
            "ORDER BY TABLE_NAME",
            schema,
        )
        rows = [r[0] for r in cur.fetchall()]
    return "\n".join(rows) if rows else f"(no tables in schema '{schema}')"


@mcp.tool()
def describe_table(table: str, schema: str = "dbo") -> str:
    """Show column names and types for a table."""
    with _connect() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE "
            "FROM INFORMATION_SCHEMA.COLUMNS "
            "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? "
            "ORDER BY ORDINAL_POSITION",
            schema, table,
        )
        rows = cur.fetchall()
    if not rows:
        return f"(table '{schema}.{table}' not found)"
    return "\n".join(f"{c}\t{t}\t{'NULL' if n == 'YES' else 'NOT NULL'}"
                     for c, t, n in rows)


@mcp.tool()
def run_query(sql: str, max_rows: int = 200) -> str:
    """Run a read-only SQL query (SELECT/WITH/EXPLAIN) and return rows."""
    if not _is_read_only(sql):
        return "ERROR: only read-only queries are allowed."
    with _connect() as conn:
        cur = conn.cursor()
        cur.execute(sql)
        cols = [d[0] for d in cur.description] if cur.description else []
        rows = cur.fetchmany(max_rows)
    if not cols:
        return "(query returned no columns)"
    out = ["\t".join(cols)]
    out += ["\t".join("" if v is None else str(v) for v in row) for row in rows]
    if len(rows) == max_rows:
        out.append(f"... (truncated at {max_rows} rows)")
    return "\n".join(out)


if __name__ == "__main__":
    mcp.run()
'@

if ($DryRun) {
    Say "DRY RUN - would write C:\pgmcp\pg_mcp_server.py and $env:USERPROFILE\sqlserver_mcp.py (skipped)" "WARN"
} else {
    Write-Utf8NoBom -Path "C:\pgmcp\pg_mcp_server.py" -Text $pgServerPy
    Say "Wrote C:\pgmcp\pg_mcp_server.py" "OK"
    Write-Utf8NoBom -Path (Join-Path $env:USERPROFILE "sqlserver_mcp.py") -Text $mssqlServerPy
    Say ("Wrote " + (Join-Path $env:USERPROFILE "sqlserver_mcp.py")) "OK"
}

# ---------------------------------------- generate sidecar + Claude config ---
$genPy = @'
import json, os, sys, shutil, datetime

sgi_user  = sys.argv[1]
py_exe    = sys.argv[2]
node_exe  = sys.argv[3]
managed   = [s for s in sys.argv[4].split(",") if s]
SIDECAR   = sys.argv[5]          # passed in so -DryRun can redirect it
CFG       = sys.argv[6]
pg_script = sys.argv[7]
emory_py    = sys.argv[8]  if len(sys.argv) > 8  else ""
emory_root  = sys.argv[9]  if len(sys.argv) > 9  else ""
emory_skill = sys.argv[10] if len(sys.argv) > 10 else ""
# "-" is the placeholder the PowerShell side sends for an empty value (see ArgOrDash)
node_exe, emory_py, emory_root, emory_skill = [("" if v == "-" else v) for v in (node_exe, emory_py, emory_root, emory_skill)]

appdata = os.environ["APPDATA"]
profile = os.environ["USERPROFILE"]

# 8.3 short path: the wrapper is invoked without quoting by some hosts, so the
# space-free form is the safe one to store.
WRAPPER = "C:\\PROGRA~1\\PROMPT~1\\prompt_security_mcp.exe"

mssql_script = os.path.join(profile, "sqlserver_mcp.py")
mongo_module = os.path.join(appdata, "npm", "node_modules",
                            "mongodb-mcp-server", "dist", "index.js")

DB_LOGIN = sgi_user + "@ETCH.COM"

# ---------------------------------------------------------------------------
# Server definitions. Everything per-user is already resolved above, so adding
# a new server is a single entry here.
# ---------------------------------------------------------------------------
DEFS = {
    "postgresql-mcp": {
        "command": py_exe,
        "args": [pg_script],
        "env": {
            "PGHOST": "awsprodpgforte-3.cmrjwlo0vmya.us-east-1.sgintlnet.com",
            "PGDATABASE": "forte",
            "PGPORT": "5432",
            "PGUSER": DB_LOGIN,
        },
    },
    "sqlserver": {
        "command": py_exe,
        "args": [mssql_script],
        "env": {
            "SQLSERVER_HOST": "QTSPRODEASDB3",
            "SQLSERVER_DATABASE": "SGEAS_DIFF",
            "ODBC_DRIVER": "ODBC Driver 18 for SQL Server",
            # Trusted_Connection uses the Windows ticket; no login needed here.
        },
    },
    "mongodb-gm": {
        "command": node_exe,
        "args": [mongo_module, "--readOnly", "--transport", "stdio"],
        "env": {
            # MONGODB-OIDC against $external: auth comes from the signed-in
            # Azure AD identity, so this string is identical for every user.
            "MDB_MCP_CONNECTION_STRING":
                "mongodb+srv://sg-prod-mg-atlas-clst-pl-0.13qes8.mongodb.net/"
                "?authSource=$external&authMechanism=MONGODB-OIDC",
        },
    },

    # ------------------------------------------------ EMORY (-WithEmory) -----
    "emory": {
        "command": emory_py,
        "args": ["-m", "emory_agent.mcp_server"],
        "env": {
            "PYTHONPATH": emory_root,
            "PYTHONUTF8": "1",
            "PYTHONIOENCODING": "utf-8",
            "EMORY_SKILL_PATH": emory_skill,
        },
    },

    # ---------------------------- SNOWFLAKE (fill in and add to -Servers) ----
    # Snowflake follows the same first-initial+lastname pattern, so DB_LOGIN
    # works here too. Drop in the account/warehouse/role and a snowflake MCP
    # entrypoint, then run:  .\Setup-SGI-MCP.ps1 -Servers snowflake
    #
    # "snowflake": {
    #     "command": py_exe,
    #     "args": ["C:\\pgmcp\\snowflake_mcp_server.py"],
    #     "env": {
    #         "SNOWFLAKE_ACCOUNT":   "<account>.<region>",
    #         "SNOWFLAKE_USER":      DB_LOGIN,
    #         "SNOWFLAKE_AUTHENTICATOR": "externalbrowser",
    #         "SNOWFLAKE_DATABASE":  "STAGING",
    #         "SNOWFLAKE_WAREHOUSE": "<warehouse>",
    #         "SNOWFLAKE_ROLE":      "<role>",
    #     },
    # },
}


def backup(path):
    if os.path.exists(path):
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        dest = path + ".bak-" + stamp
        shutil.copy(path, dest)
        return dest
    return None


def load_json(path):
    """Load existing JSON, or abort.

    Deliberately does NOT fall back to an empty dict on a parse error: this
    file holds the user's preferences, trusted folders and unmanaged servers.
    Silently 'starting fresh' would quietly delete all of it. If the file is
    corrupt a human needs to look at it.
    """
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception as exc:
        print("ERROR %s exists but is not valid JSON: %s" % (path, exc))
        print("ERROR refusing to overwrite it - that would discard your "
              "preferences and any servers this script does not manage.")
        print("ERROR fix or move the file, then re-run.")
        sys.exit(4)


def save_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # utf-8 with no BOM: json.load() and Claude Desktop both choke on a BOM
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


# ----------------------------------------------------- 1. the SIDECAR file --
# Holds the "server" blocks. Claude Desktop never reads or rewrites this file,
# which is the entire point - the "server" key survives here.
side = load_json(SIDECAR)
side.setdefault("mcpServers", {})
b = backup(SIDECAR)
if b:
    print("Backed up sidecar -> " + b)

for name in managed:
    if name not in DEFS:
        print("WARN no definition for '%s' - skipped" % name)
        continue
    if name == "emory" and not emory_py:
        print("WARN emory requested without -WithEmory - skipped")
        continue
    side["mcpServers"][name] = {
        "command": WRAPPER,
        "args": [SIDECAR, name],
        "server": DEFS[name],
    }
    print("sidecar: configured " + name)

save_json(SIDECAR, side)
print("Wrote " + SIDECAR)

# ------------------------------------------- 2. claude_desktop_config.json --
# Only {command, args}. Deliberately NO "server" key: Claude Desktop strips it,
# and v1's bug was relying on it surviving here.
cfg = load_json(CFG)
b = backup(CFG)
if b:
    print("Backed up Claude config -> " + b)
cfg.setdefault("mcpServers", {})

for name in managed:
    if name not in DEFS:
        continue
    cfg["mcpServers"][name] = {
        "command": WRAPPER,
        "args": [SIDECAR, name],
    }

# Repair any pre-existing entry left over from v1 that still points at the
# Claude config as its own sidecar, or still carries an inline "server" block.
for name, entry in list(cfg["mcpServers"].items()):
    if not isinstance(entry, dict):
        continue
    if "server" in entry:
        del entry["server"]
        print("repaired: removed stripped-by-Claude 'server' block from " + name)
    args = entry.get("args") or []
    if args and isinstance(args[0], str) and args[0].lower().endswith("claude_desktop_config.json"):
        entry["args"] = [SIDECAR] + list(args[1:])
        print("repaired: repointed " + name + " from Claude config to sidecar")

save_json(CFG, cfg)
print("Wrote " + CFG)
print("DB login for this user: " + DB_LOGIN)
'@

$genPath = Join-Path $env:TEMP "sgi_mcp_gen.py"
Write-Utf8NoBom -Path $genPath -Text $genPy
$serverList = ($Servers -join ",")

$claudeCfg    = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
$pgScriptPath = "C:\pgmcp\pg_mcp_server.py"
$effSidecar   = $SidecarPath

if ($DryRun) {
    $sandbox = Join-Path $env:TEMP ("sgi-mcp-dryrun-" + (Get-Date -Format "HHmmss"))
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $effSidecar = Join-Path $sandbox "wrapped_servers.json"
    $realCfg = $claudeCfg
    $claudeCfg = Join-Path $sandbox "claude_desktop_config.json"
    if (Test-Path $realCfg) { Copy-Item $realCfg $claudeCfg -Force }
    Say "DRY RUN - writing to $sandbox only; nothing real is modified." "WARN"
}

Say "Writing sidecar + Claude Desktop config (managed: $serverList) ..." "STEP"
# every arg quoted: an EMPTY $NODE (no mongodb-gm on this run) must still occupy its
# position, otherwise every later argument shifts left by one
# PowerShell 5.1 silently DROPS empty-string arguments to native programs, so an
# unset $NODE / $EMORY_* would shift every later argument left. Send "-" for empty.
function ArgOrDash([string]$v) { if ([string]::IsNullOrEmpty($v)) { "-" } else { $v } }
& $PY $genPath (ArgOrDash $SgiUser) (ArgOrDash $PY) (ArgOrDash $NODE) (ArgOrDash $serverList) (ArgOrDash $effSidecar) (ArgOrDash $claudeCfg) (ArgOrDash $pgScriptPath) (ArgOrDash $EMORY_PY) (ArgOrDash $EmoryDest) (ArgOrDash $EMORY_SKILL) 2>&1 | ForEach-Object { Say $_ }
if ($LASTEXITCODE -ne 0) { Say "Config generation failed - see log." "FAIL"; exit 3 }
Say "Config written" "OK"

if ($DryRun) {
    Say "---- DRY RUN: sidecar that WOULD be written ----" "STEP"
    Get-Content $effSidecar | ForEach-Object { Say $_ }
    Say "---- DRY RUN: Claude config that WOULD be written ----" "STEP"
    Get-Content $claudeCfg | ForEach-Object { Say $_ }
    Say "DRY RUN complete - no real file was changed. Sandbox: $sandbox" "OK"
    exit 0
}

# ------------------------------------------- Emory: claude-CLI keep-alive ----
if ($WithEmory -and -not $DryRun) {
    $ka = Join-Path $EmoryDest "setup\Register-ClaudeAuthKeepalive.ps1"
    if (Test-Path $ka) {
        Say "Registering the claude-CLI login keep-alive task ..." "STEP"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ka 2>&1 | ForEach-Object { Say $_ }
    } else { Say "keep-alive script not found at $ka - skipped" "WARN" }
    $authOk = $false
    try { $st = (& claude auth status 2>$null | Out-String); $authOk = ($st -match '"loggedIn":\s*true') } catch { }
    if ($authOk) { Say "claude CLI is signed in (Emory's reasoning runtime rides this login)" "OK" }
    else { Say "claude CLI is NOT signed in - run 'claude auth login' once, or emory_investigate will fail with 401." "WARN" }
}

# ------------------------------------------------------------- self-test -----
$exitCode = 0
if ($NoSelfTest) {
    Say "Skipping handshake self-test (-NoSelfTest)" "WARN"
} else {
    $testPy = @'
import json, os, queue, subprocess, sys, threading, time

WRAPPER_REAL = "C:\\Program Files\\PromptSecurity\\prompt_security_mcp.exe"
names   = [s for s in sys.argv[1].split(",") if s]
SIDECAR = sys.argv[2]
TIMEOUT = 90.0   # the wrapper can take ~10s to answer initialize


def handshake(name):
    cmd = [WRAPPER_REAL, SIDECAR, name]
    try:
        p = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8",
            errors="replace", bufsize=1,
        )
    except Exception as exc:
        return False, "could not launch wrapper: %s" % exc

    q = queue.Queue()

    def pump(stream, tag):
        try:
            for line in stream:
                q.put((tag, line))
        except Exception:
            pass
        q.put((tag, None))

    threading.Thread(target=pump, args=(p.stdout, "out"), daemon=True).start()
    threading.Thread(target=pump, args=(p.stderr, "err"), daemon=True).start()

    req = {
        "jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "sgi-setup-selftest", "version": "2.0"},
        },
    }
    try:
        p.stdin.write(json.dumps(req) + "\n")
        p.stdin.flush()
    except Exception as exc:
        p.kill()
        return False, "wrapper closed stdin immediately: %s" % exc

    errlines = []
    deadline = time.time() + TIMEOUT
    try:
        while time.time() < deadline:
            try:
                tag, line = q.get(timeout=1.0)
            except queue.Empty:
                if p.poll() is not None and q.empty():
                    break
                continue
            if line is None:
                continue
            if tag == "err":
                errlines.append(line.rstrip())
                continue
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") != 0:
                continue
            if "result" in msg:
                info = (msg["result"] or {}).get("serverInfo") or {}
                return True, "handshake OK (server reported: %s)" % info.get("name", "?")
            if "error" in msg:
                return False, "server returned error: %s" % msg["error"]
    finally:
        try:
            p.kill()
        except Exception:
            pass

    rc = p.poll()
    detail = "no initialize response within %.0fs" % TIMEOUT
    if rc is not None:
        detail = "inner server never answered; wrapper exited rc=%s" % rc
    if errlines:
        detail += " | stderr: " + " / ".join(errlines[-4:])[:400]
    else:
        detail += " | stderr was empty -> the wrapper had no inner server to launch, or it failed to spawn"
    return False, detail


failed = []
for n in names:
    ok, detail = handshake(n)
    print(("PASS " if ok else "FAIL ") + n + ": " + detail)
    if not ok:
        failed.append(n)

if failed:
    print("SELFTEST_FAILED " + ",".join(failed))
    sys.exit(1)
print("SELFTEST_ALL_PASS")
'@
    $testPath = Join-Path $env:TEMP "sgi_mcp_selftest.py"
    Write-Utf8NoBom -Path $testPath -Text $testPy
    Say "Running MCP handshake self-test (this is what v1 never checked) ..." "STEP"
    & $PY $testPath $serverList $effSidecar 2>&1 | ForEach-Object {
        $lvl = "INFO"
        if ($_ -like "PASS *") { $lvl = "OK" }
        if ($_ -like "FAIL *") { $lvl = "FAIL" }
        Say $_ $lvl
    }
    if ($LASTEXITCODE -ne 0) {
        Say "One or more servers failed the handshake. Config is written, but Claude Desktop will show them as disconnected." "FAIL"
        $exitCode = 2
    } else {
        Say "All configured servers completed the MCP handshake" "OK"
    }
}

# ---------------------------------------------------------------- summary ----
Say "----------------------------------------------------------------" "STEP"
Say "User            : $SgiUser  (DB login: $SgiUser@ETCH.COM)"
Say "Python          : $PY  ($pyVer)"
if ($NODE) { Say "Node            : $NODE" }
Say "Sidecar         : $effSidecar   <- inner definitions (Claude never rewrites this)"
Say "Claude config   : $claudeCfg   <- pointers only, no 'server' key"
Say "Managed servers : $serverList"
if ($WithEmory) {
    Say "Emory code      : $EmoryDest   (.env is per-user; venv inside)"
    Say "Emory brain     : $EMORY_SKILL"
    Say "Emory tools     : emory_investigate, emory_post_verdict, emory_eligibility_lookup, emory_connector_check"
}
Say "Log             : $logFile"

$odbc = (& $PY -c "import pyodbc;print('ODBC Driver 18 for SQL Server' in pyodbc.drivers())" 2>$null)
if ($odbc -and $odbc.Trim() -eq "False") {
    Say "ODBC Driver 18 for SQL Server is NOT installed - SQL Server queries will fail (Postgres is unaffected). Install it from Microsoft." "WARN"
}

if (Get-Process -Name "Claude" -ErrorAction SilentlyContinue) {
    Say "Claude Desktop is running - fully QUIT and restart it to pick up this config." "WARN"
} else {
    Say "Start Claude Desktop; the servers will connect on launch." "OK"
}
Say "Done (exit $exitCode)" "STEP"
exit $exitCode
