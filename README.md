# MiraFLIX on Docker Compose

MiraFLIX is a video platform (FastAPI + RQ worker + Postgres/pgvector + Redis
+ Ollama) that ingests videos, generates AI embeddings and serves streaming.
This branch runs the whole stack with **Docker Compose** on a single host —
the original deployment, used as the baseline for the Kubernetes migration.

The Kubernetes version lives on the [`k8s`](../../tree/k8s) branch. The two
branches share the **same application code and the same Makefile targets**,
so load tests can be run identically on both and the results compared.

---

## 1. Architecture

```
                ┌──────────────┐
  browser ─────▶│  my_backend  │  FastAPI, :8000
                └──────┬───────┘
                       │ uploads / embeddings / searches
        ┌──────────────┼──────────────────┐
        ▼              ▼                  ▼
  ┌──────────┐   ┌──────────┐      ┌──────────┐
  │ database │   │  redis   │      │  ollama  │
  │ pgvector │   │ RQ queue │      │ models   │
  └──────────┘   └────┬─────┘      └──────────┘
                      ▼
               ┌──────────────┐
               │   worker     │  RQ worker (fixed at 1 by default),
               │              │  generates embeddings via ollama
               └──────────────┘
```

| Service | Container | Port | Notes |
|---|---|---|---|
| backend (FastAPI) | `my_backend` | 8000 | API + uploads + streaming |
| worker (RQ) | `miraflix-worker-1` | — | consumes the queue; scale manually with `make scale-workers N=4` |
| database (pgvector) | `miraflix_db` | 5432 | Postgres + pgvector |
| redis (queue) | `my_redis` | 6379 | RQ queue |
| ollama (models) | `my_ollama` | 11434 | AI models (CPU) |
| redis-exporter | `my_redis_exporter` | 9121 | exposes `redis_key_size` (queue length) |
| prometheus | `my_prometheus` | 9090 | scrapes app + k6 remote write |
| grafana | `my_grafana` | 3000 | dashboards (admin/admin) |
| k6 | `my_k6` | — | load-test runner (used via `docker compose run`) |

Key points:

- **The worker count is fixed** — `docker compose` does not autoscale. Under a
  heavy queue the backlog grows until the backend becomes unresponsive and
  needs `docker restart my_backend`. This is the baseline that the k8s branch
  solves with HPA.
- **Config comes from the environment**: `BACKEND_URL` defaults to
  `http://my_backend:8000` (the compose container name). The k8s branch
  overrides it via env — the code is identical in both branches.

---

## 2. Prerequisites

- Docker Engine with the Compose plugin (`docker compose version` works)
- ~20 GB free disk (images + models)
- 8 GB RAM recommended (ollama + postgres + backend + worker)

---

## 3. Quick start

```bash
# clone this branch
git clone -b docker_compose https://github.com/eliamirafiori/cloud_computing_and_distributed_systems.git miraflix
cd miraflix

# check the .env (DB credentials, ports) and adjust if needed
cp .env .env.bak   # keep a backup before editing

# build + start the whole stack
make up            # = docker compose up -d --build

# start monitoring (Prometheus + Grafana)
make stack

# first run: download the embedding model into ollama (one-time, ~300MB)
docker exec my_ollama ollama pull embeddinggemma
```

Verify:

```bash
make health        # backend /health/ → 200
make ps            # all containers Up
```

| URL | Service | Login |
|---|---|---|
| http://localhost:8000/docs | FastAPI docs | — |
| http://localhost:3000 | Grafana | admin / admin |
| http://localhost:9090 | Prometheus | — |

> The `.env` file contains the DB credentials. It is committed in this repo
> (course project); for a real deployment it should stay out of version
> control.

---

## 4. Load testing (k6)

The k6 scenario script is shared with the k8s branch (`k6/script.js`). The
Makefile exposes the same targets as the k8s branch:

| Target | What it tests |
|---|---|
| `make smoke` | E2E: upload → embedding → streaming (1 VU, strict thresholds) |
| `make load` | API throughput, 300 uploads in 1m |
| `make queue` | pure enqueue of 301 re-embed jobs (queue pressure) |
| `make search` | vector search pipeline (flushes the queue first) |
| `make stream` | range requests like a real player (206 checks) |
| `make stress` | ramp 1→20/s for 2m, find the breaking point |
| `make all` | full sequence smoke → load → queue → search → stress |

```bash
make smoke
make queue
make stress
```

| Utility | What it does |
|---|---|
| `make qlen` | RQ queue length (job backlog) |
| `make flush` | empty the queue (useful between scenarios) |
| `make scale-workers N=4` | scale workers (the manual version of HPA) |
| `make restart-backend` | restart the backend after a stress run |

> k6 metrics are sent to the compose Prometheus via remote write
> (`make stack` first), so the Grafana dashboard shows the test results
> live.

---

## 5. Monitoring & Dashboard

```bash
make stack    # docker compose up -d prometheus grafana
```

The Grafana provisioning auto-loads `monitoring/grafana/dashboards/
k6-prometheus-dashboard.json` — the **k6 Prometheus + MiraFLIX** dashboard
(22 panels), the same JSON used on the k8s branch. It is portable because the
datasource is referenced by **name** (`${DS_PROMETHEUS}`), not by UID.

Highlight panels:

| Panel | Query |
|---|---|
| RQ Queue Length | `redis_key_size{key="rq:queue:videos"}` |
| Worker replicas (HPA) | `kube_deployment_status_replicas{deployment="worker"}` — **stays 1 here** |
| Backend replicas (HPA) | `kube_deployment_status_replicas{deployment="backend"}` — **stays 1 here** |
| MiraFLIX pod CPU | `sum by (pod) (rate(container_cpu_usage_seconds_total...))` |
| RQ Queue vs Worker replicas | the autoscaling story — **flat here, moving on k8s** |

> The k8s-only panels (replicas, pod CPU) show no data in docker: the
> `kube_*` metrics only exist in a cluster. That is expected — it is the
> visual proof of the difference between fixed workers and HPA.

---

## 6. Compare with the k8s branch

Run the same tests on the [`k8s`](../../tree/k8s) branch (same Makefile
targets, `./k8s/run-k6.sh <scenario> --flush`) and compare:

| Behavior | docker_compose | k8s |
|---|---|---|
| Workers under queue pressure | **fixed** (backlog grows) | **HPA 1→8** (queue drains) |
| Backend after stress | can become unresponsive → `make restart-backend` | survives (HPA scales replicas) |
| Scaling | manual (`make scale-workers N=4`) | automatic (CPU + queue length) |

The full migration guide is in `docs/ccds-proxmox-k3s-guide.md` on the k8s
branch.

---

## 7. Repository layout

```
docker-compose.yml                        # services, networks, volumes
.env                                      # DB credentials, ports
Makefile                                  # unified targets (same as k8s)
k6/
├── script.js                             # scenarios (shared with k8s)
└── assets/                               # upload test files
monitoring/
├── prometheus.yml                        # scrape config + remote write
└── grafana/provisioning/                 # datasources + dashboard auto-load
worker/                                   # RQ worker entrypoint
backend/                                  # FastAPI application
```

---

## 8. Docs

- [`k8s` branch](../../tree/k8s) — the Kubernetes migration (same app, HPA,
  in-cluster monitoring and load tests).
- `docs/ccds-proxmox-k3s-guide.md` (k8s branch) — full setup guide.
