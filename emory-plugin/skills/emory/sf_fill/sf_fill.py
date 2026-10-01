#!/usr/bin/env python
"""
sf_fill.py - fill Safe-Guard Salesforce Support Requests (SRs) from Emory verdicts, with zero model tokens.

Part of the `emory` skill (~/.claude/skills/emory/sf_fill/).  Working data lives in %USERPROFILE%\\Downloads\\EmorySF
(override with EMORYSF_HOME):  inbox/  done/  failed/  state/  sf_fill_log.csv  last_run.md

How it fits Emory
  Emory's verdict JSON carries a `salesforce` block (see references/verdict_and_delivery.md).  emory_post.ps1 drops
  that block into EmorySF\\inbox\\<SR>.json every time it runs.  This script (in --watch mode, or run by hand) picks
  the files up, fills the SR and moves them to done/ or failed/.  Emory never drives the SR form itself again.

What it knows about the SR page (verified by hand 2026-09-25/28)
  * Lightning shadow-DOM; Playwright locators pierce it.  "Accept" takes ownership from the queue.
  * Any "Edit <Field>" pencil opens inline edit for the whole record; one Save commits all fields.
  * Picklists: button[role=combobox][aria-label=Label] -> [role=listbox] -> [role=option].
    Inquiry SubType is DEPENDENT on Inquiry Type (Rating -> Portal Rating Issue | LGY | EAS | Roadrunner).
  * SR Category is a dual listbox (click in Available, then "Move selection to Chosen").
  * VIN / Dealer Number / Dealer Name / BAC are inputs named VIN__c / Dealer_Number__c / Dealer_Name__c / BAC__c.
  * SR Summary Detail is a plain <textarea> holding DATED entries ([MM/DD/YY] ...) - we APPEND, never overwrite.
  * Description is a rich-text editor with the partner's original email - NEVER written (09-28 leaked into it).
  * Integration Partner / Aggregator are Account lookups that only populate on real key presses.
  * Accept/Transfer/Resolved buttons stay visible after ownership - ownership is read from the Owner field.
    Accept -> confirm Yes -> Owner = analyst, Status New -> In Progress.
  * Status cannot be set to Closed on the record ("use Close Support Request"); closing is the More -> Close Request
    Flow (sub-status, Dealer Account lookup or "not related to a dealership", Resolution Details).  Only done when
    the record carries a `close` block.  Records already Closed are never written (a colleague closed SR00418861
    mid-fill on 09-28 and the fill was lost - we re-read right before writing).
  * The SAML session dies on a Friday->Monday gap and mid-run; a DEDICATED tab parked on Home pinging every 5 min
    kept it alive for 4 h.  The header global search works with real keystrokes; list-view search does not find
    same-day closures.

Back ends (chosen automatically): REST with the browser session cookie when the profile is API-enabled
(one PATCH per SR, values validated against describe()), otherwise the same Playwright window drives the form.

Usage
  python sf_fill.py --watch                              run forever: process EmorySF\\inbox\\*.json as they land
  python sf_fill.py verdict.json [more.json | dir/]      fill from Emory verdict JSON(s) or fill-record JSON(s)
  python sf_fill.py file.json --sr SR00418301 --dry-run  validate + plan only (nothing saved)
  python sf_fill.py --from-md Emory_Queue_Run_2026-09-25.md --out queue.json
  python sf_fill.py --discover                           dump fields/picklists/dependent map to state/sf_describe_cache.json

Login: the script opens Edge on its own profile (%LOCALAPPDATA%\\EmorySF\\profile).  Sign in through SSO once in
that window; the script waits and never types credentials.
"""
from __future__ import annotations

import argparse
import base64
import csv
import datetime as dt
import difflib
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

LIGHTNING = "https://safe-guardproducts.lightning.force.com"
MY_DOMAIN = "https://safe-guardproducts.my.salesforce.com"
QUEUE_LIST = LIGHTNING + "/lightning/o/Support_Request__c/list?filterName=IT_Client_Support_SR_API_All_Open"
RECENT_LIST = LIGHTNING + "/lightning/o/Support_Request__c/list?filterName=Recent"
HOME_URL = LIGHTNING + "/lightning/page/home"
API_VER = "v61.0"
SOBJECT = "Support_Request__c"
DEFAULT_USER = "edurrant@sgintl.com"
DEFAULT_OWNER_NAME = "Eric Durrant"      # what the Owner field shows once the SR is ours (Accept/Transfer buttons
                                         # stay visible after ownership, so button presence means nothing)
CLOSE_SUBSTATUS = ["Completed", "No_Response", "Duplicate", "IncorrectlySubmitted"]
KEEPALIVE_MIN = 5                        # a dedicated tab parked on /lightning/page/home, never navigated, pinging
                                         # every 5 min gave zero logouts in ~4 h on 09-28 (10-min in-page timer did not)

WORK = Path(os.environ.get("EMORYSF_HOME", str(Path.home() / "Downloads" / "EmorySF")))
INBOX, DONE, FAILED, STATE = WORK / "inbox", WORK / "done", WORK / "failed", WORK / "state"
PROFILE_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "EmorySF" / "profile"
DESCRIBE_CACHE = STATE / "sf_describe_cache.json"
SR_IDS = STATE / "sr_ids.json"          # SR number -> record id (saves the queue scan next time)
ACCOUNTS = STATE / "accounts.json"      # lookup name -> Account Id (REST)
FILLED = STATE / "filled.json"          # SR -> last fill result (Emory reads this to avoid redoing work)
LOG_CSV = WORK / "sf_fill_log.csv"
LAST_RUN = WORK / "last_run.md"

FIELD_LABELS = {
    "brand": "Brand", "inquiry_type": "Inquiry Type", "inquiry_subtype": "Inquiry SubType",
    "sr_category": "SR Category", "summary": "SR Summary Detail", "vin": "VIN",
    "dealer_number": "Dealer Number", "dealer_name": "Dealer Name", "bac": "BAC #:",
    "integration_partner": "Integration Partner", "aggregator": "Aggregator",
    "error_code": "Error Code", "status": "Status", "priority": "Priority",
}
KNOWN_API_NAMES = {"vin": "VIN__c", "dealer_number": "Dealer_Number__c", "dealer_name": "Dealer_Name__c", "bac": "BAC__c"}
LOOKUP_KEYS = ("integration_partner", "aggregator")
PICKLIST_KEYS = ("brand", "inquiry_type", "inquiry_subtype", "error_code", "status", "priority")
TEXT_KEYS = ("vin", "dealer_number", "dealer_name", "bac")
DATA_KEYS = PICKLIST_KEYS + TEXT_KEYS + LOOKUP_KEYS + ("sr_category", "summary")

