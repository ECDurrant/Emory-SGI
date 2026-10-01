# sf_fill - Salesforce SR fill for Emory (zero model tokens)

Emory decides; this fills. Emory's verdict JSON carries a `salesforce` block, `emory_post.ps1` drops it into
`Downloads\EmorySF\inbox\<SR>.json`, and this script writes it into the Support Request.

## Setup (once)

```
pip install playwright requests
```

Edge runs on its own profile (`%LOCALAPPDATA%\EmorySF\profile`). The first run opens Edge on the SR queue; sign in
through SSO in that window. The script waits and never types credentials.

## Everyday

| Want | Do |
|---|---|
| Hands-off: fill each SR as Emory finishes it | double-click `Downloads\EmorySF\watch.cmd` and leave it open |
| See what would change, save nothing | `Downloads\EmorySF\dry-run.cmd` (or `--dry-run`) |
| Fill whatever is in the inbox now | `Downloads\EmorySF\fill.cmd` |
| Fill one SR from any verdict/record file | `python sf_fill.py file.json --sr SR00418301` |
| Convert an old queue-run write-up | `python sf_fill.py --from-md Emory_Queue_Run_2026-09-25.md --out q.json` |
| Dump real field names, picklists, dependent Sub-Types | `python sf_fill.py --discover` (REST only) |

Processed inbox files move to `done\` or `failed\` (failed ones get a full-page screenshot). Every attempt is
logged to `sf_fill_log.csv`; per-SR outcomes live in `state\filled.json` so Emory knows what is already done;
`last_run.md` is the latest summary table.

## Input

A verdict JSON with a `salesforce` block, a bare fill record, a `{"records": [...]}` list, or a directory of any of
those. Keys, all optional except `sr` (or an `sr` on the parent verdict):

```
brand  inquiry_type  inquiry_subtype  sr_category[]  integration_partner  aggregator
vin  dealer_number  dealer_name  bac  error_code | error_text  status  priority
summary  summary_mode(append|replace)  accept  record_id | url  duplicate_of
close{substatus, dealer_account, dealer_code | not_related_to_dealer, resolution}
```

## Behaviour worth knowing

- **Diff first.** Current values are read before editing; fields already correct are skipped, and an SR with
  nothing to change returns NOCHANGE without a Save.
- **Summary appends.** SR Summary Detail holds dated entries. The paragraph gets today's `[MM/DD/YY]` and is appended
  unless the same text is already there. `summary_mode: "replace"` overrides.
- **Validation before browser.** Picklist values, Inquiry Type / SubType dependency, VIN shape. Bad records are
  SKIPped with the reason; a dry run with only bad records never opens a browser.
- **Ownership.** `accept` clicks Accept and confirms Yes (form) or sets OwnerId when the owner is a queue (REST).
  Whether to accept is read from the **Owner field** (`--owner-name`, default Eric Durrant); the Accept/Transfer
  buttons stay visible after ownership so they prove nothing. Defaults to false when the verdict is NEEDS REVIEW.
- **Closed records are never written.** Status is re-read right before writing (a colleague closed SR00418861 mid-fill
  on 09-28 and that fill was lost).
- **Closing** only happens when the record carries a `close` block: `substatus` (Completed | No_Response | Duplicate |
  IncorrectlySubmitted), `dealer_account` + `dealer_code` (or `not_related_to_dealer: true`), `resolution`. It drives
  the More -> Close Request flow; Status cannot be set to Closed directly and "Waiting on Internal Team" needs an
  Internal Support Request first. `duplicate_of` defaults the sub-status to Duplicate and the resolution text.
- **Session.** A second tab parked on Home pings every 5 minutes and is never navigated; that is what kept the SAML
  session alive for four hours on 09-28. The header global search (real keystrokes) is the fallback when an SR is not
  in the queue or Recent list, which is the case for same-day closures.
- **Lookups** are typed with real key presses; shorthand (PEN, FIE, Reynolds) is normalised to the Account names
  that resolve. The chosen name is logged.
- **Never Description.** The summary goes only into the SR Summary Detail textarea.
- **Caches.** `state\sr_ids.json` (SR to record id, so the queue is scanned once), `state\accounts.json`,
  `state\sf_describe_cache.json` (also used for offline validation).
- **Session.** One warm browser for the whole watch session; keep-alive injected; re-login is awaited if SSO expires.
  Lightning hiccups are retried once.

`EMORYSF_HOME` moves the working folder. `--cdp http://127.0.0.1:9222` attaches to an already-running browser.
