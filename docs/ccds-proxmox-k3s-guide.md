# CCDS — MiraFLIX: Kubernetes Migration on Proxmox (k3s)

## Goal

This document explains how the MiraFLIX stack (FastAPI + RQ worker + Postgres
+ Redis + Ollama) — originally running as Docker Compose — was migrated to a
**3-node k3s cluster** on Proxmox, with:

- **shared persistent storage** (NFS) so uploads survive pod restarts and can
  be served by any replica;
- **monitoring** (Prometheus + Grafana) that sees both the application and the
  cluster;
- **horizontal autoscaling** (HPA) driven by CPU **and** by the RQ queue
  length — the core topic of the course;
- **load testing** (k6) running inside the cluster, with the same Makefile
  commands as the Docker Compose version.

## Service URLs

| Service | URL | Notes |
|---|---|---|
| Backend API (FastAPI docs) | http://192.168.1.150:30080/docs | NodePort, any node (150/151/152) |
| Backend health | http://192.168.1.150:30080/health/ | `{"message":"Healthy..."}` |
| Grafana | http://192.168.1.150:30001 | anonymous, no login |
| Prometheus | http://192.168.1.150:30002 | via port-forward (see below) |
| Cluster API (k3s) | https://192.168.1.150:6443 | kubectl only |

> Prometheus has no NodePort; view it with a port-forward from the master:
> `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 30002:9090`
> then open http://localhost:30002.

---

## 1. Architecture overview

| Component | docker_compose | k8s branch |
|---|---|---|
| Orchestration | docker compose | k3s (1 master + 2 workers) |
| Storage | local bind mounts | NFS share (VM 203), dynamic PVCs |
| Queue metric | — (added: redis-exporter) | redis-exporter + prometheus-adapter |
| Autoscaling | manual (`--scale`) | HPA (CPU + queue length) |
| Monitoring | compose Prometheus + Grafana | kube-prometheus-stack |

The `k8s` branch contains the application code (untouched) plus a `k8s/`
directory with every manifest. The image is published on GHCR.

---

## 2. Infrastructure: LVM volumes (Proxmox node)

The Proxmox host has three physical disks. Two unused ones (`sdb`, `sdc`)
were dedicated to the k3s VMs, isolated from the existing `pve` volume group:

```bash
# turn the two disks into LVM physical volumes
pvcreate /dev/sdb /dev/sdc

# group them into a dedicated volume group for the k3s VMs
vgcreate k3s /dev/sdb /dev/sdc

# create a 500GB thin pool (space is allocated only when VMs actually write)
lvcreate -L 500G -T k3s/data

# register the storage in Proxmox so VMs can use it ("local-k3s")
pvesm add lvmthin local-k3s --vgname k3s --thinpool data
```

Verify: `pvs; vgs; pvesm status`.

**Why**: a dedicated VG keeps the k3s VMs completely separate from the
existing `pve`/`local-lvm` storage and gives headroom for snapshots/resizes.

---

## 3. Infrastructure: the four VMs (Proxmox node)

Four Ubuntu 24.04 cloud-init VMs are created from one downloaded cloud image:

| VM | VMID | name | cores | mem | disk | IP | role |
|---|---|---|---|---|---|---|---|
| master | 200 | k3s-master | 2 | 4096 | 40G | 192.168.1.150 | control plane |
| node1 | 201 | k3s-node1 | 2 | 4096 | 40G | 192.168.1.151 | worker |
| node2 | 202 | k3s-node2 | 2 | 4096 | 40G | 192.168.1.152 | worker |
| nfs | 203 | nfs | 1 | 1024 | 100G | 192.168.1.153 | NFS server |

```bash
# download the cloud image once: template for all four VMs
wget -O /root/noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

For **each** VM, run this block with the values from the table:

```bash
# create the VM: host CPU (best perf on bare metal), virtio NIC, guest agent
qm create <VMID> --name <name> --cores <cores> --memory <mem> \
  --cpu cputype=host --net0 virtio,bridge=vmbr0 --agent enabled=1