# Values read live off the SR form on 2026-09-28.  REST mode replaces them with describe(); a cached describe
# (state/sf_describe_cache.json) is used for offline validation when present.
LIVE_PICKLISTS = {
    "Inquiry Type": ["Cancellations", "Claims", "Marketing Materials", "Other", "Portal Credentials", "Contracting",
                     "Enrollment", "Rating", "Billing/Payments", "Reporting", "Classing", "VIN", "File Processing",
                     "Form Setup", "Dealer Activation", "Dealer Inquiry/Troubleshooting", "Program Inquiry",
                     "Production Bug"],
    "Brand": ["Hyundai", "GM", "Honda", "Agent", "Aston Martin", "BMW", "Ford", "JLR", "Marine Max", "Mazda",
              "Mercedes", "MVP", "PBL", "Subaru", "Toyota", "VCI", "NVR", "NonAuto", "Lithia", "Amazon"],
    "SR Category": ["Account Configuration", "Adjustment", "All Integration Partners", "API Error", "API Whitelist",
                    "Application Bug", "BI Access", "BI Defect", "BI Enhancement", "BI Request", "Bucket Mismatch",
                    "Cancellation", "Claim Status", "Classing - EAS", "Classing - LGY", "CMS Rights",
                    "Contract Remittance", "Contract Update", "Coverage Missing", "Data Load", "DB Update - EAS",
                    "DB Update - PG", "Dealer Enrollment", "eContracting Setup", "File Processing", "Form Setup",
                    "Lock date update", "Marketing Material", "Mobile", "Model Missing/Incorrect",
                    "New/Missing Product", "New Feature", "Not Able To Replicate", "Payment Type", "Permission Error",
                    "PPM", "Proactive Action", "Rating - EAS", "Rating - LGY", "Reconciliation", "Reports",
                    "Setup New/Missing Benefit", "Solutioning", "Training Issue", "UI Issues", "User management",
                    "VIN - EAS", "VIN - LGY", "Mulesoft", "RoadRunner", "Split Percentage Issue"],
    "Status": ["New", "In Progress", "Waiting on Internal Team", "Waiting on Client", "Closed"],
    "Error Code": ["404 SSO Error", "OKTA 400 Error", "Oops! Failed to login, please contact your administrator",
                   "Dealer is not enrolled", "Other", "400 - Request Validation Error", "400 - Unable to decode VIN",
                   "400 - modelId cannot be null", "400 - PDF Template is not available",
                   "400 - Sell does not have permission to update contract", "400 - Form Combination does not exist",
                   "400 - Cannot Update Contract in REMIT State", "400 - Cannot Remit Voided Contract",
                   "400 - Classing not found for Dealer", "401 - Unauthorized",
                   "403 - User is not authorized to access this resource with an explicit deny",
                   "404 - VIN Detail not Found", "404 - Dealer Data not Found", "404 - No Product Class Found",
                   "404 - Dealer not assigned Product", "404 - Dealer Not Found", "404 - Form Not Found",
                   "404 - Contract Not Found", "405 - Method Not Allowed", "500 - Error fetching Rates",
                   "500 - Backend Response Null/Empty", "500 - Internal Error",
                   "500 - Application Error: Can't Save Contract", "500 - Application Error: Can't Update Contract",
                   "502 - Bad Gateway", "503 - Service Unavailable"],
}
LIVE_SUBTYPES = {
    "Rating": ["Portal Rating Issue", "LGY", "EAS", "Roadrunner"],
    "Dealer Activation": ["Dealer Product/Eligibility Inquiry", "Dealer ID Request"],
    "Program Inquiry": ["SG Team Inquiry", "Partner Request"],
    "Classing": ["EAS", "LGY"],
}
BRAND_BY_PREFIX = [
    (r"^(AU|VW|POR?S|VWFS)", "VCI"), (r"^(HPP|HYU|GPP|GEN)", "Hyundai"), (r"^(GMF|CB|GM)", "GM"),
    (r"^00S|^0LD", "Agent"), (r"^HON|^ACU", "Honda"), (r"^BMW|^MINI|^D\d", "BMW"), (r"^(JAG|LR|JLR)", "JLR"),
    (r"^MB|^MERZ", "Mercedes"), (r"^SUB", "Subaru"), (r"^TOY|^LEX", "Toyota"), (r"^MAZ", "Mazda"),
    (r"^FORD|^LINC", "Ford"), (r"^NCG", "NVR"), (r"^YM", "NonAuto"),
]
# Account names confirmed to resolve in the lookups (09-28), plus the shorthand Emory tends to write.
LOOKUP_ALIASES = {
    "pen": "Provider Exchange Network", "provider exchange": "Provider Exchange Network",
    "provider exchange network (pen)": "Provider Exchange Network", "pcmi": "PCMI Corporation",
    "pcmi corporation (pcrs)": "PCMI Corporation", "pcrs": "PCMI Corporation", "f&i express": "F&I Express",
    "fi express": "F&I Express", "fie": "F&I Express", "reynolds & reynolds": "Reynolds and Reynolds",
    "reynolds": "Reynolds and Reynolds", "darwin": "Darwin Menu", "routeone": "RouteOne Menu / MaximTrak",
    "routeone menu": "RouteOne Menu / MaximTrak", "maximtrak": "RouteOne Menu / MaximTrak", "line 5": "Line5",
}


# ------------------------------------------------------------------------------------------------ utils
def log(msg: str) -> None:
    print(dt.datetime.now().strftime("%H:%M:%S"), msg, flush=True)


def today_tag() -> str:
    return dt.date.today().strftime("[%m/%d/%y]")


def norm(s) -> str:
    return re.sub(r"\s+", " ", str(s or "")).strip().lower()


def split_multi(v) -> list[str]:
    if not v:
        return []
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    return [x.strip() for x in re.split(r"[;|]", str(v)) if x.strip()]


def canon_lookup(name: str) -> str:
    return LOOKUP_ALIASES.get(norm(name), str(name or "").strip())


def brand_from_code(code: str) -> str | None:
    for pat, brand in BRAND_BY_PREFIX:
        if re.match(pat, str(code or "").upper()):
            return brand
    return None


def closest(value: str, options: list[str], n: int = 3) -> list[str]:
    return difflib.get_close_matches(value, options, n=n, cutoff=0.4)


def error_code_from_text(text: str, options: list[str]) -> str | None:
    """Map an API error string to the Error Code picklist; only returns a confident match."""
    if not text:
        return None
    t = norm(text)
    code = re.search(r"\b(4\d\d|5\d\d)\b", t)
    cands = [o for o in options if not code or o.startswith(code.group(1))]
    best, score = None, 0.0
    for o in cands:
        tail = norm(re.sub(r"^\d{3}\s*-\s*", "", o))
        s = difflib.SequenceMatcher(None, tail, t).ratio()
        if tail and tail in t:
            s = max(s, 0.95)
        if s > score:
            best, score = o, s
    return best if score >= 0.6 else None


def read_json(p: Path, default):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return default


def write_json(p: Path, data) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=1, ensure_ascii=False), encoding="utf-8")


def append_log(row: dict) -> None:
    LOG_CSV.parent.mkdir(parents=True, exist_ok=True)
    new = not LOG_CSV.exists()
    with LOG_CSV.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["when", "sr", "mode", "result", "seconds", "fields", "note"])
        if new:
            w.writeheader()
        w.writerow(row)


def remember(sr: str, **info) -> None:
    d = read_json(FILLED, {})
    d[sr] = {"when": dt.datetime.now().isoformat(timespec="seconds"), **info}
    write_json(FILLED, d)


