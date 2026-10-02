<#
  emory_post.ps1 - Emory's Teams delivery adapter.  THIS SCRIPT IS THE CARD LAYOUT AUTHORITY.

  Takes the verdict JSON Emory emits and builds TWO renderings of the same content:
    message : HTML for the live flow "Http -> Post message in a chat or channel"
              (Flow bot -> #api-support-intake). Contract: { "message": "<html>" }.
    card    : an Adaptive Card (v1.4, JSON string) with the Investigation Details behind an
              Action.ToggleVisibility button - a TRUE collapse. Teams strips <details>/<summary>
              from HTML messages, so a collapsible section is only possible as an Adaptive Card.
              Goes live the day the flow gains a "Post card in a chat or channel" step bound to
              triggerBody()?['card']. Until then the flow ignores the field.

  ------------------------------------------------------------------------------------------
  CARD LAYOUT - EXECUTIVE-SUMMARY FIRST (analyst spec 2026-09-22, replaces the 2026-09-15
  six-section "reader-first" card, which was judged too noisy: five prose boxes before the
  evidence, each restating the previous one).
  ------------------------------------------------------------------------------------------
    HEADER              one line: "Emory Case Review" + verdict pill; SR + title underneath
    EXECUTIVE SUMMARY   3-6 short bullets, plain English            <- `summary` (array)
    STATUS              one compact table with green/amber/red marks <- `status_rows` (array)
                                                                     or parsed from `checks_md`
    NEXT STEPS          the key question (bold) + numbered actions + owner
                                                                     <- `key_question`, `question_for`,
                                                                        `actions`, `owner`
    ---- divider ----
    INVESTIGATION       small, grey, de-emphasised; everything technical. Identifiers,
    DETAILS             narrative, checks, root cause, how verified, classification.
                        In Teams the message folds behind "See more" once it is long, so a
                        reader who stops at Next Steps never scrolls through this. In the
                        Adaptive Card it is hidden until "Show investigation details" is tapped.

  BACKWARD COMPATIBILITY - every 2026-09-15 field still renders, so old verdict JSON works:
    summary       <- falls back to issue_line / impact_line / action_line, then `bottom`
    key_question  <- falls back to `confirm`
    status_rows   <- falls back to parsing `checks_md` (one row per line)
    bottom / business_impact -> "Narrative" inside Investigation Details when `summary` exists

  VERDICT JSON (fields marked * are required to render; `verification` is required to POST):
    sr*, title, dealer*, product*, sub, source, platform*, reported, verdict*, verdict_color
    summary[]        plain-English bullets. No acronyms, table names, row counts.
    status_rows[]    { "item": "Ghostrider", "id": "YM900149", "status": "pass|fixed|ok|working|
                       review|warn|fail|skipped|n/a", "note": "optional short text" }
    key_question     ONE bold question the owner can answer yes/no.
    question_for     who it is aimed at, e.g. "Account Management" (heading "Key question for ...")
    actions[]        discrete, ownable items.        owner   ownership line.
    checks_md*       one line per check (analyst evidence).  root_cause  analyst explanation.
    verification[]   claim + how it was established (>= 25 chars each).  classification*.
    bottom, business_impact, confirm, issue, issue_line, impact_line, action_line  (legacy).

  PROSE FORMATTING: summary bullets, actions, key_question, bottom, business_impact, root_cause
  run through Prose(): blank line = paragraph, newline = <br>, **bold**, `code`.

  SAFETY: dry-run by DEFAULT. -Post forces a send; -Auto sends only while the toggle file
  reads on. The pre-post VERIFICATION GATE is unchanged. Never PII or plaintext passwords.

  Usage:
    powershell -File emory_post.ps1 -VerdictJson verdict.json                 # preview
    powershell -File emory_post.ps1 -VerdictJson verdict.json -Post           # deliver
    powershell -File emory_post.ps1 -VerdictJson verdict.json -Auto           # hands-off
    powershell -File emory_post.ps1 -VerdictJson emory_verdict_card.sample.json -EmitTemplate
        -> regenerates emory_verdict_card.html AND emory_verdict_card.adaptive.json (never sends)

  Source is pure ASCII on purpose (PowerShell 5.1 mis-reads unsaved UTF-8); emoji are built
  from code points and JSON data is read as UTF-8.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$VerdictJson,
  [switch]$Post,
  [switch]$Auto,
  [switch]$EmitTemplate,
  [string]$TemplateFile = '',
  [string]$UrlFile  = "C:\Users\edurrant\Downloads\emory_verdict_delivery_url.txt",
  [string]$AutoFile = "C:\Users\edurrant\Downloads\emory_autopost.txt"
)

$ErrorActionPreference = 'Stop'

$autoOn = $false
if ($Auto -and (Test-Path -LiteralPath $AutoFile)) {
  $flag = ((Get-Content -Raw -LiteralPath $AutoFile) -replace '\s','').ToLower()
  $autoOn = @('on','1','true','yes') -contains $flag
}
$doPost = $Post.IsPresent -or $autoOn

# ---- symbols from code points (source stays ASCII) ----------------------------------------
$VS16     = [string][char]0xFE0F
$E_SEARCH = [char]::ConvertFromUtf32(0x1F50E)            # magnifier
$E_CHECK  = [char]::ConvertFromUtf32(0x2705)             # green check
$E_WARN   = [char]::ConvertFromUtf32(0x26A0) + $VS16     # warning sign
$E_X      = [char]::ConvertFromUtf32(0x274C)             # red cross
$E_SKIP   = [char]::ConvertFromUtf32(0x23ED) + $VS16     # skip
$E_LIST   = [char]::ConvertFromUtf32(0x1F4CB)            # clipboard
$BULLET   = [char]::ConvertFromUtf32(0x25AA)             # small black square
$DOT      = [char]::ConvertFromUtf32(0x00B7)             # middle dot
$DOWN     = [char]::ConvertFromUtf32(0x25BE)             # small down triangle

function HtmlEsc([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return "" }
  return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
}

function Prose([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return "" }
  $t = HtmlEsc $s
  $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '<b>$1</b>')
  $t = [regex]::Replace($t, '`([^`]+?)`', '<code style="font-family: Consolas, monospace; font-size: 0.93em; background: rgba(255,255,255,0.10); padding: 1px 4px; border-radius: 3px;">$1</code>')
  $paras = [regex]::Split($t, '(?:\r?\n){2,}')
  $out = @()
  foreach ($p0 in $paras) {
    $p = ($p0 -replace "`r?`n", '<br>')
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $mt = if ($out.Count -eq 0) { '0' } else { '8px' }
    $out += "<div style='margin-top: $mt;'>$p</div>"
  }
  return ($out -join '')
}

# Strip markdown/emoji decoration for the Adaptive Card and for parsing.
function Plain([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return "" }
  $t = $s -replace '`',''
  $t = [regex]::Replace($t, '[\u2600-\u27BF\uFE0F]|[\uD83C-\uDBFF][\uDC00-\uDFFF]', '')
  return $t.Trim()
}