# import the cloud image as the VM disk
qm importdisk <VMID> /root/noble-server-cloudimg-amd64.img local-k3s

# attach disk + cloud-init; headless serial console; root login via console
qm set <VMID> --scsihw virtio-scsi-pci --scsi0 local-k3s:vm-<VMID>-disk-0
qm set <VMID> --ide2 local-k3s:cloudinit --boot order=scsi0 --serial0 socket --vga serial0
qm set <VMID> --ciuser root --cipassword '<your-password>'

# static IP, gateway (FritzBox), DNS (Pi-hole)
qm set <VMID> --ipconfig0 ip=<IP>/24,gw=192.168.1.254 --nameserver 192.168.1.71

# grow the disk, then start
qm resize <VMID> scsi0 <disk>
qm start <VMID>
```

> `--serial0 socket --vga serial0` makes the VM headless — use **xterm.js**
> in the Proxmox console for copy-paste support. Access is via the console
> with the `--cipassword` set above (`--sshkeys` is optional for SSH).

---

## 4. Cluster: k3s bootstrap

### 4.1 Install k3s on the master (VM 200)

```bash
# k3s v1.36: single-binary Kubernetes (control plane + traefik + flannel +
# metrics-server); --write-kubeconfig-mode 644 lets us copy the kubeconfig
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
```

**Why k3s**: CNCF-certified, ~512MB RAM/node, includes metrics-server (needed
for CPU-based HPA) and Traefik out of the box — ideal for small VMs while
teaching the same concepts as a full distribution.

### 4.2 Point kubectl/helm at the cluster (VM 200)

```bash
# k3s keeps the kubeconfig in /etc/rancher/k3s/k3s.yaml; copy it to the
# standard location or helm/kubectl look for the cluster at the wrong address
mkdir -p ~/.kube && \
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && \
chmod 600 ~/.kube/config
```

### 4.3 Join the two worker nodes (VM 201 and VM 202)

```bash
# get the cluster join token once, on the master
cat /var/lib/rancher/k3s/server/node-token
```

Then run the **same command on both nodes** (K3S_URL = master API,
K3S_TOKEN = cluster secret):

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.150:6443 K3S_TOKEN='<NODE-TOKEN>' sh -
```

Verify on the master (all nodes Ready):

```bash
kubectl get nodes -o wide
```

Optional cosmetic label so the role column reads `worker`:

```bash
kubectl label node k3s-node1 node-role.kubernetes.io/worker=
kubectl label node k3s-node2 node-role.kubernetes.io/worker=
```

---

## 5. Shared storage: NFS + dynamic provisioner

### 5.1 Why shared storage

The backend writes uploaded videos to `data/media/`. With HPA the backend can
run as **multiple replicas on different nodes** — a file uploaded to replica A
must be readable by replica B. A local disk would break that; **NFS shared
by all nodes** is the storage layer that makes multi-replica work. It is also
a course lesson: shared state is what turns stateless replicas into a real
distributed system.

### 5.2 NFS server (VM 203)

```bash
# install the NFS kernel server
apt-get update -qq && apt-get install -y -qq nfs-kernel-server

# directory that will hold all cluster volumes
mkdir -p /srv/nfs/k8s && chown nobody:nogroup /srv/nfs/k8s

# export to the LAN: rw, sync writes, no_root_squash (pods as root keep rights)
echo '/srv/nfs/k8s 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)' > /etc/exports

# reload exports and enable the service at boot
exportfs -ra
systemctl enable --now nfs-server
```

Verify: `systemctl is-active nfs-server && showmount -e localhost`.

### 5.3 NFS clients (VMs 200/201/202)

```bash
# nfs-common lets kubelet mount NFS volumes on each node
apt-get update -qq && apt-get install -y -qq nfs-common
```

### 5.4 Helm + dynamic provisioner (VM 200)

