from __future__ import annotations

import csv
import html
import io
import json
import logging
import traceback
from datetime import datetime, timezone

from crowdstrike.foundry.function import Function, Request, Response
from falconpy import CloudSecurityDetections

func = Function.instance()

DEFAULT_SEVERITIES = ["critical", "high"]   # matched case-insensitively
ID_PAGE = 500              # IDs requested per query_iom_entities page
ENTITY_BATCH = 100         # IDs sent per get_iom_entities call
MAX_IDS = 5000             # safety cap so a huge tenant can't blow the time limit
TABLE_LIMIT = 200          # rows rendered inline in the HTML email

DEFAULT_FQL = "severity:['high','critical']+status:'non-compliant'"

# A finding only counts as an open misconfiguration when the check FAILED.
# This tenant reports that as "non-compliant"; synonyms kept for safety.
FAILING_STATUSES = {"non-compliant", "non_compliant", "noncompliant", "failed", "fail"}


@func.handler(method="POST", path="/default")
def cspm_iom_report(request: Request, config: dict | None = None) -> Response:
    log = logging.getLogger("cspm-iom-report")

    try:
        body_in = request.body or {}
        wanted = {s.lower() for s in (body_in.get("severities") or DEFAULT_SEVERITIES)}
        # Use a caller-supplied filter if given, otherwise default to High/Critical Failed.
        fql = body_in.get("filter") or DEFAULT_FQL

        falcon = CloudSecurityDetections()

        # ---- Step 1: collect IOM IDs (query_iom_entities) ----------------
        all_ids = []
        offset = 0
        next_token = None
        pages = 0
        ids_raw_debug = {"captured": False}   # snapshot of the first response

        while len(all_ids) < MAX_IDS:
            kwargs = {"limit": ID_PAGE}
            if fql:
                kwargs["filter"] = fql
            if next_token:
                kwargs["next_token"] = next_token
            elif offset:
                kwargs["offset"] = offset

            resp = falcon.query_iom_entities(**kwargs)
            code = resp.get("status_code")
            rbody = resp.get("body", {}) or {}

            if ids_raw_debug["captured"] is False:
                ids_raw_debug = {
                    "captured": True,
                    "status_code": code,
                    "body_keys": list(rbody.keys()),
                    "meta": rbody.get("meta"),
                    "resources_len": len(rbody.get("resources") or []),
                    "errors": rbody.get("errors"),
                    "raw_sample": json.dumps(rbody, default=str)[:1800],
                }

            if code != 200:
                return _err("query_iom_entities", code, rbody, extra={"filter": fql})

            raw = rbody.get("resources") or []
            for r in raw:
                if isinstance(r, str):
                    all_ids.append(r)
                elif isinstance(r, dict):
                    rid = r.get("id") or r.get("uuid") or r.get("detection_id")
                    if rid:
                        all_ids.append(rid)
            pages += 1

            meta = rbody.get("meta") or {}
            pag = meta.get("pagination") or {}
            next_token = pag.get("next_token")
            offset += len(raw)
            total_avail = pag.get("total")

            if not raw:
                break
            if not next_token:
                if total_avail is not None and offset >= total_avail:
                    break
                if len(raw) < ID_PAGE:
                    break

        all_ids = all_ids[:MAX_IDS]

        if not all_ids:
            return Response(code=200, body={
                "ok": True, "total": 0, "total_scanned": 0,
                "summary": {}, "severity_breakdown": {},
                "subject": "[Falcon GovCloud] CSPM Critical & High Misconfigurations (0 findings)",
                "html": _build_html([], {}), "greeting": _build_html([], {}),
                "csv": "", "findings": [],
                "debug": {"pages": pages, "note": "query_iom_entities returned no IDs",
                          "filter": fql, "ids_raw_debug": ids_raw_debug},
            })

        # ---- Step 2: fetch entity details (get_iom_entities) -------------
        scanned = []
        sample_entity = None
        for i in range(0, len(all_ids), ENTITY_BATCH):
            chunk = all_ids[i:i + ENTITY_BATCH]
            resp = falcon.get_iom_entities(ids=chunk)
            code = resp.get("status_code")
            rbody = resp.get("body", {}) or {}
            if code != 200:
                return _err("get_iom_entities", code, rbody,
                            extra={"ids_in_batch": len(chunk)})
            for item in (rbody.get("resources") or []):
                if sample_entity is None and isinstance(item, dict):
                    sample_entity = item
                scanned.append(_normalize(item))

        # ---- severity breakdown across everything we fetched (diagnostic) -
        breakdown = {}
        for f in scanned:
            key = str(f.get("severity") or "Unknown")
            breakdown[key] = breakdown.get(key, 0) + 1

        # ---- final gate: High/Critical AND an actually-failing status -----
        # Severity is already restricted by the API filter; we re-check it
        # client-side AND drop anything that isn't a failing (non-compliant)
        # evaluation, since the API returns passing checks too.
        findings = [
            f for f in scanned
            if str(f.get("severity") or "").lower() in wanted
            and str(f.get("status") or "").lower() in FAILING_STATUSES
        ]

        summary = _summarize(findings)
        html = _build_html(findings, summary)
        subject = (f"[Falcon GovCloud] CSPM Critical & High Misconfigurations "
                   f"({len(findings)} findings)")
        log.info("IOM report: scanned=%d kept=%d breakdown=%s",
                 len(scanned), len(findings), breakdown)

        return Response(code=200, body={
            "ok": True,
            "total": len(findings),
            "total_scanned": len(scanned),
            "summary": summary,
            "severity_breakdown": breakdown,
            "subject": subject,
            "html": html,
            "greeting": html,            # the field Fusion exposes as a pill
            "csv": _build_csv(findings),
            "findings": findings,
            "debug": {
                "pages": pages,
                "filter": fql,
                "ids_collected": len(all_ids),
                "ids_raw_debug": ids_raw_debug,
                "capped": len(all_ids) >= MAX_IDS,
                "sample_entity_keys": list(sample_entity.keys()) if sample_entity else [],
                "sample_entity": json.dumps(sample_entity, default=str)[:4000] if sample_entity else None,
            },
        })

    except Exception as exc:  # noqa: BLE001 -- surface ANY failure in the body
        return Response(code=200, body={
            "ok": False,
            "stage": "exception",
            "type": type(exc).__name__,
            "error": str(exc),
            "traceback": traceback.format_exc()[:3000],
        })


