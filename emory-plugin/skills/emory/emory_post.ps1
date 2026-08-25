<#
  emory_post.ps1 - Emory's Teams delivery adapter.

  Takes the verdict JSON Emory already emits (the "rich verdict" schema):
    REQUIRED : sr, dealer, product, issue, sub, platform, verdict,
               checks_md, bottom, owner, classification
    OPTIONAL : title    - short subject line under the SR in the header
                          (falls back to `dealer` when absent)
               source   - aggregator / integration partner, e.g.
                          "Vision, via Provider Exchange Network (PEN)"
               reported - who raised it and when
               confirm  - what a human must still verify (NEEDS REVIEW cases)
               verdict_color

  NOTE: keep `sr`, `issue` and `sub` as SEPARATE fields - do NOT pre-merge them into
  one string. The header shows `sr` + `title` only; `issue` goes to EXECUTIVE SUMMARY
  and `sub` to CASE OVERVIEW. Merging them produced the run-on header fixed 2026-08-24.

  THIS SCRIPT IS THE SINGLE SOURCE OF TRUTH for card layout. `emory_verdict_card.html`
  is a GENERATED preview of this script's output - regenerate it after any layout edit:
    powershell -File emory_post.ps1 -VerdictJson emory_verdict_card.sample.json -EmitTemplate
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
  [switch]$EmitTemplate,                                                     # regenerate emory_verdict_card.html from this script; never sends
  [string]$TemplateFile = '',                                                # defaults to emory_verdict_card.html next to this script
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

# Emoji and symbols from code points (keeps this source pure ASCII)
$E_SEARCH = [char]::ConvertFromUtf32(0x1F50E)   # magnifier
$E_CHECK  = [char]::ConvertFromUtf32(0x2705)    # green check
$E_WARN   = [char]::ConvertFromUtf32(0x26A0)    # warning
$E_X      = [char]::ConvertFromUtf32(0x274C)    # red x
$E_FLASH  = [char]::ConvertFromUtf32(0x26A1)    # high voltage
$E_LIST   = [char]::ConvertFromUtf32(0x1F4CB)   # clipboard
$ARROW    = [char]::ConvertFromUtf32(0x2192)    # rightwards arrow →

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

# Convert markdown checks to HTML (bold, newlines)
$checks = HtmlEsc $v.checks_md
$checks = [regex]::Replace($checks, '\*\*(.+?)\*\*', '<b>$1</b>')
$checks = $checks -replace "`r?`n", '<br>'

$nl = '<br>'

# PRODUCTION CARD FORMAT — uses emory_verdict_card.html color palette & structure
# Dark theme with high contrast: blue headers, gold alerts, green/orange badges
$parts = @()

# ===== OUTER WRAPPER (dark background) =====
$parts += "<div style='font-family: Segoe UI, Arial, sans-serif; color: #fff; max-width: 900px; background: #1f1f1f;'>"

# ===== HEADER (blue gradient) =====
$parts += "<div style='background: linear-gradient(135deg, #0078d4 0%, #106ebe 100%); color: white; padding: 24px; border-radius: 8px 8px 0 0;'>"
$parts += "<div style='font-size: 24px; font-weight: 600;'>" + $E_SEARCH + " Emory Case Review</div>"
# Header stays SHORT: SR number, then a brief subject line. Never merge issue/sub in here —
# the full symptom lives in EXECUTIVE SUMMARY and the vehicle lives in CASE OVERVIEW.
# Optional `title` field wins; otherwise fall back to the dealer name.
$sr_subject = if ($v.title) { HtmlEsc $v.title } elseif ($v.dealer) { HtmlEsc $v.dealer } else { "" }
$parts += "<div style='font-size: 19px; font-weight: 600; margin-top: 10px; letter-spacing: 0.3px;'>" + (HtmlEsc $v.sr) + "</div>"
if ($sr_subject) {
  $parts += "<div style='font-size: 14px; margin-top: 4px; opacity: 0.92;'>" + $sr_subject + "</div>"
}
$parts += "</div>"