```bash
# helm: package manager for Kubernetes charts
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

```bash
# the provisioner is the "robot" that creates a subdirectory on the NFS share
# whenever a PVC asks for storage; the nfs StorageClass becomes cluster default
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ && \
helm repo update && \
helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace nfs-provisioner --create-namespace \
  --values k8s/nfs-provisioner-values.yaml
```

Verify with `kubectl get sc` (the `nfs` StorageClass must be `default`).
From now on every PVC without an explicit class lands on NFS and survives pod
deletions.

---

## 6. Application image (GHCR)

The backend/worker share one image, built from `./backend` on a machine with
Docker and published on GitHub Container Registry:

```bash
# token needs the write:packages scope (created in GitHub settings)
docker login ghcr.io --username <your-user>
docker build -t ghcr.io/<your-user>/miraflix-backend:latest ./backend
docker push ghcr.io/<your-user>/miraflix-backend:latest
```

After the first push the package must be set to **Public** in GitHub
(Packages → miraflix-backend → Settings → Change visibility), otherwise the
cluster cannot pull it without an imagePullSecret.

---

## 7. Application deployment (VM 200, master)

The `k8s/` directory contains one manifest per component. Apply them in
dependency order (namespace → secret → data services → app services):

```bash
# clone the k8s branch with the manifests
git clone -b k8s https://github.com/eliamirafiori/cloud_computing_and_distributed_systems.git miraflix
cd miraflix/k8s

# namespace: logical container for the app resources
kubectl apply -f 01-namespace.yaml

# Secret: real DB credentials read from the repo .env (values never printed)
kubectl create secret generic miraflix-secrets -n miraflix \
  --from-literal=POSTGRES_USER="$(grep -E '^POSTGRES_USER=' ../.env | cut -d= -f2-)" \
  --from-literal=POSTGRES_PASSWORD="$(grep -E '^POSTGRES_PASSWORD=' ../.env | cut -d= -f2-)" \
  --from-literal=POSTGRES_DB="$(grep -E '^POSTGRES_DB=' ../.env | cut -d= -f2-)" \
  --from-literal=POSTGRES_PORT="$(grep -E '^POSTGRES_PORT=' ../.env | cut -d= -f2-)" \
  --from-literal=POSTGRES_SERVER="postgres"

# data services: postgres (PVC 10G on NFS) + redis (queue)
kubectl apply -f 03-postgres.yaml -f 04-redis.yaml

# app services: ollama (PVC 20G on NFS) + backend (PVC 10G RWX) + worker
kubectl apply -f 05-ollama.yaml -f 06-backend.yaml -f 07-worker.yaml
```

> Important details baked into the manifests:
> - Service names are **hardcoded in the app code**: `redis`, `ollama`,
>   `my-backend` (the worker calls `http://my-backend:8000`). Kubernetes
>   service names follow RFC 1123 — **no underscores** — hence `my-backend`
>   (docker allowed `my_backend`, k8s does not).
> - PostgreSQL 18+ images require the volume mounted at `/var/lib/postgresql`
>   (the **parent** dir) — mounting `/var/lib/postgresql/data` makes the
>   image refuse to start (it manages versioned subdirectories).
> - The backend PVC is `ReadWriteMany` on NFS so all replicas share uploads
>   (required by HPA).

Verify:

```bash
# all pods Running, PVCs Bound, health check answers
kubectl get pods,pvc,svc -n miraflix
curl http://192.168.1.150:30080/health/
```

Expected: `{"message":"Healthy, up and running!"}`. The backend is exposed on
NodePort **30080** so it is reachable from any node (`192.168.1.150|151|152`).

---

## 8. Monitoring: kube-prometheus-stack (VM 200)

All monitoring configuration lives in a versioned values file
(`k8s/kube-prometheus-stack-values.yaml`): storage on NFS, Grafana anonymous,
and the **remote-write receiver** (required by k6 — see §8.2). The whole
stack is installed with one command:

```bash
# full monitoring stack: Prometheus (20Gi PVC on NFS -> data survives
# restarts), Alertmanager, Grafana (anonymous admin), node-exporter,
# kube-state-metrics, remote-write receiver enabled
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && \
helm repo update && \
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values k8s/kube-prometheus-stack-values.yaml
```

> If the stack was installed without the values file, the remote-write
> receiver can be enabled later with:
> `kubectl patch prometheus kube-prometheus-stack-prometheus -n monitoring
> --type=merge -p '{"spec":{"enableRemoteWriteReceiver":true}}'`

### 8.1 The dashboard: k6 Prometheus + MiraFLIX

The dashboard JSON lives in the repo
(`monitoring/grafana/dashboards/k6-prometheus-dashboard.json`) and is imported
in Grafana (Dashboards → Import, or via API). It has **22 panels**:

**MiraFLIX infrastructure panels (custom):**
| Panel | Query | What it shows |
|---|---|---|
| RQ Queue Length | `redis_key_size{key="rq:queue:videos"}` | jobs waiting in the queue |
| Worker replicas (HPA) | `kube_deployment_status_replicas{deployment="worker"}` | worker scale 1→8 |
| Backend replicas (HPA) | `kube_deployment_status_replicas{deployment="backend"}` | backend scale 1→4 |
| MiraFLIX pod CPU | `sum by (pod) (rate(container_cpu_usage_seconds_total...))` | CPU of every pod |
| **RQ Queue vs Worker replicas** | both metrics together | **the autoscaling story** |

**k6 panels** (from the official 19665 dashboard): Performance Overview, HTTP
requests/failures, Peak RPS, latency timings/stats, transfer rate, iterations,
requests by URL, checks.

Dashboard variables:
- `test` — scenario dropdown populated from `label_values(k6_http_reqs_total, test)`
- `quantile_stat` — latency quantile (p50/p90/p95/p99, default p95)
- `DS_PROMETHEUS` — datasource resolved by **name** (see §11.2)

> Pitfall: the official k6 dashboard uses `testid` as label and `$testid` /
> `$quantile_stat` variables. Our script tags metrics with `test`, so queries
> were adapted (`testid` → `test`); without `quantile_stat` in the templating
> the latency panels stay empty.

### 8.2 Prometheus remote-write receiver

k6 sends its metrics to Prometheus via remote write. The receiver is enabled
in the helm values (`k8s/kube-prometheus-stack-values.yaml` →
`prometheus.prometheusSpec.enableRemoteWriteReceiver: true`), so a fresh
install already accepts remote writes — no manual patch needed.

Verify: `k6_http_reqs_total` appears in Prometheus after a test.

---

## 9. Autoscaling: HPA on CPU and RQ queue length

### 9.1 Why resource requests matter

An HPA scaling on CPU works in *percentage of the declared request*: it needs
`resources.requests.cpu` on every container to know what "100%" means.
Without requests the HPA stays at 0% and never scales. Backend and worker
therefore declare `cpu: 250m`, `memory: 256Mi` requests and `cpu: 1`,
`memory: 1Gi` limits.

### 9.2 CPU-based HPA for the backend

```bash
# backend-cpu: min 1, max 4, scale when average CPU > 60% of requests
kubectl apply -f 08-hpa-backend.yaml
```

### 9.3 Queue-length metric: redis-exporter + prometheus-adapter

The **custom metric** is the RQ queue length — a business metric, not a
resource one. Three pieces make it available to the HPA:

```bash
# 1. redis-exporter: reads Redis and exposes the queue length as
#    redis_key_size{key="rq:queue:videos"} (check-keys option); the
#    ServiceMonitor tells Prometheus to scrape it
kubectl apply -f 10-redis-exporter.yaml

# 2. prometheus-adapter: translates that Prometheus metric into the external
#    metric rq_queue_length that HPA can read
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && \
helm repo update && \
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --values /root/miraflix/k8s/prometheus-adapter-values.yaml
```

