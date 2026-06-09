from __future__ import annotations

import csv
import io
import json
import logging
import traceback

from crowdstrike.foundry.function import Function, Request, Response
from falconpy import CSPMRegistration

func = Function.instance()

DEFAULT_SEVERITIES = ["critical", "high"]   # matched case-insensitively
ID_PAGE = 500          # IDs requested per queries/iom/v2 page
ENTITY_BATCH = 100     # IDs sent per entities/iom/v2 call
MAX_IDS = 5000         # safety cap so a huge tenant can't blow the time limit
TABLE_LIMIT = 200      # rows rendered inline in the HTML email


@func.handler(method="POST", path="/default")
def cspm_iom_report(request: Request, config: dict | None = None) -> Response:
    log = logging.getLogger("cspm-iom-report")

    try:
        body_in = request.body or {}
        wanted = {s.lower() for s in (body_in.get("severities") or DEFAULT_SEVERITIES)}
        fql = body_in.get("filter")  # optional server-side filter

        falcon = CSPMRegistration()

        # ---- Step 1: collect IOM IDs (queries/iom/v2) --------------------
        all_ids = []
        offset = 0
        next_token = None
        pages = 0

        while len(all_ids) < MAX_IDS:
            kwargs = {"limit": ID_PAGE}
            if fql:
                kwargs["filter"] = fql
            if next_token:
                kwargs["next_token"] = next_token
            elif offset:
                kwargs["offset"] = offset

            resp = falcon.GetConfigurationDetectionIDsV2(**kwargs)
            code = resp.get("status_code")
            rbody = resp.get("body", {}) or {}
            if code != 200:
                return _err("GetConfigurationDetectionIDsV2", code, rbody, extra={"filter": fql})

            raw = rbody.get("resources") or []
            for r in raw:
                if isinstance(r, str):
                    all_ids.append(r)
                elif isinstance(r, dict):
                    rid = r.get("id") or r.get("uuid") or r.get("detection_id")
                    if rid:
                        all_ids.append(rid)
            pages += 1

            pag = (rbody.get("meta") or {}).get("pagination") or {}
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
                "html": _build_html([], {}), "csv": "", "findings": [],
                "debug": {"pages": pages, "note": "queries/iom/v2 returned no IDs"},
            })

        # ---- Step 2: fetch entity details (entities/iom/v2) --------------
        scanned = []
        sample_entity = None
        for i in range(0, len(all_ids), ENTITY_BATCH):
            chunk = all_ids[i:i + ENTITY_BATCH]
            resp = falcon.GetConfigurationDetectionEntities(ids=chunk)
            code = resp.get("status_code")
            rbody = resp.get("body", {}) or {}
            if code != 200:
                return _err("GetConfigurationDetectionEntities", code, rbody,
                            extra={"ids_in_batch": len(chunk)})
            for item in (rbody.get("resources") or []):
                if sample_entity is None and isinstance(item, dict):
                    sample_entity = item
                scanned.append(_normalize(item))

        # ---- breakdown of EVERY raw severity value (diagnostic) ----------
        breakdown = {}
        for f in scanned:
            key = str(f.get("severity") or "Unknown")
            breakdown[key] = breakdown.get(key, 0) + 1

        # ---- filter ------------------------------------------------------
        if fql:
            findings = scanned            # trust the server-side filter
        else:
            findings = [f for f in scanned
                        if str(f.get("severity") or "").lower() in wanted]

        summary = _summarize(findings)
        log.info("IOM v2 report: scanned=%d kept=%d breakdown=%s",
                 len(scanned), len(findings), breakdown)

        return Response(code=200, body={
            "ok": True,
            "total": len(findings),
            "total_scanned": len(scanned),
            "summary": summary,
            "severity_breakdown": breakdown,
            "subject": f"[Falcon GovCloud] CSPM Critical & High Misconfigurations "
                       f"({len(findings)} findings)",
            "html": _build_html(findings, summary),
            "csv": _build_csv(findings),
            "findings": findings,
            "debug": {
                "pages": pages,
                "ids_collected": len(all_ids),
                "capped": len(all_ids) >= MAX_IDS,
                "sample_entity_keys": list(sample_entity.keys()) if sample_entity else [],
                "sample_entity": json.loads(json.dumps(sample_entity, default=str)[:1800])
                                 if sample_entity else None,
            },
        })

    except Exception as exc:   # noqa: BLE001 -- surface ANY failure in the body
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
    """IOM v2 entity -> flat row. Field names vary by cloud/provider; these
    .get() chains cover the common ones. Check debug.sample_entity to confirm."""
    if not isinstance(d, dict):
        return {"severity": "Unknown", "policy": "", "service": "",
                "cloud_provider": "", "account_id": "", "region": "",
                "resource_id": "", "status": "", "first_seen": ""}
    return {
        "severity":       d.get("severity") or d.get("severity_string") or "",
        "policy":         d.get("policy_statement") or d.get("rule_name")
                          or d.get("policy_name") or d.get("policy_id", ""),
        "service":        d.get("service") or d.get("cloud_service")
                          or d.get("resource_type", ""),
        "cloud_provider": d.get("cloud_provider") or d.get("cloud_platform")
                          or d.get("cloud", ""),
        "account_id":     d.get("account_id") or d.get("cloud_account_id")
                          or d.get("aws_account_id", ""),
        "region":         d.get("region") or d.get("cloud_region", ""),
        "resource_id":    d.get("resource_id") or d.get("resource_uuid")
                          or d.get("instance_id", ""),
        "status":         d.get("status", ""),
        "first_seen":     d.get("scan_time") or d.get("created_timestamp")
                          or d.get("created_at", ""),
    }


def _summarize(findings):
    counts = {}
    for f in findings:
        s = (f.get("severity") or "Unknown")
        s = str(s).title()
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

