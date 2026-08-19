#!/usr/bin/env bash
# per_run.sh — show every single run value, not just aggregates
set -uo pipefail

python3 - <<'PYEOF'
import os, re

BASE = "bench"
scenarios = ["smoke", "load", "queue", "search", "stream", "stress"]
envs = ["docker", "k8s"]

def extract(path):
    try:
        text = open(path).read()
    except OSError:
        return {}
    m = {}
    def grab(pattern):
        r = re.search(pattern, text)
        return r.group(1) if r else "?"
    m["checks"] = grab(r"checks_succeeded\.*\.*\.*\.*: ([0-9.]+)%")
    m["failed"] = grab(r"http_req_failed\.*\.*\.*\.*: ([0-9.]+)%")
    m["reqs"] = grab(r"http_reqs\.*\.*\.*\.*: (\d+)")
    m["iters"] = grab(r"iterations\.*\.*\.*\.*: (\d+)")
    m["dropped"] = grab(r"dropped_iterations\.*\.*\.*\.*: (\d+)")
    m["emb"] = grab(r"embedding_ready\.*\.*\.*\.*: ([0-9.]+)%")
    r = re.search(r"http_req_duration\.*\.*\.*\.*: .*", text)
    if r:
        mm = re.search(r"med=([0-9.]+)(ms|s)", r.group(0))
        pp = re.search(r"p\(95\)=([0-9.]+)(ms|s)", r.group(0))
        m["req_med"] = mm.group(1) if mm else "?"
        m["req_p95"] = pp.group(1) if pp else "?"
    return m

for env in envs:
    print(f"\n{'='*72}")
    print(f"ENV: {env} — per-run values")
    print('='*72)
    for sc in scenarios:
        files = sorted(f for f in os.listdir(f"{BASE}/{env}") if f.startswith(f"{sc}-") and f.endswith(".log"))
        print(f"\n[{sc}]")
        print(f"  {'run':4s} {'checks%':>8s} {'failed%':>8s} {'reqs':>6s} {'iters':>6s} {'drop':>6s} {'emb%':>7s} {'med(ms)':>9s} {'p95(ms)':>9s}")
        for f in files:
            m = extract(f"{BASE}/{env}/{f}")
            r = f.replace(".log","").replace(f"{sc}-","")
            print(f"  {r:4s} {m['checks']:>8s} {m['failed']:>8s} {m['reqs']:>6s} {m['iters']:>6s} {m['dropped']:>6s} {m['emb']:>7s} {m['req_med']:>9s} {m['req_p95']:>9s}")
PYEOF
