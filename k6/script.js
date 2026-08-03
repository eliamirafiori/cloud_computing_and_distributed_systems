import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  scenarios: {
    ramp: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 20 },
        { duration: "30s", target: 50 },
        { duration: "30s", target: 100 },
        { duration: "30s", target: 200 },
        { duration: "30s", target: 400 },
        { duration: "1m", target: 400 }, // hold to see if it stabilizes or collapses
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<2000"], // flag if p95 > 2s
    http_req_failed: ["rate<0.01"], // flag if >1% of requests fail
  },
};

export default function () {
  // const res = http.get("http://backend:8000/inference/");
  const res = http.get("http://backend:8000/simulate/?delay=2&jitter=0.5");
  check(res, {
    "status is 200": (r) => r.status === 200,
  });
  sleep(1);
}