def _err(stage, code, rbody, extra=None):
    """Build a debuggable error Response (NEVER pass dicts to Response errors=)."""
    body = {
        "ok": False,
        "stage": stage,
        "api_status_code": code,
        "api_errors": rbody.get("errors"),
        "api_body_keys": list(rbody.keys()),
        "raw_body_sample": json.dumps(rbody, default=str)[:1500],
    }
    if extra:
        body.update(extra)
    return Response(code=200, body=body)


def _normalize(d):
    """Cloud Security IOM entity -> flat row.

    The new (CloudSecurityDetections) API nests the useful values under
    cloud / resource / evaluation (and evaluation.rule), unlike the old
    flat CSPM shape. Paths below were taken from a live sample_entity.
    If a column comes back blank, print debug.sample_entity and adjust.
    """
    if not isinstance(d, dict):
        return {"severity": "Unknown", "status": "", "rule": "", "service": "",
                "cloud_provider": "", "account_id": "", "region": "",
                "resource_name": "", "resource_id": "", "first_seen": ""}
    cloud = d.get("cloud") or {}
    resource = d.get("resource") or {}
    ev = d.get("evaluation") or {}
    rule = ev.get("rule") or {}
    ext = d.get("extension") or {}
    return {
        "severity":       ev.get("severity") or "Unknown",
        "status":         ext.get("status") or ev.get("status") or "",
        "rule":           rule.get("name") or rule.get("description") or "",
        "service":        ev.get("service") or ev.get("service_category")
                          or resource.get("resource_type_name") or "",
        "cloud_provider": cloud.get("provider") or "",
        "account_id":     d.get("account_id") or "",
        "region":         cloud.get("region") or "",
        "resource_name":  resource.get("resource_name") or "",
        "resource_id":    resource.get("resource_id") or d.get("id") or "",
        "first_seen":     ev.get("created") or ev.get("captured") or "",
    }


def _summarize(findings):
    counts = {}
    for f in findings:
        s = str(f.get("severity") or "Unknown").title()
        counts[s] = counts.get(s, 0) + 1
    return counts


# --------------------------------------------------------------------------
# Email styling. Built for Outlook desktop, which renders through Word's
# engine: no external/<style> CSS reliance, tables for layout, inline styles,
# bgcolor attributes alongside background-color, hex colors only, and explicit
# light backgrounds on every container so the report stays dark-on-light even
# when the client is in dark mode (the cause of the washed-out first attempt).
# --------------------------------------------------------------------------

# Optional: paste the Falcon Cloud Security findings URL here to render a
# "View in Falcon" button in the header. Left blank = no button (no broken link).
CONSOLE_LINK = ""

