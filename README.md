# MiraFLIX on Kubernetes (k3s)

MiraFLIX is a video platform (FastAPI + RQ worker + Postgres/pgvector + Redis
+ Ollama) that ingests videos, generates AI embeddings and serves streaming.
This branch runs the whole stack on a **3-node k3s cluster** with shared NFS
storage, Prometheus/Grafana monitoring, **HPA autoscaling driven by CPU and by
the RQ queue length**, and in-cluster load testing with k6.

The Docker Compose version lives on the [`docker_compose`](../../tree/docker_compose)
branch. The same Makefile targets work on both — see §6.

---

## 1. Architecture

```
                ┌──────────────┐
  browser ─────▶│  my-backend  │  FastAPI, NodePort :30080
                │  (HPA 1→4)   │
                └──────┬───────┘
                       │ uploads (NFS RWX) / embeddings / searches
        ┌──────────────┼──────────────────┐
        ▼              ▼                  ▼
  ┌──────────┐   ┌──────────┐      ┌──────────┐
  │ postgres │   │  redis   │      │  ollama  │
  │ pgvector │   │ RQ queue │      │ models   │
  │ PVC NFS  │   └────┬─────┘      │ PVC NFS  │
  └──────────┘        │            └──────────┘
                      ▼
               ┌──────────────┐
               │   worker     │  RQ worker, consumes the queue,
               │  (HPA 1→8)   │  generates embeddings via ollama
               └──────────────┘
```

| Component | Deployment | Storage | Scaling |
|---|---|---|---|
| backend (FastAPI) | 1 pod | PVC `miraflix-data` 10Gi **RWX** (NFS) | HPA 1→4 on CPU >60% |
| worker (RQ) | 1 pod | — | HPA 1→8 on CPU >70% **and** queue >5 jobs/worker |
| postgres (pgvector) | 1 pod | PVC `postgres-data` 10Gi (NFS) | fixed |
| redis (queue) | 1 pod | ephemeral | fixed |
| ollama (models) | 1 pod | PVC `ollama-models` 20Gi (NFS) | fixed |
| redis-exporter | 1 pod | — | exposes `redis_key_size` (queue) |

Key design points:

- **Service names are hardcoded in the app code** (`redis`, `ollama`,
  `my-backend`), so the Services must keep those exact names. Kubernetes
  service names follow RFC 1123 — no underscores — hence `my-backend`
  (docker allowed `my_backend`, k8s does not).
- **Shared NFS storage** (`/srv/nfs/k8s` from VM 203) is what makes
  multi-replica backends work: a file uploaded to replica A is served by
  replica B.
- **PostgreSQL 18+** requires the volume mounted at `/var/lib/postgresql`
  (the parent dir), not `/var/lib/postgresql/data`.

---

## 2. Prerequisites

- A working k3s cluster (1 master + N workers) with `kubectl` and `helm`
  configured. The full Proxmox/k3s setup is documented in
  [`docs/ccds-proxmox-k3s-guide.md`](docs/ccds-proxmox-k3s-guide.md).
- An NFS server reachable from the nodes and the `nfs` StorageClass as
  default (the guide covers the provisioner).
- The backend image published on GHCR and **public**:
  `ghcr.io/<user>/miraflix-backend:latest` (the manifests reference it —
  change the image in `k8s/06-backend.yaml` / `k8s/07-worker.yaml` if yours
  differs).

---

## 3. Quick start

```bash
# 1. clone this branch
git clone -b k8s https://github.com/eliamirafiori/cloud_computing_and_distributed_systems.git miraflix
cd miraflix/k8s

# 2. namespace
kubectl apply -f 01-namespace.yaml

# 3. Secret with the real DB credentials (read from the repo .env,
#    values are never printed)
kubectl create secret generic miraflix-secrets -n miraflix \
  --from-literal=POSTGRES_USER="$(grep -E '^POSTGRES_USER=' ../.env | cut -d= -f2-)" \
  --from-literal=POSTGRES_PASSWORD="$(grep -E '^POSTGRES_PASSWORD=' ../.env | cut -d= -f2-)" \
  --from-literal=POSTGRES_DB="$(grep -E '^POSTGRES_DB=' ../.env | cut -d= -f2-)" \
  --from-literal=POSTGRES_PORT="$(grep -E '^POSTGRES_PORT=' ../.env | cut -d= -f2-)" \
  --from-literal=POSTGRES_SERVER="postgres"

# 4. data services, then app services
kubectl apply -f 03-postgres.yaml -f 04-redis.yaml
kubectl apply -f 05-ollama.yaml -f 06-backend.yaml -f 07-worker.yaml
```

Verify:

```bash
kubectl get pods,pvc,svc -n miraflix
curl http://192.168.1.150:30080/health/     # → {"message":"Healthy, up and running!"}
```

> The ollama pod pulls `embeddinggemma` automatically at startup
> (initContainer) and stores it on the NFS PVC — one-time download.

---

## 4. Autoscaling (HPA)

### 4.1 Backend — CPU

```bash
kubectl apply -f 08-hpa-backend.yaml   # min 1, max 4, CPU > 60%
```

### 4.2 Worker — CPU + RQ queue length (the interesting part)

A CPU-only HPA reacts **after** the worker is already saturated. A worker
waiting for jobs has low CPU, so a growing queue would never trigger it. The
custom metric watches the **business signal** — the RQ queue length — and
scales before the backlog grows:

