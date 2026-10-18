// NFR-2 load profile, verbatim from spec 6.4 (500 guest viewers + 50 chat posters, 15 s).
// Base URL: k6 run -e API_URL=http://<laptop1-ip>:8080 ... (defaults to http://localhost:8080).
// Run: k6 run --summary-export=tests/reports/k6-summary.json tests/k6_load.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.API_URL || 'http://localhost:8080';

export const options = {
  scenarios: {
    guest_viewers: {
      executor: 'constant-vus',
      vus: 500,
      duration: '15s',
      exec: 'viewStream',
    },
    chat_posters: {
      executor: 'constant-vus',
      vus: 50,
      duration: '15s',
      exec: 'postChat',
    },
  },
  thresholds: {
    http_req_failed: ['rate==0.00'],
    http_req_duration: ['p(95)<800'],
  },
};

export function viewStream() {
  const res = http.get(`${BASE}/audit/v1/qr/match-m1?inspect=true`);
  check(res, {
    'guest QR status is 200': (r) => r.status === 200,
    'has target_route': (r) => r.json('target_route') !== undefined,
  });
  sleep(0.1);
}

export function postChat() {
  const payload = JSON.stringify({
    chat_room_id: 'chat-cs-session-101',
    incoming_messages: [
      { message_id: `k6-${__VU}-${__ITER}`, sender: `user-${__VU}`, text: 'Live reaction' }
    ],
    check_dlq: false,
  });
  const res = http.post(`${BASE}/audit/v1/moderation/test`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, {
    'chat status is 200 or 201': (r) => r.status === 200 || r.status === 201,
  });
  sleep(0.2);
}
