import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

/*
 * MiraFLIX load tests
 * ===================
 *
 * Every heavy task (description embedding) is enqueued on the RQ queue
 * "videos"; a pool of workers drains it. These scenarios exercise the full
 * pipeline and, together with the queue backlog, show the distributed
 * behaviour of the system.
 *
 * Default: smoke. Altri scenari:
 * docker compose run --rm -e K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write k6 run -e SCENARIO=load -o experimental-prometheus-rw /scripts/script.js
 * docker compose run --rm -e K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write k6 run -e SCENARIO=queue -o experimental-prometheus-rw /scripts/script.js
 * docker compose run --rm -e K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write k6 run -e SCENARIO=search -o experimental-prometheus-rw /scripts/script.js
 * docker compose run --rm -e K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write k6 run -e SCENARIO=stress -o experimental-prometheus-rw /scripts/script.js

 *
 * On k8s, point BASE_URL at the service/ingress:
 *   docker run --rm -v ./k6:/scripts -e BASE_URL=http://miraflix:8000 grafana/k6 run /scripts/script.js
 *
 * Watch the queue backlog while a test is running:
 *   docker compose exec -T redis redis-cli LLEN rq:queue:videos
 *
 * The "queue" scenario is the distributed-systems money shot: with N workers
 * the same backlog drains N times faster. Compare worker=1 vs worker=4.
 *
 * NOTE: the upload endpoint does not return a job_id (yet), so the e2e flow
 * polls GET /videos/{id} until the embedding is populated by a worker.
 */

const BASE_URL = __ENV.BASE_URL || "http://backend:8000";

// Tiny file on purpose: load tests upload hundreds of videos.
// 9KB instead of the 26MB sample.mp4 -> no disk saturation during tests.
const VIDEO_FILE = open("./assets/sample_small.mp4", "b");

const embedReady = new Rate("embedding_ready");   // embedding ready within the poll window
const jobDuration = new Trend("job_duration_ms"); // upload -> embedding ready

const SCENARIOS = {
  smoke: {
    // End-to-end correctness: upload -> embedding -> streaming
    executor: "constant-vus",
    vus: 1,
    duration: "30s",
    exec: "e2eUpload",
    tags: { test: "smoke" },
  },
  load: {
    // API throughput: uploads only, no polling. Worker drain is measured
    // separately (queue backlog + queue scenario).
    executor: "constant-arrival-rate",
    rate: 5,
    timeUnit: "1s",
    duration: "1m",
    preAllocatedVUs: 20,
    maxVUs: 50,
    exec: "uploadOnly",
    tags: { test: "load" },
  },
  queue: {
    // Pure enqueue rate on an EXISTING video (re-embed). No file upload,
    // no polling: fast iterations, real rate. The drain is observed
    // externally (LLEN rq:queue:videos) while workers process the backlog.
    executor: "constant-arrival-rate",
    rate: 5,
    timeUnit: "1s",
    duration: "1m",
    preAllocatedVUs: 20,
    maxVUs: 50,
    exec: "enqueueReembed",
    tags: { test: "queue" },
  },
  search: {
    // Vector-search pipeline under realistic load.
    // NB: with worker=1, embeddinggemma takes ~3s per job -> sustainable rate
    // is ~0.3/s. Above that, jobs accumulate and the 30s poll times out:
    // that is the backlog lesson, covered by the stress scenario.
    executor: "constant-arrival-rate",
    rate: 1,
    timeUnit: "2s",
    duration: "1m",
    preAllocatedVUs: 10,
    maxVUs: 20,
    exec: "searchQuery",
    tags: { test: "search" },
  },
  stress: {
    // Ramp until the system breaks. No strict thresholds on purpose.
    executor: "ramping-arrival-rate",
    startRate: 1,
    timeUnit: "1s",
    preAllocatedVUs: 50,
    maxVUs: 200,
    stages: [
      { duration: "30s", target: 2 },
      { duration: "30s", target: 5 },
      { duration: "30s", target: 10 },
      { duration: "30s", target: 20 },
    ],
    exec: "e2eUpload",
    tags: { test: "stress" },
  },
};

// Run a single scenario with -e SCENARIO=load (runs all of them otherwise).
const SELECTED = __ENV.SCENARIO;