def merge_summary(existing: str, new: str, mode: str) -> str | None:
    """Dated entries accumulate in SR Summary Detail.  Returns the text to save, or None when nothing to do."""
    existing = (existing or "").strip()
    if mode == "replace" or not existing:
        return None if existing == new.strip() else new
    key = re.sub(r"^\[\d\d/\d\d/\d\d\]\s*", "", new)[:60]
    if key and key in existing:
        return None
    return existing + "\n\n" + new


# ---------------------------------------------------------------------------------------- input handling
def normalise(raw: dict, source: str) -> dict | None:
    """Accept a fill record, or an Emory verdict JSON carrying a `salesforce` block."""
    rec = dict(raw.get("salesforce") or {}) if isinstance(raw.get("salesforce"), dict) else dict(raw)
    sr_src = rec.get("sr") or rec.get("sr_number") or raw.get("sr") or ""
    m = re.search(r"SR00\d{6}", str(sr_src).upper())
    if not m:
        log(f"{source}: no SR number in '{str(sr_src)[:60]}' (INC-only tickets live in ServiceNow) - skipped")
        return None
    rec["sr"] = m.group(0)
    rec["_source"] = source
    verdict = str(raw.get("verdict") or rec.get("verdict") or "").upper()
    if "accept" not in rec:
        rec["accept"] = verdict != "NEEDS REVIEW"
    if not rec.get("record_id"):
        url = str(rec.get("url") or raw.get("sr_url") or "")
        mm = re.search(r"/lightning/r/(?:Support_Request__c/)?(a03[A-Za-z0-9]{12,15})", url)
        if mm:
            rec["record_id"] = mm.group(1)
    if rec.get("summary"):
        s = rec["summary"].strip()
        if rec.get("duplicate_of") and rec["duplicate_of"] not in s:
            s += f" Duplicate of {rec['duplicate_of']}."
        rec["summary"] = s if s.startswith("[") else f"{today_tag()} {s}"
    rec.setdefault("summary_mode", "append")
    if isinstance(rec.get("close"), dict):
        c = rec["close"]
        c["substatus"] = str(c.get("substatus") or ("Duplicate" if rec.get("duplicate_of") else "Completed")).replace(" ", "")
        if not c.get("resolution"):
            c["resolution"] = (f"Duplicate of {rec['duplicate_of']}." if rec.get("duplicate_of") else
                               re.sub(r"^\[\d\d/\d\d/\d\d\]\s*", "", rec.get("summary") or ""))
        c.setdefault("dealer_account", rec.get("dealer_name"))
        c.setdefault("dealer_code", rec.get("dealer_number"))
        c.setdefault("not_related_to_dealer", False)
    if not rec.get("brand") and rec.get("dealer_number"):
        b = brand_from_code(rec["dealer_number"])
        if b:
            rec["brand"], rec["_brand_inferred"] = b, True
    for k in LOOKUP_KEYS:
        if rec.get(k):
            rec[k] = canon_lookup(rec[k])
    rec["sr_category"] = split_multi(rec.get("sr_category"))
    if rec.get("error_text") and not rec.get("error_code"):
        ec = error_code_from_text(rec["error_text"], LIVE_PICKLISTS["Error Code"])
        if ec:
            rec["error_code"], rec["_error_code_inferred"] = ec, True
    return rec


def load_inputs(paths: list[Path]) -> list[tuple[dict, Path]]:
    out = []
    files: list[Path] = []
    for p in paths:
        files += sorted(p.glob("*.json")) if p.is_dir() else [p]
    for f in files:
        data = read_json(f, None)
        if data is None:
            log(f"{f.name}: not valid JSON - skipped")
            continue
        items = data["records"] if isinstance(data, dict) and "records" in data else (data if isinstance(data, list) else [data])
        for i, raw in enumerate(items):
            rec = normalise(raw, f"{f.name}#{i}" if len(items) > 1 else f.name)
            if rec:
                out.append((rec, f))
    return out


def parse_queue_md(path: Path) -> list[dict]:
    """Convert an Emory queue-run markdown file (## SR00xxxxxx — Dealer (CODE) — ... blocks) to records."""
    text = path.read_text(encoding="utf-8")
    recs = []
    for b in re.split(r"\n(?=## SR00\d{6})", text):
        m = re.match(r"## (SR00\d{6})(?P<rest>[^\n]*)", b)
        if not m:
            continue
        head = m.group("rest")
        rec = {"sr": m.group(1)}
        dm = re.search(r"—\s*(?P<name>[^—(]+?)\s*\((?P<codes>[A-Z0-9]{6,10}(?:\s*/\s*[A-Z0-9]{6,10})*)\)", head)
        if dm:
            rec["dealer_name"] = dm.group("name").strip()
            rec["dealer_number"] = re.split(r"\s*/\s*", dm.group("codes"))[0]
        else:
            nm = re.search(r"—\s*(?P<name>[^—]+?)\s*—", head)
            if nm:
                rec["dealer_name"] = nm.group("name").strip()
        dup = re.search(r"\+ dup (SR00\d{6})", head)
        if dup:
            rec["_duplicates_folded"] = dup.group(1)
        if "**Decision needed**" in head:
            rec["verdict"] = "NEEDS REVIEW"

        def grab(label):
            mm = re.search(label + r":\s*([^·\n]+)", b)
            return mm.group(1).strip() if mm else None

        rec["integration_partner"] = grab("Integration Partner")
        rec["aggregator"] = grab("Aggregator")
        rec["inquiry_type"] = grab("Inquiry Type")
        sub = grab("Sub-Type")
        if sub:
            rec["inquiry_subtype_suggested"] = re.sub(r"\s*\(verify\)\s*$", "", sub)
        cat = grab("SR Category")
        if cat:
            rec["sr_category"] = split_multi(cat)
        sm = re.search(r"SR Summary Detail:\s*\n(.+?)(?:\n\n|\Z)", b, re.S)
        if sm:
            rec["summary"] = re.sub(r"^\[\d\d/\d\d/\d\d\]\s*", "", sm.group(1).strip())
        vm = re.search(r"\b([A-HJ-NPR-Z0-9]{17})\b", rec.get("summary", ""))
        if vm:
            rec["vin"] = vm.group(1)
        recs.append(rec)
    return recs


