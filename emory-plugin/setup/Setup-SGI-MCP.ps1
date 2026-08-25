<#
    Setup-SGI-MCP.ps1   (v2)

    One-shot, unattended setup of Safe-Guard's read-only database MCP servers
    for Claude Desktop, behind the Prompt Security DLP wrapper.

    Configures: postgresql-mcp (Forte), sqlserver (SGEAS), mongodb-gm (Atlas),
                and preserves any existing github / ms365 entries.
                Snowflake has a ready-to-fill slot - see SNOWFLAKE below.

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

Say "Setup-SGI-MCP v2 starting for user '$SgiUser'" "STEP"
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
    Say "Installing Python dependencies (mcp, psycopg2-binary, pyodbc) ..." "STEP"
    & $PY -m pip install --upgrade --quiet mcp psycopg2-binary pyodbc 2>&1 | ForEach-Object { Say $_ }
    if ($LASTEXITCODE -ne 0) {
        Say "Machine-wide pip install failed (likely no admin) - retrying with --user" "WARN"
        & $PY -m pip install --upgrade --user --quiet mcp psycopg2-binary pyodbc 2>&1 | ForEach-Object { Say $_ }
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
& $PY $genPath $SgiUser $PY $NODE $serverList $effSidecar $claudeCfg $pgScriptPath 2>&1 | ForEach-Object { Say $_ }
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
