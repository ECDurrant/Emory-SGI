# Emory — version record

**Current version: `2026-10-01`** (2026-09-22 card, locked · Salesforce fill hand-off `sf_fill\` · evidence-based routing + RR_UTILITY + Legacy fixed queries)

**LOCKED 2026-09-22 (Ed: "i like this lets lock it in").** The card layout in `emory_post.ps1` is the approved
baseline: facts-first, Teams-native primitives, one table, the five cuts. Layout changes from here need
Ed's explicit OK; content changes per case are normal. Snapshot: `Downloads\Emory_Skill_Snapshots\emory_skill_20260922_*.zip`.
Plugin copies (`Downloads\emory-plugin`, `Downloads\sg-marketplace\emory-plugin`) re-synced to this version.

`~/.claude/skills/emory/` is the **canonical** install and is NOT version-controlled, so this file
plus the snapshot in `Downloads\Emory_Skill_Snapshots\` is the recovery path. Verify an install at
any time with:

```powershell
powershell -ExecutionPolicy Bypass -File ~/.claude/skills/emory/verify_emory.ps1
```

---

## What changed in 2026-10-01 (data audit — routing, RoadRunner, Legacy)

Card layout untouched (still the locked 2026-09-22 baseline). Query/data layer only:

- **New `references/routing.md`** — router R1 (where is this product active today, all 3 platforms, one
  Snowflake query), R2 (presence/history when R1 is empty), R3 (live call-log evidence), OEM → platform →
  rate-source census for all EAS and RR programs, gap register G1–G7. Verified on 6 known cases.
- **New `references/legacy_forte.md`** — fixed Legacy checks L0–L4 (portable SQL; verified on `00SG1055`).
- **RoadRunner moved to `STAGING.RR_UTILITY`** — `STAGING.RR` is frozen since 2024-08-13. `roadrunner.md`
  rewritten (RR1 = Checks 1/2/4/5/6 in one query, verified `GMF18645`/`BUVS` → `B2`); `sibling_diff.md` fixed.
- **Step 0 profile (P1) rewritten** — EAS presence from `V_DEALER` (shells no longer read as absent), RR from
  `RR_UTILITY`, active-product/enrolment counts per platform, prefix table re-validated (Honda → EAS, HCI split
  by product code, Agents → EAS).
- **Check 5b two paths** — RATE_SKU table *or* PRODUCT_PLAN_SKU_PRICE_HEADER (verified `MAZ42024`/`MZSP`).
- **Sub-agents / APIBRAIN / flow spec** — VIN decode fixed (old `LIKE vin_pattern+'%'` returned 0 rows);
  rate-system date gate removed; hard-coded `RATE_SKU_VCI` annotated. Backups `*.bak-20261001`.
- **Guardrails §7** source-of-truth rules + 4 new checklist items.
- **Fixed MCP tools (later 2026-10-01):** `emory-agent/emory_agent/checks.py` + 9 MCP tools (`emory_check_case`
  and single-check tools) and 4 hosted-agent tools (`fixed_*`); bound parameters in `db.py`; self-test
  `python -m emory_agent.selftest` 13/13. Found while testing: **make-level classing rows (~21k, blank model)
  were invisible to the classing query** (false "no class", e.g. Mazda) — fixed in the tool and in
  `classing_and_eligibility.md`; and gap **G8** (143 Audi dealers stuck on retired rate system 134).
- Pre-change snapshot: `Downloads\Emory_Skill_Snapshots\emory_skill_20261001_pre-routing\`.
- Postgres (Forte) queries written portable but **not re-verified live** (GlobalProtect off 2026-10-01).

---

## What changed in 2026-09-28

**Salesforce fill hand-off** (`sf_fill\sf_fill.py`, new). Emory's verdict JSON gains a structured `salesforce` block;
`emory_post.ps1` drops it into `Downloads\EmorySF\inbox\<SR>.json` (backup `emory_post.ps1.bak-sffill-20260928`); the
script fills the SR (Accept, Brand, Inquiry Type/SubType, SR Category, lookups, VIN/dealer, dated summary APPEND) with
zero model tokens — REST PATCH when the session is API-enabled, else Playwright on the inline-edit form. Diffs before
writing, validates against live picklists, retries once with a failure screenshot, logs to `EmorySF\sf_fill_log.csv`,
records per-SR results in `EmorySF\state\filled.json`. Why: the 09-28 manual fill cost ~95 browser calls for six SRs
and typed a summary into Description. `case_classification_picklists.md` rewritten with the live values (Rating type,
dependent SubTypes, 51 categories, no "Setup New/Migration"). Card layout unchanged.

---

## What changed in 2026-09-23

**Finding labels** (`emory_post.ps1`, `emory_digest.ps1`): PASS / FAIL / NEEDS REVIEW now display as **Setup is
correct / Setup issue found / Decision needed**; check rows show OK / Issue / Review / Skipped; digest table
columns CORRECT / DECIDE / ISSUE. JSON values, log and verifier unchanged. Approved by Ed after the labels were
judged confusing ("Pass" read as "ticket is fine", "Fail" as "API failed").

---

## What changed in 2026-09-22

**Card redesigned — facts first, built for how Teams really renders** (`emory_post.ps1`, the layout
authority). A live TEST post showed Teams strips backgrounds/borders/margins/uppercase/font-family and
boxes every `<table>`; the card now uses only `<p>`, lists, coloured spans and ONE table (Status). New
top block: **Facts** — Issue / Impact / Owner / Next (`issue_line`/`impact_line`/`owner`/`action_line`),
then a status line with Reported + Reviewed dates, and a footer counter "card N today" from a local
delivery log (`Downloads\emory_card_log.csv`, appended on every real post). Analyst
feedback: the 2026-09-15 six-section card was "so damn noisy". New shape: header with verdict pill →
**Executive summary** bullets (`summary[]`) → one **Status** table (`status_rows[]`, or parsed from
`checks_md`) → **Key question** (`key_question`, `question_for`) + numbered **Next steps** → a quiet
**Investigation details** appendix (identifiers, narrative, checks, root cause, how verified,
classification). Every 2026-09-15 field still renders via fallbacks.

**Five cuts (same day, efficiency review):** "what to do" appears once (Key question OR Next line;
numbered list only for ≥ 2 actions); summary only on multi-item cases; single-dealer Status is one line
with the grid in the details; Narrative dropped; status line shows dates only (`reported_date`,
`reviewed`). A typical single-dealer card is now ~10 lines above the fold.

**Look:** strictly minimal — flat dark canvas, no panels/borders/boxes/pills (a glass-panel pass was
rejected the same day as "Claude-like"), hairline-separated sections, eyebrow labels, status dots,
one verdict accent. Fonts Aptos / Aptos Display + Cascadia Mono (system fonts; Teams cannot load web
fonts). Readability floor 12.5px, body 14px near-white.

**Collapse:** Teams strips `<details>`, so the HTML card leans on Teams' "See more" fold. The payload
now also carries `card` — an Adaptive Card (v1.4) with `Action.ToggleVisibility` hiding the details.
Inert until the delivery flow gains a *Post card in a chat or channel* step bound to
`triggerBody()?['card']` (one-time flow edit, no script change).

**Daily digest (same day):** new `emory_digest.ps1` (+ `Register-EmoryDigestTask.ps1`, not registered) —
weekday channel summary from `Downloads\emory_card_log.csv`, whose schema `emory_post.ps1` now writes with a
header (`...,dealer,category,inquiry_type,pattern`; old files upgraded in place). **Standout** insight block
(scored rules: recurring pattern, owner bottleneck, oldest question, volume spike, human-share shift, FAIL
streak, Legacy share, repeat dealer) + a per-day "what stood out" column; new optional verdict field `pattern`
(controlled list) feeds it. Scheduled task 'Emory Daily Digest' registered (weekdays 08:00).

**Files:** `emory_verdict_card.sample.json` gained `summary`/`key_question`/`question_for`; new
`emory_verdict_card.sample2.json` (Yamaha / Inovatec multi-dealer, exercises `status_rows`);
`-EmitTemplate` now writes `emory_verdict_card.html` **and** `emory_verdict_card.adaptive.json`.
`verify_emory.ps1` checks the new sections, both samples, the toggle, and the font-quoting trap.
Rollback: `emory_post.ps1.bak-readerfirst-20260915`.

---

## What changed in 2026-09-16

**New reference file** `references/api_quick_tips.md`, from `Downloads\API Quick Tips.docx` —
the partner-facing self-service guide IT Client Support distributed to PEN, built from a review
of PEN-submitted API tickets. Three tables: recurring error message → XML field → meaning (with
an added "Emory's read" column routing each row to caller-side vs config), the dealer/provider
code prefix → manufacturer program map, and the well-formed-ticket checklist.

**New `Step 0a-2` in `SKILL.md`** — when an SR quotes an API error message, check it against
Section A *before* running the five checks. Caller-side rows (`retail price is not matching`,
`sellerId must be 8 characters long`, `Format is invalid`, `vin does not exist`, timeouts) get
named and returned without spending the checks on config that is fine; config rows continue to
Step 0. The Section B prefix table is explicitly a **routing hint only** — the resolved
`V_DEALER` / `cms_dealer_number` value still wins.

`verify_emory.ps1` reference manifest updated to 10 files.

---

## What changed in 2026-09-15

**1. Reader-first card layout** (`emory_post.ps1`, analyst spec). Fixed section order — At a glance
(Issue / Impact / Action Needed) → 🚨 What Happened? → 📈 Business Impact → ✅ What Needs to Be Done?
→ ❓ Verification Needed → 🔍 Investigation Details. All technical content moved to the last section.
New fields: `issue_line`, `impact_line`, `action_line`, `business_impact`, `actions` (array). Every
new field falls back to an older one, so pre-existing verdict JSON still renders.

**2. Verification gate** (`emory_post.ps1`). Posting is **refused** unless the verdict JSON carries a
`verification` array — one entry per load-bearing claim, naming how it was established; entries under
25 chars rejected. Dry runs ungated. Added after a card asserted "9 further dealers affected" — a
number never verified, from a cohort query filtering a literal date. Real set was 5.

**3. Confirm intent before presuming a fault.** Documented rule: when a config change has an owner
you have not spoken to, the action line leads with "confirm whether this was intentional".

**4. `root_cause` split from `bottom`** (2026-09-14). `bottom` = non-technical; `root_cause` =
analyst-facing. They were one field rendered in two places, which forced "technical detail follows"
seams.

**5. `Prose()` helper** (2026-09-14). Blank line = paragraph, `**bold**`, `` `backticks` `` =
monospace, in `issue` / `bottom` / `business_impact` / `root_cause` / `confirm` / `actions`.

**6. Check 5a exception documented** (`SKILL.md`, `EMORY_ANALYSIS_GUARDRAILS.md`). The default
guardrail — 5a sale-window dates are unreliable, don't gate a verdict — **still stands**. The narrow
exception requires `has_open = 0` per dealer on the base table, never a literal-date filter.

---

## File roles

| File | Role | Hand-edit? |
|---|---|---|
| `SKILL.md` | workflow spine, check order, card layout contract | yes |
| `EMORY_ANALYSIS_GUARDRAILS.md` | §0 pre-post verification gate + failure lessons | yes |
| `emory_post.ps1` | **the card layout authority**; builds HTML and delivers | yes |
| `emory_verdict_card.html` / `.adaptive.json` | GENERATED previews (HTML + Adaptive Card) — regenerate, never hand-edit | **no** |
| `emory_verdict_card.sample.json` | sample driving the preview (NEEDS REVIEW, parsed checks) | yes |
| `emory_verdict_card.sample2.json` | multi-dealer PASS sample; exercises `status_rows` | yes |
| `references/verdict_and_delivery.md` | full card contract + writing guide | yes |
| `verify_emory.ps1` | install verifier (parity, parse, smoke, gate) | yes |
| `emory_digest.ps1` | daily digest poster (reads the delivery log) | yes |
| `Register-EmoryDigestTask.ps1` | one-time scheduler registration for the digest (run by hand) | yes |
| `emory_post.ps1.bak-prestructure` | rollback to the pre-2026-09-15 layout | keep |
| `emory_post.ps1.bak-readerfirst-20260915` | rollback to the 2026-09-15 six-section layout | keep |

**Regenerate the preview after ANY layout edit:**
```powershell
powershell -File ~/.claude/skills/emory/emory_post.ps1 -VerdictJson ~/.claude/skills/emory/emory_verdict_card.sample.json -EmitTemplate
```

---

## ⚠️ Known instability: two install paths drift

`/emory` (bare) resolves to this canonical directory and is **always correct**.

`anthropic-skills:emory` resolves to a **server-synced cache** under
`AppData\Roaming\Claude\local-agent-mode-sessions\…\skills\emory\`, materialised from skill record
`skill_012SYbR4KD7mjFaxwxbWonMC` (last published **2026-08-10**). Copying files into that cache is a
**temporary** patch — it is re-materialised from the server record and will revert.

**Consequence:** until the skill record is re-published, the cached path serves the old script — no
reader-first layout, no verification gate, no corrected Check 5a guidance. **Always invoke bare
`/emory`.** Re-publishing the skill record is the only durable fix and cannot be done locally.

`verify_emory.ps1` reports parity across all three paths so drift is visible rather than silent.
