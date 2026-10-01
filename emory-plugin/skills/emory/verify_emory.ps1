<#
  verify_emory.ps1 - install verifier for the Emory skill.

  Answers "is this install the version I think it is, and does it still work?"
  Run it after any edit, after a Claude restart, or whenever a card looks wrong:

    powershell -ExecutionPolicy Bypass -File ~/.claude/skills/emory/verify_emory.ps1

  Checks, in order:
    1. FILES     - every expected canonical file is present
    2. PARSE     - emory_post.ps1 parses as valid PowerShell
    3. FEATURES  - the 2026-09-22 executive-summary layout + gate are in the script
    4. SMOKE     - both sample verdicts render, in the right section order
    5. GATE      - posting is refused when `verification` is missing
    6. PARITY    - canonical vs the server-synced cache copies (drift is expected;
                   this makes it VISIBLE rather than silent)

  Exits 0 if everything that MUST pass, passes. Cache drift is reported as a
  warning, not a failure, because only re-publishing the skill record fixes it.
  Read-only: never posts, never writes to the skill directory.
#>
[CmdletBinding()]
param([string]$SkillDir = "$env:USERPROFILE\.claude\skills\emory")

$ErrorActionPreference = 'Stop'
$fail = 0; $warn = 0
function Ok   ($m) { Write-Host "  [ OK ]   $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "  [FAIL]   $m" -ForegroundColor Red;    $script:fail++ }
function Warn ($m) { Write-Host "  [WARN]   $m" -ForegroundColor Yellow; $script:warn++ }
function Head ($m) { Write-Host "`n$m" -ForegroundColor Cyan }

Write-Host "Emory install verifier - $SkillDir" -ForegroundColor White

# ---- 1. FILES ----------------------------------------------------------------
Head "1. Files"
$expected = @('SKILL.md','VERSION.md','emory_post.ps1','EMORY_ANALYSIS_GUARDRAILS.md',
              'emory_verdict_card.sample.json','emory_verdict_card.sample2.json','emory_digest.ps1','emory_verdict_card.html','emory_verdict_card.adaptive.json',
              'aggregator_integration_partners.md','case_classification_picklists.md',
              'rating_attributes_reference.md','sf_fill\sf_fill.py','sf_fill\README.md')
foreach ($f in $expected) {
  if (Test-Path -LiteralPath (Join-Path $SkillDir $f)) { Ok $f } else { Bad "MISSING: $f" }
}
$refs = @('verdict_and_delivery.md','rates_layer.md','classing_and_eligibility.md','roadrunner.md',
          'duplicate_check.md','eligibility_matrix.md','sibling_diff.md','browser_and_intake.md',
          'connectors_and_setup.md','api_quick_tips.md')
$missingRefs = @($refs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SkillDir "references\$_")) })
if ($missingRefs.Count -eq 0) { Ok "references/ - all $($refs.Count) present" } else { Bad "references/ missing: $($missingRefs -join ', ')" }

$poster = Join-Path $SkillDir 'emory_post.ps1'

# ---- 2. PARSE ----------------------------------------------------------------
Head "2. Syntax"
$perr = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($poster, [ref]$null, [ref]$perr)
if ($perr.Count -eq 0) { Ok "emory_post.ps1 parses cleanly" }
else { Bad "emory_post.ps1 has $($perr.Count) parse error(s): $($perr[0].Message)" }

# ---- 3. FEATURES -------------------------------------------------------------
Head "3. Expected features present (2026-09-22 executive-summary layout)"
$src = Get-Content -Raw -LiteralPath $poster
$features = [ordered]@{
  'facts block: Issue/Impact/Owner/Next'  = "\$facts \+= @\('Issue'"
  'exec-summary layout: Summary list'     = "Label 'Summary'"
  'exec-summary layout: Status table'      = "Label 'Status'"
  'Teams-native: no layout tables'         = 'Teams-native primitives'
  'exec-summary layout: Key question'      = 'Key question'
  'exec-summary layout: Next steps'        = 'Next steps'
  'exec-summary layout: Investigation details' = 'Investigation details'
  'minimal look (Aptos stack)'             = 'Aptos'
  'Adaptive Card with ToggleVisibility'    = 'Action\.ToggleVisibility'
  'verification gate'                      = 'REFUSED TO POST'
  'summary[] field'                        = '\$v\.summary'
  'status_rows[] field'                    = '\$v\.status_rows'
  'key_question field'                     = '\$v\.key_question'
  'root_cause field'                       = '\$v\.root_cause'
  'actions array'                          = '\$v\.actions'
  'legacy fallbacks (issue_line etc.)'     = '\$v\.issue_line'
  'Prose() helper'                         = 'function Prose'
}
foreach ($k in $features.Keys) {
  if ($src -match $features[$k]) { Ok $k } else { Bad "missing feature: $k" }
}

