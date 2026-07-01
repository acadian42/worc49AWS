#!/usr/bin/env python3
"""Launch an FPC-E2E AWX job template or workflow, poll to completion, auto-approve
the gate, and print a SANITIZED summary (status, per-host recap, failure excerpts).
Usage:
  awx_launch.py jt "FPC-E2E preflight"
  awx_launch.py wf "FPC-E2E Workflow"
"""
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
import urllib.parse

STATE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), ".e2e-state")
AWX = os.environ.get("AWX_URL", "http://127.0.0.1:30080")
TOKEN = open(os.path.join(STATE, "awx_token")).read().strip()
FINISHED = {"successful", "failed", "error", "canceled"}
SECRET_RE = re.compile(r"(?i)(password|secret|token|bind_pw|ssh_key)")


def api(method, path, body=None):
    url = path if path.startswith("http") else AWX + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw and raw[:1] in b"{[" else raw)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw


def find(endpoint, name):
    _, d = api("GET", f"{endpoint}?name={urllib.parse.quote(name)}")
    for r in d.get("results", []):
        if r.get("name") == name:
            return r
    return None


def recap(job_id):
    _, s = api("GET", f"/api/v2/jobs/{job_id}/job_host_summaries/")
    for h in s.get("results", []):
        hn = h["summary_fields"]["host"]["name"]
        print(f"      host {hn}: ok={h['ok']} changed={h['changed']} failures={h['failures']} "
              f"dark={h['dark']} skipped={h['skipped']} rescued={h['rescued']}")


def failure_excerpt(job_id):
    st, raw = api("GET", f"/api/v2/jobs/{job_id}/stdout/?format=txt")
    text = raw.decode(errors="replace") if isinstance(raw, (bytes, bytearray)) else str(raw)
    lines = [ln for ln in text.splitlines() if re.search(r"fatal:|FAILED|failed=|ERROR|unreachable", ln)]
    seen = []
    for ln in lines[-25:]:
        ln = SECRET_RE.sub(lambda m: m.group(0), ln)  # keys, not values; AWX masks secret values
        seen.append(ln[:300])
    print("      --- failure excerpt (sanitized) ---")
    for ln in seen:
        print("      " + ln)


def poll_job(job_id, label):
    while True:
        _, j = api("GET", f"/api/v2/jobs/{job_id}/")
        st = j.get("status")
        if st in FINISHED:
            print(f"    [{label}] job {job_id} -> {st} (elapsed {j.get('elapsed')}s)")
            recap(job_id)
            if st != "successful":
                failure_excerpt(job_id)
            return st
        time.sleep(5)


def approve_pending(wf_id):
    _, nodes = api("GET", f"/api/v2/workflow_jobs/{wf_id}/workflow_nodes/?page_size=200")
    for n in nodes.get("results", []):
        job = n.get("summary_fields", {}).get("job")
        if job and job.get("type") == "workflow_approval" and job.get("status") == "pending":
            aid = n["job"]
            print(f"    approving gate (approval job {aid})")
            api("POST", f"/api/v2/workflow_approvals/{aid}/approve/", {})


def run_jt(name):
    jt = find("/api/v2/job_templates/", name)
    if not jt:
        print("no such JT", name)
        sys.exit(1)
    st, j = api("POST", f"/api/v2/job_templates/{jt['id']}/launch/", {})
    jid = j.get("job") or j.get("id")
    print(f"launched JT '{name}' -> job {jid}")
    return poll_job(jid, name)


def run_wf(name):
    wf = find("/api/v2/workflow_job_templates/", name)
    st, j = api("POST", f"/api/v2/workflow_job_templates/{wf['id']}/launch/", {})
    wid = j.get("workflow_job") or j.get("id")
    print(f"launched WORKFLOW '{name}' -> workflow_job {wid}")
    reported = set()
    while True:
        _, w = api("GET", f"/api/v2/workflow_jobs/{wid}/")
        wst = w.get("status")
        approve_pending(wid)
        _, nodes = api("GET", f"/api/v2/workflow_jobs/{wid}/workflow_nodes/?page_size=200")
        for n in sorted(nodes.get("results", []), key=lambda x: x.get("identifier") or ""):
            job = n.get("summary_fields", {}).get("job")
            if job and job["id"] not in reported and job.get("status") in FINISHED:
                reported.add(job["id"])
                ident = n.get("identifier")
                print(f"    node {ident}: {job.get('name')} -> {job['status']} (job {job['id']})")
                if job.get("type") == "job":
                    recap(job["id"])
                    if job["status"] != "successful":
                        failure_excerpt(job["id"])
        if wst in FINISHED:
            print(f"WORKFLOW {wid} -> {wst}")
            return wst, wid
        time.sleep(6)


if __name__ == "__main__":
    kind, name = sys.argv[1], sys.argv[2]
    if kind == "jt":
        sys.exit(0 if run_jt(name) == "successful" else 1)
    else:
        st, _ = run_wf(name)
        sys.exit(0 if st == "successful" else 1)