def validate(rec: dict, picklists: dict, subtypes: dict) -> list[str]:
    probs = []
    for key in ("brand", "inquiry_type", "status", "priority", "error_code"):
        v = rec.get(key)
        opts = picklists.get(FIELD_LABELS[key])
        if v and opts and v not in opts:
            probs.append(f"{FIELD_LABELS[key]} '{v}' is not a picklist value; closest: {closest(v, opts)}")
    it, st = rec.get("inquiry_type"), rec.get("inquiry_subtype")
    if st:
        allowed = subtypes.get(it)
        if allowed is not None and st not in allowed:
            probs.append(f"Inquiry SubType '{st}' not valid for '{it}'; allowed: {allowed}")
        elif allowed is None and it:
            probs.append(f"Inquiry SubType '{st}' unverified: dependent values for '{it}' unknown (run --discover)")
    cats = picklists.get("SR Category")
    for c in rec.get("sr_category", []):
        if cats and c not in cats:
            probs.append(f"SR Category '{c}' is not a value; closest: {closest(c, cats)}")
    if rec.get("vin") and not re.fullmatch(r"[A-HJ-NPR-Z0-9]{17}", rec["vin"]):
        probs.append(f"VIN '{rec['vin']}' is not 17 valid chars")
    if rec.get("summary") and len(rec["summary"]) > 32000:
        probs.append("summary longer than 32,000 chars")
    if rec.get("inquiry_subtype_suggested") and not rec.get("inquiry_subtype"):
        probs.append(f"Sub-Type '{rec['inquiry_subtype_suggested']}' is a description, not a picklist value; "
                     f"known sets: {subtypes}")
    if rec.get("status") == "Closed":
        probs.append("Status cannot be set to Closed directly (Salesforce says 'use Close Support Request'); use a `close` block")
    if rec.get("status") == "Waiting on Internal Team":
        probs.append("Status 'Waiting on Internal Team' needs an Internal Support Request on the Related Request tab first")
    c = rec.get("close")
    if c:
        if c["substatus"] not in CLOSE_SUBSTATUS:
            probs.append(f"close.substatus '{c['substatus']}' not in {CLOSE_SUBSTATUS}")
        if not c.get("resolution"):
            probs.append("close.resolution (Resolution Details) is required")
        if not c.get("dealer_account") and not c.get("not_related_to_dealer"):
            probs.append("close needs dealer_account (Account name) or not_related_to_dealer: true")
    if not any(rec.get(k) for k in DATA_KEYS) and not rec.get("accept") and not c:
        probs.append("record has nothing to set")
    return probs


def picklists_for_validation() -> tuple[dict, dict]:
    cache = read_json(DESCRIBE_CACHE, None)
    if cache and cache.get("picklists"):
        pl = dict(LIVE_PICKLISTS); pl.update(cache["picklists"])
        st = dict(LIVE_SUBTYPES); st.update(cache.get("inquiry_subtype_by_type") or {})
        return pl, st
    return LIVE_PICKLISTS, LIVE_SUBTYPES


# ------------------------------------------------------------------------------------------------ browser
def open_browser(pw, cdp: str | None):
    if cdp:
        browser = pw.chromium.connect_over_cdp(cdp)
        return browser, (browser.contexts[0] if browser.contexts else browser.new_context())
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    last = None
    for channel in ("msedge", "chrome", None):
        try:
            kw = dict(user_data_dir=str(PROFILE_DIR), headless=False, no_viewport=True, args=["--start-maximized"])
            if channel:
                kw["channel"] = channel
            return None, pw.chromium.launch_persistent_context(**kw)
        except Exception as e:  # noqa: BLE001
            last = e
    sys.exit(f"could not launch a browser: {last}\nTry: python -m playwright install chromium")


def logged_in(page) -> bool:
    u = page.url
    return "lightning.force.com/lightning/" in u and "login" not in u and "saml" not in u


def wait_for_login(page, timeout_s: int = 600) -> None:
    if not logged_in(page):
        page.goto(QUEUE_LIST, wait_until="domcontentloaded")
    t0, told = time.time(), False
    while time.time() - t0 < timeout_s:
        if logged_in(page):
            page.wait_for_timeout(1500)
            return
        if not told:
            log("Salesforce wants a sign-in. Complete SSO in the Edge window; waiting (no credentials typed here).")
            told = True
        page.wait_for_timeout(2000)
    raise RuntimeError("timed out waiting for the Salesforce login")


def install_keepalive(page, minutes: int = KEEPALIVE_MIN) -> None:
    page.evaluate("""(ms) => { if (window.__emoryKeepAlive) return;
      window.__emoryKeepAlive = setInterval(() => fetch(location.origin + '/services/data/?_ka=' + Date.now(),
        {credentials:'include', cache:'no-store', redirect:'manual'})
        .then(r => { if (r.type === 'opaqueredirect' || r.status === 0) console.warn('[sf_fill keep-alive] SESSION GONE'); })
        .catch(()=>{}), ms); }""", minutes * 60000)


def open_keepalive_tab(ctx):
    """A second tab parked on Home that is never navigated - the 09-28 session found this is what actually keeps
    the SAML session alive (a timer in the working tab dies on every full navigation)."""
    tab = ctx.new_page()
    tab.goto(HOME_URL, wait_until="domcontentloaded")
    tab.wait_for_timeout(2500)
    install_keepalive(tab)
    return tab