# Normalise any status word / code to a bucket: pass | review | fail | skip
function StatusBucket([string]$s) {
  $u = ("$s").ToUpper().Trim()
  if ($u -match '^(PASS|PASSED|OK|FIXED|WORKING|GOOD|RESOLVED|LIVE|ACTIVE|YES|GREEN)') { return 'pass' }
  if ($u -match '^FAIL' -or $u -match '^(BROKEN|ERROR|MISSING|RED|NO)$') { return 'fail' }
  if ($u -match 'SKIP|NOT CHECKED|^N/?A$|NOT RUN|NONE') { return 'skip' }
  return 'review'
}
function StatusMark([string]$bucket) {
  switch ($bucket) { 'pass' { $E_CHECK } 'fail' { $E_X } 'skip' { $E_SKIP } default { $E_WARN } }
}
function StatusColor([string]$bucket) {
  switch ($bucket) { 'pass' { '#3fb950' } 'fail' { '#f85149' } 'skip' { '#8b949e' } default { '#f0883e' } }
}
function StatusWord([string]$bucket, [string]$given) {
  if ($given) { return $given }
  switch ($bucket) { 'pass' { 'OK' } 'fail' { 'Issue' } 'skip' { 'Skipped' } default { 'Review' } }
}
# Reader-facing label for the overall finding (2026-09-23). The JSON `verdict` keeps PASS / FAIL /
# NEEDS REVIEW for the log, the verifier and older tooling; only what people SEE changes.
#   PASS         -> Setup is correct    (nothing to fix on our side; cause is partner / dealer / by design)
#   FAIL         -> Setup issue found   (a specific configuration problem, with its owner)
#   NEEDS REVIEW -> Decision needed     (setup may be deliberate; one team must confirm intent)
function FindingLabel([string]$bucket) {
  switch ($bucket) { 'pass' { 'Setup is correct' } 'fail' { 'Setup issue found' } default { 'Decision needed' } }
}

# Parse one checks_md line into item / status / note. Defensive on purpose: the model varies the shape.
# Accepted shapes:
#   "1. Dealer status - PASS - EAS dealer 58271 active"          (label first)
#   "[emoji] **FAIL (request)** - Dealer code: detail"           (status first, optional qualifier)
#   "[emoji] **DUPLICATE** - Contract dedup: detail"             (non-status keyword first)
#   "Anything at all: detail"                                    (no status word -> review, name = text before ':')
# The check NAME is always squeezed to a short canonical label (<= 4 words); everything else goes to the note.
$CHECK_VOCAB = @(
  @('sr dedup|salesforce|duplicate sr|dup sr',                 'SR dedup'),
  @('dedup|duplicate|already active|existing contract',       'Duplicate contract'),
  @('dealer|seller|rooftop',                                  'Dealer'),
  @('product assign|product code|products? on|product\b',    'Product'),
  @('form',                                                   'Form'),
  @('rate system',                                            'Rate system'),
  @('sku|rate table|pricing|rates?\b',                        'Rate SKU'),
  @('class',                                                  'Classing'),
  @('matrix|eligib|condition rule|step 7',                    'Eligibility rule'),
  @('caller|partner.side|routing|wrong service|wrong endpoint','Request routing'),
  @('live|postman|api call|endpoint',                         'Live API'),
  @('attachment|payload|request json',                        'Request payload')
)
function CanonicalItem([string]$raw) {
  $t = ($raw -replace '\s+',' ').Trim()
  foreach ($pair in $CHECK_VOCAB) { if ($t -match ('(?i)' + $pair[0])) { return $pair[1] } }
  $t = [regex]::Replace($t, '^(Step\s*\d+[a-z]?\s*[:\-]\s*)', '')
  $m = [regex]::Match($t, '^([^:\u2014\u2013(]{3,48}?)\s*(?::|\s[\u2014\u2013-]\s|\()')
  if ($m.Success) { $t = $m.Groups[1].Value.Trim() }
  $w = $t -split ' '
  if ($w.Count -gt 4) { $t = ($w[0..3] -join ' ') }
  if ($t.Length -gt 36) { $t = $t.Substring(0,36).TrimEnd() }
  return $t
}
$STATUS_RX = '(?i)\b(NEEDS REVIEW|NEEDS-HUMAN|REVIEW|PASS(?:ED)?|FAIL(?:ED)?|SKIPPED|NOT CHECKED|NOT RUN|N/A|INFO|OK|FIXED|WORKING|DUPLICATE|WARN(?:ING)?)\b'
function ParseCheckLine([string]$line) {
  $raw = ($line -replace '\*\*','')
  $emojiBucket = ''
  if ($raw.Contains($E_CHECK)) { $emojiBucket = 'pass' }
  elseif ($raw.Contains($E_X)) { $emojiBucket = 'fail' }
  elseif ($raw.Contains([string][char]0x23ED)) { $emojiBucket = 'skip' }
  elseif ($raw.Contains([string][char]0x26A0)) { $emojiBucket = 'review' }
  $t = Plain $raw
  $t = $t -replace '^\s*\d+[\.\)]\s*',''
  if ([string]::IsNullOrWhiteSpace($t)) { return $null }
  $trimChars = [char[]]@(' ', '-', ':', [char]0x2013, [char]0x2014, '|')
  $splitter = New-Object regex '\s*(?::|\s[-\u2013\u2014]\s)\s*'
  $m = [regex]::Match($t, $STATUS_RX)
  $word = ''; $qual = ''; $item = ''; $note = ''
  $bucket = if ($emojiBucket) { $emojiBucket } else { 'review' }
  if ($m.Success -and $m.Index -le 40) {
    # status (or DUPLICATE/WARN) leads: "STATUS (qualifier) - Name: detail"
    $word = $m.Groups[1].Value
    if ($word -notmatch '^(?i)(duplicate|warn)') { $bucket = StatusBucket $word } elseif (-not $emojiBucket) { $bucket = 'review' }
    $pre  = $t.Substring(0, $m.Index).Trim($trimChars)
    $post = $t.Substring($m.Index + $m.Length).Trim($trimChars)
    $qm = [regex]::Match($post, '^\(([^)]{1,30})\)\s*')
    if ($qm.Success) { $qual = $qm.Groups[1].Value.Trim(); $post = $post.Substring($qm.Length).Trim($trimChars) }
    if ($pre) { $item = $pre; $note = $post }
    else {
      $sp = $splitter.Split($post, 2)
      if ($sp.Count -ge 2) { $item = $sp[0].Trim(); $note = $sp[1].Trim() } else { $item = $post; $note = '' }
    }
  } elseif ($m.Success) {
    # label first: "Name - STATUS - detail"
    $word = $m.Groups[1].Value
    if ($word -notmatch '^(?i)(duplicate|warn)') { $bucket = StatusBucket $word }
    $item = $t.Substring(0, $m.Index).Trim($trimChars); $note = $t.Substring($m.Index + $m.Length).Trim($trimChars)
  } else {
    $sp = $splitter.Split($t, 2)
    if ($sp.Count -ge 2) { $item = $sp[0].Trim(); $note = $sp[1].Trim() } else { $item = $t; $note = '' }
  }
  $short = CanonicalItem $item
  if ($short -ne $item.Trim() -and $item.Trim().Length -gt $short.Length + 3) { $note = ($item.Trim() + '. ' + $note).Trim() }
  if ($qual) { $note = ('[' + $qual + '] ' + $note).Trim() }
  $wordOut = if ($word) { $word.ToUpper() } else { '' }
  if ($wordOut -eq 'DUPLICATE' -or $wordOut -like 'WARN*') { $wordOut = 'NEEDS REVIEW' }
  return @{ item = $short; status = $bucket; word = $wordOut; note = $note }
}

