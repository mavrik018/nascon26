// k6 concurrency test (NFR-3, spec 5.12): 20 buyers hit "buy" for the LAST unit at the same moment.
// Pass = exactly 1 order succeeds, 19 get 409 OUT_OF_STOCK, stock ends at 0 (never negative).
// WARNING: calls /audit/v1/reset first, which wipes demo data back to the seed. Run: k6 run qa/k6/checkout_race.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const API = __ENV.API_URL || 'http://localhost:8080';
const VARIANT = 'var-jersey-001-M';
const won = new Counter('orders_paid');
const soldOut = new Counter('orders_out_of_stock');

export const options = {
  scenarios: {
    race: { executor: 'per-vu-iterations', vus: 20, iterations: 1, maxDuration: '30s' },
  },
  thresholds: {
    orders_paid: ['count==1'],
    orders_out_of_stock: ['count==19'],
  },
};

export function setup() {
  const r = http.post(`${API}/audit/v1/reset`, JSON.stringify({ seed: 42, stock: { [VARIANT]: 1 } }), {
    headers: { 'Content-Type': 'application/json' },
  });
  check(r, { 'reset ok': (x) => x.status === 200 });
}

export default function () {
  const body = {
    order_id: `race-${__VU}`,
    customer_id: `buyer-${__VU}`,
    items: [{ variant_id: VARIANT, quantity: 1 }],
    discount_code: null,
    payment: { token: 'tok_success' },
  };
  const r = http.post(`${API}/audit/v1/checkout`, JSON.stringify(body), {
    headers: { 'Content-Type': 'application/json' },
  });
  if (r.status === 201) won.add(1);
  if (r.status === 409 && r.json('error.code') === 'OUT_OF_STOCK') soldOut.add(1);
}

export function teardown() {
  const inv = http.get(`${API}/audit/v1/inventory/${VARIANT}`);
  check(inv, { 'stock is 0, never negative': (x) => x.json('stock') === 0 });
}