# --------------------------------------------------------------------------------------------------- REST
class Rest:
    def __init__(self, sid: str, user: str):
        import requests
        self.s = requests.Session()
        self.s.headers.update({"Authorization": "Bearer " + sid, "Content-Type": "application/json"})
        self.base = f"{MY_DOMAIN}/services/data/{API_VER}"
        self.user = user
        self.by_label: dict[str, dict] = {}
        self.picklists: dict[str, list[str]] = {}
        self.subtypes: dict[str, list[str]] = {}
        self.me: str | None = None
        self.accounts = read_json(ACCOUNTS, {})

    def probe(self) -> bool:
        r = self.s.get(f"{self.base}/sobjects/{SOBJECT}/describe", timeout=30)
        if r.status_code != 200:
            log(f"REST not available with this session ({r.status_code}); using the form")
            return False
        self._index(r.json()["fields"])
        write_json(DESCRIBE_CACHE, {
            "fetched": dt.datetime.now().isoformat(timespec="seconds"),
            "fields": {f["label"]: {"name": f["name"], "type": f["type"], "updateable": f["updateable"],
                                    "referenceTo": f.get("referenceTo", [])} for f in r.json()["fields"]},
            "picklists": self.picklists, "inquiry_subtype_by_type": self.subtypes})
        log(f"REST ok - {len(self.by_label)} fields, describe cached")
        return True

    def _index(self, fields: list[dict]):
        self.by_label = {f["label"]: f for f in fields}
        for f in fields:
            if f["type"] in ("picklist", "multipicklist"):
                self.picklists[f["label"]] = [v["value"] for v in f["picklistValues"] if v["active"]]
        sub = self.by_label.get("Inquiry SubType")
        if sub and sub.get("controllerName"):
            ctrl = next(f for f in fields if f["name"] == sub["controllerName"])
            ctrl_vals = [v["value"] for v in ctrl["picklistValues"]]
            dep: dict[str, list[str]] = {}
            for v in sub["picklistValues"]:
                if not v.get("validFor"):
                    continue
                bits = base64.b64decode(v["validFor"])
                for i, cv in enumerate(ctrl_vals):
                    if i // 8 < len(bits) and bits[i // 8] & (0x80 >> (i % 8)):
                        dep.setdefault(cv, []).append(v["value"])
            self.subtypes = dep

    def api_name(self, key: str) -> str:
        f = self.by_label.get(FIELD_LABELS[key])
        n = f["name"] if f else KNOWN_API_NAMES.get(key)
        if not n:
            raise ValueError(f"describe() has no field labelled '{FIELD_LABELS[key]}'")
        return n

    def query(self, soql: str) -> list[dict]:
        r = self.s.get(f"{self.base}/query", params={"q": soql}, timeout=30)
        r.raise_for_status()
        return r.json()["records"]

    def my_id(self) -> str:
        if not self.me:
            rows = self.query(f"SELECT Id FROM User WHERE Username = '{self.user}' LIMIT 1")
            if not rows:
                raise ValueError(f"no User with Username {self.user}; pass --user")
            self.me = rows[0]["Id"]
        return self.me

    def find_account(self, name: str) -> str:
        if name in self.accounts:
            return self.accounts[name]
        esc = name.replace("\\", "\\\\").replace("'", "\\'")
        rows = self.query(f"SELECT Id, Name FROM Account WHERE Name = '{esc}' LIMIT 5") or \
            self.query(f"SELECT Id, Name FROM Account WHERE Name LIKE '%{esc}%' LIMIT 10")
        if not rows:
            raise ValueError(f"no Account matches '{name}'")
        exact = [r for r in rows if norm(r["Name"]) == norm(name)]
        pick = exact[0] if len(exact) == 1 else (rows[0] if len(rows) == 1 else None)
        if not pick:
            raise ValueError(f"'{name}' is ambiguous: {[r['Name'] for r in rows]}")
        self.accounts[name] = pick["Id"]
        write_json(ACCOUNTS, self.accounts)
        return pick["Id"]

    def fill(self, rec: dict, dry: bool) -> tuple[str, str]:
        names = {k: self.api_name(k) for k in DATA_KEYS if rec.get(k)}
        status_f = self.api_name("status")
        fields = ["Id", "Name", "OwnerId", status_f] + [n for n in names.values() if n != status_f]
        rows = self.query(f"SELECT {', '.join(fields)} FROM {SOBJECT} WHERE Name = '{rec['sr']}' LIMIT 1")
        if not rows:
            return "FAIL", "SR not found"
        cur = rows[0]
        ids = read_json(SR_IDS, {}); ids[rec["sr"]] = cur["Id"]; write_json(SR_IDS, ids)
        if str(cur.get(status_f) or "") == "Closed":      # a colleague may have closed it meanwhile (SR00418861, 09-28)
            return "SKIP", "record is Closed - not writing"
        payload, skipped = {}, []
        for key, n in names.items():
            if key == "sr_category":
                want = set(rec[key]); have = set(split_multi(cur.get(n)))
                if want - have:
                    payload[n] = ";".join(sorted(have | want))
                else:
                    skipped.append(key)
            elif key == "summary":
                merged = merge_summary(cur.get(n) or "", rec[key], rec.get("summary_mode", "append"))
                if merged is None:
                    skipped.append(key)
                else:
                    payload[n] = merged
            elif key in LOOKUP_KEYS:
                acc = self.find_account(rec[key])
                if cur.get(n) != acc:
                    payload[n] = acc
                else:
                    skipped.append(key)
            elif str(cur.get(n) or "") != str(rec[key]):
                payload[n] = rec[key]
            else:
                skipped.append(key)
        if rec.get("accept") and str(cur["OwnerId"]).startswith("00G"):   # owned by a queue -> take it
            payload["OwnerId"] = self.my_id()
        if not payload:
            return "NOCHANGE", f"already matches ({len(skipped)} fields)"
        if dry:
            return "DRY", "would PATCH " + ", ".join(payload) + (f"; unchanged: {skipped}" if skipped else "")
        r = self.s.patch(f"{self.base}/sobjects/{SOBJECT}/{cur['Id']}", data=json.dumps(payload), timeout=60)
        if r.status_code not in (200, 204):
            return "FAIL", f"{r.status_code} {r.text[:300]}"
        back = self.s.get(f"{self.base}/sobjects/{SOBJECT}/{cur['Id']}", params={"fields": ",".join(payload)}, timeout=30).json()
        bad = [k for k, v in payload.items() if str(back.get(k) or "") != str(v)]
        return ("OK" if not bad else "PARTIAL"), (f"set {len(payload)} fields" + (f", unchanged {len(skipped)}" if skipped else "")
                                                   if not bad else f"mismatch after save: {bad}")


# ----------------------------------------------------------------------------------------------------- UI
READ_JS = """
(function(){
  function all(root, sel, out){ out=out||[]; for (const el of root.querySelectorAll('*')) {
    if (el.matches && el.matches(sel)) out.push(el); if (el.shadowRoot) all(el.shadowRoot, sel, out);} return out; }
  const res = {};
  for (const f of all(document, 'record_flexipage-record-field, records-record-layout-item')) {
    const lab = all(f, '.slds-form-element__label, label, .test-id__field-label').map(x => x.textContent.trim()).find(Boolean);
    if (!lab || res[lab] !== undefined) continue;
    const ta = all(f, 'textarea')[0];
    let txt = ta ? ta.value : (f.innerText || '');
    txt = txt.replace(/\\s+/g, ' ').trim();
    if (txt.startsWith(lab)) txt = txt.slice(lab.length).trim();
    res[lab] = txt.replace(/\\bEdit [A-Za-z #:/]+$/, '').replace(/\\bPreview\\b/g, '').trim().slice(0, 4000);
  }
  res.__accept = all(document, 'button').some(b => b.textContent.trim() === 'Accept');
  const path = all(document, '.slds-path__item.slds-is-current, .slds-path__item.slds-is-active').map(e => e.innerText.trim())[0];
  if (path && !res.Status) res.Status = path.replace(/^Current Stage:\\s*/i, '');
  return res;
})()
"""


