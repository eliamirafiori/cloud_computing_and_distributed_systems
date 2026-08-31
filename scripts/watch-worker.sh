#!/bin/bash
# watch-worker.sh — observe worker pod rescheduling after node2 death
export KUBECONFIG=/root/.kube/config
echo "=== osservazione rischedulazione WORKER (node2 morto) — ogni 20s ==="
for i in $(seq 1 20); do
  NOW=$(date '+%H:%M:%S')
  W=$(kubectl get pods -n miraflix -l app=worker -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase' --no-headers 2>/dev/null)
  N2=$(kubectl get node k3s-node2 --no-headers 2>/dev/null | awk '{print $2}')
  echo "[$NOW] node2=$N2 | $W"
  # worker running on a node != node2?
  echo "$W" | grep -v k3s-node2 | grep Running >/dev/null 2>&1 && { echo "=== WORKER RISCHEDULATO ==="; break; }
  sleep 20
done
echo ""
echo "=== health ==="
curl -s -m 5 http://192.168.1.150:30080/health/ | head -c 60
echo ""
echo "=== worker finale ==="
kubectl get pods -n miraflix -l app=worker -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase' 2>/dev/null