# ===== MAIN CONTENT (dark gray) =====
$parts += "<div style='background: #2a2a2a; padding: 24px; border: 1px solid #444; border-radius: 0 0 8px 8px;'>"

# ===== CASE OVERVIEW =====
$parts += "<div style='margin-bottom: 24px;'>"
$parts += "<div style='font-size: 16px; font-weight: 600; color: #58a6ff; margin-bottom: 12px;'>CASE OVERVIEW</div>"
$parts += "<div style='font-size: 13px; line-height: 2; color: #e6edf3;'>"
$parts += "<div><b>Dealer:</b> $(HtmlEsc $v.dealer)</div>"
$parts += "<div><b>Product:</b> $(HtmlEsc $v.product)</div>"
if ($v.sub)      { $parts += "<div><b>Vehicle:</b> $(HtmlEsc $v.sub)</div>" }
if ($v.source)   { $parts += "<div><b>Source:</b> $(HtmlEsc $v.source)</div>" }
$parts += "<div><b>Platform:</b> $(HtmlEsc $v.platform)</div>"
if ($v.reported) { $parts += "<div><b>Reported:</b> $(HtmlEsc $v.reported)</div>" }
$parts += "</div></div>"

# ===== EXECUTIVE SUMMARY (gold alert) =====
$alert_bg = if ($v.verdict -match 'FAIL') { '#5f3d00' } else { '#3d3600' }
$alert_color = '#ffd700'
$parts += "<div style='margin-bottom: 24px; padding: 16px; background: " + $alert_bg + "; border-left: 4px solid " + $alert_color + "; border-radius: 4px;'>"
$parts += "<div style='font-weight: 600; color: " + $alert_color + "; margin-bottom: 8px; font-size: 14px;'>" + $E_FLASH + " EXECUTIVE SUMMARY</div>"
$parts += "<div style='font-size: 13px; color: #ffffff; line-height: 1.7;'>"
# Label each part on its own line — never run `issue` straight into `bottom` with a dash.
$parts += "<div><b>What the dealer saw:</b> " + (HtmlEsc $v.issue) + "</div>"
$parts += "<div style='margin-top: 10px;'><b>What we found:</b> " + (HtmlEsc $v.bottom) + "</div>"
if ($v.owner) { $parts += "<div style='margin-top: 10px;'><b>Next action:</b> Escalate to " + (HtmlEsc $v.owner) + "</div>" }
$parts += "</div></div>"

# ===== KEY FINDINGS (checks, color-coded) =====
$parts += "<div style='margin-bottom: 24px;'>"
$parts += "<div style='font-size: 16px; font-weight: 600; color: #58a6ff; margin-bottom: 12px;'>KEY FINDINGS</div>"
$parts += "<div style='background: #1f3a2f; padding: 14px; border-left: 4px solid #3fb950; border-radius: 4px; font-size: 12px; line-height: 1.8; color: #aeffad;'>"
$parts += $checks
$parts += "</div></div>"

# ===== ROOT CAUSE ANALYSIS (blue box) =====
$parts += "<div style='margin-bottom: 24px;'>"
$parts += "<div style='font-size: 16px; font-weight: 600; color: #58a6ff; margin-bottom: 12px;'>ROOT CAUSE ANALYSIS</div>"
$parts += "<div style='padding: 14px; background: #0d2e5f; border-left: 4px solid #1f6feb; border-radius: 4px; font-size: 13px; margin-bottom: 12px; color: #c9d1d9;'>"
$parts += "<b style='color: #79c0ff;'>PRIMARY:</b> $(HtmlEsc $v.bottom)"
$parts += "</div>"
if ($v.confirm) {
  $parts += "<div style='padding: 14px; background: #3d3d3d; border-radius: 4px; font-size: 13px; color: #c9d1d9;'>"
  $parts += "<b style='color: #e6edf3;'>VERIFICATION NEEDED:</b> $(HtmlEsc $v.confirm)"
  $parts += "</div>"
}
$parts += "</div>"

