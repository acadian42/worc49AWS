#!/usr/bin/env python3
"""Trigger the FPC-E2E AWX project SCM update and wait for it to finish."""
import json
import os
import time
import urllib.request

STATE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), ".e2e-state")
AWX = os.environ.get("AWX_URL", "http://127.0.0.1:30080")
TOKEN = open(os.path.join(STATE, "awx_token")).read().strip()
OBJ = json.load(open(os.path.join(STATE, "awx_objects.json")))
PID = OBJ["project"]
SRC = OBJ["inventory_source"]


def api(method, path):
    req = urllib.request.Request(AWX + path, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def wait(path, label):
    for _ in range(60):
        p = api("GET", path)
        if p.get("status") in ("successful", "failed", "error", "canceled"):
            print(label, "->", p.get("status"), "rev", (p.get("scm_revision") or "")[:12])
            return
        time.sleep(3)


# 1) sync the project to the latest commit
api("POST", f"/api/v2/projects/{PID}/update/")
wait(f"/api/v2/projects/{PID}/", f"project {PID}")
# 2) CRITICAL: re-sync the SCM inventory source so jobs get the latest group_vars
api("POST", f"/api/v2/inventory_sources/{SRC}/update/")
wait(f"/api/v2/inventory_sources/{SRC}/", f"inventory_source {SRC}")