class Ui:
    def __init__(self, page, user: str, owner_name: str = DEFAULT_OWNER_NAME):
        self.page, self.user, self.owner_name = page, user, owner_name

    def global_search(self, sr: str) -> str | None:
        """Header global search works with a real click + keystrokes (found SR00418956 after it left the queue on 09-28)."""
        p = self.page
        try:
            p.goto(HOME_URL, wait_until="domcontentloaded")
            p.wait_for_timeout(2500)
            box = p.get_by_role("button", name=re.compile(r"^Search", re.I))
            if box.count():
                box.first.click()
            inp = p.get_by_role("combobox", name=re.compile(r"Search", re.I)).first
            inp.wait_for(timeout=8000)
            inp.click()
            inp.press_sequentially(sr, delay=40)
            hit = p.get_by_role("option").filter(has_text=sr)
            hit.first.wait_for(timeout=8000)
            hit.first.click()
            for _ in range(20):
                p.wait_for_timeout(500)
                m = re.search(r"/lightning/r/(?:Support_Request__c/)?(a03[A-Za-z0-9]{12,15})/", p.url)
                if m:
                    return f"{LIGHTNING}/lightning/r/{SOBJECT}/{m.group(1)}/view"
        except Exception as e:  # noqa: BLE001
            log(f"{sr}: global search did not resolve ({type(e).__name__})")
        return None

    def find_record_url(self, sr: str, extra_lists: list[str]) -> str | None:
        ids = read_json(SR_IDS, {})
        if sr in ids:
            return f"{LIGHTNING}/lightning/r/{SOBJECT}/{ids[sr]}/view"
        p = self.page
        for url in [QUEUE_LIST, RECENT_LIST] + extra_lists:
            p.goto(url, wait_until="domcontentloaded")
            p.wait_for_timeout(3500)
            # cache every SR link on the page while we are here
            hrefs = p.evaluate("""() => { function all(r,s,o){o=o||[];for(const e of r.querySelectorAll('*')){if(e.matches&&e.matches(s))o.push(e);if(e.shadowRoot)all(e.shadowRoot,s,o);}return o;}
              return all(document,'a').filter(a=>/^SR00\\d{6}$/.test(a.textContent.trim())).map(a=>[a.textContent.trim(),a.getAttribute('href')]); }""")
            for _ in range(8):
                for name, href in hrefs:
                    m = re.search(r"/(a03[A-Za-z0-9]{12,15})/", href or "")
                    if m:
                        ids[name] = m.group(1)
                if sr in ids:
                    write_json(SR_IDS, ids)
                    return f"{LIGHTNING}/lightning/r/{SOBJECT}/{ids[sr]}/view"
                p.mouse.wheel(0, 2500)
                p.wait_for_timeout(700)
                hrefs = p.evaluate("""() => { function all(r,s,o){o=o||[];for(const e of r.querySelectorAll('*')){if(e.matches&&e.matches(s))o.push(e);if(e.shadowRoot)all(e.shadowRoot,s,o);}return o;}
                  return all(document,'a').filter(a=>/^SR00\\d{6}$/.test(a.textContent.trim())).map(a=>[a.textContent.trim(),a.getAttribute('href')]); }""")
        write_json(SR_IDS, ids)
        url = self.global_search(sr)          # closed / same-day records are not in the list views
        if url:
            ids[sr] = url.rsplit("/", 2)[-2]
            write_json(SR_IDS, ids)
        return url

    # ---- primitives, each mirroring a step that worked by hand on 2026-09-28
    def read(self) -> dict:
        self.page.wait_for_timeout(1200)
        return self.page.evaluate(READ_JS)

    def in_edit(self) -> bool:
        return self.page.get_by_role("button", name="Save", exact=True).count() > 0

    def click_edit(self):
        p = self.page
        if self.in_edit():
            return
        for label in ("Edit Inquiry Type", "Edit Brand", "Edit SR Category"):
            b = p.get_by_role("button", name=label)
            if b.count():
                b.first.click()
                p.get_by_role("button", name="Save", exact=True).first.wait_for(timeout=15000)
                p.wait_for_timeout(1200)
                return
        raise RuntimeError("no inline Edit pencil found on the record")

    def accept(self) -> bool:
        """Accept -> confirm Yes -> Owner = analyst, Status New -> In Progress."""
        p = self.page
        b = p.get_by_role("button", name="Accept", exact=True)
        if not b.count():
            return False
        b.first.click()
        p.wait_for_timeout(1500)
        yes = p.get_by_role("button", name=re.compile(r"^(Yes|OK|Confirm)$", re.I))
        if yes.count():
            yes.first.click()
        p.wait_for_timeout(2500)
        return True

    def close_request(self, c: dict) -> tuple[str, str]:
        """More -> Close Request flow screen (verified 2026-09-28 on eight closures)."""
        p = self.page
        more = p.get_by_role("button", name=re.compile(r"^(More|Show more actions)", re.I))
        if more.count():
            more.first.click()
            p.wait_for_timeout(800)
        item = p.get_by_role("menuitem", name=re.compile(r"Close Request", re.I))
        if not item.count():
            item = p.get_by_role("button", name=re.compile(r"Close Request", re.I))
        if not item.count():
            raise RuntimeError("Close Request action not found")
        item.first.click()
        sel = p.locator('select[name="Closed_SubStatus"]').first
        sel.wait_for(timeout=15000)
        sel.select_option(c["substatus"])
        chosen = ""
        if c.get("not_related_to_dealer"):
            cb = p.locator('input[name="Not_related_to_a_Dealership"]').first
            if not cb.is_checked():
                cb.check()
        else:
            inp = p.get_by_role("combobox", name=re.compile(r"Dealer Account", re.I)).first
            inp.click()
            inp.press_sequentially(c["dealer_account"], delay=45)
            opts = p.get_by_role("option").filter(has_text=re.compile(re.escape(c["dealer_account"].split()[0]), re.I))
            opts.first.wait_for(timeout=10000)
            texts = [opts.nth(i).inner_text().replace("\n", " ") for i in range(min(opts.count(), 8))]
            pick = 0
            if c.get("dealer_code"):        # the right account may be the SECOND row (Walker Toyota CCC34073 vs 0LD10259)
                pick = next((i for i, t in enumerate(texts) if c["dealer_code"].upper() in t.upper()), None)
                if pick is None:
                    pick = next((i for i, t in enumerate(texts) if norm(t).startswith(norm(c["dealer_account"]))), 0)
            chosen = texts[pick]
            opts.nth(pick).click()
            p.wait_for_timeout(600)
        ta = p.get_by_role("textbox", name=re.compile(r"Resolution", re.I))
        if not ta.count():
            ta = p.locator("textarea")
        ta.first.fill(c["resolution"])
        p.get_by_role("button", name=re.compile(r"^Close$", re.I)).last.click()
        for _ in range(30):
            p.wait_for_timeout(500)
            if not p.locator('select[name="Closed_SubStatus"]').count():
                break
        back = self.read()
        ok = "Closed" in back.get("Status", "")
        return ("OK" if ok else "PARTIAL"), f"Close Request {c['substatus']}" + (f" (account: {chosen})" if chosen else "") + ("" if ok else " | Status not showing Closed yet")

    def set_picklist(self, label: str, value: str):
        p = self.page
        box = p.get_by_role("combobox", name=label, exact=True).first
        box.scroll_into_view_if_needed()
        box.click()
        opt = p.get_by_role("option", name=value, exact=True)
        opt.first.wait_for(timeout=8000)
        opt.first.click()
        p.wait_for_timeout(500)

    def set_dual_listbox(self, values: list[str]):
        p = self.page
        dual = p.locator("lightning-dual-listbox").first
        dual.scroll_into_view_if_needed()
        for v in values:
            if dual.get_by_role("listbox").nth(1).get_by_role("option", name=v, exact=True).count():
                continue
            opt = dual.get_by_role("listbox").nth(0).get_by_role("option", name=v, exact=True)
            if not opt.count():
                raise ValueError(f"SR Category option '{v}' not in the Available list")
            opt.first.click()
            dual.get_by_role("button", name=re.compile("Move selection to Chosen", re.I)).first.click()
            p.wait_for_timeout(400)

    def set_text(self, api_name: str, value: str):
        inp = self.page.locator(f'input[name="{api_name}"]').first
        inp.scroll_into_view_if_needed()
        inp.fill(value)

    def set_lookup(self, label: str, text: str) -> str:
        p = self.page
        inp = p.get_by_role("combobox", name=label, exact=True)
        if not inp.count():
            inp = p.locator(f'input[aria-label="{label}"]')
        inp = inp.first
        inp.scroll_into_view_if_needed()
        inp.click()
        inp.press_sequentially(text, delay=45)          # real key presses; JS .value= never opens the list
        first = re.escape(text.split()[0])
        opts = p.get_by_role("option").filter(has_text=re.compile(first, re.I))
        opts.first.wait_for(timeout=10000)
        names = [norm(opts.nth(i).inner_text()) for i in range(min(opts.count(), 8))]
        exact = [i for i, n in enumerate(names) if n.startswith(norm(text))]
        pick = exact[0] if exact else 0
        chosen = opts.nth(pick).inner_text().split("\n")[0].strip()
        opts.nth(pick).click()
        p.wait_for_timeout(700)
        return chosen

    def set_summary(self, text: str):
        p = self.page
        field = p.locator("record_flexipage-record-field").filter(
            has=p.locator("label, .slds-form-element__label", has_text=re.compile(r"^\s*SR Summary Detail\s*$")))
        ta = field.locator("textarea").first
        if not ta.count():
            raise RuntimeError("SR Summary Detail textarea not found - refusing to type anywhere else")
        ta.scroll_into_view_if_needed()
        ta.fill(text)

    def save(self):
        p = self.page
        p.get_by_role("button", name="Save", exact=True).last.click()
        for _ in range(30):
            p.wait_for_timeout(500)
            if not self.in_edit():
                return
        err = [e.strip() for e in p.locator(".slds-has-error, .forceFormPageError, [role=alert]").all_inner_texts()
               if e.strip() and not re.search(r"No items|Loading", e)]
        raise RuntimeError("record still in edit mode after Save: " + " | ".join(err)[:400])

    def cancel(self):
        b = self.page.get_by_role("button", name="Cancel", exact=True)
        if b.count():
            b.last.click()
            self.page.wait_for_timeout(800)

    def fill(self, rec: dict, url: str, dry: bool) -> tuple[str, str]:
        p = self.page
        p.goto(url, wait_until="domcontentloaded")
        p.wait_for_timeout(3500)
        cur = self.read()                                   # pre-write re-read: the record may have moved on
        if "Closed" in cur.get("Status", ""):
            return "SKIP", "record is Closed - not writing"
        plan, skipped = [], []
        for key in PICKLIST_KEYS + TEXT_KEYS + LOOKUP_KEYS:
            if rec.get(key):
                (skipped if norm(rec[key]) in norm(cur.get(FIELD_LABELS[key], "")) else plan).append(key)
        cats_missing = [c for c in rec.get("sr_category", []) if c not in cur.get("SR Category", "")]
        if cats_missing:
            plan.append("sr_category")
        elif rec.get("sr_category"):
            skipped.append("sr_category")
        summary_text = None
        if rec.get("summary"):
            summary_text = merge_summary(cur.get("SR Summary Detail", ""), rec["summary"], rec.get("summary_mode", "append"))
            (plan if summary_text else skipped).append("summary")
        # ownership is decided from the Owner field; the Accept/Transfer buttons stay visible after ownership
        do_accept = bool(rec.get("accept") and cur.get("__accept") and norm(self.owner_name) not in norm(cur.get("Owner", "")))
        if not plan and not do_accept:
            return "NOCHANGE", f"already matches ({len(skipped)} fields)"
        if dry:
            return "DRY", "would set " + ", ".join(plan) + (" + Accept" if do_accept else "") + (f"; unchanged: {skipped}" if skipped else "")
        done = []
        if do_accept and self.accept():
            done.append("Accept")
        if plan:
            self.click_edit()
            if "brand" in plan:
                self.set_picklist("Brand", rec["brand"]); done.append("Brand")
            if "inquiry_type" in plan:
                self.set_picklist("Inquiry Type", rec["inquiry_type"]); done.append("Inquiry Type"); p.wait_for_timeout(800)
            if rec.get("inquiry_subtype") and ("inquiry_subtype" in plan or "inquiry_type" in plan):
                self.set_picklist("Inquiry SubType", rec["inquiry_subtype"]); done.append("Inquiry SubType")
            for key in ("error_code", "status", "priority"):
                if key in plan:
                    self.set_picklist(FIELD_LABELS[key], rec[key]); done.append(FIELD_LABELS[key])
            if "sr_category" in plan:
                self.set_dual_listbox(cats_missing); done.append("SR Category")
            for key in TEXT_KEYS:
                if key in plan:
                    self.set_text(KNOWN_API_NAMES[key], rec[key]); done.append(FIELD_LABELS[key])
            for key in LOOKUP_KEYS:
                if key in plan:
                    got = self.set_lookup(FIELD_LABELS[key], rec[key]); done.append(f"{FIELD_LABELS[key]}={got}")
            if "summary" in plan:
                self.set_summary(summary_text); done.append("SR Summary Detail")
            self.save()
        back = self.read()
        misses = [FIELD_LABELS[k] for k in plan if k in PICKLIST_KEYS and norm(rec[k]) not in norm(back.get(FIELD_LABELS[k], ""))]
        misses += [f"SR Category:{c}" for c in cats_missing if c not in back.get("SR Category", "")]
        if "summary" in plan and re.sub(r"^\[\d\d/\d\d/\d\d\]\s*", "", rec["summary"])[:40] not in back.get("SR Summary Detail", ""):
            misses.append("SR Summary Detail")
        return ("OK" if not misses else "PARTIAL"), ", ".join(done) + (f" | not confirmed: {misses}" if misses else "")