Key details of the adapter config (`prometheus-adapter-values.yaml`):
- the rule lives under **`rules.external`** — that is what makes the chart
  create the `external.metrics.k8s.io` APIService (a rule under `custom`
  would not);
- the metric name is **`redis_key_size`** (modern redis_exporter v1.89+
  renamed it — `redis_key_llen` no longer exists);
- `resources.overrides` for namespace/pod are required, otherwise the adapter
  fails with "unable to convert resource namespaces into label";
- `prometheus.url` must point at the kube-prometheus-stack service
  (`prometheus.default.svc` — the chart default — does not exist here).

### 9.4 The worker HPA: CPU + queue combined

Kubernetes allows **only one HPA per Deployment** (two HPAs on the same
target cause `AmbiguousSelector`), so the worker uses a single HPA with both
metrics — the controller computes replicas for each and uses the highest:

```bash
# worker-hpa: min 1, max 8
#   - CPU: scale when average usage > 70% of requests
#   - queue: scale when (queued jobs)/(workers) > 5
kubectl apply -f 11-hpa-worker-queue.yaml
```

Verify:

```bash
kubectl get hpa -n miraflix
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/miraflix/rq_queue_length"
```

Expected: `backend-cpu` and `worker-hpa` with real targets (e.g.
`cpu: 0%/70%, 0/5 (avg)`) and the external metric returning the queue length.

### 9.5 The autoscaling story

The `queue` test enqueues re-embed jobs at 5/s. The HPA sees the queue grow
past 5 jobs per worker and **scales the worker deployment 1 → 8**; the eight
workers drain the queue; when the queue is empty the HPA scales back down
(with a cooldown to avoid oscillation). The dashboard panel "RQ Queue vs
Worker replicas" shows exactly this cause→effect chain. This is the answer to
the Docker Compose limitation: in compose the worker count is fixed manually,
in k8s the *workload itself* decides.

---

## 10. Load testing: k6 in the cluster

The tests run as a Kubernetes Job (`k8s/12-k6-job.yaml`) using the official
`grafana/k6` image. The script and the upload asset are mounted from a
ConfigMap; metrics go to the in-cluster Prometheus via remote write.

### 10.1 The ConfigMap (generated by Kustomize)

The script and the upload asset are packaged into the `k6-scripts` ConfigMap
by **Kustomize** — the generator lives in the repo root (`kustomization.yaml`)
and reads the files directly from `k6/`, so there is no duplication and no
manual `kubectl create configmap`:

```bash
# from the repo root: generate and apply the ConfigMap
kubectl apply -k .
# preview: kubectl kustomize .
```

Why Kustomize: `configMapGenerator` keeps the name `k6-scripts` stable
(`disableNameSuffixHash: true`), which the Job manifest and `run-k6.sh`
reference by name. The Job maps the flat keys to the paths the script expects
(`/scripts/script.js`, `/scripts/assets/sample_small.mp4`) with `items`.

### 10.2 The scenarios

| Scenario | Executor | Rate | What it tests |
|---|---|---|---|
| smoke | constant-vus (1) | 30s | E2E: upload → embedding → streaming (strict thresholds) |
| load | constant-arrival-rate | 5/s, 1m | API throughput (uploads only) |
| queue | constant-arrival-rate | 5/s, 1m | pure enqueue of re-embed jobs — **drives the custom HPA** |
| search | constant-arrival-rate | 1/2s, 1m | vector search pipeline |
| stream | constant-arrival-rate | 10/s, 1m | range requests like a real player (206 checks) |
| stress | ramping-arrival-rate | 1→20/s | ramp until the system breaks (no strict thresholds) |

> The embedding model is pulled automatically at startup by the ollama
> initContainer (`k8s/05-ollama.yaml`) — no manual download needed; it is
> saved on the NFS PVC.

