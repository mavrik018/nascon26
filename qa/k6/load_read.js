// k6 read-only load test: 20 virtual users for ~40 s on the autograder read routes.
// Safe on a running demo (no writes). Run:  k6 run qa/k6/load_read.js
// Different server:                         k6 run -e API_URL=http://192.168.1.20:8080 qa/k6/load_read.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const API = __ENV.API_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '10s', target: 20 }, // ramp up
    { duration: '20s', target: 20 }, // hold
    { duration: '10s', target: 0 },  // ramp down
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],   // fewer than 1% errors
    http_req_duration: ['p(95)<500'], // 95% of requests under 500 ms
  },
};

export default function () {
  const health = http.get(`${API}/health`);
  check(health, { 'health 200': (r) => r.status === 200 });

  const table = http.get(`${API}/audit/v1/standings/league-alpha-1`);
  check(table, { 'standings 200': (r) => r.status === 200, 'has 4 rows': (r) => r.json('table').length === 4 });

  const score = http.get(`${API}/audit/v1/score/alpha1-m04`);
  check(score, { 'score 200': (r) => r.status === 200, 'signed events': (r) => r.json('events.0.signature').length === 64 });

  sleep(0.5);
}
