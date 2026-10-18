// k6 security check (NFR-5): /api/v1 allows 100 requests per 10 s per IP, then answers 429 RATE_LIMITED.
// One user fires 130 quick requests; we expect about 100 x 200 and the rest 429. Run: k6 run qa/k6/rate_limit.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const API = __ENV.API_URL || 'http://localhost:8080';
const ok = new Counter('answered_200');
const limited = new Counter('answered_429');

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    answered_429: ['count>0'],   // the limiter must kick in
    answered_200: ['count<=100'], // and never let more than 100 through in the window
  },
};

export default function () {
  const responses = http.batch(Array.from({ length: 130 }, () => ['GET', `${API}/api/v1/ping`]));
  for (const r of responses) {
    if (r.status === 200) ok.add(1);
    if (r.status === 429) {
      limited.add(1);
      check(r, { '429 uses the error envelope': (x) => x.json('error.code') === 'RATE_LIMITED' });
    }
  }
}
