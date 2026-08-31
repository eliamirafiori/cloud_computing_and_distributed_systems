#!/usr/bin/env bash
# watch-boot.sh — observe full system recovery after a COMPLETE power cut.
#
# Run this BEFORE the power cut (it keeps polling until everything is back).
# It records the timeline of: VMs up → nodes Ready → all pods Running →
# service healthy → Grafana up.
#
# Usage:  ./watch-boot.sh   (run from the master or admin; polls every 30s)
set -uo pipefail

# VMs (Proxmox guests): master, node1, node2, nfs
VMS=(192.168.1.150 192.168.1.151 192.168.1.152 192.168.1.153)
NAMES=(k3s-master k3s-node1 k3s-node2 nfs)
HEALTH="http://192.168.1.150:30080/health/"
LOG="boot-recovery.log"
export KUBECONFIG=/root/.kube/config

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG}"; }

log "===== FULL POWER-CUT RECOVERY WATCH ====="
log "waiting for VMs to come back (polling every 30s, up to 20 min)..."

ALL_UP=0
ALL_NODES_READY=0
ALL_PODS_RUNNING=0
SERVICE_OK=""
GRAFANA_OK=""

for i in $(seq 1 40); do   # 40 × 30s = 20 min
  sleep 30
  NOW=$(date '+%H:%M:%S')

  # 1. VMs up?
  UP=0
  for ip in "${VMS[@]}"; do
    ping -c1 -W2 "${ip}" >/dev/null 2>&1 && UP=$((UP+1))
  done
  if [ "${UP}" = "4" ] && [ "${ALL_UP}" = "0" ]; then
    ALL_UP=1
    log "ALL 4 VMs UP at ${NOW} (master+2 workers+NFS)"
  fi

  # 2. nodes Ready?
  NREADY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
  if [ "${NREADY}" = "3" ] && [ "${ALL_NODES_READY}" = "0" ]; then
    ALL_NODES_READY=1
    log "ALL 3 NODES READY at ${NOW}"
  fi

  # 3. all miraflix pods Running?
  PTOT=$(kubectl get pods -n miraflix --no-headers 2>/dev/null | wc -l || echo 0)
  PRUN=$(kubectl get pods -n miraflix --no-headers 2>/dev/null | grep -c Running || echo 0)
  if [ "${PTOT}" -ge 1 ] && [ "${PTOT}" = "${PRUN}" ] && [ "${ALL_PODS_RUNNING}" = "0" ]; then
    ALL_PODS_RUNNING=1
    log "ALL ${PRUN} miraflix PODS RUNNING at ${NOW}"
  fi

  # 4. service healthy?
  H=$(curl -s -m 4 -o /dev/null -w "%{http_code}" "${HEALTH}" 2>/dev/null || echo 000)
  if [ "${H}" = "200" ] && [ -z "${SERVICE_OK}" ]; then
    SERVICE_OK="${NOW}"
    log "SERVICE HEALTHY (200) at ${NOW}"
  fi

  # 5. grafana up?
  G=$(curl -s -m 4 -o /dev/null -w "%{http_code}" "http://192.168.1.150:30001/api/health" 2>/dev/null || echo 000)
  if [ "${G}" = "200" ] && [ -z "${GRAFANA_OK}" ]; then
    GRAFANA_OK="${NOW}"
    log "GRAFANA UP at ${NOW}"
  fi

  # done?
  if [ -n "${SERVICE_OK}" ] && [ -n "${GRAFANA_OK}" ]; then
    log "===== RECOVERY COMPLETE ====="
    break
  fi

  log "  [${NOW}] vms=${UP}/4 nodes_ready=${NREADY}/3 pods=${PRUN}/${PTOT} health=${H} grafana=${G}"
done

# final report
log ""
log "===== RECOVERY TIMELINE (power cut → full service) ====="
log "  VMs up:          ${ALL_UP}"
log "  nodes Ready:     ${ALL_NODES_READY}"
log "  pods Running:    ${ALL_PODS_RUNNING}"
log "  service healthy: ${SERVICE_OK:-NOT YET}"
log "  grafana up:      ${GRAFANA_OK:-NOT YET}"
log "  full log: ${LOG}"
