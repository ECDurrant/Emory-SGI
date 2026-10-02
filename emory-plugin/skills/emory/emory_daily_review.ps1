<#
  emory_daily_review.ps1 - Emory's END-OF-DAY REVIEW.

  Every case anyone ran through Emory today, posted to Teams or not, in one picture: how many,
  how they split, which platforms, who owns the next step, what recurred, which known data gaps
  were hit, and which cases were reviewed but never posted.

  Sources (both local, no new access):
    review log  Downloads\emory_review_log.csv (or $env:EMORY_REVIEW_LOG) - written on EVERY Emory
                run by emory_post.ps1 (dry run or post) and by the MCP tools (emory_check_case,
                emory_investigate, emory_post_verdict)
    card log    Downloads\emory_card_log.csv - cards actually posted (older history, before the
                review log existed)
  Cases are merged by SR / INC number (else dealer + product); the latest row wins and a case
  counts as posted if any row says so.

  Output: ALWAYS saved to Downloads\Emory_Daily_Reviews\<date>.html and <date>.md. Posted to
  #api-support-intake only with -Post, or -Auto while Downloads\emory_autopost.txt reads "on"
  (the same revocable toggle as the cards). Quiet rule: no cases = no post unless -PostIfEmpty.
  Same visual rules as the card and digest: Teams-native primitives, small grey uppercase labels,
  exactly ONE <table>.

  Usage:
    powershell -File emory_daily_review.ps1                    # today, preview + save, no post
    powershell -File emory_daily_review.ps1 -Auto              # what the 17:30 task runs
    powershell -File emory_daily_review.ps1 -For 2026-10-01    # a past day
  Schedule: Register-EmoryDailyReviewTask.ps1 (weekdays 17:30).
  Pure ASCII source (PS 5.1); symbols built from code points.
#>
[CmdletBinding()]
param(
  [switch]$Post,
  [switch]$Auto,
  [switch]$PostIfEmpty,
  [string]$For = '',
  [string]$ReviewLog = '',
  [string]$CardLog  = "C:\Users\edurrant\Downloads\emory_card_log.csv",
  [string]$UrlFile  = "C:\Users\edurrant\Downloads\emory_verdict_delivery_url.txt",
  [string]$AutoFile = "C:\Users\edurrant\Downloads\emory_autopost.txt",
  [string]$OutDir   = "C:\Users\edurrant\Downloads\Emory_Daily_Reviews"
)
$ErrorActionPreference = 'Stop'

if (-not $ReviewLog) {
  $ReviewLog = if ($env:EMORY_REVIEW_LOG) { $env:EMORY_REVIEW_LOG } else { Join-Path (Split-Path -Parent $UrlFile) 'emory_review_log.csv' }
}
$autoOn = $false
if ($Auto -and (Test-Path -LiteralPath $AutoFile)) {
  $flag = ((Get-Content -Raw -LiteralPath $AutoFile) -replace '\s','').ToLower()
  $autoOn = @('on','1','true','yes') -contains $flag
}
$doPost = $Post.IsPresent -or $autoOn

$day = if ($For) { [datetime]::ParseExact($For, 'yyyy-MM-dd', $null) } else { (Get-Date).Date }
$dayS = $day.ToString('yyyy-MM-dd')
$monday = $day.AddDays(-(([int]$day.DayOfWeek + 6) % 7))