SEV_COLORS = {
    "critical": "#C81E1E",
    "high":     "#C2410C",
    "medium":   "#B45309",
    "low":      "#3F6212",
}
_OUTER_BG = "#E9EDF1"
_CARD_BG  = "#FFFFFF"
_HEAD_BG  = "#1B2430"
_BORDER   = "#D0D7DE"
_ZEBRA    = "#F3F5F7"
_TXT      = "#1F2937"
_MUTED    = "#6B7280"
_FONT     = "Segoe UI,Arial,sans-serif"

_HTML_HEAD = (
    "<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
    "<meta name='color-scheme' content='light'>"
    "<meta name='supported-color-schemes' content='light'>"
    "<style>:root{color-scheme:light;supported-color-schemes:light;}</style>"
    "</head>"
)


def _esc(v):
    return html.escape(str(v if v is not None else ""))


def _now_utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def _sev_color(sev):
    return SEV_COLORS.get(str(sev or "").lower(), "#4B5563")


def _date_only(ts):
    ts = str(ts or "")
    return ts[:10] if len(ts) >= 10 else ts


def _short_rid(rid):
    """Last path segment of a long cloud resource id (full value stays in CSV)."""
    return str(rid or "").rstrip("/").split("/")[-1]


def _build_html(findings, summary):
    generated = _now_utc()

    if not findings:
        body = (
            f"<body style=\"margin:0;padding:0;background-color:{_OUTER_BG}\">"
            f"<table width='100%' cellpadding='0' cellspacing='0' bgcolor='{_OUTER_BG}'"
            f" style='background-color:{_OUTER_BG}'><tr><td align='center' style='padding:24px'>"
            f"<table width='640' cellpadding='0' cellspacing='0' bgcolor='{_CARD_BG}'"
            f" style='background-color:{_CARD_BG};border:1px solid {_BORDER};font-family:{_FONT}'>"
            f"<tr><td bgcolor='{_HEAD_BG}' style='background-color:{_HEAD_BG};color:#fff;"
            f"padding:18px 24px;font-size:18px;font-weight:bold'>"
            f"Falcon Cloud Security (CSPM)</td></tr>"
            f"<tr><td style='padding:24px;color:{_TXT};font-size:14px'>"
            f"No open Critical or High misconfigurations were found for this period."
            f"<div style='color:{_MUTED};font-size:12px;margin-top:16px'>"
            f"Generated {generated} &middot; Falcon GovCloud</div>"
            f"</td></tr></table></td></tr></table></body>"
        )
        return _HTML_HEAD + body + "</html>"

    total = len(findings)
    crit = sum(1 for f in findings if str(f.get("severity", "")).lower() == "critical")
    high = sum(1 for f in findings if str(f.get("severity", "")).lower() == "high")

    def card(label, value, bg):
        return (
            f"<td width='33%' align='center' bgcolor='{bg}' style='background-color:{bg};"
            f"color:#fff;padding:14px;font-family:{_FONT}'>"
            f"<div style='font-size:26px;font-weight:bold;line-height:1'>{value}</div>"
            f"<div style='font-size:11px;text-transform:uppercase;letter-spacing:.5px;"
            f"margin-top:4px'>{label}</div></td>"
        )

    cards = (
        f"<table width='100%' cellpadding='0' cellspacing='6'><tr>"
        f"{card('Total findings', total, _HEAD_BG)}"
        f"{card('Critical', crit, SEV_COLORS['critical'])}"
        f"{card('High', high, SEV_COLORS['high'])}"
        f"</tr></table>"
    )

    cols = [
        ("Severity", 74), ("Rule", 230), ("Service", 110), ("Cloud", 62),
        ("Region", 84), ("Resource", 250), ("First seen", 92),
    ]
    header = "".join(
        f"<th align='left' width='{w}' style='padding:8px 10px;font-size:11px;"
        f"text-transform:uppercase;letter-spacing:.4px;color:#fff;"
        f"background-color:{_HEAD_BG};font-family:{_FONT};white-space:nowrap'>{c}</th>"
        for c, w in cols
    )

    td_base = (f"padding:7px 10px;font-size:12px;color:{_TXT};"
               f"border-bottom:1px solid {_BORDER};vertical-align:top;font-family:{_FONT}")

    rows = ""
    for i, r in enumerate(findings[:TABLE_LIMIT]):
        zebra = _CARD_BG if i % 2 == 0 else _ZEBRA
        sev = r.get("severity", "")
        sev_bg = _sev_color(sev)
        rname = str(r.get("resource_name") or "")
        rid_short = _short_rid(r.get("resource_id"))
        sub = ""
        if rname and rid_short and rid_short.lower() != rname.lower():
            sub = (f"<div style='color:{_MUTED};font-size:11px;margin-top:2px;"
                   f"word-break:break-all'>{_esc(rid_short)}</div>")
        res_cell = (f"<div style='font-weight:600;word-break:break-word'>"
                    f"{_esc(rname or rid_short) or '&mdash;'}</div>{sub}")

        rows += (
            f"<tr bgcolor='{zebra}' style='background-color:{zebra}'>"
            f"<td bgcolor='{sev_bg}' style='background-color:{sev_bg};color:#fff;"
            f"font-weight:bold;font-size:11px;text-align:center;padding:7px 8px;"
            f"white-space:nowrap;font-family:{_FONT}'>{_esc(str(sev or '—').upper())}</td>"
            f"<td style='{td_base};word-break:break-word'>{_esc(r.get('rule', ''))}</td>"
            f"<td style='{td_base}'>{_esc(r.get('service', ''))}</td>"
            f"<td style='{td_base}'>{_esc(r.get('cloud_provider', ''))}</td>"
            f"<td style='{td_base};white-space:nowrap'>{_esc(r.get('region', ''))}</td>"
            f"<td style='{td_base}'>{res_cell}</td>"
            f"<td style='{td_base};white-space:nowrap'>{_esc(_date_only(r.get('first_seen')))}</td>"
            f"</tr>"
        )

    note = ""
    if total > TABLE_LIMIT:
        note = (f"<tr><td colspan='7' style='padding:10px;font-size:12px;color:{_MUTED};"
                f"background-color:{_CARD_BG};font-family:{_FONT}'>"
                f"Showing the first {TABLE_LIMIT} of {total} findings. "
                f"Full list is in the attached CSV.</td></tr>")

    button = ""
    if CONSOLE_LINK:
        button = (
            f"<div style='margin-top:12px'><a href='{_esc(CONSOLE_LINK)}' "
            f"style='background-color:#E12E26;color:#fff;text-decoration:none;"
            f"padding:8px 16px;font-size:12px;font-weight:bold;font-family:{_FONT};"
            f"display:inline-block'>View in Falcon &rarr;</a></div>"
        )

    body = (
        f"<body style=\"margin:0;padding:0;background-color:{_OUTER_BG}\">"
        f"<table width='100%' cellpadding='0' cellspacing='0' bgcolor='{_OUTER_BG}'"
        f" style='background-color:{_OUTER_BG}'><tr><td align='center' style='padding:24px 12px'>"
        f"<table width='980' cellpadding='0' cellspacing='0' bgcolor='{_CARD_BG}'"
        f" style='background-color:{_CARD_BG};border:1px solid {_BORDER};max-width:980px'>"
        f"<tr><td bgcolor='{_HEAD_BG}' style='background-color:{_HEAD_BG};padding:18px 24px;"
        f"font-family:{_FONT}'>"
        f"<div style='color:#fff;font-size:18px;font-weight:bold'>Falcon Cloud Security (CSPM)</div>"
        f"<div style='color:#AEB8C4;font-size:13px;margin-top:2px'>"
        f"Critical &amp; High Misconfigurations &middot; Falcon GovCloud</div>"
        f"{button}</td></tr>"
        f"<tr><td style='padding:16px 18px 4px'>{cards}</td></tr>"
        f"<tr><td style='padding:12px 18px 18px'>"
        f"<table width='100%' cellpadding='0' cellspacing='0' "
        f"style='border-collapse:collapse;border:1px solid {_BORDER}'>"
        f"<thead><tr>{header}</tr></thead><tbody>{rows}{note}</tbody></table>"
        f"</td></tr>"
        f"<tr><td style='padding:14px 24px;border-top:1px solid {_BORDER};"
        f"color:{_MUTED};font-size:11px;font-family:{_FONT}'>"
        f"Automated report from Falcon GovCloud (Foundry &amp; Fusion SOAR) "
        f"&middot; Generated {generated}</td></tr>"
        f"</table></td></tr></table></body>"
    )
    return _HTML_HEAD + body + "</html>"


def _build_csv(findings):
    if not findings:
        return ""
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=list(findings[0].keys()))
    writer.writeheader()
    writer.writerows(findings)
    return buf.getvalue()


if __name__ == "__main__":
    func.run()

