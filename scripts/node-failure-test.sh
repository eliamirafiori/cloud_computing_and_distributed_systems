#!/usr/bin/env bash
# node-failure-test.sh — simulate a worker node death and measure how long
# k8s takes to restore the service WITHOUT human intervention.
#
# Usage:
#   ./node-failure-test.sh                 # pick the worker with most pods
#   ./node-failure-test.sh k3s-node1       # test a specific node
#   ./node-failure-test.sh k3s-node1 --kill hard   # hard kill (qm stop from Proxmox)
#
# Phases:
#   0. baseline: nodes, pods, health, HPA
#   1. kill the target node (soft: ssh poweroff | hard: you run qm stop)
#   2. observe every 10s: node status, pods, health endpoint
#   3. detect rescheduling (pods recreated on surviving nodes)
#   4. service restored (health 200 again)
#   5. report: timeline + total service outage time
#
set -uo pipefail

NODE="${1:-auto}"
KILL_MODE="${2:-soft}"
NS="miraflix"
HEALTH_URL="http://192.168.1.150:30080/health/"
REPORT="node-failure-report.md"
LOG="node-failure.log"

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }
stamp(){ date '+%H:%M:%S'; }

# ---- phase 0: baseline ----
log "===== NODE FAILURE TEST ====="
log "target node: ${NODE} | kill mode: ${KILL_MODE}"
log ""
log "--- baseline: nodes ---"
kubectl get nodes -o wide | tee -a "${LOG}"
log ""
log "--- baseline: pods in ${NS} ---"
kubectl get pods -n "${NS}" -o wide | tee -a "${LOG}"
log ""
log "--- baseline: HPA ---"
kubectl get hpa -n "${NS}" | tee -a "${LOG}"
log ""
log "--- baseline: health ---"
curl -s -m 5 "${HEALTH_URL}" | head -c 100 | tee -a "${LOG}"
echo "" | tee -a "${LOG}"

