# ============================================================================
# MiraFLIX — unified Makefile for the K8S branch
# ============================================================================
# Same targets as the docker_compose branch, but runs inside the k3s cluster.
#
# Lifecycle : up down build pull ps
# Monitoring: stack health logs qlen watch-queue prometheus grafana info
# Test      : smoke load queue search stream stress all
# Utility   : flush seed scale-workers restart-backend dashboard-dl clean
#
# Quick start (on the master node, inside the repo):
#   make queue        # run the queue scenario (auto-flushes afterwards)
#   make all          # full sequence: smoke -> load -> queue -> search -> stream -> stress
#   make help         # full target list
# ============================================================================

NS       ?= miraflix
# One-command runner (ConfigMap refresh + Job + wait + results + optional flush)
K6_RUN   := ./k8s/run-k6.sh
# Backend reachable from inside the cluster (Service NodePort on any node)
BACKEND  ?= http://192.168.1.150:30080
GRAFANA  ?= http://192.168.1.150:30001

.PHONY: up down down-clean build pull ps stack health logs \
        logs-backend logs-worker qlen watch-queue prometheus grafana info \
        smoke load queue search stream stress all \
        flush seed scale-workers restart-backend dashboard-dl clean help

# ---------------------------------------------------------------------------
# Lifecycle (k8s: cluster is already running; these are informational)
# ---------------------------------------------------------------------------

up: ## cluster status (k8s: no stack to start)
	@kubectl get nodes -o wide
	@echo "MiraFLIX: http://$(BACKEND)/docs"
	@echo "Grafana : $(GRAFANA)"

down: ## stop the miraflix namespace (k8s)
	@echo "Stopping miraflix namespace (pods scaled to 0):"
	@kubectl scale deploy --all --replicas=0 -n $(NS)

down-clean: ## delete the miraflix namespace and its volumes
	@echo "WARNING: this deletes Postgres, Redis and upload data!"
	@kubectl delete ns $(NS)

build: ## rebuild the backend image (push to GHCR from a Docker machine)
	@echo "Build happens outside the cluster:"
	@echo "  docker build -t ghcr.io/<user>/miraflix-backend:latest ./backend"
	@echo "  docker push ghcr.io/<user>/miraflix-backend:latest"

pull: ## pull the backend image (forces the latest on every pod)
	@kubectl rollout restart deploy/backend deploy/worker -n $(NS)

ps: ## pod status
	@kubectl get pods -n $(NS) -o wide

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

stack: ## monitoring status (kube-prometheus-stack already installed)
	@kubectl get pods -n monitoring | grep -E "prometheus|grafana|alertmanager"
	@echo "Grafana : $(GRAFANA) (anonymous)"

health: ## backend health check
	@curl -s -o /dev/null -w "backend /health/: %{http_code} (%{time_total}s)\n" $(BACKEND)/health/

logs: ## logs of a deployment (SVC=backend|worker|postgres|redis|ollama)
	@kubectl logs -f --tail=50 deploy/$(SVC) -n $(NS)

logs-backend: ## backend logs
	@kubectl logs -f --tail=50 deploy/backend -n $(NS)

logs-worker: ## worker logs
	@kubectl logs -f --tail=50 deploy/worker -n $(NS)

qlen: ## RQ queue length (job backlog)
	@kubectl exec -n $(NS) deploy/redis -- redis-cli LLEN rq:queue:videos

watch-queue: ## watch the backlog in real time
	@while true; do printf "%s: " "$$(date +%H:%M:%S)"; \
	  kubectl exec -n $(NS) deploy/redis -- redis-cli LLEN rq:queue:videos 2>/dev/null; \
	  sleep 1; done

prometheus: ## open Prometheus in the browser
	@echo "Prometheus (in-cluster): port-forward to view"
	@echo "  kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"

grafana: ## open Grafana in the browser
	@echo "Grafana: $(GRAFANA) (anonymous, dashboard: k6 Prometheus + MiraFLIX)"

info: ## summary of service URLs
	@echo "Backend API : http://$(BACKEND)/docs"
	@echo "Grafana     : $(GRAFANA) (anonymous)"
	@echo "HPA         : kubectl get hpa -n $(NS)"

# ---------------------------------------------------------------------------
# k6 tests (identical targets to the docker_compose branch)
# ---------------------------------------------------------------------------

smoke: ## e2e: upload -> embedding -> stream (1 VU, 30s)
	$(K6_RUN) smoke --flush

load: ## uploads at 5/s for 1m, API throughput
	$(K6_RUN) load --flush

queue: ## re-embeds at 5/s for 1m, pure queue pressure -> watch the HPA scale
	$(K6_RUN) queue --flush

search: ## vector search e2e
	$(K6_RUN) search --flush

stream: ## range requests like a real player (206 checks), 10/s for 1m
	$(K6_RUN) stream --flush

stress: ## ramp 1->20/s for 2m, find the breaking point
	$(K6_RUN) stress --flush

all: ## full sequence: smoke -> load -> queue -> search -> stream -> stress
	@for s in smoke load queue search stream stress; do \
	  echo "==> $$s"; \
	  $(K6_RUN) $$s --flush; \
	done

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

flush: ## flush the RQ queue (useful between scenarios)
	@kubectl exec -n $(NS) deploy/redis -- redis-cli DEL rq:queue:videos
	@echo "queue flushed"

seed: ## upload a sample video and print its id (needed by `queue`)
	@curl -s -X POST $(BACKEND)/uploads/video/ \
	  -F 'video_model={"description":"seed video"}' \
	  -F "file=@k6/assets/sample_small.mp4;type=video/mp4" \
	  | python3 -c "import sys,json; d=json.load(sys.stdin); print('video_id:', d.get('id'))"

scale-workers: ## scale workers: make scale-workers N=4 (default 4)
	@kubectl scale deploy worker --replicas=$(or $(N),4) -n $(NS)
	@echo "Workers active: $(or $(N),4)"

restart-backend: ## restart the backend deployment
	@kubectl rollout restart deploy/backend -n $(NS)
	@echo "backend restarted (on k8s the HPA usually handles this)"

dashboard-dl: ## download the official k6 dashboard for Grafana
	@mkdir -p monitoring/grafana/dashboards
	@curl -L -o monitoring/grafana/dashboards/k6-prometheus-dashboard.json \
	  "https://grafana.com/api/dashboards/19665/revisions/latest/download"
	@echo "Downloaded to monitoring/grafana/dashboards/"

clean: ## delete the k6 job and old completed pods
	@kubectl delete job k6-run -n $(NS) --ignore-not-found
	@kubectl delete pods -n $(NS) -l job-name=k6-run --ignore-not-found

help: ## list all targets
	@grep -E '^[a-zA-Z0-9-]+:.*##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'
