#!/usr/bin/env bash
# compare_stress.sh — compare stress runs: original vs re-run, per run
set -uo pipefail

python3 - <<'PYEOF'
import os, re

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
        pp = re.search(r"p\(95\)=([0-9.]+)(ms|s)", r.group(0))
        if pp:
            v = float(pp.group(1)) * (1000 if pp.group(2) == "s" else 1)
            m["p95"] = str(int(v))
    return m

for env in ["docker", "k8s"]:
    print(f"\n{'='*66}")
    print(f"STRESS — {env}: original (first bench) vs re-run")
    print('='*66)
    print(f"  {'run':4s} {'checks%':>8s} {'failed%':>8s} {'reqs':>6s} {'iters':>6s} {'drop':>6s} {'emb%':>7s} {'p95(ms)':>9s}")
    for i in [1, 2, 3]:
        o = extract(f"bench/{env}/stress-{i}.log")
        n = extract(f"bench/stress-rerun/{env}/stress-{i}.log")
        print(f"  orig {i}: {o.get('checks','?'):>8s} {o.get('failed','?'):>8s} {o.get('reqs','?'):>6s} {o.get('iters','?'):>6s} {o.get('dropped','?'):>6s} {o.get('emb','?'):>7s} {o.get('p95','?'):>9s}")
        print(f"  new  {i}: {n.get('checks','?'):>8s} {n.get('failed','?'):>8s} {n.get('reqs','?'):>6s} {n.get('iters','?'):>6s} {n.get('dropped','?'):>6s} {n.get('emb','?'):>7s} {n.get('p95','?'):>9s}")
PYEOF
