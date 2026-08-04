import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  scenarios: {
    // 1. Smoke test — confirms basic correctness before anything heavier
    smoke: {
      executor: "constant-vus",
      vus: 1,
      duration: "30s",
      exec: "hitInference",
    },

    // 2. Load test — steady expected traffic, does it hold p95 targets?
    load: {
      executor: "constant-arrival-rate",
      rate: 5,
      timeUnit: "1s",
      duration: "3m",
      preAllocatedVUs: 50,
      maxVUs: 200,
      startTime: "35s",
      exec: "hitInference",
    },

    // 3. Breakpoint / stress test — ramp until it actually breaks
    breakpoint: {
      executor: "ramping-arrival-rate",
      startRate: 1,
      timeUnit: "1s",
      preAllocatedVUs: 500,
      maxVUs: 1000,
      stages: [
        { duration: "1m", target: 5 },
        { duration: "1m", target: 15 },
        { duration: "1m", target: 30 },
        { duration: "1m", target: 60 },
        { duration: "1m", target: 100 },
      ],
      startTime: "4m",
      exec: "hitInference",
    },

    // 4. Spike test — sudden burst, does it recover after?
    spike: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 5 },
        { duration: "10s", target: 300 }, // sudden spike
        { duration: "30s", target: 300 },
        { duration: "10s", target: 5 }, // sudden drop — check recovery
        { duration: "30s", target: 5 },
      ],
      startTime: "9m",
      exec: "hitInference",
    },

    // 5. Soak test — moderate load, long duration, catches leaks/degradation
    // Run this one separately (`k6 run --tag testtype=soak`), it's long
    soak: {
      executor: "constant-vus",
      vus: 20,
      duration: "30m",
      exec: "hitInference",
      startTime: "0s", // run standalone, don't stack with the above
    },
  },
  // thresholds: {
  //   http_req_duration: ["p(95)<2000"],
  //   http_req_failed: ["rate<0.01"],
  // },
};

export function hitInference() {
  const enqueueRes = http.get("http://backend:8000/embed/ciao_mi_chiamo_elia");
  check(enqueueRes, { "enqueued 200": (r) => r.status === 200 });

  const jobId = JSON.parse(enqueueRes.body).job_id;

  let result;
  const maxAttempts = 60; // tune to your expected inference latency
  for (let i = 0; i < maxAttempts; i++) {
    sleep(1);
    const res = http.get(`http://backend:8000/inference/${jobId}`);
    const body = JSON.parse(res.body);

    if (body.status === "finished" || body.status === "failed") {
      result = body;
      break;
    }
  }

  check(result, {
    "job finished": (r) => r && r.status === "finished",
  });
}