# Cap a block of prose to its first sentence (or a word boundary) for the top of the card.
# Returns @{ text; cut }. Keeps **bold** balanced when the cut lands inside a bold run.
function FirstSentence([string]$s, [int]$max) {
  if ([string]::IsNullOrEmpty($s)) { return @{ text = ''; cut = $false } }
  $t = ($s -replace "`r?`n", ' ') -replace '\s{2,}', ' '
  $t = $t.Trim()
  if ($t.Length -le $max) { return @{ text = $t; cut = $false } }
  # a first sentence that only slightly overruns the cap is kept whole (no mid-thought ellipsis)
  $soft = [int]($max * 1.35)
  $m = [regex]::Match($t, '^(.{20,' + $soft + '}?[\.\?!])(?:\s|$)')
  if ($m.Success) { $out = $m.Groups[1].Value }
  else {
    # otherwise cut at the last clause boundary in the back half of the window, else at a word
    $win = $t.Substring(0, [Math]::Min($t.Length, $max))
    $floor = [int]($max * 0.55)
    $cutAt = -1
    foreach ($sep in @('; ', ' - ', (' ' + [string][char]0x2014 + ' '), (' ' + [string][char]0x2013 + ' '), ', ', ': ')) {
      $i = $win.LastIndexOf($sep); if ($i -ge $floor -and $i -gt $cutAt) { $cutAt = $i }
    }
    if ($cutAt -lt 0) { $cutAt = $win.LastIndexOf(' '); if ($cutAt -lt 20) { $cutAt = $max } }
    $out = $t.Substring(0, $cutAt).TrimEnd(' ,;:-') + [string][char]0x2026
  }
  if ((([regex]::Matches($out, '\*\*')).Count % 2) -eq 1) { $out += '**' }
  return @{ text = $out; cut = $true }
}

if (-not (Test-Path -LiteralPath $VerdictJson)) { throw "Verdict file not found: $VerdictJson" }
$v = Get-Content -Raw -Encoding UTF8 -LiteralPath $VerdictJson | ConvertFrom-Json

