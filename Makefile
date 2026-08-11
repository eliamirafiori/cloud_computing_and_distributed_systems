# ============================================================================
# MiraFLIX — unified Makefile (compose + k6 + Prometheus + Grafana)
# ============================================================================
# Lifecycle : up down build pull ps
# Monitoring: stack health logs qlen watch-queue prometheus grafana info
# Test      : smoke load queue search stress all
# Utility   : flush seed scale-workers restart-backend dashboard-dl clean
#
# Quick start:
#   make up && make stack
#   make smoke && make load && make queue && make search && make stress
#   make help        # full target list
# ============================================================================

COMPOSE := docker compose
# Remote write: BOTH -o and the env var are required (k6 v2.2 ignores the URL in the flag)
RW_URL  := http://prometheus:9090/api/v1/write
K6_RUN  := $(COMPOSE) run --rm -e K6_PROMETHEUS_RW_SERVER_URL=$(RW_URL) k6 run -o experimental-prometheus-rw
# Video file used by the seed target (adjust if your sample has a different name)
SAMPLE  ?= k6/assets/sample_small.mp4

.PHONY: up down down-clean build pull ps stack health logs \
        qlen watch-queue prometheus grafana info \
        smoke load queue search stress all \
        flush seed scale-workers restart-backend dashboard-dl clean help

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

up: ## start the whole stack (db, redis, ollama, worker, backend)
	$(COMPOSE) up -d
	@echo "Backend: http://localhost:8000/docs"

down: ## stop everything (volumes kept)
	$(COMPOSE) down

down-clean: ## stop everything and delete volumes (fresh DB)
	@echo "WARNING: this deletes Postgres and Redis data!"
	$(COMPOSE) down -v

build: ## rebuild the backend image
	$(COMPOSE) build backend worker

pull: ## pull images
	$(COMPOSE) pull

ps: ## container status
	$(COMPOSE) ps

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

stack: ## start Prometheus + Grafana
	$(COMPOSE) up -d prometheus grafana
	@echo "Grafana: http://localhost:3000 (admin/admin) -> Dashboards -> k6 Prometheus"

health: ## backend health check
	@curl -s -o /dev/null -w "backend /health/: %{http_code} (%{time_total}s)\n" http://localhost:8000/health/

logs: ## logs of all services (SVC=backend for a single one)
	$(COMPOSE) logs -f --tail=50 $(SVC)

logs-backend: ## backend logs
	$(COMPOSE) logs -f --tail=50 backend

logs-worker: ## worker logs
	$(COMPOSE) logs -f --tail=50 worker

qlen: ## RQ queue length (job backlog)
	@$(COMPOSE) exec -T redis redis-cli LLEN rq:queue:videos

watch-queue: ## watch the backlog in real time
	@watch -n 1 "$(COMPOSE) exec -T redis redis-cli LLEN rq:queue:videos"

prometheus: ## open Prometheus in the browser
	@echo "Prometheus: http://localhost:9090"
	@(xdg-open http://localhost:9090 2>/dev/null || open http://localhost:9090 2>/dev/null) || true

grafana: ## open Grafana in the browser
	@echo "Grafana: http://localhost:3000 (admin/admin) -> Dashboards -> k6 Prometheus"
	@(xdg-open http://localhost:3000 2>/dev/null || open http://localhost:3000 2>/dev/null) || true

info: ## summary of service URLs
	@echo "Backend API : http://localhost:8000/docs"
	@echo "Prometheus  : http://localhost:9090"
	@echo "Grafana     : http://localhost:3000 (admin/admin)"
	@echo "Redis       : localhost:6379"
	@echo "Ollama      : localhost:11434"

# ---------------------------------------------------------------------------
# k6 tests
# ---------------------------------------------------------------------------

smoke: ## e2e: upload -> embedding -> stream (1 VU, 30s)
	$(K6_RUN) -e SCENARIO=smoke /scripts/script.js

load: ## 300 uploads in 1m, API throughput
	$(K6_RUN) -e SCENARIO=load /scripts/script.js

queue: ## 301 re-embeds in 1m, pure queue pressure
	$(K6_RUN) -e SCENARIO=queue /scripts/script.js

search: ## vector search e2e (flushes the queue first)
	$(COMPOSE) exec -T redis redis-cli DEL rq:queue:videos >/dev/null 2>&1 || true
	@sleep 5
	$(K6_RUN) -e SCENARIO=search /scripts/script.js

stress: ## ramp 1->20/s for 2m, find the breaking point
	$(COMPOSE) exec -T redis redis-cli DEL rq:queue:videos >/dev/null 2>&1 || true
	@sleep 4
	$(K6_RUN) -e SCENARIO=stress /scripts/script.js

all: ## full sequence: smoke -> load -> queue -> search -> stress
	@echo "==> smoke"
	$(K6_RUN) -e SCENARIO=smoke /scripts/script.js
	@echo "==> load"
	$(K6_RUN) -e SCENARIO=load /scripts/script.js
	@echo "==> queue"
	$(K6_RUN) -e SCENARIO=queue /scripts/script.js
	@echo "==> search"
	$(COMPOSE) exec -T redis redis-cli DEL rq:queue:videos >/dev/null 2>&1 || true
	@sleep 5
	$(K6_RUN) -e SCENARIO=search /scripts/script.js
	@echo "==> stress"
	$(COMPOSE) exec -T redis redis-cli DEL rq:queue:videos >/dev/null 2>&1 || true
	@sleep 4
	$(K6_RUN) -e SCENARIO=stress /scripts/script.js

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

flush: ## flush the RQ queue (useful between scenarios)
	$(COMPOSE) exec -T redis redis-cli DEL rq:queue:videos

seed: ## upload a sample video and print its id (needed by `queue`)
	@curl -s -X POST http://localhost:8000/uploads/video/ \
	  -F 'video_model={"description":"seed video"}' \
	  -F "file=@$(SAMPLE);type=video/mp4" \
	  | python3 -c "import sys,json; d=json.load(sys.stdin); print('video_id:', d.get('id'))"

scale-workers: ## scale workers: make scale-workers N=4 (default 4)
	$(COMPOSE) up -d --scale worker=$(or $(N),4) worker
	@echo "Workers active: $(or $(N),4) — check the drain with: make qlen"

restart-backend: ## restart the backend (stuck after a stress run)
	docker restart my_backend

dashboard-dl: ## download the official k6 dashboard for Grafana
	@mkdir -p monitoring/grafana/dashboards
	@curl -L -o monitoring/grafana/dashboards/k6-prometheus-dashboard.json \
	  "https://grafana.com/api/dashboards/19665/revisions/latest/download"
	@echo "Downloaded to monitoring/grafana/dashboards/"

clean: ## remove stopped containers and unused images
	$(COMPOSE) down --remove-orphans
	docker system prune -f

help: ## list all targets
	@grep -E '^[a-zA-Z0-9-]+:.*##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'