# --------------------------------------------------------------------------------------------------- runner
class Runner:
    def __init__(self, a):
        self.a = a
        self.rest: Rest | None = None
        self.ui: Ui | None = None
        self.page = None
        self.results: list[tuple[str, str, str]] = []

    def start(self, pw):
        self.browser, self.ctx = open_browser(pw, self.a.cdp)
        self.page = self.ctx.pages[0] if self.ctx.pages else self.ctx.new_page()
        wait_for_login(self.page)
        self.keepalive_tab = open_keepalive_tab(self.ctx)   # parked on Home, never navigated
        self.page.bring_to_front()
        if not self.a.ui_only:
            sid = next((c["value"] for c in self.ctx.cookies() if c["name"] == "sid" and "my.salesforce.com" in c["domain"]), None)
            if sid:
                cand = Rest(sid, self.a.user)
                if cand.probe():
                    self.rest = cand
            else:
                log("no my.salesforce.com sid cookie in this session; using the form")
        self.ui = Ui(self.page, self.a.user, self.a.owner_name)

    def lists(self):
        if self.rest:
            return self.rest.picklists, self.rest.subtypes
        return picklists_for_validation()

    def one(self, rec: dict) -> tuple[str, str, str]:
        t0 = time.time()
        pl, st = self.lists()
        probs = validate(rec, pl, st)
        if probs:
            note = "; ".join(probs)[:400]
            log(f"{rec['sr']}: SKIP - {note}")
            return "SKIP", "-", note
        mode = "REST" if self.rest else "UI"
        try:
            if not logged_in(self.page):
                wait_for_login(self.page)
            if self.rest:
                status, note = self.rest.fill(rec, self.a.dry_run)
            else:
                url = rec.get("url") or (f"{LIGHTNING}/lightning/r/{SOBJECT}/{rec['record_id']}/view" if rec.get("record_id") else None)
                url = url or self.ui.find_record_url(rec["sr"], self.a.list_url)
                if not url:
                    status, note = "FAIL", "SR not in the queue/Recent list; add record_id (from the SR URL) to the record"
                else:
                    try:
                        status, note = self.ui.fill(rec, url, self.a.dry_run)
                    except Exception as e:  # noqa: BLE001  one retry after a Lightning hiccup
                        FAILED.mkdir(parents=True, exist_ok=True)
                        shot = FAILED / f"{rec['sr']}_{dt.datetime.now():%H%M%S}.png"
                        try:
                            self.page.screenshot(path=str(shot), full_page=True)
                        except Exception:  # noqa: BLE001
                            pass
                        log(f"{rec['sr']}: {type(e).__name__}: {str(e)[:120]} - screenshot {shot.name}; retrying once")
                        self.ui.cancel()
                        status, note = self.ui.fill(rec, url, self.a.dry_run)
            # closing is a Flow screen, UI-only, and only when the record asks for it
            if rec.get("close") and status in ("OK", "NOCHANGE", "PARTIAL", "DRY"):
                if self.a.dry_run:
                    note += f" | would Close Request as {rec['close']['substatus']}"
                else:
                    rid = read_json(SR_IDS, {}).get(rec["sr"])
                    url = rec.get("url") or (f"{LIGHTNING}/lightning/r/{SOBJECT}/{rid}/view" if rid else None) or self.ui.find_record_url(rec["sr"], self.a.list_url)
                    if self.page.url.split("?")[0] != url:
                        self.page.goto(url, wait_until="domcontentloaded"); self.page.wait_for_timeout(3000)
                    cst, cnote = self.ui.close_request(rec["close"])
                    status = cst if status == "OK" else status
                    note += " | " + cnote
                    mode += "+close"
        except Exception as e:  # noqa: BLE001
            status, note = "FAIL", f"{type(e).__name__}: {e}"[:400]
        secs = round(time.time() - t0, 1)
        log(f"{rec['sr']}: {status} [{mode}] {note} ({secs}s)")
        if not self.a.dry_run:
            append_log({"when": dt.datetime.now().isoformat(timespec="seconds"), "sr": rec["sr"], "mode": mode,
                        "result": status, "seconds": secs, "fields": ", ".join(k for k in DATA_KEYS if rec.get(k)), "note": note[:500]})
            if status in ("OK", "PARTIAL", "NOCHANGE"):
                remember(rec["sr"], result=status, mode=mode, note=note[:300], source=rec.get("_source", ""))
        return status, mode, note

    def process(self, items: list[tuple[dict, Path]], move: bool):
        for rec, src in items:
            status, mode, note = self.one(rec)
            self.results.append((rec["sr"], status, note))
            if move and src.parent == INBOX:
                dest = (DONE if status in ("OK", "NOCHANGE", "PARTIAL") else FAILED)
                dest.mkdir(parents=True, exist_ok=True)
                shutil.move(str(src), str(dest / f"{src.stem}_{dt.datetime.now():%Y%m%d_%H%M%S}{src.suffix}"))

    def report(self):
        if not self.results:
            return
        lines = [f"# sf_fill run {dt.datetime.now():%Y-%m-%d %H:%M}", "", "| SR | result | note |", "|---|---|---|"]
        lines += [f"| {sr} | {st} | {note.replace('|', '/')[:160]} |" for sr, st, note in self.results]
        LAST_RUN.parent.mkdir(parents=True, exist_ok=True)
        LAST_RUN.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("\nSR           RESULT    NOTE")
        for sr, st, note in self.results:
            print(f"{sr}  {st:<9} {note[:110]}")

    def close(self):
        try:
            (self.browser or self.ctx).close()
        except Exception:  # noqa: BLE001
            pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*", help="verdict/fill JSON files or directories (default: EmorySF\\inbox)")
    ap.add_argument("--sr", action="append", help="only these SR numbers (repeatable)")
    ap.add_argument("--dry-run", action="store_true", help="validate + plan, change nothing")
    ap.add_argument("--watch", action="store_true", help="keep running; process inbox files as they arrive")
    ap.add_argument("--interval", type=int, default=5, help="watch poll seconds (default 5)")
    ap.add_argument("--no-accept", action="store_true", help="never take ownership")
    ap.add_argument("--ui-only", action="store_true", help="skip the REST probe, drive the form")
    ap.add_argument("--discover", action="store_true", help="dump describe()/picklists and exit")
    ap.add_argument("--from-md", help="convert an Emory queue-run .md into records (with --out)")
    ap.add_argument("--out", help="where --from-md writes its JSON")
    ap.add_argument("--list-url", action="append", default=[], help="extra list views to scan for the SR")
    ap.add_argument("--cdp", help="attach to a running browser (e.g. http://127.0.0.1:9222)")
    ap.add_argument("--user", default=DEFAULT_USER, help="your Salesforce username (ownership via REST)")
    ap.add_argument("--owner-name", default=DEFAULT_OWNER_NAME, help="how the Owner field reads once the SR is yours")
    a = ap.parse_args()

    for d in (INBOX, DONE, FAILED, STATE):
        d.mkdir(parents=True, exist_ok=True)

    if a.from_md:
        recs = parse_queue_md(Path(a.from_md))
        out = Path(a.out or Path(a.from_md).with_suffix(".sf.json"))
        write_json(out, {"records": recs})
        log(f"wrote {len(recs)} records to {out}; set inquiry_subtype to real picklist values, then run the fill")
        return 0

    paths = [Path(p) for p in a.inputs] or ([INBOX] if not a.discover else [])
    items = [] if a.discover else load_inputs(paths)
    if a.sr:
        want = {s.upper() for s in a.sr}
        items = [(r, f) for r, f in items if r["sr"] in want]
    if a.no_accept:
        for r, _ in items:
            r["accept"] = False
    if not items and not a.watch and not a.discover:
        log(f"nothing to do (inbox: {INBOX})")
        return 0

    pl, st = picklists_for_validation()
    bad = [(r["sr"], validate(r, pl, st)) for r, _ in items]
    for sr, probs in bad:
        for pr in probs:
            log(f"{sr}: {pr}")
    if a.dry_run and items and all(p for _, p in bad):
        log("every record needs fixes; not opening a browser")
        return 1

    from playwright.sync_api import sync_playwright
    with sync_playwright() as pw:
        run = Runner(a)
        run.start(pw)
        if a.discover:
            if run.rest:
                log(f"picklists: {list(run.rest.picklists)}\nInquiry SubType by type: {json.dumps(run.rest.subtypes, indent=1)}")
            else:
                log("REST unavailable; built-in live lists apply (see LIVE_PICKLISTS / LIVE_SUBTYPES)")
            run.close()
            return 0
        move = not a.dry_run and paths == [INBOX]
        run.process(items, move)
        if a.watch:
            log(f"watching {INBOX} every {a.interval}s - drop verdict JSON files there; Ctrl+C to stop")
            seen = {f for _, f in items}
            try:
                while True:
                    time.sleep(a.interval)
                    new = [f for f in sorted(INBOX.glob("*.json")) if f not in seen]
                    if new:
                        run.process(load_inputs(new), move=not a.dry_run)
                        run.report()
                    seen = {f for f in INBOX.glob("*.json")}
            except KeyboardInterrupt:
                log("stopped")
        run.report()
        run.close()
    return 0 if all(s in ("OK", "DRY", "NOCHANGE") for _, s, _ in run.results) else 1


if __name__ == "__main__":
    sys.exit(main())
