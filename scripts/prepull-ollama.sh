#!/usr/bin/env bash
# prepull-ollama.sh — pull the ollama image on EVERY node, so a pod that
# migrates after a reboot/failure starts instantly (no 3.4GB Docker Hub pull).
#
# The MODEL (embeddinggemma) already lives on the NFS PVC and survives
# reboots — this script only pre-warms the per-node image cache.
#
# Usage:
#   ./prepull-ollama.sh            # pull on all 3 nodes
#   ./prepull-ollama.sh k3s-node2  # pull on one node only
#
set -uo pipefail

IMAGE="ollama/ollama:latest"
TARGET="${1:-all}"

if [ "${TARGET}" = "all" ]; then
  NODES=$(kubectl get nodes -o name | cut -d/ -f2)
else
  NODES="${TARGET}"
fi

for node in ${NODES}; do
  echo "=== [${node}] pulling ${IMAGE} ==="
  timeout 900 kubectl debug node/"${node}" -it --image=alpine -- \
    sh -c "echo 'using ctr on host namespace...'" >/dev/null 2>&1 || true
  # direct approach: run ctr on the node via SSH (master has keys)
  IP=$(kubectl get node "${node}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  echo "  node IP: ${IP}"
  if [ "${node}" = "$(kubectl get nodes -o name | head -1 | cut -d/ -f2)" ]; then
    # master: ctr directly
    sudo ctr -n k8s.io images pull "${IMAGE}" 2>&1 | tail -2
  else
    # worker: ctr via ssh from master
    timeout 900 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${IP}" \
      "sudo ctr -n k8s.io images pull '${IMAGE}'" 2>&1 | tail -2
  fi
done

echo
echo "=== done — image present on: ==="
kubectl get nodes -o wide --no-headers | awk '{print $1, $6}'