### 10.3 Running a scenario

The one-command runner `k8s/run-k6.sh` (see §12) does everything: refreshes
the ConfigMap, deletes the previous Job, creates the Job with the requested
`SCENARIO`, waits and prints results. The `--flush` flag empties the RQ queue
afterwards so the next test can start immediately — otherwise `search` and
`stress` would queue behind the previous test's backlog and time out (the
poll window is 30s).

```bash
./k8s/run-k6.sh queue --flush
```

### 10.4 What the tests demonstrate (not just numbers)

- **smoke / load / search** prove the application is *correct* under the
  expected load: uploads succeed, embeddings are produced, searches complete,
  streams answer 206.
- **queue** demonstrates the *reason HPA was built*: a burst of jobs must not
  stall the product — the queue is the early-warning signal that workers are
  needed, before CPU saturates.
- **stream** exercises the product's core feature (video playback) with
  realistic byte-range requests.
- **stress** finds the *breaking point* and shows the difference between the
  two deployment styles: with a single fixed worker (compose) a heavy burst
  saturates the queue and the backend can become unresponsive; with HPA the
  cluster scales workers out, the queue drains, and the backend keeps
  answering. The exact failure rate is a property of the run, not the point
  of the exercise — the point is *resilience through scaling*.

---

## 11. Docker parity: same metrics, same dashboard

The same queue-length metric and the same Grafana dashboard are available in
the Docker Compose deployment, so both versions are monitored with the same
panels.

### 11.1 What was added to the docker_compose branch

| File | Change |
|---|---|
| `docker-compose.yml` | new `redis-exporter` service (`--check-keys=rq:queue:videos`) |
| `monitoring/prometheus.yml` | new scrape target `redis-exporter:9121` |
| `monitoring/grafana/dashboards/k6-prometheus-dashboard.json` | replaced with the **portable** dashboard (22 panels) |

The compose Grafana provisioning (`dashboards.yml`) auto-loads every file
from `/var/lib/grafana/dashboards`, so the dashboard appears after
`docker compose up -d grafana` — no manual import.

### 11.2 Why the dashboard is portable

The dashboard uses `${DS_PROMETHEUS}` instead of a hardcoded datasource UID.
Grafana resolves that variable by datasource **name**, and the datasource is
named "Prometheus" in both environments (in k8s its UID is `prometheus`, in
docker it is random). The same JSON therefore works everywhere.

### 11.3 Same metrics, different infrastructure

| Metric | docker | k8s |
|---|---|---|
| `redis_key_size{key="rq:queue:videos"}` | redis-exporter service | redis-exporter deployment + ServiceMonitor |
| k6 metrics (remote write) | compose Prometheus | in-cluster Prometheus |
| worker replicas panel | **1 (fixed)** | **HPA 1→8** |
| backend replicas panel | **1 (fixed)** | **HPA 1→4** |

The same dashboard shows the same queue behavior — but only k8s can scale:
the replica panels stay flat in docker and move in k8s. That contrast is the
point of the migration.

---

## 12. Unified Makefile (same commands in both worlds)

Both branches expose the **same Makefile targets**; only the backend differs
(docker compose vs. the k8s runner script).

| Target | docker_compose | k8s |
|---|---|---|
| `make smoke` / `load` / `queue` / `search` / `stream` / `stress` | `docker compose run ... k6 -e SCENARIO=...` | `./k8s/run-k6.sh <scenario> --flush` |
| `make all` | full sequence | full sequence (with --flush) |
| `make qlen` | `docker compose exec redis redis-cli LLEN ...` | `kubectl exec deploy/redis -- redis-cli LLEN ...` |
| `make flush` | `docker compose exec redis redis-cli DEL ...` | `kubectl exec deploy/redis -- redis-cli DEL ...` |
| `make scale-workers N=4` | `docker compose up -d --scale worker=N` | `kubectl scale deploy worker --replicas=N` |

