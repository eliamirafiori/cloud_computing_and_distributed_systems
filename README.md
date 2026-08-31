# MiraFLIX — Benchmark & Documentation Branch

This is an **orphan branch** (no shared history with `main`, `docker_compose`
or `k8s`): it contains only the benchmark data, reports and analysis scripts
produced for the CCDS course project.

## Contents

```
bench-results.md              ← the full benchmark report (methodology, per-run
                                data, aggregates, stress re-run, interpretation)
ccds-proxmox-k3s-guide.md     ← the complete setup guide (Proxmox → k3s → HPA)
scripts/                      ← benchmark + analysis scripts (reproducibility)
docker/                       ← 21 raw k6 logs (5 scenarios × 3 runs + stress × 6)
k8s/                          ← 21 raw k6 logs (5 scenarios × 3 runs + stress × 6)
```

> The stress scenario was run **6 times per environment** (3 standard + 3
> dedicated re-runs) because it is the most informative scenario: it is the
> only one that exposes the resilience difference between the two platforms
> (docker backend can die mid-test, k8s never does). See `bench-results.md` Section 4.

## Key numbers (summary)

| Scenario | docker checks% | k8s checks% | docker p95 | k8s p95 |
|---|---|---|---|---|
| smoke | 100% | 100% | 27.8ms | 90.2ms |
| load | 100% | 100% | 32.6ms | 104.3ms |
| queue | 100% | 100% | 8.3ms | 44.1ms |
| search | 100% | 100% | 4.4ms | 5.6ms |
| stream | 100% | 100% | 2.3ms | 3.3ms |
| stress | ~56% (1/6 catastrophic) | ~63% (0/6) | — | — |

## One-line conclusion

> k8s trades ~3× request latency (cost of distribution) for resilience and
> autoscaling: correctness is identical, the docker backend can die under
> stress (manual restart), the k8s one scales and self-heals.

## How the data was produced

- `bench.sh` / `bench-stress.sh`: run the scenarios N times per environment
  with a full baseline reset before every run (queue flush, worker=1, HPA
  paused → re-enabled only for scaling scenarios)
- `analyze.sh`, `deep_analyze.sh`, `per_run.sh`, `compare_stress.sh`,
  `gen_tables.sh`: extract and aggregate the k6 metrics from the raw logs

See `bench-results.md` for the full methodology and honest caveats.
