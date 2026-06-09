import csv
import io
import logging

from crowdstrike.foundry.function import Function, Request, Response
from falconpy import CSPMRegistration

func = Function.instance()

DEFAULT_SEVERITIES = ["Critical", "High"]   # CSPM uses Title Case
PAGE_SIZE = 400
TABLE_LIMIT = 200                            # rows rendered inline in the email


@func.handler(method="POST", path="/cspm-iom-report")
def cspm_iom_report(request: Request, config: dict | None = None) -> Response:
    log = logging.getLogger("cspm-iom-report")

    body_in = request.body or {}
    severities = body_in.get("severities") or DEFAULT_SEVERITIES

    # Context auth -- no credentials needed inside Foundry.
    falcon = CSPMRegistration()

    findings = []
    for sev in severities:
        next_token = None
        while True:
            kwargs = {"severity": sev, "limit": PAGE_SIZE}
            if next_token:
                kwargs["next_token"] = next_token

            resp = falcon.GetConfigurationDetections(**kwargs)
            code = resp.get("status_code")
            rbody = resp.get("body", {}) or {}

            if code != 200:
                log.error("CSPM API error %s: %s", code, rbody.get("errors"))
                return Response(
                    code=code or 500,
                    errors=[{"code": code or 500,
                             "message": f"CSPM API error: {rbody.get('errors')}"}],
                )

            for item in (rbody.get("resources") or []):
                findings.extend(_normalize(item, sev))

            next_token = ((rbody.get("meta") or {}).get("pagination") or {}).get("next_token")
            if not next_token:
                break

    summary = _summarize(findings)
    log.info("CSPM report built: %d findings (%s)", len(findings), summary)

    return Response(
        code=200,
        body={
            "total": len(findings),
            "summary": summary,
            "subject": f"[Falcon GovCloud] CSPM Critical & High Misconfigurations "
                       f"({len(findings)} findings)",
            "html": _build_html(findings, summary),
            "csv": _build_csv(findings),
            "findings": findings,
        },
    )


def _normalize(item, sev_fallback):
    """CSPM responses are sometimes flat, sometimes nest detections under a key.
    Inspect body.findings after a test run and tweak these keys to your tenant."""
    nested = None
    for key in ("resources", "detections", "iom", "findings"):
        if isinstance(item.get(key), list):
            nested = item[key]
            break
    rows = nested if nested is not None else [item]

    out = []
    for d in rows:
        out.append({
            "severity":       d.get("severity") or sev_fallback,
            "policy":         d.get("policy_statement") or d.get("rule_name") or d.get("policy_id", ""),
            "service":        d.get("service", ""),
            "cloud_provider": d.get("cloud_provider") or d.get("cloud", ""),
            "account_id":     d.get("account_id") or d.get("cloud_account_id") or d.get("aws_account_id", ""),
            "region":         d.get("region", ""),
            "resource_id":    d.get("resource_id") or d.get("instance_id", ""),
            "status":         d.get("status", ""),
            "first_seen":     d.get("scan_time") or d.get("created_timestamp", ""),
        })
    return out


def _summarize(findings):
    counts = {}
    for f in findings:
        s = (f.get("severity") or "Unknown").title()
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