```bash
# redis-exporter: exposes redis_key_size{key="rq:queue:videos"} to Prometheus
kubectl apply -f 10-redis-exporter.yaml

# prometheus-adapter: exposes that metric as external metric rq_queue_length
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --values /root/miraflix/k8s/prometheus-adapter-values.yaml

# one HPA with both metrics (Kubernetes allows only ONE HPA per Deployment)
kubectl apply -f 11-hpa-worker-queue.yaml   # min 1, max 8, CPU>70% AND queue>5
```

The autoscaling loop: queue grows → HPA scales workers 1→8 → workers drain the
queue → HPA scales back down.

---

## 5. Monitoring & Dashboard

### 5.1 Install the stack (values are versioned)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values k8s/kube-prometheus-stack-values.yaml
```

The values file covers: Prometheus storage on NFS (20Gi), **remote-write
receiver enabled** (required by k6), Grafana anonymous with **NodePort 30001**.

### 5.2 The dashboard

`monitoring/grafana/dashboards/k6-prometheus-dashboard.json` is the **k6
Prometheus + MiraFLIX** dashboard (22 panels). Import it in Grafana
(Dashboards → Import) or via API. Highlights:

| Panel | Query |
|---|---|
| RQ Queue Length | `redis_key_size{key="rq:queue:videos"}` |
| Worker replicas (HPA) | `kube_deployment_status_replicas{deployment="worker"}` |
| Backend replicas (HPA) | `kube_deployment_status_replicas{deployment="backend"}` |
| MiraFLIX pod CPU | `sum by (pod) (rate(container_cpu_usage_seconds_total...))` |
| **RQ Queue vs Worker replicas** | queue + replicas together (the autoscaling story) |

Dashboard variables: `test` (scenario dropdown), `quantile_stat`
(p50/p90/p95/p99) and `DS_PROMETHEUS` (portable datasource, works also on the
docker Grafana).

Access: `http://192.168.1.150:30001` (any node) — anonymous.

---

## 6. Load testing (k6)

The tests run as a Kubernetes Job (`k8s/12-k6-job.yaml`) with the script and
the upload asset mounted from a ConfigMap generated by Kustomize:

```bash
kubectl apply -k .     # from the repo root: generates k6-scripts ConfigMap
```

Scenarios (all defined in `k6/script.js`):

| Scenario | Rate | What it tests |
|---|---|---|
| smoke | 1 VU, 30s | E2E: upload → embedding → streaming (strict thresholds) |
| load | 5/s, 1m | API throughput (uploads only) |
| queue | 5/s, 1m | pure enqueue — **drives the custom HPA** |
| search | 1/2s, 1m | vector search pipeline |
| stream | 10/s, 1m | range requests like a real player (206 checks) |
| stress | 1→20/s | ramp until the system breaks |

One-command runner:

```bash
./k8s/run-k6.sh smoke --flush    # runs smoke, empties the queue afterwards
./k8s/run-k6.sh queue --flush    # watch the HPA scale on the dashboard
```

The `--flush` flag empties the RQ queue after the test so the next scenario
can start immediately (otherwise search/stress queue behind the backlog and
time out).

### Same Makefile as docker

| Target | k8s (this branch) | docker_compose |
|---|---|---|
| `make smoke/load/queue/search/stream/stress` | `./k8s/run-k6.sh <s> --flush` | `docker compose run ... k6` |
| `make qlen` | `kubectl exec deploy/redis -- redis-cli LLEN ...` | `docker compose exec redis ...` |
| `make flush` | `kubectl exec deploy/redis -- redis-cli DEL ...` | `docker compose exec redis ...` |
| `make scale-workers N=4` | `kubectl scale deploy worker --replicas=N` | `docker compose up -d --scale worker=N` |

---

## 7. Repository layout

```
k8s/
├── 01-namespace.yaml              # miraflix namespace
├── 02-secret.yaml                 # Secret template (real values from .env at deploy)
├── 03-postgres.yaml               # postgres + PVC 10G NFS + Service
├── 04-redis.yaml                  # redis + Service
├── 05-ollama.yaml                 # ollama + PVC 20G NFS + initContainer (model pull)
├── 06-backend.yaml                # backend + PVC 10G RWX + Service NodePort 30080
├── 07-worker.yaml                 # RQ worker (same image, rq command)
├── 08-hpa-backend.yaml            # HPA backend: CPU 60%, 1→4
├── 10-redis-exporter.yaml         # redis-exporter + ServiceMonitor
├── 11-hpa-worker-queue.yaml       # HPA worker: CPU 70% + queue>5, 1→8
├── 12-k6-job.yaml                 # k6 Job (ConfigMap mount, remote write)
├── 13-grafana-nodeport.yaml       # grafana NodePort (fallback; values file preferred)
├── kube-prometheus-stack-values.yaml  # monitoring: storage, remote-write, grafana
├── nfs-provisioner-values.yaml    # storage provisioner config
├── prometheus-adapter-values.yaml # external metric rq_queue_length
└── run-k6.sh                      # one-command k6 runner (+ --flush)

kustomization.yaml                 # Kustomize: generates k6-scripts ConfigMap
k6/                                # load-test script + assets
monitoring/grafana/dashboards/     # the 22-panel dashboard JSON
Makefile                           # unified targets (same as docker_compose)
```

---

## 8. Docs

- [`docs/ccds-proxmox-k3s-guide.md`](docs/ccds-proxmox-k3s-guide.md) — the
  full guide: Proxmox VMs, k3s, NFS, deploy, HPA, dashboard, k6, operational
  startup/restart.
- [Docker Compose branch](../../tree/docker_compose) — the original stack and
  the same dashboard/metrics for comparison.