$DOTCH = [char]::ConvertFromUtf32(0x25CF)
$DOT   = [char]::ConvertFromUtf32(0x00B7)
$MUTED = '#8b949e'
$LBL_STYLE = "font-size: 11px; font-weight: 600; color: $MUTED;"
$SMALL = "font-size: 12px; color: $MUTED;"
$AIR = "<p style='margin: 0; font-size: 6px;'>&nbsp;</p>"
function HtmlEsc([string]$s) { if ([string]::IsNullOrEmpty($s)) { return "" }; return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') }
function Label([string]$t) { return "<p style='margin: 0; $LBL_STYLE'>" + $t.ToUpper() + "</p>" }
function Para([string]$inner, [string]$extra) { return "<p style='margin: 0; $extra'>$inner</p>" }
function Bucket([string]$verdict) { switch -Wildcard ("$verdict".ToUpper()) { 'FAIL*' { 'fail' } '*NEEDS*' { 'review' } 'PASS*' { 'pass' } default { 'review' } } }
function Color([string]$b) { switch ($b) { 'pass' { '#3fb950' } 'fail' { '#f85149' } default { '#f0883e' } } }
function Word([string]$b) { switch ($b) { 'pass' { 'Setup is correct' } 'fail' { 'Setup issue found' } default { 'Decision needed' } } }
function Short([string]$s, [int]$n) { $t = ("$s" -replace '\s+',' ').Trim(); if ($t.Length -gt $n) { return $t.Substring(0, $n - 3) + '...' }; return $t }
function CaseKey($sr, $dealer, $product) {
  $m = [regex]::Match("$sr", '(SR\d{6,}|INC\d{6,})')
  if ($m.Success) { return $m.Value }
  if ("$sr".Trim()) { return ("$sr".Trim() -split '\s')[0] }
  return ("$dealer|$product").ToUpper()
}
function PlatformName([string]$p) {
  $u = "$p".ToUpper().Trim()
  # the platform named FIRST wins ("EAS (... answered by Legacy)" is an EAS case)
  if ($u -match '^(EAS)\b') { return 'EAS' }
  if ($u -match '^(ROADRUNNER|RR)\b') { return 'RoadRunner' }
  if ($u -match '^(LEGACY|FORTE|CMS)\b') { return 'Legacy' }
  if ($u -match 'ROADRUNNER|^RR') { return 'RoadRunner' }
  if ($u -match 'LEGACY|FORTE|CMS') { return 'Legacy' }
  if ($u -match 'EAS') { return 'EAS' }
  if ($u -match 'NONE|NOT ACTIVE') { return 'Not enrolled anywhere' }
  if ($u) { return (Short $p 24) }
  return 'Unknown'
}

# ---- load + merge ------------------------------------------------------------------------
$cases = @{}
function Upsert($key, $time, $row, [bool]$posted) {
  if (-not $cases.ContainsKey($key)) { $cases[$key] = [ordered]@{ time = $time; row = $row; posted = $posted; runs = 1 }; return }
  $c = $cases[$key]; $c.runs++
  if ($posted) { $c.posted = $true }
  if ($time -ge $c.time) { $c.time = $time; $c.row = $row }
}
$weekKeys = @{}
if (Test-Path -LiteralPath $ReviewLog) {
  foreach ($r in (Import-Csv -LiteralPath $ReviewLog -Encoding UTF8)) {
    $t = "$($r.reviewed)"; if ($t.Length -lt 10) { continue }
    $k = CaseKey $r.sr $r.dealer $r.product
    $d = [datetime]::ParseExact($t.Substring(0,10), 'yyyy-MM-dd', $null)
    if ($d -ge $monday -and $d -le $day) { $weekKeys["$($t.Substring(0,10))|$k"] = 1 }
    if ($t.StartsWith($dayS)) {
      $row = [ordered]@{ sr = $r.sr; dealer = $r.dealer; product = $r.product; platform = $r.platform; verdict = $r.verdict;
                         owner = $r.owner; pattern = $r.pattern; issue = $r.first_issue; summary = $r.summary; source = $r.source; reviewer = $r.reviewer }
      Upsert $k $t $row ($r.posted -eq 'yes')
    }
  }
}
if (Test-Path -LiteralPath $CardLog) {
  foreach ($r in (Import-Csv -LiteralPath $CardLog -Encoding UTF8)) {
    $t = "$($r.posted)"; if ($t.Length -lt 10) { continue }
    if ("$($r.sr)" -like 'TEST*' -or "$($r.title)" -like 'TEST*') { continue }
    $k = CaseKey $r.sr $r.dealer ''
    $d = [datetime]::ParseExact($t.Substring(0,10), 'yyyy-MM-dd', $null)
    if ($d -ge $monday -and $d -le $day) { $weekKeys["$($t.Substring(0,10))|$k"] = 1 }
    if ($t.StartsWith($dayS)) {
      $row = [ordered]@{ sr = $r.sr; dealer = $r.dealer; product = ''; platform = $r.platform; verdict = $r.verdict;
                         owner = $r.owner; pattern = $r.pattern; issue = $r.title; summary = $r.key_question; source = 'card'; reviewer = '' }
      Upsert $k $t $row $true
    }
  }
}
$list = @($cases.GetEnumerator() | Sort-Object { $_.Value.time } | ForEach-Object { $_ })
$n = $list.Count
$nPass = @($list | Where-Object { (Bucket $_.Value.row.verdict) -eq 'pass' }).Count
$nFail = @($list | Where-Object { (Bucket $_.Value.row.verdict) -eq 'fail' }).Count
$nRev  = $n - $nPass - $nFail
$nPosted = @($list | Where-Object { $_.Value.posted }).Count
$weekN = $weekKeys.Count

$byPlat  = $list | Group-Object { PlatformName $_.Value.row.platform } | Sort-Object Count -Descending
$byOwner = $list | Where-Object { "$($_.Value.row.owner)".Trim() -and (Bucket $_.Value.row.verdict) -ne 'pass' } |
           Group-Object { Short (("$($_.Value.row.owner)" -split '[;(]')[0]) 40 } | Sort-Object Count -Descending
$byPat   = $list | Where-Object { "$($_.Value.row.pattern)".Trim() } | Group-Object { $_.Value.row.pattern } |
           Where-Object { $_.Count -ge 2 } | Sort-Object Count -Descending
$gapRules = [ordered]@{
  'G3 - onboarding dealer shell with no products' = 'G3|onboarding shell|0 products'
  'G8 - Audi dealer on retired rate system 134'   = 'G8|rate system 134'
  'G6 - BMW/MINI Canada prices expired'           = 'G6|20296'
  'G5 - RoadRunner Honda with no live rates'      = 'G5'
}
$gapHits = @()
foreach ($g in $gapRules.Keys) {
  $hits = @($list | Where-Object { ("$($_.Value.row.issue) $($_.Value.row.summary)") -match $gapRules[$g] })
  if ($hits.Count) { $gapHits += "$g ($($hits.Count))" }
}
$notPosted = @($list | Where-Object { -not $_.Value.posted })

# ---- build the message ---------------------------------------------------------------------
$p = @()
$p += "<div>"
$p += Para ("<b>Emory " + $DOT + " end-of-day review</b> &nbsp;<span style='$SMALL'>" + $day.ToString('dddd d MMMM yyyy') + "</span>") "font-size: 16px;"
$status = "$n case" + $(if ($n -ne 1) { 's' } else { '' }) + " reviewed today"
if ($n) {
  $status += " &nbsp;" + $DOT + "&nbsp; <span style='color: $(Color 'pass')'>$DOTCH</span> correct $nPass" +
             " &nbsp;<span style='color: $(Color 'review')'>$DOTCH</span> decide $nRev" +
             " &nbsp;<span style='color: $(Color 'fail')'>$DOTCH</span> issue $nFail" +
             " &nbsp;" + $DOT + "&nbsp; $nPosted posted to Teams"
}
$status += " &nbsp;" + $DOT + "&nbsp; $weekN this week"
$p += Para $status "$SMALL"
$p += $AIR

if (-not $n) {
  $p += Para "No cases were run through Emory today." ""
} else {
  $p += Label "Platforms"
  $p += Para ((@($byPlat | ForEach-Object { "$($_.Name) $($_.Count)" })) -join " &nbsp;$DOT&nbsp; ") ""
  $p += $AIR
  if ($byOwner) {
    $p += Label "Who owns the next step"
    $p += Para ((@($byOwner | Select-Object -First 6 | ForEach-Object { (HtmlEsc $_.Name) + " $($_.Count)" })) -join " &nbsp;$DOT&nbsp; ") ""
    $p += $AIR
  }
  if ($byPat -or $gapHits) {
    $p += Label "What recurred"
    foreach ($g in $byPat) { $p += Para ((HtmlEsc $g.Name) + " - $($g.Count) cases") "" }
    foreach ($g in $gapHits) { $p += Para ("Known data gap hit: " + (HtmlEsc $g)) "" }
    $p += $AIR
  }
  $p += Label "Cases"
  $p += "<table>"
  $p += "<tr><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>TIME</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>SR</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>DEALER " + $DOT + " PRODUCT</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>PLATFORM</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>FINDING</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>OWNER</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>POSTED</th></tr>"
  foreach ($e in $list) {
    $r = $e.Value.row; $b = Bucket $r.verdict
    $srTxt = CaseKey $r.sr $r.dealer $r.product
    $dp = (Short "$($r.dealer)" 34) + $(if ("$($r.product)".Trim()) { " $DOT " + (Short "$($r.product)" 18) } else { '' })
    $finding = "<span style='color: $(Color $b)'>$DOTCH</span> " + (Word $b) + $(if ("$($r.issue)".Trim()) { "<br><span style='$SMALL'>" + (HtmlEsc (Short "$($r.issue)" 110)) + "</span>" } else { '' })
    $own = if ($b -eq 'pass') { '-' } else { HtmlEsc (Short (("$($r.owner)" -split '[;(]')[0]) 40) }
    $p += "<tr><td style='padding: 3px 10px;'>" + $e.Value.time.Substring(11) + "</td><td style='padding: 3px 10px;'>" + (HtmlEsc $srTxt) + "</td><td style='padding: 3px 10px;'>" + (HtmlEsc $dp) + "</td><td style='padding: 3px 10px;'>" + (HtmlEsc (PlatformName $r.platform)) + "</td><td style='padding: 3px 10px;'>" + $finding + "</td><td style='padding: 3px 10px;'>" + $own + "</td><td style='padding: 3px 10px;'>" + $(if ($e.Value.posted) { 'yes' } else { 'no' }) + "</td></tr>"
  }
  $p += "</table>"
  if ($notPosted.Count) {
    $p += $AIR
    $p += Label "Reviewed but not posted"
    $p += Para (($notPosted | ForEach-Object { HtmlEsc (CaseKey $_.Value.row.sr $_.Value.row.dealer $_.Value.row.product) }) -join ", ") ""
  }
}
$p += $AIR
$p += Para ("Built from Emory's review log (every case run, posted or not) and card log. &nbsp;" + $DOT + "&nbsp; <i>Emory</i>") "$SMALL"
$p += "</div>"
$message = -join $p

# ---- save (always) -----------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$wrap = "<meta charset='utf-8'><title>Emory end-of-day review $dayS</title><style>body{margin:0;padding:28px;background:#1f1f1f;color:#e6e6e6;font-family:'Segoe UI',sans-serif;font-size:14px;max-width:1100px} table{border-collapse:collapse} table td,table th{border:1px solid #4a4a4a;vertical-align:top} p{margin:0}</style><body>"
Set-Content -LiteralPath (Join-Path $OutDir "$dayS.html") -Value ($wrap + "`n" + $message + "`n</body>") -Encoding UTF8
$md = @("# Emory end-of-day review - $dayS", "",
        "$n cases reviewed - correct $nPass, decide $nRev, issue $nFail - $nPosted posted to Teams - $weekN this week", "")
if ($n) {
  $md += "Platforms: " + ((@($byPlat | ForEach-Object { "$($_.Name) $($_.Count)" })) -join ', ')
  if ($byOwner) { $md += "Owners: " + ((@($byOwner | ForEach-Object { "$($_.Name) $($_.Count)" })) -join ', ') }
  if ($byPat) { $md += "Recurring: " + ((@($byPat | ForEach-Object { "$($_.Name) ($($_.Count))" })) -join ', ') }
  if ($gapHits) { $md += "Known gaps hit: " + ($gapHits -join ', ') }
  $md += ""
  $md += "| Time | SR | Dealer / product | Platform | Finding | Owner | Posted |"
  $md += "| --- | --- | --- | --- | --- | --- | --- |"
  foreach ($e in $list) {
    $r = $e.Value.row; $b = Bucket $r.verdict
    $md += "| " + $e.Value.time.Substring(11) + " | " + (CaseKey $r.sr $r.dealer $r.product) + " | " + ((Short "$($r.dealer) $($r.product)" 50) -replace '\|','/') + " | " + (PlatformName $r.platform) + " | " + (Word $b) + ": " + ((Short "$($r.issue)" 90) -replace '\|','/') + " | " + $(if ($b -eq 'pass') { '-' } else { (Short (("$($r.owner)" -split '[;(]')[0]) 40) -replace '\|','/' }) + " | " + $(if ($e.Value.posted) { 'yes' } else { 'no' }) + " |"
  }
}
Set-Content -LiteralPath (Join-Path $OutDir "$dayS.md") -Value $md -Encoding UTF8
Write-Host "Saved -> $(Join-Path $OutDir "$dayS.html") and .md   ($n cases, $nPosted posted, $weekN this week)" -ForegroundColor Green

# ---- deliver (gated) -----------------------------------------------------------------------
if (-not $doPost) {
  if ($Auto) { Write-Host "AUTO-POST OFF (toggle '$AutoFile' is not on) - saved locally, not posted." -ForegroundColor Yellow }
  else { Write-Host "DRY RUN - not posted. Use -Post, or -Auto with the hands-off toggle on." -ForegroundColor Yellow }
  return
}
if (-not $n -and -not $PostIfEmpty) { Write-Host "No cases today - review NOT posted (quiet rule). Pass -PostIfEmpty to force." -ForegroundColor Yellow; return }
if (-not (Test-Path -LiteralPath $UrlFile)) { throw "Delivery URL file not found: $UrlFile" }
$url = (Select-String -Path $UrlFile -Pattern 'https://\S+').Matches.Value | Select-Object -First 1
if (-not $url) { throw "No https URL found in $UrlFile" }
$payload = @{ message = $message } | ConvertTo-Json -Depth 4 -Compress
$resp = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -UseBasicParsing
Write-Host "End-of-day review posted to #api-support-intake. HTTP $($resp.StatusCode)" -ForegroundColor Green