# pick the target node automatically: the worker hosting the most pods
if [ "${NODE}" = "auto" ]; then
  NODE=$(kubectl get pods -n "${NS}" -o wide --no-headers 2>/dev/null \
    | awk '{print $7}' | grep -v "$(kubectl get nodes -o name | head -1 | cut -d/ -f2)" \
    | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  log "auto-selected node: ${NODE}"
fi

# pods currently on the target node (tracked by name for rescheduling)
log "--- pods on ${NODE} ---"
PODS_ON_NODE=$(kubectl get pods -n "${NS}" -o jsonpath='{range .items[?(@.spec.nodeName=="'"${NODE}"'")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
echo "${PODS_ON_NODE}" | tee -a "${LOG}"
NODE_IP=$(kubectl get node "${NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
log "node IP: ${NODE_IP}"

# ---- phase 1: kill the node ----
T0=$(stamp)
log ""
log "--- phase 1: killing ${NODE} at ${T0} ---"
if [ "${KILL_MODE}" = "soft" ]; then
  log "soft kill: ssh poweroff to ${NODE_IP}"
  timeout 20 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "root@${NODE_IP}" "poweroff" 2>&1 | tee -a "${LOG}" || true
  # VERIFY the node is really dying (stop responding to ping within 60s)
  log "verifying node is actually down..."
  DOWN=0
  for i in $(seq 1 12); do
    sleep 5
    if ! ping -c1 -W2 "${NODE_IP}" >/dev/null 2>&1; then
      DOWN=1
      log "node ${NODE} is DOWN (no ping) after ~$((i*5))s"
      break
    fi
  done
  if [ "${DOWN}" = "0" ]; then
    log "!! node still responding after 60s — ABORTING (kill failed)"
    log "report: n/a (kill failed — node never went down)"
    exit 1
  fi
else
  log "HARD KILL requested — run this on Proxmox NOW:"
  log "    qm stop <VMID of ${NODE}>"
  read -r -p "press ENTER when the node is actually dead..." _
  # verify too
  for i in $(seq 1 12); do
    sleep 5
    if ! ping -c1 -W2 "${NODE_IP}" >/dev/null 2>&1; then
      DOWN=1
      log "node ${NODE} is DOWN (no ping)"
      break
    fi
  done
  if [ "${DOWN}" != "1" ]; then
    log "!! node still responding — ABORTING"
    exit 1
  fi
fi

# ---- phase 2+3: observe until service restored ----
log ""
log "--- phase 2/3: observing (every 10s) ---"
FIRST_NOTREADY=""
FIRST_RESCHE=""
RESTORED=""
for i in $(seq 1 120); do   # up to 20 minutes
  sleep 10
  NOW=$(stamp)

  # node status
  NSTATUS=$(kubectl get node "${NODE}" --no-headers 2>/dev/null | awk '{print $2}' || echo "UNREACHABLE")
  if [ "${NSTATUS}" != "Ready" ] && [ "${NSTATUS}" != "UNREACHABLE" ] && [ -z "${FIRST_NOTREADY}" ]; then
    FIRST_NOTREADY="${NOW} (${NSTATUS})"
    log "→ node ${NODE} NOT READY at ${NOW} (${NSTATUS})"
  fi

  # pods of the DEAD node recreated on a surviving node (rescheduling)
  if [ -z "${FIRST_RESCHE}" ] && [ -n "${PODS_ON_NODE}" ]; then
    for pod in ${PODS_ON_NODE}; do
      PNAME=$(echo "${pod}" | sed 's/\(.*\)-[a-z0-9]*-[a-z0-9]*$/\1/')
      NEWNODE=$(kubectl get pod -n "${NS}" "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
      NEWSTATUS=$(kubectl get pod -n "${NS}" "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [ -n "${NEWNODE}" ] && [ "${NEWNODE}" != "${NODE}" ] && [ "${NEWSTATUS}" = "Running" ]; then
        FIRST_RESCHE="${NOW}"
        log "→ pod ${pod} recreated on ${NEWNODE} at ${NOW} (rescheduling detected)"
        break
      fi
    done
  fi

  # health (informative — may not drop if the backend is on another node)
  H=$(curl -s -m 4 -o /dev/null -w "%{http_code}" "${HEALTH_URL}" 2>/dev/null || echo "000")

  # COMPLETION CONDITION: for every pod that WAS on the dead node, its
  # ReplicaSet now has a Running pod on a SURVIVING node. (The recreated
  # pod has a NEW name, so we must match by ReplicaSet label, not by pod name.)
  ALL_RESCHE=1
  if [ -n "${PODS_ON_NODE}" ]; then
    for pod in ${PODS_ON_NODE}; do
      # find the ReplicaSet owner label (e.g. pod-template-hash) of the old pod
      PTPL=$(kubectl get pod -n "${NS}" "${pod}" -o jsonpath='{.metadata.labels.pod-template-hash}' 2>/dev/null || true)
      if [ -n "${PTPL}" ]; then
        # any Running pod of the same ReplicaSet on a node != dead node?
        OK=$(kubectl get pods -n "${NS}" -l "pod-template-hash=${PTPL}" -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
          | awk -v n="${NODE}" '$1 != n && $2 == "Running"' | head -1)
        if [ -z "${OK}" ]; then ALL_RESCHE=0; break; fi
      else
        # fallback: any Running pod of the same app label on another node
        APP=$(kubectl get pod -n "${NS}" "${pod}" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || true)
        OK=$(kubectl get pods -n "${NS}" -l "app=${APP}" -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
          | awk -v n="${NODE}" '$1 != n && $2 == "Running"' | head -1)
        if [ -z "${OK}" ]; then ALL_RESCHE=0; break; fi
      fi
    done
  else
    ALL_RESCHE=0
  fi
  if [ "${ALL_RESCHE}" = "1" ] && [ -z "${RESTORED}" ]; then
    RESTORED="$(stamp)"
    log "→ ALL pods of ${NODE} recreated & Running on surviving nodes at ${RESTORED}"
    log "  (health during test: last=${H})"
    break
  fi
  log "  [${NOW}] node=${NSTATUS} health=${H} rescheduled=${ALL_RESCHE}/1"
done

# ---- phase 4: final state ----
log ""
log "--- phase 4: final state ---"
kubectl get nodes -o wide | tee -a "${LOG}"
kubectl get pods -n "${NS}" -o wide | tee -a "${LOG}"
kubectl get hpa -n "${NS}" | tee -a "${LOG}"

# ---- phase 5: report ----
log ""
log "===== REPORT ====="
if [ -n "${FIRST_NOTREADY}" ]; then log "node NotReady:      ${FIRST_NOTREADY}"; else log "node NotReady:      never detected"; fi
if [ -n "${FIRST_RESCHE}" ]; then log "first reschedule:   ${FIRST_RESCHE}"; else log "first reschedule:   never detected"; fi
if [ -n "${RESTORED}" ]; then log "service restored:   ${RESTORED}"; else log "service restored:   NOT restored within window"; fi
log "kill at:            ${T0}"

# compute durations (HH:MM:SS diff)
python3 - "${T0}" "${FIRST_NOTREADY}" "${FIRST_RESCHE}" "${RESTORED}" <<'PYEOF' | tee -a "${LOG}"
import sys
def sec(t):
    if not t or t.startswith("never") or t == "": return None
    h,m,s = t.split(":")[:3]
    return int(h)*3600+int(m)*60+int(s)
t0, tnr, tres, tr = (sec(x) for x in sys.argv[1:5])
def fmt(a,b):
    if a is None or b is None: return "n/a"
    d = b-a
    return f"{d//60}m{d%60:02d}s"
print(f"  detection time (kill→NotReady):    {fmt(t0, tnr)}")
print(f"  reschedule time (kill→first pod):  {fmt(t0, tres)}")
print(f"  SERVICE OUTAGE (kill→health 200):  {fmt(t0, tr)}")
PYEOF
log ""
log "full log: ${LOG}"
