# Executive summary writing guide, card contract & posting

*Reference for the `emory` skill. Read this when SKILL.md points you here — it is the
full detail for that step, moved out so the main workflow stays readable.*

---

### Plain-Language Writing Guide (the `bottom` / at-a-glance fields)

The **at-a-glance lines and "What Happened?"** are what decision-makers read first — write it for someone with zero knowledge of Safe-Guard systems, products, APIs, ratings, or contracting. A new hire should understand the issue immediately without reading the rest of the case.

**Structure (3–5 sentences, plain English):**
1. **What the dealer experienced** (1–2 sentences): Plain description of the problem from the dealer's perspective. No jargon.
2. **What investigation revealed** (1–2 sentences): What we actually found. Separate facts (config is correct, contract exists) from unknowns (doesn't explain the missing rates).
3. **Next action and owner** (1 sentence): Who is responsible and what they'll do. Conversational, not a checklist.

**What to avoid:**
- ❌ Acronyms (EAS, PBL, SKU, RC#, DCR, V_PROGRAM_VEHICLE_CLASS)
- ❌ System names (Snowflake, Tier 1, dbo.*, RATE_SKU_VCI)
- ❌ Speculative language ("might," "could," "possibly") — state known facts or unknowns clearly
- ❌ Lists of findings (those go in Investigation Details → Checks)
- ❌ Technical jargon (rate system assignment, product eligibility, vehicle classing)
- ❌ Internal process details (live-fire verification, Tier 2 queries, cross-reference tables)

**What to include:**
- ✅ What the dealer was trying to do ("only received a quote for one product")
- ✅ What we confirmed ("setup appears to be correct," "vehicle identified successfully")
- ✅ Known blockers or surprises ("existing contract on the same VIN," "rates failed to return")
- ✅ What's still uncertain ("may be preventing additional sales, though we need to verify")
- ✅ Plain-English next step ("Account Management should review the contract")

**Example (plain language):**
> The dealer was only able to get a quote for one product when they submitted a request for three: Tire & Wheel, Multi-Coverage, and the main coverage plan. We confirmed the dealer and all three products are set up correctly in the system, and the vehicle was recognized. However, we found an existing contract on the same vehicle from four days earlier that may be preventing the system from selling new products, though we're not certain that's the cause. Account Management and the Rates team need to check whether the earlier contract is blocking the quote and validate the pricing calculation to figure out what's really happening.

**Anti-example (jargon, lists, speculation):**
> ❌ The dealer reported missing POTW/POMC rates on VIN WP0CE2A88SK237101. Step 1: Dealer status PASS. Step 2: Products assigned PASS. Step 3: Rate systems 1679/1672 assigned. Step 4: POTW/POMC SKUs = 0 (API-computed). Step 5: Vehicle eligible. Duplicate POCP contract (SG0009958690, 2026-08-15) might be blocking RC#1 or RC#4 — Rates & Forms and Account Mgmt should investigate Tier 1/Tier 2 data discrepancy and verify Rate System Application windows against 5b SKU windows.

**Verdict JSON schema (2026-09-22):**
```json
{
  "sr": "SR/Case number",
  "title": "Short subject line (becomes the card title)",
  "dealer": "Dealer name (code)",
  "product": "Product code - product name",
  "sub": "Vehicle details (Year Make Model, VIN) or other context",
  "source": "Integration partner, via aggregator",
  "reported": "Who raised it and when",
  "platform": "EAS | Legacy | RoadRunner | Multi-platform",
  "verdict": "PASS | FAIL | NEEDS REVIEW",

  "issue_line":   "ONE sentence: what is not rating/working (Facts: Issue)",
  "impact_line":  "ONE sentence: who cannot do what (Facts: Impact)",
  "action_line":  "ONE sentence: the single next action (Facts: Next)",
  "reported_date": "YYYY-MM-DD (else the first date inside `reported` is used)",
  "reviewed":     "YYYY-MM-DD (defaults to today)",
  "show_summary": false,
  "pattern":      "Rate system end-dated   (controlled list below; feeds the digest Standout)",
  "summary":      ["3-5 plain-English bullets that ADD to the facts, never restate them"],
  "status_rows":  [{ "item": "Ghostrider", "id": "YM900149", "status": "fixed", "note": "" }],
  "key_question": "ONE yes/no question for the owner",
  "question_for": "Account Management",
  "actions":      ["Discrete ownable item 1", "Discrete ownable item 2"],
  "owner":        "Ownership line beneath the actions",

  "checks_md":     "N. Check name - PASS|FAIL|NEEDS REVIEW|SKIPPED - detail   (one line per check)",
  "root_cause":    "Analyst-facing technical explanation (Investigation details)",
  "verification":  ["claim - how it was established (REQUIRED to post, >= 25 chars each)"],
  "classification":"**Integration Partner:** ...\n**Aggregator:** ...\n**Inquiry Type:** ...\n**Inquiry Sub-Type:** ...\n**SR Category:** ...",
  "salesforce": {                       // structured twin of `classification` — what sf_fill.py writes into the SR
    "record_id": "a03Ux00000tfAF8IAM",   // from the SR URL at intake
    "brand": "VCI", "inquiry_type": "Rating", "inquiry_subtype": "EAS",
    "sr_category": ["Rating - EAS", "Coverage Missing"],
    "integration_partner": "Reynolds and Reynolds", "aggregator": "Provider Exchange Network",
    "vin": "WA125AGU6T2021477", "dealer_number": "AU423D75", "dealer_name": "Audi Tri-Cities",
    "summary": "<SR Summary Detail paragraph, no date prefix>",
    "accept": true,                      // take ownership; default false for NEEDS REVIEW
    "close": {                           // OPTIONAL - only when the analyst wants the SR closed (More -> Close Request flow)
      "substatus": "Completed",          // Completed | No_Response | Duplicate | IncorrectlySubmitted
      "dealer_account": "Walker Toyota of Alexandria", "dealer_code": "0LD10259",   // or "not_related_to_dealer": true
      "resolution": "<Resolution Details text>"
    }
  },

  "bottom": "legacy - now Narrative inside details", "business_impact": "legacy - Narrative",
  "confirm": "legacy - falls back to key_question"
}
```
`status_rows` is optional: omit it for single-dealer cases and the Status table is parsed from
`checks_md`, which must then keep the `N. Name - STATUS - detail` (or `STATUS - Name: detail`) shape.

**Readability contract (2026-09-22, after the Burns Hyundai card).** The top of the card must be
readable in ten seconds on a phone. The renderer now enforces these caps and moves anything longer
into the details, but write to them so nothing is cut:
- `sr` = the ticket ID **only** (`INC1321020`). Housekeeping about attachments or threads goes in
  `root_cause` or the details, never in `sr`.
- `title` <= 90 chars. `issue_line` / `impact_line` = ONE sentence, <= 180 chars. `owner` = ONE team,
  <= 8 words (list secondary owners inside the actions, not in `owner`). `key_question` <= 220 chars.
- `actions[]` = **owner in bold, then one sentence, <= 25 words.** Evidence and identifiers belong in
  `root_cause` / `verification`, not in the action text.
- `checks_md` line shape: `EMOJI **STATUS** - Name: detail`. `Name` is one of the canonical check
  names (the renderer maps anything else onto them): **SR dedup, Duplicate contract, Dealer, Product,
  Form, Rate system, Rate SKU, Classing, Eligibility rule, Live API, Request payload.** Put qualifiers
  such as "(request)" in the detail, not in the name. A line with no status word renders as NEEDS REVIEW.
- The single-dealer Status line shows check *names* only (never details); with more than four
  non-passing checks it shows counts instead.

### Card layout — executive summary first, FIXED ORDER (analyst spec, 2026-09-22)

| Order | Block | Field(s) |
|---|---|---|
| 1 | Header: title, then status line (● verdict · SR · platform · Reported · Reviewed) | `title`, `sr`, `platform`, `reported`, `reviewed`, `verdict` |
| 2 | **Facts** — Issue / Impact / Owner / Next, one line each | `issue_line`, `impact_line`, `owner`, `action_line` |
| 3 | **Summary** — multi-item cases only; bullets that add to the facts | `summary[]`, `show_summary` |
| 4 | **Status** — multi-item: the table (the only `<table>`); single-dealer: one line, grid in details | `status_rows[]` or parsed `checks_md` |
| 5 | **Key question · {question_for}** (when a human must decide) / **Next steps** (only ≥ 2 actions) | `key_question`, `question_for`, `actions[]` |
| 6 | **▾ Investigation details** — identifiers, Narrative, Checks, Root cause, How this was verified, Classification & routing | everything technical |

**Why it changed:** the 2026-09-15 card (At a glance → What Happened → Business Impact → What Needs
to Be Done → Verification Needed → Investigation Details) put five prose boxes in front of the
evidence and each restated the previous one. Analysts called it noisy. The model for the new shape
was a hand-written executive summary (Yamaha / Inovatec, 2026-09-21): bullets, one status table,
one key question, and the evidence out of the way.

**Collapsing the details — what is and isn't possible in Teams.**
- Teams **strips `<details>`/`<summary>`** from HTML messages, so an HTML card cannot have a real
  toggle. The details block is therefore last, visually quiet (12.5px, muted) and separated by a
  hairline; Teams' own **"See more"** fold hides it for anyone who stops at Next steps.
- A **true collapse** needs an Adaptive Card with `Action.ToggleVisibility`. `emory_post.ps1` already
  emits one as the `card` field of the payload (v1.4, "Show investigation details" button, details
  container `isVisible: false`). It is inert until the flow gets a **"Post card in a chat or
  channel"** action (Flow bot → #api-support-intake) with *Adaptive Card* = `triggerBody()?['card']`
  and the trigger schema gains `"card": {"type": "string"}`. One-time flow edit; no script change.
  `-EmitTemplate` writes `emory_verdict_card.adaptive.json` for previewing at adaptivecards.io/designer.

**Five cuts (efficiency review, 2026-09-22) — the card says each thing once:**
1. "What to do" appears **once**: the Key question when a human must decide, otherwise the Next fact
   line. The numbered Next steps list renders only when there are **two or more** distinct actions.
2. `summary` renders only on multi-item cases (`status_rows`) or legacy verdicts with no facts lines
   (`show_summary: true` forces it). It must add to the facts, never restate them.
3. Single-dealer Status is **one line** ("5 of 6 checks pass · Rate SKUs need review"); the full grid
   moves into the details. Multi-item cases keep the table up top because the table *is* the case.
4. Narrative (`bottom` / `business_impact`) is no longer rendered anywhere.
5. The status line shows **dates only**: `reported_date` (or the first date found in `reported`) and
   `reviewed` (defaults to today). Who raised it moves to the details identifiers.

**How Teams really renders the card (observed live 2026-09-22).** Teams keeps colour, bold, font
size, `<p>`, `<br>`, `<ul>/<ol>` and `<table>`; it strips backgrounds, borders, margins, padding,
uppercase/letter-spacing and font-family, and it draws its **own cell borders on every `<table>`**. So
the card uses Teams-native primitives only: `<p>` blocks, list elements, coloured `<span>`s, small grey
labels written in UPPERCASE text, and exactly **one** `<table>` (the Status grid). Never use a table
for layout; the browser preview (`emory_verdict_card.html`) mimics Teams' borders so this shows up
before posting. No background is ever set, so colours must read on both Teams themes.

**Visual language (2026-09-22):** strictly minimal. One flat dark canvas (`#0e1116`); **no panels,
no borders, no rounded boxes, no accent bars, no pills** — a first pass with translucent "glass"
panels was rejected as "Claude-like panels". Sections are separated only by a 1px hairline
(`rgba(255,255,255,0.08)`) and whitespace; uppercase eyebrow labels; one accent colour (the
verdict, shown as a coloured dot + word, not a badge); coloured dots for status. Fonts **Aptos / Aptos Display**
(Microsoft 365 default, on every Teams client) and **Cascadia Mono** for IDs; web fonts cannot be
loaded into a Teams message. Readability floor: body 14px at 92% white, nothing under 12.5px, muted
text never under 55%. Font stacks use **double quotes** inside the single-quoted style attributes —
a single-quoted font name terminates the attribute and the whole card falls back to a serif.

### Two audiences, two fields — still true

| Field | Renders as | Written for | Contains |
|---|---|---|---|
| `summary[]` | Executive summary | **zero** SG knowledge | plain English. NO acronyms, table/column/system names, row counts, contract numbers |
| `key_question` | Key question | the owner | one yes/no question |
| `root_cause` | Investigation details → Root cause | an analyst | tables, columns, counts, identifiers |
| `checks_md` | Status table (parsed) and/or details → Checks | an analyst | evidence, one line per check |

**`pattern` field (optional, feeds the digest's Standout insight).** One short root-cause pattern name from
this controlled list, so recurrences can be counted across cases: `Rate system end-dated` · `Product not
assigned` · `Dealer not enrolled` · `Dealer mapping` · `Classing gap` · `Eligibility rule` · `Forms missing` ·
`Pricing verification` · `Contracting defect` · `Duplicate contract` · `Caller-side request error` · `Working as
designed` · `API/routing defect`. Add a new name only when none fits; keep it under four words.

### Daily digest (`emory_digest.ps1`, added 2026-09-22)

One post per weekday morning that makes the channel a source of truth: yesterday's cards with verdict
dots and owners, **Waiting on an answer** (key questions from the last 7 days, oldest first, with owner
and age), four **Key metrics** lines (cases this week vs last, share needing a human, average days
from report to review, open questions) and a **14-day trend** table with text bars (the only `<table>`).
A **Standout** block sits under the status line: a headline insight plus up to two supporting lines,
chosen by scored rules (recurring root-cause pattern, one owner holding most open questions, oldest
unanswered question, volume spike, share needing a human vs last week, FAIL streak, Legacy share, repeat
dealer, mostly working-as-designed). The trend table has a **What stood out** column with each day's
dominant pattern. Same Teams-native rules as the card. Data source is the **local delivery log**
`Downloads\emory_card_log.csv`, which `emory_post.ps1` appends to on every real post (schema:
`posted,sr,title,verdict,owner,platform,question_for,key_question,reported_date,dealer,category,inquiry_type,pattern`;
older files are upgraded in place); rows whose
SR or title start with `TEST` are ignored. **Quiet rule:** no cards yesterday and no open questions
means no post (`-PostIfEmpty` overrides). `-For YYYY-MM-DD` rebuilds a past day; `-EmitTemplate`
writes `emory_digest_preview.html`. Scheduling: `Register-EmoryDigestTask.ps1` creates a weekday
08:00 task that runs `-Auto` (gated by the same `emory_autopost.txt` toggle) — run it once yourself;
it is not registered automatically.

**Finding labels (2026-09-23).** The JSON `verdict` values stay `PASS` / `FAIL` / `NEEDS REVIEW` (log,
verifier, older tooling), but what people **see** is now: PASS → **Setup is correct** (nothing to fix on
our side; the cause is the partner, the dealer, or working as designed) · FAIL → **Setup issue found** (a
specific configuration problem, with its owner) · NEEDS REVIEW → **Decision needed** (the setup may be
deliberate; one team must confirm intent). Check rows show OK / Issue / Review / Skipped. The digest
uses the same words, shortened to CORRECT / DECIDE / ISSUE in the trend table. Reason: "Pass" read as
"the ticket is fine", "Fail" read as "the API failed", and every ticket "needs review".

### ⛔ VERIFICATION GATE — posting is blocked without it (2026-09-15)

`emory_post.ps1` **refuses to post** unless the verdict JSON carries a `verification` array: one
entry per load-bearing claim, naming the claim **and how it was established**. Entries under 25
characters are rejected. Dry runs are never gated.

**Why:** a card was posted stating "9 further dealers carry the same broken config" — a number that
was **never verified**. It came from a cohort query filtering a **literal date value**, which both
missed affected dealers and included healthy ones. The real set was 5. **Inference is not
verification**; if you did not run it, it does not go on the card. Carry retractions forward
explicitly as `RETRACTED …` entries rather than silently dropping them.

**Prose formatting:** `summary` bullets, `key_question`, `bottom`, `business_impact`, `root_cause` and each
`actions` item run through `Prose()` — blank line = new paragraph, single newline = line break,
`**bold**`, `` `backticks` `` = monospace. Use blank lines to separate beats.

**Verdict accent:** PASS `#3fb950`, NEEDS REVIEW `#f0883e`, FAIL `#f85149` (pill, glow, key-question rule, footer); a hex `verdict_color` overrides it.

**Posting it (the wiring).** After the verdict, offer to post it to `#api-support-intake`.
On the analyst's OK, POST it (via `curl`, Bash) to the **HTTP delivery flow** — the Power
Automate flow **"Http -> Post message in a chat or channel"** (manual HTTP trigger → Teams
**"Post message in a chat or channel"**, posting as **Flow bot** to the **#api-support-intake**
group chat). The contract is a **single field**: `{ "message": "<html>" }`. The flow binds
that straight into the Teams message (`triggerBody()?['message']`, wrapped in a `<p>`), so
the message body **is HTML** — build the voice draft above and convert it for Teams:
newlines → `<br>`, the `Dealer:/Product:/Issue:` labels → `<b>…</b>`, `&` → `&amp;`. Lead
line stays `🔎 <b>Emory · pre-analysis</b> — {platform} · <b>{VERDICT}</b>` and it still
signs `— Emory` at the end, so it reads as her even though Flow bot is the poster.

Its POST URL (the `…&sig=…` trigger URL) lives in `Downloads\emory_verdict_delivery_url.txt`
— **read it at post-time; never hardcode it in this skill or the shared package** (it's a
secret).

**Delivery is HANDS-OFF (opted in 2026-08-05).** At the end of every case, write the verdict
JSON and call the bundled poster with **`-Auto`** — it posts automatically **only while the
toggle `Downloads\emory_autopost.txt` reads `on`**, so hands-off is deliberate and revocable,
not silent. This is the default end-of-run step now — don't stop to ask "post?" while the
toggle is on. Guardrails still hold: it only ever posts Emory's own read-only pre-analysis
card, never a dealer's PII or a plaintext password.

**The bundled poster `emory_post.ps1`** (in this skill's folder) takes the verdict JSON Emory
already emits (see the schema above - `verification` is REQUIRED to post; `summary`/`status_rows`/`key_question`/`actions`
drive blocks 2-4), builds the HTML `message` (glass look, Aptos) plus the Adaptive Card `card`, and delivers.
**The script IS the card layout; `emory_verdict_card.html` is a generated preview of its output** (see
"Card template" below).
The script uses emoji conversion (UTF-32 code points) to ensure proper Teams rendering, and all HTML
is properly escaped. **`classification` is mandatory, not optional** — it's the Step 7 case-classification
block (Integration Partner, Aggregator, Inquiry Type, Inquiry Sub-Type, SR Category from
`case_classification_picklists.md` / `aggregator_integration_partners.md`), formatted as
`"**Label:** value"` lines (same convention as `checks_md`). Always populate it in the verdict
JSON on the first post — never as a separate follow-up card; a card missing it is incomplete
(confirmed 2026-08-18: it was omitted on the first pass for three cases and had to be posted as
awkward bolt-on follow-ups).

**Card layout — single source of truth (reconciled 2026-08-24):**
- **`emory_post.ps1` is the authority.** It builds the card; nothing reads the HTML file at post time.
- **`emory_verdict_card.html` is a GENERATED preview**, carrying a "DO NOT HAND-EDIT" banner. It exists
  so the palette/structure can be eyeballed without posting. **Regenerate it after any layout edit:**
  ```bash
  powershell -File ~/.claude/skills/emory/emory_post.ps1 -VerdictJson ~/.claude/skills/emory/emory_verdict_card.sample.json -EmitTemplate
  ```
  `-EmitTemplate` never posts. The sample (`emory_verdict_card.sample.json`) is the INC1315934 RV GAP
  case, kept deliberately as a **NEEDS REVIEW** verdict so the reference card keeps demonstrating the
  orange styling, and it populates every optional field so none silently rots.
- **Why this changed:** the HTML was previously marked "frozen / DO NOT MODIFY" while the script was
  separately named the authoritative adapter — two sources of truth for one layout. They drifted, and
  the drift was only caught by eye (the run-on header on INC1316449). Generating the file from the
  script removes the possibility structurally.
- Color palette: Dark backgrounds (#2a2a2a, #1f1f1f) | Blue headers (#58a6ff) | Gold alerts (#ffd700,
  box bg #3d3600 normally / #5f3d00 on FAIL — verdict-conditional, not drift) | Green PASS (#3fb950) |
  Orange REVIEW (#f0883e) | **Red FAIL (#f85149)**
- **The Checks block (Investigation Details) and the footer status badge are verdict-coloured** (fixed 2026-08-25).
  Both were previously pinned — findings always green, footer always orange — so a FAIL card
  rendered its findings in success-green, the opposite of what a channel skim needs. They now
  derive accent / background / text from the verdict: PASS `#3fb950` on `#1f3a2f`, NEEDS REVIEW
  `#f0883e` on `#3a2a18`, FAIL `#f85149` on `#3a1d1d`. The optional `verdict_color` field in the
  verdict JSON overrides the accent — until this fix it was documented but silently ignored.
- **Never pre-merge `sr` / `issue` / `sub` into one string.** Header = `sr` + `title` only; `bottom` →
  "What Happened?"; `business_impact` → "Business Impact"; `sub` → Investigation Details as *vehicle
  only* (channel goes in `source`). Merging them produced the run-on header fixed 2026-08-24.

```bash
# hands-off end-of-case step (posts iff emory_autopost.txt = on; previews otherwise):
powershell -ExecutionPolicy Bypass -File ~/.claude/skills/emory/emory_post.ps1 -VerdictJson verdict.json -Auto
# force a send regardless of the toggle:
powershell -ExecutionPolicy Bypass -File ~/.claude/skills/emory/emory_post.ps1 -VerdictJson verdict.json -Post
# preview only, never sends:
powershell -ExecutionPolicy Bypass -File ~/.claude/skills/emory/emory_post.ps1 -VerdictJson verdict.json
```

**Pause hands-off** any time: write `off` to `Downloads\emory_autopost.txt` (then `-Auto`
just previews). `-UrlFile`/`-AutoFile` default to the `Downloads\` files; point them at your
own on other installs (both are local, kept OUT of the shared package). Or POST by hand:

```bash
curl -sS -X POST "$(grep -o 'https://[^ ]*' Downloads/emory_verdict_delivery_url.txt)" \
  -H "Content-Type: application/json" --data '{"message":"<html…>"}'
```

(Verified live 2026-08-05: `{"message": …}` for the SQ8 verdict → run **Succeeded**, both
steps green, message posted as Flow bot to #api-support-intake. The earlier failures were an
**empty** message field — the flow needs the `message` field populated or "Post message"
fails in ~180 ms.)

- **Posting is a send, but the analyst has opted into hands-off** (`emory_autopost.txt = on`),
  so `-Auto` delivers without a per-case prompt. The standing authorization covers **only
  Emory's own pre-analysis card to #api-support-intake** — nothing else. If the toggle is
  `off`, fall back to preview + explicit OK. Any *other* send (email, DM, a different channel)
  still needs a fresh OK.
- Keep it to what a teammate skimming the channel needs: verdict, one-line why, the
  single next action. The full check-by-check reasoning stays above it for anyone who
  clicks in.

**Card HTML preview (`emory_verdict_card.html` — GENERATED, do not hand-edit):**
A rendered snapshot of what `emory_post.ps1` currently emits, regenerated with `-EmitTemplate` (above).
Open it to check the styling:
- Dark theme (background #2a2a2a, #1f1f1f) for readability
- White text on dark backgrounds (#e6edf3 for body, #ffffff for summaries)
- Blue section headers (#58a6ff)
- Gold title in alert box (#ffd700)
- Green PASS badges (#3fb950)
- Orange REVIEW badges (#f0883e)
- Blue link boxes (#0d2e5f, #1f6feb)
- High contrast throughout — validated 2026-08-24 (INC1315934)

**Do not rebuild the HTML inline in each case, and do not hand-edit the preview file.** Emory's job is
to emit the verdict JSON and call `emory_post.ps1` — the script renders it. If the *layout* genuinely
needs to change, edit the script, then regenerate the preview with `-EmitTemplate` so the two stay in
lockstep. Layout changes are still a deliberate act requiring the analyst's OK; content changes (what
goes in each field) are ordinary case work and need no approval.
- Never put a dealer's PII or a plaintext password from a payload into the card. This holds
  even in hands-off mode — the guardrail is what makes auto-post safe.

### Salesforce fill hand-off (`salesforce` block → `sf_fill.py`, added 2026-09-28)

`emory_post.ps1` writes `$v.salesforce` to `Downloads\EmorySF\inbox\<SR>.json` on every run. `sf_fill\sf_fill.py`
(`--watch`, or `Downloads\EmorySF\watch.cmd`) fills the SR from there: REST PATCH when the session is API-enabled,
otherwise the inline-edit form with Playwright. Rules the block must follow, or the record is SKIPPED with the reason
in `sf_fill_log.csv`:
- only real picklist values (`case_classification_picklists.md`); Inquiry SubType must belong to the Inquiry Type;
- `sr_category` is a list; `summary` has no date prefix (the script dates it and APPENDS to existing entries);
- lookups are Account names that resolve (Reynolds and Reynolds, Line5, Darwin Menu, Darwin Online, RouteOne Menu /
  MaximTrak, Provider Exchange Network, F&I Express, PCMI Corporation); shorthand like "PEN" is normalised;
- `record_id` from the SR URL saves a queue scan; `duplicate_of` adds "Duplicate of SR…" to the summary;
- `error_text` (the raw API error) may be given instead of `error_code`; the script maps it when confident.
Results: `EmorySF\state\filled.json` (per SR), `EmorySF\last_run.md`, screenshots of failures in `EmorySF\failed\`.
- `close` is optional and UI-only (Status cannot be PATCHed to Closed - Salesforce answers "use Close Support Request"; and
  "Waiting on Internal Team" needs an Internal Support Request first). The script picks the Dealer Account row that carries
  `dealer_code` (the right one can be the SECOND row); Account codes drift from the SR (Audi Tri-Cities = AU423D74 in
  Salesforce vs AU423D75 in the case), so give both name and code. Records already Closed are skipped, never written.
- Ownership is judged from the Owner field (Accept/Transfer stay visible after ownership). Accept -> Yes -> Owner = analyst,
  Status New -> In Progress.
