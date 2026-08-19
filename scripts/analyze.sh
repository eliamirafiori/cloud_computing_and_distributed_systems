#!/usr/bin/env bash
# analyze.sh — extract metrics from bench/<env>/ logs and compute statistics.
#
# Usage:
#   ./analyze.sh docker
#   ./analyze.sh k8s
#   ./analyze.sh all          # both environments, side by side
#
# For each scenario it extracts from every run:
#   - checks_succeeded %
#   - http_req_failed %
#   - http_reqs (total requests)
#   - iterations
#   - http_req_duration p95
#   - iteration_duration p95
# Then prints per-scenario: mean, median, std-dev, min, max.
#
set -uo pipefail

ENV="${1:-all}"
SCENARIOS="smoke load queue search stream stress"
BASE="bench"

python3 - "${ENV}" <<'PYEOF'
import sys, os, re, statistics

env_arg = sys.argv[1]
BASE = "bench"
scenarios = ["smoke", "load", "queue", "search", "stream", "stress"]
envs = ["docker", "k8s"] if env_arg == "all" else [env_arg]

def extract(path):
    """Return dict of metrics from a k6 log file, or None."""
    try:
        text = open(path).read()
    except OSError:
        return None
    m = {}
    def grab(pattern, group=1):
        r = re.search(pattern, text)
        return r.group(group) if r else None
    m["checks_succeeded"] = grab(r"checks_succeeded\.\.\.: ([0-9.]+)%")
    m["checks_failed"] = grab(r"checks_failed\.\.\.\.: ([0-9.]+)%")
    m["http_req_failed"] = grab(r"http_req_failed\.*\.*\.*\.*: ([0-9.]+)%")
    m["http_reqs"] = grab(r"http_reqs\.*\.*\.*\.*: (\d+)")
    m["iterations"] = grab(r"iterations\.*\.*\.*\.*: (\d+)")
    def grab_p95(pattern):
        r = re.search(pattern, text)
        if not r:
            return None
        val, unit = r.group(1), r.group(2)
        if unit == "s":
            return str(float(val) * 1000)  # seconds -> ms
        return val
    m["req_p95"] = grab_p95(r"http_req_duration\.*\.*\.*\.*: .*p\(95\)=([0-9.]+)(ms|s)")
    m["iter_p95"] = grab_p95(r"iteration_duration\.*\.*\.*\.*: .*p\(95\)=([0-9.]+)(ms|s)")
    return m

def stats(values):
    """mean, median, stdev, min, max of numeric list."""
    if not values:
        return None
    return {
        "mean": round(statistics.mean(values), 2),
        "median": round(statistics.median(values), 2),
        "stdev": round(statistics.stdev(values), 2) if len(values) > 1 else 0.0,
        "min": round(min(values), 2),
        "max": round(max(values), 2),
    }

results = {}
for env in envs:
    results[env] = {}
    for sc in scenarios:
        files = sorted(
            f for f in os.listdir(f"{BASE}/{env}") if f.startswith(f"{sc}-") and f.endswith(".log")
        )
        runs = []
        for f in files:
            m = extract(f"{BASE}/{env}/{f}")
            if m and m["checks_succeeded"]:
                runs.append(m)
        results[env][sc] = {"files": files, "runs": runs}

# ---- output ----
for env in envs:
    print(f"\n{'='*70}")
    print(f"ENVIRONMENT: {env}  ({sum(len(v['runs']) for v in results[env].values())} valid runs)")
    print('='*70)
    for sc in scenarios:
        r = results[env][sc]
        if not r["runs"]:
            print(f"\n[{sc}] — no valid runs")
            continue
        n = len(r["runs"])
        print(f"\n[{sc}]  runs={n}  files={len(r['files'])}")
        for metric in ["checks_succeeded", "http_req_failed", "http_reqs", "req_p95", "iter_p95"]:
            vals = []
            for run in r["runs"]:
                v = run.get(metric)
                if v is not None:
                    try:
                        vals.append(float(v))
                    except ValueError:
                        pass
            s = stats(vals)
            if s:
                print(f"  {metric:20s} mean={s['mean']:>10}  median={s['median']:>10}  "
                      f"stdev={s['stdev']:>8}  min={s['min']:>10}  max={s['max']:>10}")

# ---- side-by-side summary ----
if env_arg == "all":
    print(f"\n{'='*70}")
    print("SIDE-BY-SIDE: mean checks% / mean failed% / mean p95(ms)")
    print('='*70)
    print(f"{'scenario':10s} {'docker checks':>14s} {'k8s checks':>12s} | {'docker fail':>12s} {'k8s fail':>10s} | {'docker p95':>11s} {'k8s p95':>9s}")
    print('-'*70)
    for sc in scenarios:
        def mean_metric(env, sc, metric):
            runs = results[env][sc]["runs"]
            vals = []
            for r in runs:
                v = r.get(metric)
                if v is not None:
                    try: vals.append(float(v))
                    except ValueError: pass
            return round(statistics.mean(vals), 2) if vals else float('nan')
        print(f"{sc:10s} {mean_metric('docker', sc, 'checks_succeeded'):>13.2f}% "
              f"{mean_metric('k8s', sc, 'checks_succeeded'):>11.2f}% | "
              f"{mean_metric('docker', sc, 'http_req_failed'):>11.2f}% "
              f"{mean_metric('k8s', sc, 'http_req_failed'):>9.2f}% | "
              f"{mean_metric('docker', sc, 'req_p95'):>10.2f} "
              f"{mean_metric('k8s', sc, 'req_p95'):>8.2f}")
PYEOF