# ---- Salesforce fill hand-off (added 2026-09-28) ------------------------------------------
# If the verdict carries a `salesforce` block, drop it into EmorySF\inbox\<SR>.json.  sf_fill.py (skill
# folder sf_fill\, run via Downloads\EmorySF\watch.cmd) fills the SR from there with zero model tokens.
# This runs on every invocation (posting or -EmitTemplate) and never touches the card.
try {
  if ($v.PSObject.Properties.Name -contains 'salesforce' -and $v.salesforce) {
    $sfHome = if ($env:EMORYSF_HOME) { $env:EMORYSF_HOME } else { Join-Path $env:USERPROFILE 'Downloads\EmorySF' }
    $inbox = Join-Path $sfHome 'inbox'
    if (-not (Test-Path -LiteralPath $inbox)) { New-Item -ItemType Directory -Force -Path $inbox | Out-Null }
    $srm = [regex]::Match(("" + $v.salesforce.sr + " " + $v.sr), 'SR00\d{6}')
    if ($srm.Success) {
      $drop = [ordered]@{ sr = $srm.Value; verdict = $v.verdict; salesforce = $v.salesforce; from = (Split-Path -Leaf $VerdictJson); written = (Get-Date).ToString('s') }
      $dropPath = Join-Path $inbox ($srm.Value + '.json')
      [IO.File]::WriteAllText($dropPath, ($drop | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
      Write-Host ("[sf-fill] wrote " + $dropPath)
    } else {
      Write-Host "[sf-fill] verdict has a salesforce block but no SR00 number - nothing dropped (INC-only ticket?)"
    }
  }
} catch { Write-Host ("[sf-fill] drop skipped: " + $_.Exception.Message) }

# ============================================================================
# PRE-POST VERIFICATION GATE  (added 2026-09-15 after INC1320603 - unchanged)
# Every claim on a card must trace to a query actually run. Posting requires a
# `verification` array, one entry per load-bearing claim (>= 25 chars each).
# Dry runs are never gated. See EMORY_ANALYSIS_GUARDRAILS.md.
# ============================================================================
if ($doPost) {
  $ver = $v.verification
  $verCount = 0
  if ($ver) { $verCount = @($ver).Count }
  if ($verCount -lt 1) {
    throw @"
REFUSED TO POST - no 'verification' block in the verdict JSON.

Every claim on the card must trace to a query you actually ran. Add a
'verification' array to $VerdictJson, one entry per load-bearing claim:

  "verification": [
    "<claim> - <the query/table that established it, and the value returned>",
    "..."
  ]

Include counts and any scope claim ("N other dealers affected"). If a claim
from an earlier version of the card turned out to be unverified, say so
explicitly as a RETRACTED entry rather than silently dropping it.

Preview freely without -Post; the gate only applies to real delivery.
(Gate added 2026-09-15 after INC1320603 - see EMORY_ANALYSIS_GUARDRAILS.md.)
"@
  }
  $thin = @($ver) | Where-Object { -not $_ -or ([string]$_).Trim().Length -lt 25 }
  if (@($thin).Count -gt 0) {
    throw "REFUSED TO POST - $(@($thin).Count) verification entr(y/ies) are empty or under 25 chars. Each must name the claim AND how it was established, not just 'checked'."
  }
  Write-Host "Verification gate: PASSED - $verCount claim(s) traced to evidence." -ForegroundColor DarkGray
}

# ---- derive the content model (shared by both renderings) ---------------------------------
$vb = switch -Wildcard ($v.verdict) { 'FAIL*' { 'fail'; break } '*NEEDS*' { 'review'; break } 'PASS*' { 'pass'; break } default { 'review' } }
$verdict_accent = StatusColor $vb
if ($v.verdict_color -and "$($v.verdict_color)" -match '^#') { $verdict_accent = [string]$v.verdict_color }
$verdict_bg = switch ($vb) { 'fail' { '#3a1d1d' } 'pass' { '#1f3a2f' } default { '#3a2a18' } }
$badge = StatusMark $vb
$finding = FindingLabel $vb

# Executive summary bullets
$summary = @()
if ($v.summary) { $summary = @($v.summary | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }) }
$summaryFromLegacy = $false
if ($summary.Count -eq 0) {
  $summaryFromLegacy = $true
  foreach ($f in @($v.issue_line, $v.impact_line, $v.action_line)) { if ($f) { $summary += [string]$f } }
  if ($summary.Count -eq 0 -and $v.bottom) {
    $summary = @([regex]::Split([string]$v.bottom, '(?:\r?\n){2,}') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }
}

# Status rows
$rows = @()
$rowsFromChecks = $false
if ($v.status_rows) {
  foreach ($r in @($v.status_rows)) {
    $given = ([string]$r.status).Trim()
    $b = StatusBucket $given
    # Keep the author's word when it is descriptive ("Fixed", "Working", "Not enrolled");
    # bucket keywords (pass/fail/review/warn/skip) render as the canonical PASS/FAIL/NEEDS REVIEW/SKIPPED.
    $word = if ($given -and $given -notmatch '^(?i)(pass|ok|fail|review|warn|skip|skipped|n/?a|good|red|green|amber)$') {
      $given.Substring(0,1).ToUpper() + $given.Substring(1)
    } else { StatusWord $b '' }
    $rows += @{ item = [string]$r.item; id = [string]$r.id; status = $b; word = $word; note = [string]$r.note }
  }
} elseif ($v.checks_md) {
  $rowsFromChecks = $true
  foreach ($line in ([string]$v.checks_md -split "`r?`n")) {
    $pc = ParseCheckLine $line
    if ($pc) { $rows += @{ item = $pc.item; id = ''; status = $pc.status; word = (StatusWord $pc.status ''); note = $pc.note } }
  }
}
$hasIds = @($rows | Where-Object { $_.id }).Count -gt 0

# Key question + actions
$key_q = if ($v.key_question) { [string]$v.key_question } elseif ($v.confirm) { [string]$v.confirm } else { '' }
$q_for = if ($v.question_for) { [string]$v.question_for } else { '' }
$actions = @(); if ($v.actions) { $actions = @($v.actions | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }) }
$owner = if ($v.owner) { [string]$v.owner } else { '' }

# Legacy prose (bottom / business_impact) - no longer rendered anywhere (cut 2026-09-22); kept for the record
$narrative = @()
if (-not $summaryFromLegacy) {
  if ($v.bottom) { $narrative += [string]$v.bottom }
  if ($v.business_impact) { $narrative += [string]$v.business_impact }
}
# root_cause falls back to `bottom` only when bottom is not already shown (as summary or narrative).
$root_cause = if ($v.root_cause) { [string]$v.root_cause } else { '' }
$sr_subject = if ($v.title) { [string]$v.title } elseif ($v.dealer) { [string]$v.dealer } else { '' }
# The status line wants the ticket ID only ("INC1321020"); anything else the author put in `sr` is
# housekeeping and renders in the details as "Ticket".
$sr_full = if ($v.sr) { [string]$v.sr } else { '' }
$sr_idm = [regex]::Match($sr_full, '(?i)\b(?:INC|SR|CASE|SDP|RITM|REQ)\s*[#:-]?\s*\d{4,}')
$sr_id = if ($sr_idm.Success) { ($sr_idm.Value -replace '\s','') } else { (FirstSentence $sr_full 40).text }
$sr_extra = if ($sr_idm.Success -and $sr_full.Trim() -ne $sr_id) { $sr_full } else { '' }
# Top-of-card copies of the long fields: one sentence each. Full text still renders in the details.
$issue_top  = FirstSentence ([string]$v.issue_line)  180
$impact_top = FirstSentence ([string]$v.impact_line) 180
$ownerParts = @([regex]::Split($owner, '\s+(?:' + [regex]::Escape([string][char]0x00B7) + '|\|)\s+|;\s+') | Where-Object { $_.Trim() })
$owner_top  = if ($ownerParts.Count -gt 1) { @{ text = (($ownerParts[0] -replace '\.$','').Trim() + ' (+' + ($ownerParts.Count - 1) + ' more in details)'); cut = $true } } else { FirstSentence $owner 110 }
$keyq_top   = FirstSentence $key_q 220
$actions_top = @(); $actionsCut = $false
foreach ($a in $actions) { $fs = FirstSentence ([string]$a) 170; $actions_top += $fs.text; if ($fs.cut) { $actionsCut = $true } }

# ============================================================================
# RENDERING 1 - HTML message (live flow)
# ----------------------------------------------------------------------------
# WHAT TEAMS ACTUALLY RENDERS (observed on a live TEST post, 2026-09-22):
#   KEEPS  : color, font-weight, font-size, <b>, <i>, <p>, <br>, <ul>/<ol>/<li>, <table>
#   STRIPS : background, border, padding, margin, border-radius, text-transform,
#            letter-spacing, font-family (falls back to Teams' Segoe UI)
#   ADDS   : its OWN visible cell borders on EVERY <table> - so a table used for layout
#            (header row, numbered steps) shows up as boxes. Tables are used ONLY for the
#            Status grid, where a bordered grid is what the reader expects.
# So the card is built from Teams-native primitives: <p> for blocks, <br> for air,
# <ul>/<ol> for lists, colored <span>s for status, small grey text for labels. Labels
# are written in UPPERCASE text because text-transform is stripped.
#
# LAYOUT (tightened 2026-09-22 after the analyst's efficiency review - five cuts):
#   Title, then status line: verdict dot, SR, platform, Reported <date>, Reviewed <date>
#   FACTS     Issue / Impact / Owner / Next - one line each. "Next" is dropped when a Key
#             question exists (the question IS the next step) - "what to do" appears ONCE.
#   SUMMARY   only on multi-item cases (status_rows) or when there are no facts lines;
#             `show_summary: true` forces it. Never restates the facts.
#   STATUS    single-dealer: ONE line ("5 of 6 checks pass - Rate SKUs need review"), grid in
#             the details. Multi-item (status_rows): the table stays up top - that IS the case.
#   KEY QUESTION  only when a human must decide.  NEXT STEPS  only when >= 2 distinct actions.
#   INVESTIGATION DETAILS  small grey, last: identifiers, checks grid, root cause, how
#             verified, classification. Narrative (legacy `bottom`) is no longer rendered.
#   Footer: verdict, "card N today" (local delivery log), signature
# ============================================================================
$DOTCH = [char]::ConvertFromUtf32(0x25CF)   # filled circle - the status dot

# Teams theme-safe palette: no background is ever applied, so these must read on BOTH
# the dark and light Teams themes. Mid greys for labels, default text colour for body.
$MUTED = '#8b949e'
$LBL_STYLE = "font-size: 11px; font-weight: 600; color: $MUTED;"   # NOT $LABEL: it would collide with DetailBlock's $label parameter (PS is case-insensitive)
$SMALL = "font-size: 12px; color: $MUTED;"

# Inline markdown (bold, code) with NO block wrapper - for label + value on one line.
function Inline([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return "" }
  $t = HtmlEsc $s
  $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '<b>$1</b>')
  $t = [regex]::Replace($t, '`([^`]+?)`', '<code>$1</code>')
  return ($t -replace "`r?`n", ' ')
}
function Dot([string]$bucket) {
  return "<span style='color: " + (StatusColor $bucket) + ";'>" + $DOTCH + "</span>"
}
function Label([string]$t) { return "<p style='margin: 0; $LBL_STYLE'>" + $t.ToUpper() + "</p>" }
function Para([string]$inner, [string]$extra) { return "<p style='margin: 0; $extra'>$inner</p>" }
$AIR = "<p style='margin: 0; font-size: 6px;'>&nbsp;</p>"   # the only spacer Teams honours

