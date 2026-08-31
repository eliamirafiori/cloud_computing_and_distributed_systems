#!/bin/bash
# watch-reschedule.sh — observe pod rescheduling after node1 death (every 30s)
export KUBECONFIG=/root/.kube/config
echo "=== osservazione rischedulazione pod (node1 morto) — ogni 30s ==="
for i in $(seq 1 16); do
  NOW=$(date '+%H:%M:%S')
  echo ""
  echo "--- [$NOW] check $i ---"
  kubectl get pods -n miraflix -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase' 2>/dev/null
  N1=$(kubectl get node k3s-node1 --no-headers 2>/dev/null | awk '{print $2}')
  echo "node1: ${N1}"
  # postgres/redis su altro nodo?
  MOVED=$(kubectl get pods -n miraflix -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -E "postgres|redis" | grep -v k3s-node1 | grep Running | wc -l)
  echo "pod dati rischedulati (Running su nodo vivo): ${MOVED}"
  if [ "${MOVED}" -ge 3 ]; then
    echo "=== TUTTI I POD DATI RISCHEDULATI ==="
    break
  fi
  sleep 30
done
echo ""
echo "=== health backend ==="
curl -s -m 5 http://192.168.1.150:30080/health/ | head -c 80
echo ""
echo "=== dati intatti? (postgres query) ==="
kubectl exec -n miraflix deploy/postgres -- psql -U postgres -d miraflix -c "SELECT count(*) FROM videos;" 2>&1 | head -4 || echo "(postgres non ancora su)"
