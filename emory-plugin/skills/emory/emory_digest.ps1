<#
  emory_digest.ps1 - Emory's DAILY DIGEST for #api-support-intake.

  One post per morning that makes the channel a source of truth for the day: how many cases Emory
  worked yesterday, how they split, which questions are waiting on which owner, how long cases had
  waited before review, and a 14-day trend. Built ONLY from the local delivery log that
  emory_post.ps1 appends to on every real card (Downloads\emory_card_log.csv) - no new access needed.

  Same visual rules as the verdict card (locked 2026-09-22): Teams-native primitives only, no boxes,
  small grey UPPERCASE labels, one accent colour per status, exactly ONE <table> (the 14-day trend).
  Teams strips backgrounds/borders/margins and boxes every table, so nothing else is styled.

  Sections:
    EMORY - DAILY DIGEST / <weekday, date>
    status line: N cases yesterday - PASS n - NEEDS REVIEW n - FAIL n - N this week
    STANDOUT             headline insight + 2 supporting lines (recurring cause, owner
                         bottleneck, oldest question, volume spike, issue streak, repeat dealer...)
    YESTERDAY            one line per card: verdict dot, SR, title, owner
    WAITING ON AN ANSWER  key questions asked in the last 7 days, oldest first, with owner + age
    KEY METRICS          cards this week / last week, review share, avg days reported->reviewed
    14-DAY TREND         table: day - cases (text bar) - pass - review - fail - what stood out
                         (the day's dominant root-cause pattern)

  Quiet rule: with no cards yesterday AND no open questions the digest is NOT posted (nothing to
  say = no post) unless -PostIfEmpty is given.

  Usage:
    powershell -File emory_digest.ps1                      # preview (dry run)
    powershell -File emory_digest.ps1 -Post                # deliver now
    powershell -File emory_digest.ps1 -Auto                # deliver iff emory_autopost.txt = on
    powershell -File emory_digest.ps1 -For 2026-09-22      # digest for a specific "yesterday"
    powershell -File emory_digest.ps1 -LogFile x.csv -EmitTemplate   # write emory_digest_preview.html

  Pure ASCII source (PS 5.1); symbols built from code points.
#>
[CmdletBinding()]
param(
  [switch]$Post,
  [switch]$Auto,
  [switch]$PostIfEmpty,
  [switch]$EmitTemplate,
  [string]$For = '',                                                         # the day being reported (default: yesterday)
  [string]$LogFile  = "C:\Users\edurrant\Downloads\emory_card_log.csv",
  [string]$UrlFile  = "C:\Users\edurrant\Downloads\emory_verdict_delivery_url.txt",
  [string]$AutoFile = "C:\Users\edurrant\Downloads\emory_autopost.txt",
  [string]$TemplateFile = ''
)
$ErrorActionPreference = 'Stop'

$autoOn = $false
if ($Auto -and (Test-Path -LiteralPath $AutoFile)) {
  $flag = ((Get-Content -Raw -LiteralPath $AutoFile) -replace '\s','').ToLower()
  $autoOn = @('on','1','true','yes') -contains $flag
}
$doPost = $Post.IsPresent -or $autoOn

$DOTCH = [char]::ConvertFromUtf32(0x25CF)   # filled circle
$DOT   = [char]::ConvertFromUtf32(0x00B7)   # middle dot
$BLOCK   = [char]::ConvertFromUtf32(0x2587)   # lower seven-eighths block, the text bar (NOT $BAR: collides with $bar below, PS is case-insensitive)
$MUTED = '#8b949e'
$LBL_STYLE = "font-size: 11px; font-weight: 600; color: $MUTED;"
$SMALL = "font-size: 12px; color: $MUTED;"
$AIR = "<p style='margin: 0; font-size: 6px;'>&nbsp;</p>"

function HtmlEsc([string]$s) { if ([string]::IsNullOrEmpty($s)) { return "" }; return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') }
function Label([string]$t) { return "<p style='margin: 0; $LBL_STYLE'>" + $t.ToUpper() + "</p>" }
function Para([string]$inner, [string]$extra) { return "<p style='margin: 0; $extra'>$inner</p>" }
function Bucket([string]$verdict) { switch -Wildcard ($verdict) { 'FAIL*' { 'fail' } '*NEEDS*' { 'review' } 'PASS*' { 'pass' } default { 'review' } } }
function Color([string]$b) { switch ($b) { 'pass' { '#3fb950' } 'fail' { '#f85149' } default { '#f0883e' } } }
# Reader-facing finding labels (2026-09-23): the log keeps PASS/FAIL/NEEDS REVIEW, the digest shows these.
function Word([string]$b) { switch ($b) { 'pass' { 'setup correct' } 'fail' { 'setup issue' } default { 'decision needed' } } }
function ShortWord([string]$b) { switch ($b) { 'pass' { 'CORRECT' } 'fail' { 'ISSUE' } default { 'DECIDE' } } }
function Dot([string]$b) { return "<span style='color: " + (Color $b) + "; font-weight: 700;'>" + $DOTCH + "</span>" }
function Plural([int]$n, [string]$one, [string]$many) { if ($n -eq 1) { return "$n $one" } else { return "$n $many" } }

# ---- load the log ---------------------------------------------------------------------------
$rows = @()
if (Test-Path -LiteralPath $LogFile) {
  $raw = Get-Content -LiteralPath $LogFile -Encoding UTF8 | Where-Object { $_.Trim() }
  if ($raw.Count -gt 1 -and $raw[0] -like 'posted,*') {
    $rows = @($raw | ConvertFrom-Csv)
  } elseif ($raw.Count -gt 0 -and $raw[0] -notlike 'posted,*') {
    # v1 log (no header): posted,sr,verdict,owner
    $rows = @($raw | ConvertFrom-Csv -Header posted,sr,verdict,owner | ForEach-Object {
      $_ | Add-Member -NotePropertyName title -NotePropertyValue $_.sr -PassThru |
           Add-Member -NotePropertyName question_for -NotePropertyValue '' -PassThru |
           Add-Member -NotePropertyName key_question -NotePropertyValue '' -PassThru |
           Add-Member -NotePropertyName reported_date -NotePropertyValue '' -PassThru })
  }
}
$rows = @($rows | Where-Object { $_.sr -notlike 'TEST*' -and $_.title -notlike 'TEST*' })   # test posts never count
foreach ($r in $rows) {
  $d = [datetime]::MinValue
  [void][datetime]::TryParse($r.posted, [ref]$d)
  $r | Add-Member -NotePropertyName day -NotePropertyValue $d.Date -Force
  $r | Add-Member -NotePropertyName bucket -NotePropertyValue (Bucket $r.verdict) -Force
}

$today = if ($For) { ([datetime]$For).Date.AddDays(1) } else { (Get-Date).Date }
$yday  = $today.AddDays(-1)
$weekStart = $today.AddDays(-(([int]$today.DayOfWeek + 6) % 7))          # Monday
$lastWeekStart = $weekStart.AddDays(-7)

$yRows    = @($rows | Where-Object { $_.day -eq $yday })
$weekRows = @($rows | Where-Object { $_.day -ge $weekStart -and $_.day -lt $today })
$lastWeek = @($rows | Where-Object { $_.day -ge $lastWeekStart -and $_.day -lt $weekStart })
$recent7  = @($rows | Where-Object { $_.day -ge $today.AddDays(-7) -and $_.day -lt $today })
$questions = @($recent7 | Where-Object { $_.key_question } | Sort-Object day)

$nPass = @($yRows | Where-Object { $_.bucket -eq 'pass' }).Count
$nRev  = @($yRows | Where-Object { $_.bucket -eq 'review' }).Count
$nFail = @($yRows | Where-Object { $_.bucket -eq 'fail' }).Count

# avg days from reported -> reviewed (this week, where a reported date is known)
$lags = @()
foreach ($r in $weekRows) {
  $rd = [datetime]::MinValue
  if ($r.reported_date -and [datetime]::TryParse($r.reported_date, [ref]$rd)) { $lags += ($r.day - $rd.Date).TotalDays }
}
$avgLag = if ($lags.Count -gt 0) { [math]::Round(($lags | Measure-Object -Average).Average, 1) } else { $null }
$reviewShare = if ($weekRows.Count -gt 0) { [math]::Round(100 * @($weekRows | Where-Object { $_.bucket -ne 'pass' }).Count / $weekRows.Count) } else { $null }

$isEmpty = ($yRows.Count -eq 0 -and $questions.Count -eq 0)

# ---- STANDOUT: what is notable about the recent cases -------------------------------------------
# Deterministic rules over the last 7 days / this week, each scored; the top one is the headline,
# the next two are supporting lines. Business language only. Falls back to "no recurring pattern".
function PatternOf($r) {
  if ($r.pattern) { return [string]$r.pattern }
  if ($r.category) { return (([string]$r.category) -split '\s+-\s+')[0] }
  if ($r.inquiry_type) { return [string]$r.inquiry_type }
  return ''
}
$ins = @()

# a. recurring root-cause pattern in the last 7 days
# 'Working as designed' is not a cause to fix, so it is excluded here and handled by rule i.
$pg = @($recent7 | Where-Object { (PatternOf $_) -and ((PatternOf $_) -notlike 'Working as designed*') } | Group-Object { PatternOf $_ } | Sort-Object Count -Descending)
if ($pg.Count -gt 0 -and $pg[0].Count -ge 2) {
  $g0 = $pg[0]
  $srs = @($g0.Group | Sort-Object posted -Descending | Select-Object -First 3 | ForEach-Object { $_.sr }) -join ', '
  $yHit = @($g0.Group | Where-Object { $_.day -eq $yday }).Count -gt 0
  $incl = if ($yHit) { ", including yesterday" } else { "" }
  $bonus = if ($yHit) { 5 } else { 0 }
  $ins += @{ score = (10 * $g0.Count + $bonus); rule = 'pattern'
             text = "<b>" + (HtmlEsc $g0.Name) + "</b> is the recurring cause: " + $g0.Count + " of " + $recent7.Count + " cases in the last 7 days" + $incl + " <span style='color: " + $MUTED + ";'>(" + (HtmlEsc $srs) + ")</span>" }
}
# b. one owner holds most open questions
if ($questions.Count -ge 2) {
  $og = @($questions | Where-Object { $_.question_for } | Group-Object question_for | Sort-Object Count -Descending)
  if ($og.Count -gt 0 -and $og[0].Count -ge 2 -and ($og[0].Count * 2) -ge $questions.Count) {
    $ins += @{ score = (8 * $og[0].Count); rule = 'owner'
               text = "<b>" + (HtmlEsc $og[0].Name) + "</b> holds " + $og[0].Count + " of the " + $questions.Count + " open questions; the queue is waiting on one team" }
  }
}
# c. oldest unanswered question
if ($questions.Count -gt 0) {
  $oldest = $questions[0]
  $oAge = [int]($today - $oldest.day).TotalDays
  if ($oAge -ge 5) {
    $ins += @{ score = (3 * $oAge); rule = 'age'
               text = "Oldest unanswered question is <b>" + $oAge + " days</b> old: " + (HtmlEsc $oldest.question_for) + ", " + (HtmlEsc $oldest.title) + " <span style='color: " + $MUTED + ";'>(" + (HtmlEsc $oldest.sr) + ")</span>" }
  }
}
# d. volume spike yesterday
$prior13 = @($rows | Where-Object { $_.day -ge $today.AddDays(-14) -and $_.day -lt $yday })
$avg13 = if ($prior13.Count -gt 0) { [math]::Round($prior13.Count / 13.0, 1) } else { 0 }
$maxPrior = 0
foreach ($g in @($prior13 | Group-Object day)) { if ($g.Count -gt $maxPrior) { $maxPrior = $g.Count } }
if ($yRows.Count -ge 3 -and $yRows.Count -gt $maxPrior -and $yRows.Count -ge (2 * $avg13)) {
  $ins += @{ score = 25; rule = 'volume'
             text = "Yesterday was the <b>busiest day in two weeks</b>: " + $yRows.Count + " cases against a daily average of " + $avg13 }
}
# e. share needing a human moved vs last week
if ($weekRows.Count -ge 3 -and $lastWeek.Count -ge 3) {
  $lwShare = [math]::Round(100 * @($lastWeek | Where-Object { $_.bucket -ne 'pass' }).Count / $lastWeek.Count)
  $dShare = $reviewShare - $lwShare
  if ([math]::Abs($dShare) -ge 20) {
    $dir = if ($dShare -gt 0) { 'up' } else { 'down' }
    $ins += @{ score = 15; rule = 'share'
               text = "Cases needing a human are <b>$dir</b>: $reviewShare% this week vs $lwShare% last week" }
  }
}
# f. consecutive working days with a FAIL
$streak = 0; $dcur = $yday
while ($true) {
  if ($dcur.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) { $dcur = $dcur.AddDays(-1); continue }
  $dayFails = @($rows | Where-Object { $_.day -eq $dcur -and $_.bucket -eq 'fail' }).Count
  if ($dayFails -gt 0) { $streak++; $dcur = $dcur.AddDays(-1) } else { break }
  if ($streak -ge 10) { break }
}
if ($streak -ge 2) { $ins += @{ score = (12 * $streak); rule = 'streak'; text = "A <b>setup issue</b> has been found on <b>$streak working days in a row</b>" } }
# g. Legacy share
$lg = @($recent7 | Where-Object { $_.platform -like 'Legacy*' -or $_.platform -like '*LGY*' }).Count
if ($lg -ge 2 -and $recent7.Count -gt 0 -and (100 * $lg / $recent7.Count) -ge 40) {
  $ins += @{ score = 10; rule = 'platform'; text = "<b>Legacy</b> platform cases are a large share: $lg of " + $recent7.Count + " in the last 7 days" }
}
# h. same dealer twice in 7 days
$dg = @($recent7 | Where-Object { $_.dealer } | Group-Object dealer | Where-Object { $_.Count -ge 2 } | Sort-Object Count -Descending)
if ($dg.Count -gt 0) { $ins += @{ score = (12 * $dg[0].Count); rule = 'dealer'; text = "<b>" + (HtmlEsc $dg[0].Name) + "</b> has come up " + $dg[0].Count + " times in 7 days" } }
# i. mostly working-as-designed
$wad = @($recent7 | Where-Object { (PatternOf $_) -like 'Working as designed*' }).Count
if ($recent7.Count -ge 4 -and (2 * $wad) -ge $recent7.Count) {
  $ins += @{ score = 9; rule = 'wad'; text = "<b>$wad of " + $recent7.Count + "</b> cases this week were working as designed: partner and dealer education, not fixes" }
}
# j. always-available fallback: the mix of causes in the last 7 days (top four)
$mixG = @($recent7 | Where-Object { PatternOf $_ } | Group-Object { PatternOf $_ } | Sort-Object Count -Descending | Select-Object -First 4)
if ($mixG.Count -gt 0) {
  $mixBits = @()
  foreach ($g in $mixG) { $mixBits += (HtmlEsc $g.Name) + $(if ($g.Count -gt 1) { " x" + $g.Count } else { '' }) }
  $ins += @{ score = 5; rule = 'mix'; text = "Mix of causes in the last 7 days: " + ($mixBits -join ", ") }
}
$ins = @($ins | Sort-Object { -$_.score })

# ---- build the message --------------------------------------------------------------------------
$p = @()
$p += "<div style='font-family: Aptos, ""Segoe UI"", sans-serif; line-height: 1.45;'>"
$p += Label ("Emory " + $DOT + " Daily digest")
$p += Para ("<b>" + $today.ToString('dddd, d MMMM yyyy') + "</b>") "font-size: 20px; line-height: 1.25;"

$st = @()
$yb = if ($yRows.Count -eq 0) { 'pass' } elseif ($nFail -gt 0) { 'fail' } elseif ($nRev -gt 0) { 'review' } else { 'pass' }
$st += (Dot $yb) + " <b>" + (Plural $yRows.Count 'case' 'cases') + " yesterday</b>"
if ($yRows.Count -gt 0) {
  if ($nPass -gt 0) { $st += "<span style='color: #3fb950;'>$nPass setup correct</span>" }
  if ($nRev  -gt 0) { $st += "<span style='color: #f0883e;'>$nRev decision needed</span>" }
  if ($nFail -gt 0) { $st += "<span style='color: #f85149;'>$nFail setup issue</span>" }
}
$st += (Plural $weekRows.Count 'case' 'cases') + " this week"
$p += Para (($st -join (" &nbsp;" + $DOT + "&nbsp; "))) "font-size: 13px; color: $MUTED;"
$p += $AIR

# STANDOUT (headline + up to two supporting lines)
$p += Label 'Standout'
if ($ins.Count -eq 0) {
  $p += Para "No recurring pattern in the last 7 days; cases are spread across owners and causes." "font-size: 14px;"
} else {
  $p += Para $ins[0].text "font-size: 14.5px;"
  if ($ins.Count -gt 1) {
    $p += "<ul style='margin: 0; padding-left: 18px; font-size: 13.5px;'>"
    foreach ($x in @($ins | Select-Object -Skip 1 -First 2)) { $p += "<li>" + $x.text + "</li>" }
    $p += "</ul>"
  }
}
$p += $AIR

# YESTERDAY
$p += Label 'Yesterday'
if ($yRows.Count -eq 0) {
  $p += Para "No cases posted." "font-size: 14px; color: $MUTED;"
} else {
  $p += "<ul style='margin: 0; padding-left: 18px; font-size: 14px; list-style: none;'>"
  foreach ($r in ($yRows | Sort-Object posted)) {
    $t = if ($r.title -and $r.title -ne $r.sr) { (HtmlEsc $r.sr) + " " + $DOT + " " + (HtmlEsc $r.title) } else { HtmlEsc $r.sr }
    $own = if ($r.owner) { " &nbsp;<span style='color: $MUTED;'>" + $DOT + "&nbsp; " + (HtmlEsc (($r.owner -split ';')[0].Trim())) + "</span>" } else { '' }
    $p += "<li>" + (Dot $r.bucket) + " " + $t + $own + "</li>"
  }
  $p += "</ul>"
}
$p += $AIR

# WAITING ON AN ANSWER
if ($questions.Count -gt 0) {
  $p += Label 'Waiting on an answer'
  $p += Para "Key questions Emory asked in the last 7 days. Oldest first." "$SMALL"
  $p += "<ol style='margin: 0; padding-left: 22px; font-size: 14px;'>"
  foreach ($q in $questions) {
    $age = [int]($today - $q.day).TotalDays
    $ageTxt = if ($age -le 1) { '1d' } else { "${age}d" }
    $who = if ($q.question_for) { "<b>" + (HtmlEsc $q.question_for) + "</b> " + $DOT + " " } else { '' }
    $p += "<li>" + $who + (HtmlEsc $q.key_question) + " <span style='color: $MUTED;'>(" + (HtmlEsc $q.sr) + ", $ageTxt)</span></li>"
  }
  $p += "</ol>"
  $p += $AIR
}

# KEY METRICS - one line each
$p += Label 'Key metrics'
$m = @()
$delta = $weekRows.Count - $lastWeek.Count
$deltaTxt = if ($lastWeek.Count -eq 0 -and $weekRows.Count -eq 0) { '' } elseif ($delta -gt 0) { " (+$delta vs last week)" } elseif ($delta -lt 0) { " ($delta vs last week)" } else { " (same as last week)" }
$m += "<b style='color: $MUTED;'>This week</b>&nbsp;&nbsp; " + (Plural $weekRows.Count 'case' 'cases') + $deltaTxt
if ($null -ne $reviewShare) { $m += "<b style='color: $MUTED;'>Needing a person</b>&nbsp;&nbsp; $reviewShare% of this week's cases needed a decision or a fix" }
if ($null -ne $avgLag) { $m += "<b style='color: $MUTED;'>Time to review</b>&nbsp;&nbsp; $avgLag days on average from report to Emory's review (this week)" }
$m += "<b style='color: $MUTED;'>Open questions</b>&nbsp;&nbsp; " + (Plural $questions.Count 'question' 'questions') + " asked in the last 7 days"
foreach ($line in $m) { $p += Para $line "font-size: 14px;" }
$p += $AIR

# 14-DAY TREND - the one table
$p += Label '14-day trend'
$maxDay = 1
$trend = @()
for ($i = 13; $i -ge 0; $i--) {
  $d = $today.AddDays(-1 - $i)
  $dr = @($rows | Where-Object { $_.day -eq $d })
  $note = ''
  if ($dr.Count -gt 0) {
    $dpg = @($dr | Where-Object { PatternOf $_ } | Group-Object { PatternOf $_ } | Sort-Object Count -Descending)
    if ($dpg.Count -gt 0) { $note = $dpg[0].Name; if ($dpg[0].Count -gt 1) { $note += " x" + $dpg[0].Count } }
  }
  $trend += @{ day = $d; n = $dr.Count; pass = @($dr | Where-Object { $_.bucket -eq 'pass' }).Count; rev = @($dr | Where-Object { $_.bucket -eq 'review' }).Count; fail = @($dr | Where-Object { $_.bucket -eq 'fail' }).Count; note = $note }
  if ($dr.Count -gt $maxDay) { $maxDay = $dr.Count }
}
$p += "<table style='border-collapse: collapse; font-size: 13px;'>"
$p += "<tr><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>DAY</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>CASES</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>CORRECT</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>DECIDE</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>ISSUE</th><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>WHAT STOOD OUT</th></tr>"
foreach ($t in $trend) {
  if ($t.day.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday) -and $t.n -eq 0) { continue }   # quiet weekends drop out
  $barLen = [int][math]::Round(10 * $t.n / $maxDay)
  $bar = if ($t.n -gt 0) { "<span style='color: #58a6ff;'>" + ($BLOCK * $barLen) + "</span> " } else { "<span style='color: $MUTED;'>" + $DOT + "</span> " }
  $dim = if ($t.n -eq 0) { "color: $MUTED;" } else { '' }
  $p += "<tr><td style='padding: 3px 10px; white-space: nowrap; $dim'>" + $t.day.ToString('ddd dd MMM') + "</td>"
  $p += "<td style='padding: 3px 10px; white-space: nowrap; $dim'>" + $bar + $t.n + "</td>"
  $p += "<td style='padding: 3px 10px; color: #3fb950;'>" + $(if ($t.pass) { $t.pass } else { '' }) + "</td>"
  $p += "<td style='padding: 3px 10px; color: #f0883e;'>" + $(if ($t.rev) { $t.rev } else { '' }) + "</td>"
  $p += "<td style='padding: 3px 10px; color: #f85149;'>" + $(if ($t.fail) { $t.fail } else { '' }) + "</td>"
  $p += "<td style='padding: 3px 10px; color: $MUTED;'>" + (HtmlEsc $t.note) + "</td></tr>"
}
$p += "</table>"
$p += $AIR
$p += Para ("Counts come from Emory's own delivery log (cards posted to this channel), not from Salesforce. Test posts are excluded. &nbsp;" + $DOT + "&nbsp; <i>Emory</i>") "$SMALL"
$p += "</div>"

$message = -join $p
$payload = @{ message = $message } | ConvertTo-Json -Depth 4 -Compress

if ($EmitTemplate) {
  if (-not $TemplateFile) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $TemplateFile = Join-Path $root 'emory_digest_preview.html'
  }
  $wrap = "<!-- GENERATED by emory_digest.ps1 -EmitTemplate; do not hand-edit. Mimics Teams (dark bg, table borders). -->`n<meta charset='utf-8'><style>body{margin:0;padding:28px;background:#1f1f1f;color:#e6e6e6;font-family:'Segoe UI',sans-serif;font-size:14px;max-width:1000px} table td,table th{border:1px solid #4a4a4a} p{margin:0}</style><body>"
  Set-Content -LiteralPath $TemplateFile -Value ($wrap + "`n" + $message + "`n</body>") -Encoding UTF8
  Write-Host "Regenerated digest preview -> $TemplateFile" -ForegroundColor Green
  return
}

Write-Host "----- Emory daily digest (HTML) -----"
Write-Host $message
Write-Host "-------------------------------------"
Write-Host ("yesterday=" + $yRows.Count + " week=" + $weekRows.Count + " questions=" + $questions.Count + " empty=" + $isEmpty) -ForegroundColor DarkGray

if (-not $doPost) {
  Write-Host "DRY RUN - not posted. Use -Post, or -Auto with the hands-off toggle on." -ForegroundColor Yellow
  return
}
if ($isEmpty -and -not $PostIfEmpty) {
  Write-Host "Nothing to report (no cases yesterday, no open questions) - digest NOT posted. Pass -PostIfEmpty to force." -ForegroundColor Yellow
  return
}
if (-not (Test-Path -LiteralPath $UrlFile)) { throw "Delivery URL file not found: $UrlFile" }
$url = (Select-String -Path $UrlFile -Pattern 'https://\S+').Matches.Value | Select-Object -First 1
if (-not $url) { throw "No https URL found in $UrlFile" }
$bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -UseBasicParsing
Write-Host "Digest posted to #api-support-intake. HTTP $($resp.StatusCode)" -ForegroundColor Green