# Dates. `reported` is free text in older verdicts ("Dealer via Account Management - 2026-08-23");
# the status line wants only the date, so pull the first date-looking token out of it. The full
# text still appears in the details identifiers. `reported_date` overrides; `reviewed` defaults to today.
$reportedText = if ($v.reported) { [string]$v.reported } else { '' }
$reportedDate = if ($v.reported_date) { [string]$v.reported_date } else {
  $dm = [regex]::Match($reportedText, '\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{2,4}')
  if ($dm.Success) { $dm.Value } else { '' }
}
$reviewed = if ($v.reviewed) { [string]$v.reviewed } else { (Get-Date).ToString('yyyy-MM-dd') }

# Cards posted today - from the local delivery log the poster appends to on every real send.
$LogFile = Join-Path (Split-Path -Parent $UrlFile) 'emory_card_log.csv'
$todayCount = 0
if (Test-Path -LiteralPath $LogFile) {
  $today = (Get-Date).ToString('yyyy-MM-dd')
  $todayCount = @(Get-Content -LiteralPath $LogFile | Where-Object { $_ -like "$today*" -or $_ -like "`"$today*" }).Count
}
$cardOrdinal = $todayCount + 1

# Status grid HTML (used up top for multi-item cases, in the details for single-dealer ones)
function StatusGrid() {
  $g = "<table style='border-collapse: collapse; font-size: 13px;'>"
  $firstCol = if ($rowsFromChecks) { 'CHECK' } else { 'ITEM' }
  $g += "<tr><th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>" + $firstCol + "</th>"
  if ($hasIds) { $g += "<th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>ID</th>" }
  $g += "<th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>STATUS</th>"
  $g += "<th style='text-align: left; padding: 3px 10px; $LBL_STYLE'>DETAIL</th></tr>"
  foreach ($r in $rows) {
    $g += "<tr><td style='padding: 3px 10px; font-weight: 600;'>" + (HtmlEsc $r.item) + "</td>"
    if ($hasIds) { $g += "<td style='padding: 3px 10px; color: $MUTED;'>" + (HtmlEsc $r.id) + "</td>" }
    $g += "<td style='padding: 3px 10px; color: " + (StatusColor $r.status) + "; font-weight: 600; white-space: nowrap;'>" + $DOTCH + " " + (HtmlEsc $r.word) + "</td>"
    $g += "<td style='padding: 3px 10px; color: $MUTED;'>" + (HtmlEsc $r.note) + "</td></tr>"
  }
  return $g + "</table>"
}

$multiItem = [bool]$v.status_rows
$hasFacts  = [bool]($v.issue_line -or $v.impact_line -or $owner -or $v.action_line)
$showSummary = ($summary.Count -gt 0) -and ($multiItem -or -not $hasFacts -or [bool]$v.show_summary)

$p = @()
$p += "<div style='font-family: Aptos, ""Segoe UI"", sans-serif; line-height: 1.45;'>"

# ---- HEADER ----------------------------------------------------------------------------
$p += Label ("Emory " + $DOT + " Case review")
$p += Para ("<b>" + $(if ($sr_subject) { HtmlEsc ((FirstSentence $sr_subject 110).text) } else { HtmlEsc $sr_id }) + "</b>") "font-size: 20px; line-height: 1.25;"
$st = @()
$st += "<span style='color: " + $verdict_accent + "; font-weight: 700;'>" + $DOTCH + " " + $finding + "</span>"
if ($sr_subject -and $sr_id) { $st += (HtmlEsc $sr_id) }
if ($v.platform) { $st += (HtmlEsc ((FirstSentence ([string]$v.platform) 48).text)) }
if ($reportedDate) { $st += "Reported " + (HtmlEsc $reportedDate) }
$st += "Reviewed " + (HtmlEsc $reviewed)
$p += Para (($st -join (" &nbsp;" + $DOT + "&nbsp; "))) "$SMALL"
$p += $AIR

# ---- FACTS: Issue / Impact / Owner / Next ---------------------------------------------
# "Next" is the single next action. If a key question exists it IS the next step, so the
# Next line is omitted rather than saying the same thing twice.
$facts = @()
if ($v.issue_line)  { $facts += @('Issue',  $issue_top.text) }
if ($v.impact_line) { $facts += @('Impact', $impact_top.text) }
$ownerShown = $false
if ($owner)         { $facts += @('Owner',  $owner_top.text); $ownerShown = $true }
$nextLine = if ($v.action_line) { [string]$v.action_line } elseif ($actions.Count -eq 1) { [string]$actions[0] } else { '' }
if ($nextLine -and -not $key_q) { $facts += @('Next', (FirstSentence $nextLine 180).text) }
if ($facts.Count -gt 0) {
  for ($i = 0; $i -lt $facts.Count; $i += 2) {
    $p += Para ("<b style='color: $MUTED;'>" + $facts[$i] + "</b>&nbsp;&nbsp; " + (Inline $facts[$i+1])) "font-size: 14px;"
  }
  $p += $AIR
}

# ---- SUMMARY (multi-item cases, or legacy verdicts with no facts) -----------------------
if ($showSummary) {
  $p += Label 'Summary'
  $p += "<ul style='margin: 0; padding-left: 18px; font-size: 14px;'>"
  foreach ($s in $summary) { $p += "<li>" + (Prose ([string]$s)) + "</li>" }
  $p += "</ul>"
  $p += $AIR
}

# ---- STATUS ------------------------------------------------------------------------------
$gridInDetails = $false
if ($rows.Count -gt 0) {
  $p += Label 'Status'
  if ($multiItem) {
    $p += StatusGrid
  } else {
    # one line: "5 of 6 checks pass - Rate SKUs need review - Dealer status failed"
    $passN = @($rows | Where-Object { $_.status -eq 'pass' }).Count
    $skipN = @($rows | Where-Object { $_.status -eq 'skip' }).Count
    $ran   = $rows.Count - $skipN
    $bits  = @()
    $bits += "<span style='color: #3fb950; font-weight: 600;'>" + $DOTCH + " " + $passN + " of " + $ran + " checks OK</span>"
    $failRows = @($rows | Where-Object { $_.status -eq 'fail' }); $revRows = @($rows | Where-Object { $_.status -eq 'review' })
    if (($failRows.Count + $revRows.Count) -le 4) {
      foreach ($r in $failRows) { $bits += "<span style='color: #f85149; font-weight: 600;'>" + $DOTCH + " " + (HtmlEsc $r.item) + " has an issue</span>" }
      foreach ($r in $revRows)  { $bits += "<span style='color: #f0883e; font-weight: 600;'>" + $DOTCH + " " + (HtmlEsc $r.item) + " needs review</span>" }
    } else {
      if ($failRows.Count -gt 0) { $bits += "<span style='color: #f85149; font-weight: 600;'>" + $DOTCH + " " + $failRows.Count + " failed</span>" }
      if ($revRows.Count -gt 0)  { $bits += "<span style='color: #f0883e; font-weight: 600;'>" + $DOTCH + " " + $revRows.Count + " need review</span>" }
    }
    if ($skipN -gt 0) { $bits += "<span style='color: $MUTED;'>" + $skipN + " skipped</span>" }
    $p += Para (($bits -join (" &nbsp;" + $DOT + "&nbsp; "))) "font-size: 14px;"
    $gridInDetails = $true
  }
  $p += $AIR
}

# ---- KEY QUESTION (only when a human must decide) + NEXT STEPS (only when >= 2) ---------
if ($key_q) {
  $qh = if ($q_for) { "Key question " + $DOT + " " + (HtmlEsc $q_for) } else { "Key question" }
  $p += Label $qh
  $p += Para ("<b>" + (Inline $keyq_top.text) + "</b>") "font-size: 14.5px;"
  $p += $AIR
}
if ($actions.Count -ge 2) {
  $p += Label 'Next steps'
  $p += "<ol style='margin: 0; padding-left: 22px; font-size: 14px;'>"
  foreach ($a in $actions_top) { $p += "<li>" + (Inline ([string]$a)) + "</li>" }
  $p += "</ol>"
  if ($owner -and -not $ownerShown) { $p += Para ("<b style='color: $MUTED;'>Owner</b>&nbsp;&nbsp; " + (Inline $owner)) "font-size: 13px;" }
  $p += $AIR
}

# ---- INVESTIGATION DETAILS - small, grey, last -----------------------------------------
$p += $AIR
$p += Para ([string]::new([char]0x2500, 34)) "font-size: 11px; color: #4d5560; line-height: 1;"
$p += Label ($DOWN + " Investigation details")
$p += Para "Supporting evidence for the summary above. Skip unless you need it." "$SMALL"

function DetailBlock([string]$label, [string]$inner) {
  if ([string]::IsNullOrWhiteSpace($inner)) { return "" }
  return $AIR + (Label $label) + (Para $inner "font-size: 12.5px; color: #a9b1ba;")
}

$ids = @()
if ($v.dealer)   { $ids += "<b>Dealer</b> " + (HtmlEsc $v.dealer) }
if ($v.product)  { $ids += "<b>Product</b> " + (HtmlEsc $v.product) }
if ($v.sub)      { $ids += "<b>Vehicle</b> " + (HtmlEsc $v.sub) }
if ($v.source)   { $ids += "<b>Source</b> " + (HtmlEsc $v.source) }
if ($reportedText) { $ids += "<b>Reported by</b> " + (HtmlEsc $reportedText) }
if ($sr_extra) { $ids += "<b>Ticket</b> " + (HtmlEsc $sr_extra) }
if ($ids.Count -gt 0) { $p += Para (($ids -join (" &nbsp;" + $DOT + "&nbsp; "))) "$SMALL" }
# Anything the top of the card shortened renders in full here, once.
$fullBits = @()
if ($issue_top.cut)  { $fullBits += "<b>Issue</b> " + (Inline ([string]$v.issue_line)) }
if ($impact_top.cut) { $fullBits += "<b>Impact</b> " + (Inline ([string]$v.impact_line)) }
if ($owner_top.cut)  { $fullBits += "<b>Owner</b> " + (Inline $owner) }
if ($keyq_top.cut)   { $fullBits += "<b>Key question</b> " + (Inline $key_q) }
if ($fullBits.Count -gt 0) { $p += DetailBlock 'In full' (($fullBits | ForEach-Object { "<div>" + $_ + "</div>" }) -join '') }
if ($actionsCut -and $actions.Count -gt 0) {
  $ol = "<ol style='margin: 0; padding-left: 22px;'>"
  foreach ($a in $actions) { $ol += "<li>" + (Prose ([string]$a)) + "</li>" }
  $p += DetailBlock 'Next steps, in full' ($ol + "</ol>")
}


if ($gridInDetails) { $p += $AIR + (Label 'Checks') + (StatusGrid) }
elseif ($v.checks_md -and -not $rowsFromChecks) {
  $checks = HtmlEsc $v.checks_md
  $checks = [regex]::Replace($checks, '\*\*(.+?)\*\*', '<b>$1</b>')
  $checks = $checks -replace "`r?`n", '<br>'
  $checks = [regex]::Replace($checks, '\bNEEDS REVIEW\b', '<b style="color: #f0883e;">NEEDS REVIEW</b>')
  $checks = [regex]::Replace($checks, '\bPASS\b',         '<b style="color: #3fb950;">PASS</b>')
  $checks = [regex]::Replace($checks, '\bFAIL\b',         '<b style="color: #f85149;">FAIL</b>')
  $p += DetailBlock 'Checks' $checks
}

if ($root_cause) { $p += DetailBlock 'Root cause' (Prose $root_cause) }

if ($v.verification) {
  $vl = "<ol style='margin: 0; padding-left: 22px;'>"
  foreach ($e in @($v.verification)) { $vl += "<li>" + (HtmlEsc ([string]$e)) + "</li>" }
  $vl += "</ol>"
  $p += DetailBlock 'How this was verified' $vl
}

if ($v.classification) {
  $cls = HtmlEsc $v.classification
  $cls = [regex]::Replace($cls, '\*\*(.+?)\*\*', "<b>" + '$1' + "</b>")
  $cls = (@($cls -split "`r?`n" | Where-Object { $_.Trim() })) -join (" &nbsp;" + $DOT + "&nbsp; ")
  $p += DetailBlock 'Classification &amp; routing' $cls
} else {
  $p += DetailBlock 'Classification &amp; routing' "<i>Classification pending</i>"
}

$p += $AIR
$p += Para ("<span style='color: " + $verdict_accent + "; font-weight: 700;'>" + $DOTCH + " " + $finding + "</span> &nbsp;" + $DOT + "&nbsp; card " + $cardOrdinal + " today &nbsp;" + $DOT + "&nbsp; read-only pre-analysis, confirm with the owner before acting &nbsp;" + $DOT + "&nbsp; <i>Emory</i>") "$SMALL"
$p += "</div>"

$message = -join $p

# ============================================================================
# RENDERING 2 - Adaptive Card with a real collapse (Action.ToggleVisibility)
# ============================================================================
function TB([string]$text, [hashtable]$extra) {
  $o = [ordered]@{ type = 'TextBlock'; text = $text; wrap = $true }
  if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
  return $o
}
function AcColor([string]$bucket) {
  switch ($bucket) { 'pass' { 'Good' } 'fail' { 'Attention' } 'skip' { 'Default' } default { 'Warning' } }
}
$acColor = AcColor $vb

$body = @()
$hdrSub = "**" + (Plain $v.sr) + "**"
if ($sr_subject) { $hdrSub += " " + $DOT + " " + (Plain $sr_subject) }
$body += [ordered]@{ type = 'ColumnSet'; columns = @(
  [ordered]@{ type = 'Column'; width = 'stretch'; items = @(
    (TB ($E_SEARCH + " Emory Case Review") @{ weight = 'Bolder'; size = 'Medium' }),
    (TB $hdrSub @{ isSubtle = $true; size = 'Small'; spacing = 'None' })
  )},
  [ordered]@{ type = 'Column'; width = 'auto'; verticalContentAlignment = 'Center'; items = @(
    (TB ($badge + " " + $finding) @{ weight = 'Bolder'; color = $acColor })
  )}
)}

$body += TB 'Executive Summary' @{ weight = 'Bolder'; spacing = 'Medium'; color = 'Accent' }
if ($summary.Count -gt 0) { $body += TB ((@($summary | ForEach-Object { "- " + (Plain ([string]$_)) })) -join "`n") @{ spacing = 'Small' } }

if ($rows.Count -gt 0) {
  $body += TB 'Status' @{ weight = 'Bolder'; spacing = 'Medium'; color = 'Accent' }
  foreach ($r in $rows) {
    $cols = @()
    $itemTxt = "**" + (Plain $r.item) + "**"
    if ($r.note) { $itemTxt += "  " + (Plain $r.note) }
    $cols += [ordered]@{ type = 'Column'; width = 'stretch'; items = @((TB $itemTxt @{ size = 'Small' })) }
    if ($hasIds) { $cols += [ordered]@{ type = 'Column'; width = 'auto'; items = @((TB (Plain $r.id) @{ size = 'Small'; fontType = 'Monospace' })) } }
    $cols += [ordered]@{ type = 'Column'; width = 'auto'; items = @((TB ((StatusMark $r.status) + " " + $r.word) @{ size = 'Small'; weight = 'Bolder'; color = (AcColor $r.status) })) }
    $body += [ordered]@{ type = 'ColumnSet'; spacing = 'Small'; separator = $true; columns = $cols }
  }
}

if ($key_q -or $actions.Count -gt 0 -or $owner) {
  $body += TB 'Next Steps' @{ weight = 'Bolder'; spacing = 'Medium'; color = 'Accent' }
  if ($key_q) {
    $qh = if ($q_for) { "Key question for " + (Plain $q_for) } else { 'Key question' }
    $body += TB $qh @{ isSubtle = $true; size = 'Small'; spacing = 'Small' }
    $body += TB ("**" + (Plain $keyq_top.text) + "**") @{ spacing = 'None' }
  }
  if ($actions.Count -gt 0) {
    $i = 0
    $body += TB ((@($actions_top | ForEach-Object { $i++; "$i. " + (Plain ([string]$_)) })) -join "`n") @{ spacing = 'Small' }
  }
  if ($owner) { $body += TB ("Owner: " + (Plain $owner)) @{ isSubtle = $true; size = 'Small' } }
}

$body += [ordered]@{ type = 'ActionSet'; spacing = 'Medium'; actions = @(
  [ordered]@{ type = 'Action.ToggleVisibility'; title = ($E_SEARCH + " Show investigation details"); targetElements = @('emoryDetails') }
)}

$det = @()
$facts = @()
if ($v.dealer)   { $facts += [ordered]@{ title = 'Dealer';   value = (Plain $v.dealer) } }
if ($v.product)  { $facts += [ordered]@{ title = 'Product';  value = (Plain $v.product) } }
if ($v.sub)      { $facts += [ordered]@{ title = 'Vehicle';  value = (Plain $v.sub) } }
if ($v.source)   { $facts += [ordered]@{ title = 'Source';   value = (Plain $v.source) } }
if ($v.platform) { $facts += [ordered]@{ title = 'Platform'; value = (Plain $v.platform) } }
if ($v.reported) { $facts += [ordered]@{ title = 'Reported'; value = (Plain $v.reported) } }
if ($facts.Count -gt 0) { $det += [ordered]@{ type = 'FactSet'; facts = $facts } }
if ($v.checks_md -and -not $rowsFromChecks) {
  $det += TB 'Checks' @{ weight = 'Bolder'; size = 'Small'; spacing = 'Medium' }
  $det += TB ([string]$v.checks_md) @{ size = 'Small'; spacing = 'None' }
}
if ($root_cause) {
  $det += TB 'Root cause' @{ weight = 'Bolder'; size = 'Small'; spacing = 'Medium' }
  $det += TB (Plain $root_cause) @{ size = 'Small'; spacing = 'None' }
}
if ($v.verification) {
  $i = 0
  $det += TB 'How this was verified' @{ weight = 'Bolder'; size = 'Small'; spacing = 'Medium' }
  $det += TB ((@(@($v.verification) | ForEach-Object { $i++; "$i. " + (Plain ([string]$_)) })) -join "`n") @{ size = 'Small'; spacing = 'None'; isSubtle = $true }
}
if ($v.classification) {
  $cf = @()
  foreach ($ln in ([string]$v.classification -split "`r?`n")) {
    $mm = [regex]::Match($ln, '^\s*\**\s*([^*:]+?)\s*:?\s*\**\s*:?\s*(.*)$')
    if ($mm.Success -and $mm.Groups[2].Value.Trim()) { $cf += [ordered]@{ title = $mm.Groups[1].Value.Trim(); value = (Plain $mm.Groups[2].Value) } }
  }
  if ($cf.Count -gt 0) {
    $det += TB 'Classification & routing' @{ weight = 'Bolder'; size = 'Small'; spacing = 'Medium' }
    $det += [ordered]@{ type = 'FactSet'; spacing = 'None'; facts = $cf }
  }
}
$body += [ordered]@{ type = 'Container'; id = 'emoryDetails'; isVisible = $false; style = 'emphasis'; spacing = 'Small'; items = $det }
$body += TB ($badge + " " + $finding + " " + $DOT + " Read-only pre-analysis, confirm with the owning team before acting " + $DOT + " Emory") @{ isSubtle = $true; size = 'Small'; separator = $true }

$card = [ordered]@{
  type = 'AdaptiveCard'; '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; version = '1.4'
  msteams = [ordered]@{ width = 'Full' }
  body = $body
}
# Compact JSON for the wire (Teams caps a card at ~28 KB); the -EmitTemplate file is pretty-printed.
$cardJson = $card | ConvertTo-Json -Depth 20 -Compress

$payload = @{ message = $message; card = $cardJson } | ConvertTo-Json -Depth 4 -Compress

# ---- -EmitTemplate: regenerate both previews from THIS script; never sends -----------------
if ($EmitTemplate) {
  if (-not $TemplateFile) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $TemplateFile = Join-Path $root 'emory_verdict_card.html'
  }
  $stamp  = (Get-Date).ToString('yyyy-MM-dd')
  $banner = @(
    "<!-- ============================================================================",
    "     emory_verdict_card.html - GENERATED FILE, DO NOT HAND-EDIT.",
    "",
    "     Rendered preview of emory_post.ps1's HTML output (the executive-summary-first",
    "     layout, 2026-09-22). The script is the single source of truth for card layout.",
    "",
    "     Regenerate after ANY layout change:",
    "       powershell -File emory_post.ps1 -VerdictJson emory_verdict_card.sample.json -EmitTemplate",
    "",
    "     Last generated: $stamp",
    "     ============================================================================ -->",
    "<meta charset='utf-8'><style>body{margin:0;padding:28px;background:#1f1f1f;color:#e6e6e6;font-family:'Segoe UI',sans-serif;font-size:14px;max-width:1000px} table td,table th{border:1px solid #4a4a4a} p{margin:0}</style><body>"
  ) -join "`n"
  Set-Content -LiteralPath $TemplateFile -Value ($banner + "`n" + $message + "`n</body>") -Encoding UTF8
  $cardFile = [System.IO.Path]::ChangeExtension($TemplateFile, '.adaptive.json')
  Set-Content -LiteralPath $cardFile -Value ($card | ConvertTo-Json -Depth 20) -Encoding UTF8
  Write-Host "Regenerated HTML preview   -> $TemplateFile" -ForegroundColor Green
  Write-Host "Regenerated Adaptive Card  -> $cardFile  (paste into adaptivecards.io/designer to preview the toggle)" -ForegroundColor Green
  Write-Host "(-EmitTemplate never posts.)" -ForegroundColor Yellow
  return
}

Write-Host "----- Emory message (HTML, what posts to #api-support-intake) -----"
Write-Host $message
Write-Host "------------------------------------------------------------------"
Write-Host "(payload also carries 'card': an Adaptive Card with collapsible details, $($cardJson.Length) chars; used once the flow has a Post-card step)" -ForegroundColor DarkGray

# ---- Review log (every case Emory reviews, posted or not) ----------------------------------
# One row per run -> Downloads\emory_review_log.csv (or $env:EMORY_REVIEW_LOG, e.g. a shared
# OneDrive folder for a team-wide picture). emory_daily_review.ps1 builds the end-of-day review
# from it, so a case shows up even when its card is never posted. Never fails the run.
function Write-ReviewLog([string]$posted) {
  try {
    $rl = if ($env:EMORY_REVIEW_LOG) { $env:EMORY_REVIEW_LOG } else { Join-Path (Split-Path -Parent $UrlFile) 'emory_review_log.csv' }
    $rhdr = 'reviewed,sr,dealer,product,vin,platform,verdict,owner,pattern,first_issue,summary,posted,source,reviewer'
    if (-not (Test-Path -LiteralPath $rl) -or ((Get-Item -LiteralPath $rl).Length -eq 0)) {
      Set-Content -LiteralPath $rl -Value $rhdr -Encoding UTF8
    }
    function RQ([string]$x) { $t = ("$x" -replace '"','""' -replace "`r?`n",' '); if ($t.Length -gt 500) { $t = $t.Substring(0,500) }; return '"' + $t + '"' }
    $sum = if ($v.action_line) { [string]$v.action_line } elseif ($v.bottom) { [string]$v.bottom } else { '' }
    $iss = if ($v.issue_line) { [string]$v.issue_line } elseif ($v.issue) { [string]$v.issue } else { '' }
    $row = @((Get-Date).ToString('yyyy-MM-dd HH:mm'), $v.sr, $v.dealer, $v.product, $v.vin, $v.platform, $v.verdict,
             $owner, $v.pattern, $iss, $sum, $posted, 'emory_post', $env:USERNAME | ForEach-Object { RQ $_ }) -join ','
    Add-Content -LiteralPath $rl -Value $row -Encoding UTF8
  } catch { Write-Host "(review log not written: $($_.Exception.Message))" -ForegroundColor DarkGray }
}

if (-not $doPost) { Write-ReviewLog 'no' }
if (-not $doPost) {
  if ($Auto) { Write-Host "AUTO-POST OFF (toggle '$AutoFile' is not on) - dry run, not posted." -ForegroundColor Yellow }
  else { Write-Host "DRY RUN - not posted. Re-run with -Post (or -Auto when hands-off is on) to deliver." -ForegroundColor Yellow }
  return
}
if ($autoOn -and -not $Post) { Write-Host "AUTO-POST ON (hands-off) - delivering..." -ForegroundColor Cyan }

if (-not (Test-Path -LiteralPath $UrlFile)) { throw "Delivery URL file not found: $UrlFile" }
$url = (Select-String -Path $UrlFile -Pattern 'https://\S+').Matches.Value | Select-Object -First 1
if (-not $url) { throw "No https URL found in $UrlFile" }

$bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -UseBasicParsing
Write-Host "Posted to #api-support-intake. HTTP $($resp.StatusCode)" -ForegroundColor Green
Write-ReviewLog 'yes'
# Delivery log (local, never shared): one line per real post, drives the "card N today" footer.
# Schema (CSV, header written on first use, older files upgraded in place):
#   posted,sr,title,verdict,owner,platform,question_for,key_question,reported_date,dealer,category,inquiry_type,pattern
# category / inquiry_type come from the classification block; pattern is the optional `pattern` field
# (short root-cause pattern name from the controlled list in references/verdict_and_delivery.md).
# emory_digest.ps1 reads this to build the daily digest and its Standout insight.
try {
  function CsvQ([string]$x) { return '"' + (("$x") -replace '"','""' -replace "`r?`n",' ') + '"' }
  function ClsField([string]$name) {
    if (-not $v.classification) { return '' }
    $mm = [regex]::Match([string]$v.classification, '(?im)\*\*' + [regex]::Escape($name) + ':\*\*\s*(.+)$')
    if ($mm.Success) { return $mm.Groups[1].Value.Trim() } else { return '' }
  }
  $hdr = 'posted,sr,title,verdict,owner,platform,question_for,key_question,reported_date,dealer,category,inquiry_type,pattern'
  $hdrCols = ($hdr -split ',').Count
  if (-not (Test-Path -LiteralPath $LogFile) -or ((Get-Item -LiteralPath $LogFile).Length -eq 0)) {
    Set-Content -LiteralPath $LogFile -Value $hdr -Encoding UTF8
  } else {
    $existing = @(Get-Content -LiteralPath $LogFile -Encoding UTF8)
    if ($existing[0] -ne $hdr) {
      # upgrade an older schema: keep rows, pad missing columns
      $oldCols = if ($existing[0] -like 'posted,*') { ($existing[0] -split ',').Count } else { 4 }
      $body = if ($existing[0] -like 'posted,*') { $existing[1..($existing.Count-1)] } else { $existing }
      $pad = ',""' * ($hdrCols - $oldCols)
      Set-Content -LiteralPath $LogFile -Value (@($hdr) + @($body | ForEach-Object { $_ + $pad })) -Encoding UTF8
    }
  }
  $pattern = if ($v.pattern) { [string]$v.pattern } else { '' }
  $line = @((Get-Date).ToString('yyyy-MM-dd HH:mm'), $v.sr, $sr_subject, $v.verdict, $owner, $v.platform, $q_for, $key_q, $reportedDate, $v.dealer, (ClsField 'SR Category'), (ClsField 'Inquiry Type'), $pattern | ForEach-Object { CsvQ $_ }) -join ','
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
} catch { Write-Host "(delivery log not written: $($_.Exception.Message))" -ForegroundColor DarkGray }
