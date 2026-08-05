<#
  emory_post.ps1 - Emory's Teams delivery adapter.

  Takes the verdict JSON Emory already emits (the "rich verdict" schema:
    sr, dealer, product, issue, sub, platform, verdict, verdict_color,
    checks_md, bottom, owner, confirm)
  and turns it into the single { "message": "<html>" } payload the live flow
  expects ("Http -> Post message in a chat or channel", Flow bot -> #api-support-intake),
  then POSTs it.

  SAFETY: dry-run by DEFAULT - prints the built message and does NOT send.
  Pass -Post to actually deliver. Never wire this to auto-fire without the analyst's OK.

  Usage:
    powershell -File emory_post.ps1 -VerdictJson path\to\verdict.json          # preview only
    powershell -File emory_post.ps1 -VerdictJson path\to\verdict.json -Post     # deliver

  The secret trigger URL is read at post-time from -UrlFile (never hardcoded here).
  Source is pure ASCII on purpose (PowerShell 5.1 mis-reads unsaved UTF-8); emoji are
  built from code points and JSON data is read as UTF-8.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$VerdictJson,
  [switch]$Post,                                                              # force send
  [switch]$Auto,                                                             # send only if the toggle file says on
  [string]$UrlFile  = "C:\Users\edurrant\Downloads\emory_verdict_delivery_url.txt",
  [string]$AutoFile = "C:\Users\edurrant\Downloads\emory_autopost.txt"       # "on"/"off" master switch for hands-off mode
)

$ErrorActionPreference = 'Stop'

# Resolve whether we actually send. -Post always sends. -Auto sends ONLY while the
# hands-off toggle file reads on/1/true/yes, so hands-off is deliberate and revocable
# (pause it by writing "off" to $AutoFile) rather than silent, permanent behavior.
$autoOn = $false
if ($Auto -and (Test-Path -LiteralPath $AutoFile)) {
  $flag = ((Get-Content -Raw -LiteralPath $AutoFile) -replace '\s','').ToLower()
  $autoOn = @('on','1','true','yes') -contains $flag
}
$doPost = $Post.IsPresent -or $autoOn

# Emoji from code points (keeps this source pure ASCII)
$E_SEARCH = [char]::ConvertFromUtf32(0x1F50E)   # magnifier
$E_CHECK  = [char]::ConvertFromUtf32(0x2705)    # green check
$E_WARN   = [char]::ConvertFromUtf32(0x26A0)    # warning
$E_X      = [char]::ConvertFromUtf32(0x274C)    # red x

function HtmlEsc([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return "" }
  return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
}

if (-not (Test-Path -LiteralPath $VerdictJson)) { throw "Verdict file not found: $VerdictJson" }
$v = Get-Content -Raw -Encoding UTF8 -LiteralPath $VerdictJson | ConvertFrom-Json

$badge = switch -Wildcard ($v.verdict) {
  'PASS*'   { $E_CHECK; break }
  '*NEEDS*' { $E_WARN;  break }
  'FAIL*'   { $E_X;     break }
  default   { $E_SEARCH }
}

# checks_md -> HTML: escape, then **bold** -> <b>, newlines -> <br>
$checks = HtmlEsc $v.checks_md
$checks = [regex]::Replace($checks, '\*\*(.+?)\*\*', '<b>$1</b>')
$checks = $checks -replace "`r?`n", '<br>'

$nl = '<br>'
$parts = @(
  "$E_SEARCH <b>Emory &middot; pre-analysis</b> &nbsp;&mdash;&nbsp; " + (HtmlEsc $v.sr) + " &nbsp;&middot;&nbsp; <b>" + (HtmlEsc $v.verdict) + "</b> $badge$nl",
  "<i>" + (HtmlEsc $v.platform) + "</i>$nl$nl",
  "Hey team &mdash; I took a first pass at this one before anyone picks it up.$nl$nl",
  "<b>Dealer:</b> "  + (HtmlEsc $v.dealer)  + $nl,
  "<b>Product:</b> " + (HtmlEsc $v.product) + $nl,
  "<b>Issue:</b> "   + (HtmlEsc $v.issue)   + $nl
)
if ($v.sub)     { $parts += "<b>Vehicle:</b> " + (HtmlEsc $v.sub) + $nl }
$parts += "$nl<b>Here's what I checked:</b>$nl$checks$nl$nl"
$parts += "<b>My read:</b> " + (HtmlEsc $v.bottom) + "$nl$nl"
if ($v.owner)   { $parts += "<b>I'd route it to:</b> " + (HtmlEsc $v.owner) + $nl }
if ($v.confirm) { $parts += "<b>Can someone confirm:</b> " + (HtmlEsc $v.confirm) + $nl }
$parts += "$nl<i>Read-only first pass &mdash; worth a human confirm before we act. &mdash; Emory</i>"

$message = -join $parts
$payload = @{ message = $message } | ConvertTo-Json -Depth 4 -Compress

Write-Host "----- Emory message (HTML, what posts to #api-support-intake) -----"
Write-Host $message
Write-Host "------------------------------------------------------------------"

if (-not $doPost) {
  if ($Auto) {
    Write-Host "AUTO-POST OFF (toggle '$AutoFile' is not on) - dry run, not posted." -ForegroundColor Yellow
  } else {
    Write-Host "DRY RUN - not posted. Re-run with -Post (or -Auto when hands-off is on) to deliver." -ForegroundColor Yellow
  }
  return
}
if ($autoOn -and -not $Post) { Write-Host "AUTO-POST ON (hands-off) - delivering..." -ForegroundColor Cyan }

if (-not (Test-Path -LiteralPath $UrlFile)) { throw "Delivery URL file not found: $UrlFile" }
$url = (Select-String -Path $UrlFile -Pattern 'https://\S+').Matches.Value | Select-Object -First 1
if (-not $url) { throw "No https URL found in $UrlFile" }

$bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -UseBasicParsing
Write-Host "Posted to #api-support-intake. HTTP $($resp.StatusCode)" -ForegroundColor Green
