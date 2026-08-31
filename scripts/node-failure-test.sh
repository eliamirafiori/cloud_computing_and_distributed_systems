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

# pods currently on the target node
log "--- pods on ${NODE} ---"
kubectl get pods -n "${NS}" -o wide --field-selector spec.nodeName="${NODE}" 2>/dev/null | tee -a "${LOG}"
NODE_IP=$(kubectl get node "${NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
log "node IP: ${NODE_IP}"

# ---- phase 1: kill the node ----
T0=$(stamp)
log ""
log "--- phase 1: killing ${NODE} at ${T0} ---"
if [ "${KILL_MODE}" = "soft" ]; then
  log "soft kill: ssh poweroff to ${NODE_IP}"
  timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=8 "root@${NODE_IP}" "poweroff" 2>&1 | tee -a "${LOG}" || true
else
  log "HARD KILL requested — run this on Proxmox NOW:"
  log "    qm stop <VMID of ${NODE}>"
  read -r -p "press ENTER when the node is actually dead..." _
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

  # pods on other nodes (rescheduling happened?)
  NEWPOD=$(kubectl get pods -n "${NS}" -o wide 2>/dev/null \
    | awk -v n="${NODE}" '$7 != n && $3 == "Running"' | grep -v "NAME" | head -1)
  if [ -n "${NEWPOD}" ] && [ -z "${FIRST_RESCHE}" ]; then
    FIRST_RESCHE="${NOW}"
    log "→ first pod running on a surviving node at ${NOW}: ${NEWPOD}"
  fi

  # health
  H=$(curl -s -m 4 -o /dev/null -w "%{http_code}" "${HEALTH_URL}" 2>/dev/null || echo "000")
  if [ "${H}" = "200" ] && [ -z "${RESTORED}" ]; then
    # make sure it really is up (not a fluke)
    sleep 5
    H2=$(curl -s -m 4 -o /dev/null -w "%{http_code}" "${HEALTH_URL}" 2>/dev/null || echo "000")
    if [ "${H2}" = "200" ]; then
      RESTORED="$(stamp)"
      log "→ SERVICE RESTORED at ${RESTORED} (health 200)"
      break
    fi
  fi
  log "  [${NOW}] node=${NSTATUS} health=${H} pods_running=$(kubectl get pods -n "${NS}" --no-headers 2>/dev/null | grep -c Running)"
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
