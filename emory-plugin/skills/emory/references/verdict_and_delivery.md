# Executive summary writing guide, card contract & posting

*Reference for the `emory` skill. Read this when SKILL.md points you here — it is the
full detail for that step, moved out so the main workflow stays readable.*

---

### Executive Summary Writing Guide

The **Executive Summary** is the headline that decision-makers read first — write it for someone with zero knowledge of Safe-Guard systems, products, APIs, ratings, or contracting. A new hire should understand the issue immediately without reading the rest of the case.

**Structure (3–5 sentences, plain English):**
1. **What the dealer experienced** (1–2 sentences): Plain description of the problem from the dealer's perspective. No jargon.
2. **What investigation revealed** (1–2 sentences): What we actually found. Separate facts (config is correct, contract exists) from unknowns (doesn't explain the missing rates).
3. **Next action and owner** (1 sentence): Who is responsible and what they'll do. Conversational, not a checklist.

**What to avoid:**
- ❌ Acronyms (EAS, PBL, SKU, RC#, DCR, V_PROGRAM_VEHICLE_CLASS)
- ❌ System names (Snowflake, Tier 1, dbo.*, RATE_SKU_VCI)
- ❌ Speculative language ("might," "could," "possibly") — state known facts or unknowns clearly
- ❌ Lists of findings (those go in Key Findings)
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

**Verdict JSON schema (required fields — all must be populated):**
```json
{
  "sr": "SR/Case number",
  "dealer": "Dealer name (code)",
  "product": "Product code — product name",
  "issue": "What's not working (one line, plain English)",
  "sub": "Vehicle details (Year Make Model, VIN) or other context",
  "platform": "EAS | Legacy | RoadRunner | Multi-platform",
  "verdict": "PASS | FAIL | NEEDS REVIEW",
  "checks_md": "✅ Dealer status\n✅ Product assigned\n❌ Rates missing\n? Classing unclear",
  "bottom": "Root cause summary (2-3 sentences, plain English, no jargon — what we found + why + what's uncertain)",
  "confirm": "What needs validation and why (if NEEDS REVIEW) — write for a non-technical audience",
  "owner": "Escalation team/person (Account Manager, Rates & Forms, OEM Program, etc.)",
  "classification": "**Integration Partner:** Name\n**Aggregator:** Name\n**Inquiry Type:** Value\n**Inquiry Sub-Type:** Value\n**SR Category:** Value"
}
```

**Key fields for plain-language summary:**
- **`issue`** — What the dealer experienced (e.g., "Only received a quote for one product instead of three")
- **`bottom`** — The investigation finding in 2–3 plain-English sentences (what we found, why we think it happened, what we're uncertain about)
- **`confirm`** — Plain description of what needs verification next (e.g., "Whether the existing contract is blocking the quote")

**Visual styling in the card:**
- Green highlight (✅) on PASS checks
- Red highlight (❌) on FAIL checks  
- Orange warning (?) on NEEDS REVIEW items
- Yellow box on the classification block (the SR form fields to fill)
- Emoji status badges (✅/⚠️/❌) in the header and throughout

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
already emits (rich schema: `sr, dealer, product, issue, sub, platform, verdict, verdict_color,
checks_md, bottom, owner, confirm, classification` + optional `title, source, reported`), builds the
HTML `message` itself — dark theme, high-contrast colors, blue/gold/green badges — and delivers.
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
- **The KEY FINDINGS block and the footer status badge are verdict-coloured** (fixed 2026-08-25).
  Both were previously pinned — findings always green, footer always orange — so a FAIL card
  rendered its findings in success-green, the opposite of what a channel skim needs. They now
  derive accent / background / text from the verdict: PASS `#3fb950` on `#1f3a2f`, NEEDS REVIEW
  `#f0883e` on `#3a2a18`, FAIL `#f85149` on `#3a1d1d`. The optional `verdict_color` field in the
  verdict JSON overrides the accent — until this fix it was documented but silently ignored.
- **Never pre-merge `sr` / `issue` / `sub` into one string.** Header = `sr` + `title` only; `issue` →
  EXECUTIVE SUMMARY ("What the dealer saw" / "What we found"); `sub` → CASE OVERVIEW as *vehicle only*
  (channel goes in `source`). Merging them is what produced the run-on header fixed 2026-08-24.

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
