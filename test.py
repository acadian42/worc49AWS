from __future__ import annotations

import csv
import io
import json
import logging
import traceback

from crowdstrike.foundry.function import Function, Request, Response
from falconpy import CloudSecurityDetections

func = Function.instance()

DEFAULT_SEVERITIES = ["critical", "high"]   # matched case-insensitively
ID_PAGE = 500              # IDs requested per query_iom_entities page
ENTITY_BATCH = 100         # IDs sent per get_iom_entities call
MAX_IDS = 5000             # safety cap so a huge tenant can't blow the time limit
TABLE_LIMIT = 200          # rows rendered inline in the HTML email

DEFAULT_FQL = "severity:['high','critical']+status:'failed'"


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

        # ---- final severity gate (belt-and-suspenders on top of the API) -
        # Even though the API filter already restricts severity, we re-check
        # client-side so nothing but High/Critical can ever reach the report.
        findings = [f for f in scanned
                    if str(f.get("severity") or "").lower() in wanted]

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


def _build_html(findings, summary):
    if not findings:
        return ("<html><body style='font-family:Segoe UI,Arial,sans-serif'>"
                "<h2>CSPM Critical &amp; High Misconfigurations</h2>"
                "<p>No open Critical or High IOMs found for this period.</p>"
                "</body></html>")

    fields = list(findings[0].keys())
    summary_rows = "".join(
        f"<tr><td style='padding:4px 12px'>{k}</td>"
        f"<td style='padding:4px 12px;text-align:right'><b>{v}</b></td></tr>"
        for k, v in sorted(summary.items())
    )
    header = "".join(
        f"<th style='padding:6px 10px;text-align:left;border-bottom:2px solid #444'>{f}</th>"
        for f in fields
    )
    rows = ""
    for r in findings[:TABLE_LIMIT]:
        cells = "".join(
            f"<td style='padding:4px 10px;border-bottom:1px solid #ddd'>{r.get(f, '')}</td>"
            for f in fields
        )
        rows += f"<tr>{cells}</tr>"

    note = ""
    if len(findings) > TABLE_LIMIT:
        note = (f"<p>Showing the first {TABLE_LIMIT} of {len(findings)} findings. "
                f"Full list is in the attached CSV.</p>")

    return f"""\
<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#222">
<h2>Falcon Cloud Security (CSPM) - Critical &amp; High Misconfigurations</h2>
<p>Total findings: <b>{len(findings)}</b></p>
<table style="border-collapse:collapse;margin-bottom:18px">{summary_rows}</table>
{note}
<table style="border-collapse:collapse;font-size:13px"><thead><tr>{header}</tr></thead>
<tbody>{rows}</tbody></table>
<p style="color:#888;font-size:12px">Automated monthly report from Falcon GovCloud (Foundry + Fusion SOAR).</p>
</body></html>"""


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