export const options = {
  scenarios: SELECTED ? { [SELECTED]: SCENARIOS[SELECTED] } : SCENARIOS,
  // Strict thresholds only on the correctness scenarios (smoke/load/search).
  // queue and stress are exploratory: read the numbers, not the pass/fail.
  thresholds: {
    "http_req_failed{test:smoke}": ["rate<0.01"],
    "checks{test:smoke}": ["rate>0.90"],
    "embedding_ready{test:smoke}": ["rate>0.90"],
    "http_req_failed{test:load}": ["rate<0.01"],
    "checks{test:load}": ["rate>0.90"],
    "http_req_failed{test:search}": ["rate<0.01"],
    "checks{test:search}": ["rate>0.90"],
  },
};

// Video used by the "queue" scenario (re-embed). A smoke run creates it (id=1
// on a fresh DB). If you already have data: -e SEED_VIDEO_ID=<id>
const SEED_VIDEO_ID = __ENV.SEED_VIDEO_ID || "1";

const POLL_ATTEMPTS = 30;
const POLL_INTERVAL_S = 1;

// Polls GET /videos/{id} until the worker populates the embedding.
function pollEmbedding(videoId) {
  const start = Date.now();
  for (let i = 0; i < POLL_ATTEMPTS; i++) {
    sleep(POLL_INTERVAL_S);
    const res = http.get(`${BASE_URL}/videos/${videoId}`, {
      tags: { name: "get_video" },
    });
    const emb = res.status === 200 ? res.json().embedding : null;
    if (emb && emb.length > 0) {
      jobDuration.add(Date.now() - start);
      return true;
    }
  }
  jobDuration.add(Date.now() - start);
  return false;
}

function upload(description) {
  return http.post(
    `${BASE_URL}/uploads/video/`,
    {
      video_model: JSON.stringify({ description }),
      file: http.file(VIDEO_FILE, "sample_small.mp4", "video/mp4"),
    },
    { tags: { name: "upload" } },
  );
}

export function e2eUpload() {
  // 1. Multipart upload -> 201 {id, video_url, streaming_url, ...}
  const uploadRes = upload(`k6 e2e ${__VU}-${__ITER}`);
  check(uploadRes, { "upload 201": (r) => r.status === 201 });

  if (uploadRes.status !== 201) {
    embedReady.add(false);
    return;
  }

  const videoId = uploadRes.json().id;

  // 2. Poll until a worker writes the embedding
  const ok = pollEmbedding(videoId);
  check(ok, { "embedding ready": (v) => v === true });
  embedReady.add(ok);

  // 3. Range request on the streaming endpoint (expected 206)
  const rangeRes = http.get(`${BASE_URL}/streams/video/${videoId}`, {
    headers: { Range: "bytes=0-1023" },
    tags: { name: "stream_range" },
  });
  check(rangeRes, { "stream 206": (r) => r.status === 206 });
}

export function uploadOnly() {
  // Upload without polling: measures API + DB + storage throughput.
  const uploadRes = upload(`k6 load ${__VU}-${__ITER}`);
  check(uploadRes, { "upload 201": (r) => r.status === 201 });

  if (uploadRes.status === 201) {
    const rangeRes = http.get(
      `${BASE_URL}/streams/video/${uploadRes.json().id}`,
      { headers: { Range: "bytes=0-1023" }, tags: { name: "stream_range" } },
    );
    check(rangeRes, { "stream 206": (r) => r.status === 206 });
  }
}

export function enqueueReembed() {
  // POST /embeddings/embed/{id}: enqueue a re-embed job for an existing video.
  // No file, no DB row, no polling: pure pressure on the queue.
  const res = http.post(
    `${BASE_URL}/embeddings/embed/${SEED_VIDEO_ID}`,
    null,
    { tags: { name: "reembed" } },
  );
  check(res, { "reembed 202": (r) => r.status === 202 });
}

export function searchQuery() {
  // POST /searches/search/ -> job_id, then poll until "done".
  const res = http.post(
    `${BASE_URL}/searches/search/`,
    { query: `k6 search ${__VU}-${__ITER}` },
    { tags: { name: "search" } },
  );
  check(res, { "search 202": (r) => r.status === 202 });
  if (res.status !== 202) return;

  const jobId = res.json().job_id;
  let done = false;
  for (let i = 0; i < POLL_ATTEMPTS; i++) {
    sleep(POLL_INTERVAL_S);
    const r = http.get(`${BASE_URL}/searches/search/${jobId}`, {
      tags: { name: "search_poll" },
    });
    const body = r.json();
    if (body.status === "done" || body.status === "failed") {
      done = body.status === "done";
      break;
    }
  }
  check(done, { "search done": (v) => v === true });
}
