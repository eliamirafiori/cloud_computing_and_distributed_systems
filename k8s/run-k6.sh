#!/usr/bin/env bash
# run-k6.sh — run a k6 load-test scenario in the cluster with ONE command.
#
# Usage:
#   ./run-k6.sh smoke|load|queue|search|stream|stress [--flush]
#
# What it does:
#   1. refreshes the k6-scripts ConfigMap (script + upload asset)
#   2. deletes any previous k6-run Job
#   3. creates the Job with the requested SCENARIO env
#   4. waits for completion (or failure) and prints the key results
#   5. with --flush: empties the RQ queue afterwards so the next test can
#      start immediately (search/stress would otherwise queue behind the
#      backlog and time out)
#
# Example:
#   ./run-k6.sh queue --flush   # enqueue re-embed jobs, then empty the queue
#   ./run-k6.sh search          # clean run right after
#
set -euo pipefail

# ---------- config ----------
SCENARIO="${1:-}"
FLUSH=0
if [ "${2:-}" = "--flush" ]; then FLUSH=1; fi
NS="${K6_NAMESPACE:-miraflix}"
JOB="k6-run"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_SRC="${REPO_DIR}/k6/script.js"
ASSET_SRC="${REPO_DIR}/k6/assets/sample_small.mp4"
RW_URL="${K6_RW_URL:-http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/write}"
BASE_URL="${K6_BASE_URL:-http://my-backend:8000}"
TIMEOUT_S="${K6_TIMEOUT_S:-300}"

VALID="smoke load queue search stream stress"
if [ -z "${SCENARIO}" ]; then
  echo "usage: $0 <scenario>   (one of: ${VALID})" >&2
  exit 1
fi
if ! echo "${VALID}" | grep -qw "${SCENARIO}"; then
  echo "error: unknown scenario '${SCENARIO}' (valid: ${VALID})" >&2
  exit 1
fi

# ---------- 1. refresh ConfigMap ----------
echo "==> ConfigMap k6-scripts (${NS})"
kubectl create configmap k6-scripts \
  --from-file=script.js="${SCRIPT_SRC}" \
  --from-file=sample_small.mp4="${ASSET_SRC}" \
  -n "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------- 2. delete old job (ignore "not found") ----------
kubectl delete job "${JOB}" -n "${NS}" --ignore-not-found >/dev/null

# ---------- 3. create Job ----------
echo "==> Job ${JOB} (scenario: ${SCENARIO})"
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:latest
          command: ["k6", "run", "-o", "experimental-prometheus-rw", "/scripts/script.js"]
          env:
            - name: SCENARIO
              value: "${SCENARIO}"
            - name: BASE_URL
              value: "${BASE_URL}"
            - name: K6_PROMETHEUS_RW_SERVER_URL
              value: "${RW_URL}"
            - name: K6_PROMETHEUS_RW_TREND_STATS
              value: "p(95),p(99)"
          volumeMounts:
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: scripts
          configMap:
            name: k6-scripts
            items:
              - key: script.js
                path: script.js
              - key: sample_small.mp4
                path: assets/sample_small.mp4
EOF

# ---------- 4. wait and show results ----------
echo "==> waiting for completion (timeout ${TIMEOUT_S}s)..."
kubectl wait --for=condition=complete "job/${JOB}" -n "${NS}" --timeout="${TIMEOUT_S}s" \
  || echo "!! job did not complete (failed or timed out) — logs below"

echo "==> results"
kubectl logs "job/${JOB}" -n "${NS}" --tail=40 2>/dev/null \
  | grep -E "checks|✓|✗|http_req_failed|http_reqs|iterations\.|embedding_ready|crossed" \
  || kubectl logs "job/${JOB}" -n "${NS}" --tail=40 2>/dev/null || true

# ---------- 5. optional: empty the RQ queue ----------
if [ "${FLUSH}" = "1" ]; then
  echo "==> flushing RQ queue (rq:queue:videos)..."
  kubectl exec -n "${NS}" deploy/redis -- redis-cli DEL rq:queue:videos >/dev/null 2>&1 \
    || echo "!! could not flush queue (redis not reachable?)"
  echo "==> queue flushed, next test can start immediately"
fi
