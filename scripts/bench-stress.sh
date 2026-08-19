#!/usr/bin/env bash
# bench-stress.sh — run ONLY the stress scenario N times (full reset each time)
# Usage: ./bench-stress.sh k8s 3 | docker 3
set -euo pipefail

ENV="${1:?usage: bench-stress.sh k8s|docker N}"
N="${2:?usage: bench-stress.sh k8s|docker N}"
OUT="bench/${ENV}-stress2"
mkdir -p "${OUT}"

log() { echo "[bench-stress:${ENV}] $*"; }

reset_k8s() {
  log "reset: flush queue + pause HPA + scale worker to 1"
  kubectl exec -n miraflix deploy/redis -- redis-cli DEL rq:queue:videos >/dev/null 2>&1 || true
  kubectl patch hpa worker-hpa -n miraflix --type=merge -p '{"spec":{"maxReplicas":1}}' >/dev/null
  kubectl scale deploy worker --replicas=1 -n miraflix >/dev/null
  kubectl rollout status deploy/worker -n miraflix --timeout=180s >/dev/null
  kubectl scale deploy backend --replicas=1 -n miraflix >/dev/null
  kubectl rollout status deploy/backend -n miraflix --timeout=120s >/dev/null
  log "reset: waiting for metrics to cool down with HPA paused (90s)..."
  sleep 90
  local rq hpa
  rq=$(kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/miraflix/rq_queue_length" 2>/dev/null | grep -o '"value":"[0-9]*"' | head -1 | grep -o '[0-9]*' || echo "?")
  hpa=$(kubectl get hpa worker-hpa -n miraflix -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "?")
  log "reset done: queue=${rq} hpa_replicas=${hpa} (HPA stays paused)"
}

unpause_hpa() {
  kubectl patch hpa worker-hpa -n miraflix --type=merge -p '{"spec":{"maxReplicas":8}}' >/dev/null
  log "HPA unpaused (maxReplicas=8)"
}

reset_docker() {
  log "reset: flush queue + wait + restart backend"
  docker compose -f /root/miraflix/docker-compose.yml exec -T redis redis-cli DEL rq:queue:videos >/dev/null 2>&1 || true
  sleep 15
  docker restart my_backend >/dev/null 2>&1 || true
  log "reset: waiting for backend healthy (30s)..."
  sleep 30
}

for run in $(seq 1 "${N}"); do
  log "===== STRESS RUN ${run}/${N} ====="
  if [ "${ENV}" = "k8s" ]; then
    reset_k8s
    unpause_hpa
    sleep 15
    K6_FULL_LOG=1 ./k8s/run-k6.sh stress --flush > "${OUT}/stress-${run}.log" 2>&1 || true
  else
    reset_docker
    ( cd /root/miraflix && make stress ) > "${OUT}/stress-${run}.log" 2>&1 || true
  fi
  log "done -> ${OUT}/stress-${run}.log"
done
log "ALL DONE"