# ===== RECOMMENDED NEXT STEPS =====
if ($v.owner) {
  $parts += "<div style='margin-bottom: 24px;'>"
  $parts += "<div style='font-size: 16px; font-weight: 600; color: #58a6ff; margin-bottom: 12px;'>RECOMMENDED NEXT STEPS</div>"
  $parts += "<div style='background: #0d2e5f; padding: 14px; border-left: 4px solid #1f6feb; border-radius: 6px; font-size: 13px; line-height: 1.8; color: #c9d1d9;'>"
  $parts += "<div><b style='color: #79c0ff;'>" + $ARROW + " Escalation:</b> " + (HtmlEsc $v.owner) + "</div>"
  $action_type = if ($v.verdict -match 'FAIL') { 'Configuration review &amp; DCR' } elseif ($v.verdict -match 'NEEDS') { 'Validation &amp; confirmation' } else { 'Deployment' }
  $parts += "<div><b style='color: #79c0ff;'>" + $ARROW + " Action Type:</b> $action_type</div>"
  $parts += "</div></div>"
}

# ===== CASE CLASSIFICATION & ROUTING =====
$parts += "<div style='background: #0d2e5f; padding: 14px; border: 1px solid #1f6feb; border-radius: 6px; font-size: 12px; color: #c9d1d9;'>"
$parts += "<div style='font-weight: 600; color: #79c0ff; margin-bottom: 10px;'>" + $E_LIST + " CASE CLASSIFICATION &amp; ROUTING</div>"
if ($v.classification) {
  $cls = HtmlEsc $v.classification
  $cls = [regex]::Replace($cls, '\*\*(.+?)\*\*', '<b style="color: #e6edf3;">$1</b>')
  $cls = $cls -replace "`r?`n", '<br>'
  $parts += "<div style='line-height: 1.8;'>$cls</div>"
} else {
  $parts += "<i>Classification pending - see raw verdict for details</i>"
}
$parts += "</div>"

$parts += "</div>"  # end main content div

# ===== FOOTER =====
$status_emoji = switch -Wildcard ($v.verdict) {
  'PASS*' { $E_CHECK }
  '*NEEDS*' { $E_WARN }
  'FAIL*' { $E_X }
  default { $E_SEARCH }
}
$parts += "<div style='background: #1f1f1f; padding: 16px; text-align: center; font-size: 11px; color: #8b949e; border-top: 1px solid #444; border-radius: 0 0 8px 8px;'>"
$parts += "<b style='color: #f0883e;'>" + $status_emoji + " Status: " + (HtmlEsc $v.verdict) + "</b> - Read-only pre-analysis. Contact team for confirmation. - <i>Emory</i>"
$parts += "</div>"

$parts += "</div>"  # end outer wrapper

$message = -join $parts
$payload = @{ message = $message } | ConvertTo-Json -Depth 4 -Compress

# -EmitTemplate regenerates the reference card from THIS script's own output, so the
# template can never silently drift from what actually posts. It never sends.
if ($EmitTemplate) {
  # $PSScriptRoot is not bindable in a param default under PS 5.1 - resolve it here.
  if (-not $TemplateFile) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $TemplateFile = Join-Path $root 'emory_verdict_card.html'
  }
  $stamp  = (Get-Date).ToString('yyyy-MM-dd')
  $banner = @(
    "<!-- ============================================================================",
    "     emory_verdict_card.html - GENERATED FILE, DO NOT HAND-EDIT.",
    "",
    "     This is a rendered preview of emory_post.ps1's output. That script is the",
    "     single source of truth for card layout; this file exists so the palette and",
    "     structure can be eyeballed without posting to Teams.",
    "",
    "     Regenerate after ANY layout change:",
    "       powershell -File emory_post.ps1 -VerdictJson emory_verdict_card.sample.json -EmitTemplate",
    "",
    "     Last generated: $stamp",
    "     ============================================================================ -->"
  ) -join "`n"
  Set-Content -LiteralPath $TemplateFile -Value ($banner + "`n" + $message) -Encoding UTF8
  Write-Host "Regenerated template -> $TemplateFile" -ForegroundColor Green
  Write-Host "(-EmitTemplate never posts.)" -ForegroundColor Yellow
  return
}

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
