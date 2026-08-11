import http from "k6/http";
import { check, sleep } from "k6";

/*
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
*/

/*
SCENARIOS
Upload dei video (saturazione banda di rete e trasferimento dati)
Streaming dei video (saturazione della banda e probabili race conditions)
Ricerca degli utenti (stress test di Ollama)
*/

export const options = {
  vus: 1000,
  duration: '10s',
};

export default function hitInference() {
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

/*
  TOTAL RESULTS 

    checks_total.......: 9671   5.284696/s
    checks_succeeded...: 53.60% 5184 out of 9671
    checks_failed......: 46.39% 4487 out of 9671

    ✓ enqueued 200
    ✗ job finished
      ↳  0% — ✓ 21 / ✗ 4487

    HTTP
    http_req_duration..............: avg=3.73ms min=703.84µs med=1.78ms max=135.07ms p(90)=7.58ms p(95)=14.47ms
      { expected_response:true }...: avg=3.73ms min=703.84µs med=1.78ms max=135.07ms p(90)=7.58ms p(95)=14.47ms
    http_req_failed................: 0.00%  0 out of 304074
    http_reqs......................: 304074 166.16056/s

    EXECUTION
    dropped_iterations.............: 6293   3.438796/s
    iteration_duration.............: avg=1m0s   min=22.05s   med=1m0s   max=1m0s     p(90)=1m0s   p(95)=1m0s   
    iterations.....................: 4508   2.463387/s
    vus............................: 16     min=16          max=1025
    vus_max........................: 1320   min=820         max=1320

    NETWORK
    data_received..................: 59 MB  32 kB/s
    data_sent......................: 35 MB  19 kB/s
*/