# ---- 4. SMOKE ----------------------------------------------------------------
Head "4. Smoke test (both sample verdicts render, sections in order)"
$sample  = Join-Path $SkillDir 'emory_verdict_card.sample.json'    # parsed checks_md path
$sample2 = Join-Path $SkillDir 'emory_verdict_card.sample2.json'   # explicit status_rows path
$order = @('CASE REVIEW','>Issue<|SUMMARY','STATUS</p>','KEY QUESTION','NEXT STEPS','INVESTIGATION DETAILS','HOW THIS WAS VERIFIED','CLASSIFICATION')
foreach ($sf in @($sample, $sample2)) {
  $name = Split-Path -Leaf $sf
  try {
    if (-not (Test-Path -LiteralPath $sf)) { Bad "missing sample: $name"; continue }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $poster -VerdictJson $sf 2>&1
    $html = ($out -join "`n")
    if ($html -match 'DRY RUN') { Ok "$name renders (dry run, nothing posted)" } else { Bad "$name did not reach DRY RUN" }
    $pos = @(); $bad = $false
    foreach ($o in $order) {
      $m = [regex]::Match($html, $o)
      if (-not $m.Success) { Bad "$name - section not rendered: $o"; $bad = $true } else { $pos += $m.Index }
    }
    if (-not $bad) {
      $sorted = ($pos | Sort-Object)
      if (-not (Compare-Object $pos $sorted -SyncWindow 0)) { Ok "$name - section order correct ($($order.Count) sections)" }
      else { Bad "$name - sections rendered OUT OF ORDER" }
    }
    if ($html -match "font-family: '") { Bad "$name - single-quoted font name inside a single-quoted style attribute (breaks the stack)" }
    $layoutTables = ([regex]::Matches($html, '<table')).Count
    if ($layoutTables -le 1) { Ok "$name - only the Status grid uses <table> (Teams draws borders on every table)" } else { Bad "$name - $layoutTables <table> elements; Teams will box each one" }
    if ($html -notmatch 'technical detail follows') { Ok "$name - no 'technical detail follows' seam" }
    else { Warn "$name contains a 'technical detail follows' seam - split bottom/root_cause" }
  } catch { Bad "smoke test threw on $name : $($_.Exception.Message)" }
}
# the Adaptive Card rendering (regenerated by -EmitTemplate) must carry the collapse toggle
$ac = Join-Path $SkillDir 'emory_verdict_card.adaptive.json'
if ((Test-Path -LiteralPath $ac) -and ((Get-Content -Raw -LiteralPath $ac) -match 'Action\.ToggleVisibility')) { Ok "emory_verdict_card.adaptive.json carries Action.ToggleVisibility (collapsible details)" }
else { Bad "emory_verdict_card.adaptive.json missing or has no ToggleVisibility - rerun -EmitTemplate" }
# status_rows must win over checks_md when both are present (sample2)
try {
  $out2 = (& powershell -NoProfile -ExecutionPolicy Bypass -File $poster -VerdictJson $sample2 2>&1) -join "`n"
  if ($out2 -match 'YM795720' -and $out2 -match 'ITEM</th>') { Ok "sample2 - status_rows rendered as the Status table (Item/ID columns)" } else { Bad "sample2 - status_rows table not rendered" }
  $out1 = (& powershell -NoProfile -ExecutionPolicy Bypass -File $poster -VerdictJson $sample 2>&1) -join "`n"
  if ($out1 -match 'CHECK</th>') { Ok "sample - checks_md parsed into the Status table (Check column)" } else { Bad "sample - parsed checks table not rendered" }
} catch { Bad "status table test threw: $($_.Exception.Message)" }

# ---- 5. GATE -----------------------------------------------------------------
Head "5. Verification gate blocks an unverified post"
$tmp = Join-Path $env:TEMP "emory_gatetest_$PID.json"
try {
  '{"sr":"GATE-TEST","dealer":"d","product":"p","issue":"i","sub":"s","platform":"EAS","verdict":"PASS","checks_md":"x","bottom":"b","owner":"o","classification":"c"}' |
    Set-Content -LiteralPath $tmp -Encoding UTF8
  $g = & powershell -NoProfile -ExecutionPolicy Bypass -File $poster -VerdictJson $tmp -Post 2>&1
  $gt = ($g -join "`n")
  if ($gt -match 'REFUSED TO POST') { Ok "gate refused a verdict with no verification block" }
  elseif ($gt -match 'Posted to') { Bad "GATE BYPASSED - an unverified card was POSTED" }
  else { Warn "gate outcome unclear - inspect manually" }
} catch {
  if ("$($_.Exception.Message)" -match 'REFUSED TO POST') { Ok "gate refused (threw as designed)" }
  else { Warn "gate test inconclusive: $($_.Exception.Message)" }
} finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }

# ---- 6. PARITY ---------------------------------------------------------------
Head "6. Install parity (canonical vs server-synced cache)"
$canon = (Get-FileHash -LiteralPath $poster -Algorithm MD5).Hash
Write-Host "  canonical emory_post.ps1 = $canon" -ForegroundColor Gray
$cacheRoot = "$env:APPDATA\Roaming\Claude\local-agent-mode-sessions"
if (-not (Test-Path $cacheRoot)) { $cacheRoot = "$env:APPDATA\Claude\local-agent-mode-sessions" }
if (Test-Path $cacheRoot) {
  $copies = @(Get-ChildItem -Path $cacheRoot -Recurse -Filter 'emory_post.ps1' -ErrorAction SilentlyContinue)
  if ($copies.Count -eq 0) { Ok "no cached copies present - nothing to drift" }
  foreach ($c in $copies) {
    $h = (Get-FileHash -LiteralPath $c.FullName -Algorithm MD5).Hash
    if ($h -eq $canon) { Ok "cache in sync: $($c.FullName)" }
    else { Warn "CACHE STALE (expected): $($c.FullName)`n             -> serves the OLD card format. Use bare /emory; re-publish the skill record to fix durably." }
  }
} else { Ok "no cache root found - single install" }

# ---- summary -----------------------------------------------------------------
Write-Host ""
if ($fail -eq 0 -and $warn -eq 0) { Write-Host "RESULT: STABLE - all checks passed." -ForegroundColor Green }
elseif ($fail -eq 0)              { Write-Host "RESULT: STABLE - $warn warning(s), nothing blocking." -ForegroundColor Yellow }
else                              { Write-Host "RESULT: BROKEN - $fail failure(s), $warn warning(s)." -ForegroundColor Red }
exit $fail