On k8s, every test target goes through `k8s/run-k6.sh`, which:

1. refreshes the `k6-scripts` ConfigMap (script + upload asset);
2. deletes any previous Job;
3. creates the Job with the requested `SCENARIO` (validated input);
4. waits for completion and prints the key results;
5. with `--flush`: empties the RQ queue so the next test starts immediately.

Quick start (k8s branch, on the master):

```bash
cd /root/miraflix

make qlen        # current queue length (0 = empty)
make queue       # enqueue re-embeds -> watch the HPA scale on the dashboard
make stream      # streaming range requests
make all         # full sequence: smoke -> load -> queue -> search -> stream -> stress
make flush       # empty the queue manually if needed
```

---

## 13. Operational: startup, restart, crash recovery

Unlike docker compose (where you `up` and `restart` containers imperatively),
Kubernetes is **declarative**: the cluster continuously reconciles the desired
state (the manifests) with the actual state. There is no "start the stack" —
there is "make sure the VMs are on".

### 13.1 Bring the stack up (after a VM reboot)

```bash
# from Proxmox: start the four VMs (k3s is a systemd service, it comes up
# on its own; the deployments reconcile themselves)
qm start 200 && qm start 201 && qm start 202 && qm start 203

# after ~2 minutes, verify (from the master, or from admin with kubectl)
kubectl get nodes -o wide        # all Ready
kubectl get pods -n miraflix     # all Running — k8s recreated them by itself
```

No `docker compose up` needed: PVCs survive on NFS, deployments recreate the
pods, services stay the same.

> If the VMs should start automatically after a host reboot:
> `qm set 200 --onboot 1 && qm set 201 --onboot 1 && qm set 202 --onboot 1 && qm set 203 --onboot 1`

### 13.2 A pod crashed — what happens

Deployments use `restartPolicy: Always`, so a crashed pod is **restarted
automatically**. If it keeps crashing (`CrashLoopBackOff`), inspect and fix:

```bash
kubectl get pods -n miraflix                     # status
kubectl logs -n miraflix deploy/backend --tail=50  # why?
kubectl rollout restart deploy/backend -n miraflix # clean restart after a fix
```

### 13.3 Restart one service

```bash
kubectl rollout restart deploy/backend -n miraflix
kubectl rollout restart deploy/worker  -n miraflix
kubectl rollout restart deploy/ollama   -n miraflix
```

### 13.4 Stop / start the whole app

```bash
kubectl scale deploy --all --replicas=0 -n miraflix   # stop (data stays on PVCs)
kubectl scale deploy --all --replicas=1 -n miraflix   # start again
```

### 13.5 A helm component breaks (monitoring, adapter, provisioner)

```bash
helm upgrade prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --values /root/miraflix/k8s/prometheus-adapter-values.yaml
```

### 13.6 Summary: docker vs k8s

| Action | docker | k8s |
|---|---|---|
| Bring up | `docker compose up -d` | start the VMs; the cluster reconciles |
| Crashed container | stays down (or restart policy) | **automatic restart** |
| Manual restart | `docker restart my_backend` | `kubectl rollout restart deploy/backend` |
| Stop everything | `docker compose down` | `kubectl scale deploy --all --replicas=0` |

---

## 14. Summary of the running stack

| Component | Pod | Storage | Notes |
|---|---|---|---|
| API (FastAPI) | backend | PVC miraflix-data (10Gi RWX, NFS) | HPA 1→4 on CPU |
| RQ worker | worker | — | HPA 1→8 on CPU + queue |
| AI models | ollama | PVC ollama-models (20Gi, NFS) | CPU only |
| Database | postgres | PVC postgres-data (10Gi, NFS) | mount `/var/lib/postgresql` |
| Queue | redis | — | ephemeral |
| Queue metrics | redis-exporter | — | `redis_key_size` |
| Monitoring | kube-prometheus-stack | Prometheus 20Gi on NFS | Grafana anonymous |
