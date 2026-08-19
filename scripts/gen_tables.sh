#!/usr/bin/env bash
# gen_tables.py — estrae i valori esatti per ogni run e genera le tabelle del report
set -uo pipefail
python3 - <<'PYEOF'
import os, re

BASE = "bench"
scenarios = ["smoke", "load", "queue", "search", "stream", "stress"]

def extract(path):
    try:
        text = open(path).read()
    except OSError:
        return None
    m = {}
    def grab(pattern):
        r = re.search(pattern, text)
        return r.group(1) if r else "—"
    m["checks"] = grab(r"checks_succeeded\.*\.*\.*\.*: ([0-9.]+)%")
    m["failed"] = grab(r"http_req_failed\.*\.*\.*\.*: ([0-9.]+)%")
    m["reqs"] = grab(r"http_reqs\.*\.*\.*\.*: (\d+)")
    m["iters"] = grab(r"iterations\.*\.*\.*\.*: (\d+)")
    m["dropped"] = grab(r"dropped_iterations\.*\.*\.*\.*: (\d+)")
    m["emb"] = grab(r"embedding_ready\.*\.*\.*\.*: ([0-9.]+)%")
    r = re.search(r"http_req_duration\.*\.*\.*\.*: .*", text)
    if r:
        line = r.group(0)
        mm = re.search(r"med=([0-9.]+)(ms|s)", line)
        pp = re.search(r"p\(95\)=([0-9.]+)(ms|s)", line)
        def cv(x):
            if not x: return "—"
            v = float(x.group(1)) * (1000 if x.group(2) == "s" else 1)
            return f"{v:.2f}" if v >= 1 else f"{v:.2f}"
        m["med"] = cv(mm)
        m["p95"] = cv(pp)
    return m

for env in ["docker", "k8s"]:
    print(f"\n### {env}")
    print("| Scenario | run | checks% | failed% | reqs | iters | dropped | emb_ready% | med(ms) | p95(ms) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for sc in scenarios:
        files = sorted(f for f in os.listdir(f"{BASE}/{env}") if f.startswith(f"{sc}-") and f.endswith(".log"))
        for f in files:
            m = extract(f"{BASE}/{env}/{f}")
            r = f.replace(".log", "").replace(f"{sc}-", "")
            print(f"| {sc} | {r} | {m['checks']} | {m['failed']} | {m['reqs']} | {m['iters']} | {m['dropped']} | {m['emb']} | {m['med']} | {m['p95']} |")
PYEOF
