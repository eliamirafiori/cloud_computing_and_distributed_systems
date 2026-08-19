#!/usr/bin/env bash
# deep_analyze.sh — extract FULL k6 metrics for deep interpretation
set -uo pipefail

python3 - <<'PYEOF'
import os, re, statistics

BASE = "bench"
scenarios = ["smoke", "load", "queue", "search", "stream", "stress"]
envs = ["docker", "k8s"]

def extract(path):
    try:
        text = open(path).read()
    except OSError:
        return None
    m = {}
    def grab(pattern, group=1):
        r = re.search(pattern, text)
        return r.group(group) if r else None
    def grab_dur(pattern):
        # http_req_duration...: avg=... min=... med=... max=... p(90)=... p(95)=...
        r = re.search(pattern, text)
        if not r: return {}
        d = {}
        for k in ["avg","min","med","max"]:
            rr = re.search(rf"{k}=([0-9.]+)(ms|s)", r.group(0))
            if rr:
                v = float(rr.group(1)) * (1000 if rr.group(2)=="s" else 1)
                d[k] = round(v, 2)
        for k in ["p90","p95"]:
            rr = re.search(rf"p\({k[-1]}\)=([0-9.]+)(ms|s)", r.group(0))
            if rr:
                v = float(rr.group(1)) * (1000 if rr.group(2)=="s" else 1)
                d[k] = round(v, 2)
        return d
    m["req"] = grab_dur(r"http_req_duration\.*\.*\.*\.*: .*")
    m["iter"] = grab_dur(r"iteration_duration\.*\.*\.*\.*: .*")
    m["checks_total"] = grab(r"checks_total\.*\.*\.*\.*: (\d+)")
    m["checks_succ"] = grab(r"checks_succeeded\.*\.*\.*\.*: ([0-9.]+)%")
    m["checks_fail"] = grab(r"checks_failed\.*\.*\.*\.*: ([0-9.]+)%")
    m["failed"] = grab(r"http_req_failed\.*\.*\.*\.*: ([0-9.]+)%")
    m["reqs"] = grab(r"http_reqs\.*\.*\.*\.*: (\d+)")
    m["iters"] = grab(r"iterations\.*\.*\.*\.*: (\d+)")
    m["dropped"] = grab(r"dropped_iterations\.*\.*\.*\.*: (\d+)")
    m["emb_ready"] = grab(r"embedding_ready\.*\.*\.*\.*: ([0-9.]+)%")
    m["vus"] = grab(r"vus\.*\.*\.*\.*: (\d+)")
    m["vus_max"] = grab(r"vus_max\.*\.*\.*\.*: (\d+)")
    return m

def mean(vals):
    return round(statistics.mean(vals), 2) if vals else float('nan')

for env in envs:
    print(f"\n{'='*78}")
    print(f"ENV: {env}")
    print('='*78)
    for sc in scenarios:
        files = sorted(f for f in os.listdir(f"{BASE}/{env}") if f.startswith(f"{sc}-") and f.endswith(".log"))
        runs = [extract(f"{BASE}/{env}/{f}") for f in files]
        runs = [r for r in runs if r]
        if not runs: continue
        n = len(runs)
        print(f"\n[{sc}] n={n}")
        # request duration percentiles
        for key, label in [("req","http_req"), ("iter","iter")]:
            avgs = [r[key].get("avg") for r in runs if r[key].get("avg") is not None]
            meds = [r[key].get("med") for r in runs if r[key].get("med") is not None]
            p90s = [r[key].get("p90") for r in runs if r[key].get("p90") is not None]
            p95s = [r[key].get("p95") for r in runs if r[key].get("p95") is not None]
            maxs = [r[key].get("max") for r in runs if r[key].get("max") is not None]
            print(f"  {label:5s}: avg={mean(avgs):>10.1f}ms  med={mean(meds):>9.1f}  p90={mean(p90s):>9.1f}  p95={mean(p95s):>9.1f}  max={mean(maxs):>10.1f}")
        # other metrics (mean of runs)
        for key, label in [("checks_succ","checks%"), ("failed","failed%"), ("emb_ready","emb_ready%"),
                            ("reqs","reqs"), ("iters","iters"), ("dropped","dropped")]:
            vals = [float(r[key]) for r in runs if r.get(key) is not None]
            if vals:
                print(f"  {label:10s}: {mean(vals):>10.1f}  (min={min(vals):.1f} max={max(vals):.1f})")
        vus = [r["vus_max"] for r in runs if r.get("vus_max")]
        if vus:
            print(f"  vus_max    : {mean([float(v) for v in vus]):>10.1f}")
PYEOF
