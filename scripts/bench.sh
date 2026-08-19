#!/usr/bin/env bash
# bench.sh — run the full k6 benchmark N times on one environment.
#
# Usage:
#   ./bench.sh k8s 10     # 10 full runs on the k3s cluster
#   ./bench.sh docker 10  # 10 full runs on the docker VM
#
# Each run = smoke load queue search stream stress.
# Before EVERY run the environment is RESET to a consistent state:
#   - queue flushed
#   - worker scaled back to 1 (k8s) / already fixed at 1 (docker)
#   - wait for HPA/metrics to stabilize (k8s) so the next test always
#     starts from the same baseline (otherwise HPA cooldown contaminates
#     the data — the core consistency problem this script solves)
#
# Results are saved to bench/<env>/<scenario>-<run>.log
#
set -euo pipefail

ENV="${1:?usage: bench.sh k8s|docker N}"
N="${2:?usage: bench.sh k8s|docker N}"
# ORDER MATTERS: the non-scaling scenarios (smoke/load/search/stream) run
# first so they always start from the 1-worker baseline; the scaling
# scenarios (queue/stress) run last — they drive the HPA up, and a mini
# reset before stress brings the worker back to 1.
SCENARIOS="smoke load search stream queue stress"
OUT="bench/${ENV}"
mkdir -p "${OUT}"

log() { echo "[bench:${ENV}] $*"; }

reset_k8s() {
  log "reset: flush queue + pause HPA + scale worker to 1"
  # flush the queue (pending jobs)
  kubectl exec -n miraflix deploy/redis -- redis-cli DEL rq:queue:videos >/dev/null 2>&1 || true
  # PAUSE the HPA: cap maxReplicas=1 so it cannot fight the scale-down
  kubectl patch hpa worker-hpa -n miraflix --type=merge \
    -p '{"spec":{"maxReplicas":1}}' >/dev/null
  # scale down and WAIT until the worker is really at 1 replica
  kubectl scale deploy worker --replicas=1 -n miraflix >/dev/null
  kubectl rollout status deploy/worker -n miraflix --timeout=180s >/dev/null
  # also scale backend down/up so it starts clean (HPA backend too)
  kubectl scale deploy backend --replicas=1 -n miraflix >/dev/null
  kubectl rollout status deploy/backend -n miraflix --timeout=120s >/dev/null
  # CRITICAL: wait with the HPA STILL PAUSED so the metrics cool down.
  # Prometheus keeps the series of terminated pods for ~5min (staleness
  # threshold), so restoring maxReplicas=8 too early makes the HPA re-scale
  # on the still-visible CPU of the old workers.
  log "reset: waiting for metrics to cool down with HPA paused (90s)..."
  sleep 90
  local rq hpa
  rq=$(kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/miraflix/rq_queue_length" 2>/dev/null | grep -o '"value":"[0-9]*"' | head -1 | grep -o '[0-9]*' || echo "?")
  hpa=$(kubectl get hpa worker-hpa -n miraflix -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "?")
  log "reset done: queue=${rq} hpa_replicas=${hpa} (HPA stays paused)"
  # NOTE: maxReplicas stays 1 here. The scenarios that must be able to
  # scale (queue, stress) restore maxReplicas=8 right before running.
}

# restore the HPA scaling capability for scenarios that must scale
unpause_hpa() {
  kubectl patch hpa worker-hpa -n miraflix --type=merge \
    -p '{"spec":{"maxReplicas":8}}' >/dev/null
  log "HPA unpaused (maxReplicas=8) for scaling scenario"
}

reset_docker() {
  log "reset: flush queue + wait for worker to drain current job + restart backend"
  docker compose -f /root/miraflix/docker-compose.yml exec -T redis redis-cli DEL rq:queue:videos >/dev/null 2>&1 || true
  # wait until the queue is really empty AND the worker finished its current
  # job (sleep generously: embedding takes ~4-5s per job)
  sleep 15
  docker restart my_backend >/dev/null 2>&1 || true
  log "reset: waiting for backend healthy (30s)..."
  sleep 30
}

run_scenario() {
  local scenario="$1" run="$2"
  local logf="${OUT}/${scenario}-${run}.log"
  log "run ${run}/${N}: ${scenario}"
  # queue and stress are the scaling scenarios: restore the HPA right
  # before them so the test itself drives the scale-up from a 1-worker
  # baseline. The other scenarios keep the HPA paused (maxReplicas=1).
  if [ "${ENV}" = "k8s" ] && { [ "${scenario}" = "queue" ] || [ "${scenario}" = "stress" ]; }; then
    unpause_hpa
    # stress runs right after queue (which left 8 workers): bring it back
    # to 1 with a mini reset so every scaling scenario starts from the
    # same baseline.
    if [ "${scenario}" = "stress" ]; then
      log "mini-reset before stress: pause HPA, scale worker to 1"
      kubectl patch hpa worker-hpa -n miraflix --type=merge \
        -p '{"spec":{"maxReplicas":1}}' >/dev/null
      kubectl scale deploy worker --replicas=1 -n miraflix >/dev/null
      kubectl rollout status deploy/worker -n miraflix --timeout=180s >/dev/null
      sleep 60
      kubectl patch hpa worker-hpa -n miraflix --type=merge \
        -p '{"spec":{"maxReplicas":8}}' >/dev/null
      log "mini-reset done, stress starts from 1 worker"
    fi
    # let the HPA pick up the restored max before the test starts
    sleep 15
  fi
  if [ "${ENV}" = "k8s" ]; then
    K6_FULL_LOG=1 ./k8s/run-k6.sh "${scenario}" --flush > "${logf}" 2>&1 || true
  else
    ( cd /root/miraflix && make "${scenario}" ) > "${logf}" 2>&1 || true
  fi
  log "done: ${scenario} -> ${logf}"
}

for run in $(seq 1 "${N}"); do
  log "===== RUN ${run}/${N} ====="
  if [ "${ENV}" = "k8s" ]; then reset_k8s; else reset_docker; fi
  for s in ${SCENARIOS}; do
    run_scenario "${s}" "${run}"
  done
  log "===== RUN ${run} complete ====="
done

log "ALL DONE — results in ${OUT}/"
