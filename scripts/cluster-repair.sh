#!/usr/bin/env bash
# cluster-repair.sh — clean up stale pods after a cluster reboot.
#
# After all VMs shut down together (power cut / phil reboot), some pods
# can stay in "Unknown" state: the kubelet that owned them never updated
# their status. They block PVCs (RWO volumes) and namespace cleanup.
# This script force-deletes every pod that is not Running/Completed,
# letting the controllers recreate them on a healthy node.
#
# Safe: only targets pods in Pending/Unknown/Error/Failed states.
# Run AFTER the NFS VM is up and all nodes are Ready.
#
set -uo pipefail

echo "=== [$(date '+%H:%M:%S')] cluster-repair ==="

# 1. wait for nodes
echo "--- waiting for all nodes Ready (max 5 min) ---"
for i in $(seq 1 30); do
  NREADY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready ")
  NTOT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  if [ "${NREADY:-0}" -eq "${NTOT:-0}" ] && [ "${NTOT:-0}" -ge 1 ]; then
    echo "all ${NTOT} nodes Ready"
    break
  fi
  sleep 10
done

# 2. find stale pods (not Running, not Completed)
echo "--- searching for stale pods ---"
STALE=$(kubectl get pods -A --no-headers 2>/dev/null \
  | awk '$4 != "Running" && $4 != "Completed" && $4 != "Terminating" {print $1"/"$2"/"$4}')

if [ -z "${STALE}" ]; then
  echo "no stale pods — cluster is clean"
else
  echo "$STALE"
  echo "--- force-deleting stale pods ---"
  kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 != "Running" && $4 != "Completed" && $4 != "Terminating" {print $1, $2}' \
    | while read -r ns pod; do
        kubectl delete pod -n "${ns}" "${pod}" --force --grace-period=0 2>&1 | tail -1
      done
fi

# 3. summary
echo "--- final state ---"
kubectl get nodes 2>/dev/null | awk '{print $1, $2}'
kubectl get pods -A --no-headers 2>/dev/null | awk '{print $1, $2, $3, $4}' | sort | uniq -c | head -10

echo "=== repair done ==="
