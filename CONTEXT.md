# CONTEXT — shared live tracker (both laptops)

**Resume anywhere:** `git pull`, read this file, continue your next unticked row. Update your rows + "Last updated"
and push at least once per window. Laptop 2's detailed instructions: `LAPTOP2_PLAN.md`.

_Last updated: Sun 18 Oct 2026, 11:15 PKT (Laptop 1)_

## Hard rules (Day 2 PDF, binding)
- Freeze 14:00, final push **14:05:00 PKT**. Push in every window: W1 10:15–11:30 ✅ · W2 11:30–12:45 · W3 12:45–13:45 · W4 13:45–14:05.
- Commits descend from Day 1 `11b52ef`; never force-push or rewrite history. Author mavrik018, no co-author lines.
- Salts only via env (`DAY1_SALT`, `DAY2_SALT` in git-ignored `.env`); hard-coding voids credit. **Never decide a salt — ask the team.**
- `docker compose up -d --build` healthy ≤120 s; `localhost:4444/status` ≥3 ready nodes; ports 8080, 4444, 4723, 1935, 8888, 8889.
- Don't fabricate reports/coverage. Backend 80% / frontend 20%.

## Decisions taken (with the team, 11:10)
- Selenium images **4.24.0** (already on Laptop 1, no 5 GB pull). MinIO image + segno/websockets/pytest-xdist approved.
- DAY2_SALT is in Laptop 1 `.env`. DAY1_SALT: **waiting for the team to provide it**.

## Task board
| # | Task | Owner | Status |
|---|---|---|---|
| 1 | Foundation: `sign_day2`, DAY2_SALT in compose, reset seeds (match-m1, player-beta-2, QR maps, guest_anon_tok_7721, empty cart), error codes | L1 | ⏳ |
| 2 | Public guest API + `/web/*` file routes (contract in LAPTOP2_PLAN.md) | L1 | ⏳ |
| 3 | `POST /audit/v1/stream/key` (+ MediaMTX auth hook, revoke cuts ingest) | L1 | ⏳ |
| 4 | `POST /audit/v1/costream/session` | L1 | ⏳ |
| 5 | QR: `/audit/v1/qr/{id}`, exports svg/png/pdf, `/q/{code}` 302, scan telemetry | L1 | ⏳ |
| 6 | Guest 403 boundary + `/audit/v1/guest/cart-merge` | L1 | ⏳ |
| 7 | `/audit/v1/moderation/test` + DLQ | L1 | ⏳ |
| 8 | `/metrics` + `DELETE /audit/v1/privacy/user/{id}` | L1 | ⏳ |
| 9 | WebSocket `/ws/matches/{id}` score push (NFR-1) | L1 | ⏳ |
| 10 | Compose: MediaMTX, MinIO, Redis, Selenium hub + 3 nodes; ≤120 s | L1 | ⏳ |
| 11 | COVERAGE_DAY2.json (measured), TRACEABILITY.md Part II rows | L1 | ⏳ |
| L2-1 | Guest Web Player HTML/JS (9 data-testids, WCAG) | L2 | ⏳ |
| L2-2 | `tests/selenium/test_guest_grid.py` (3 tests, -n 3) | L2 | ⏳ |
| L2-3 | `tests/k6_load.js` + real k6 summary | L2 | ⏳ |
| L2-4 | Flutter `nascon://` deep links + APK | L2 | ⏳ |
| L2-5 | `tests/appium/test_mobile_deeplink.py` | L2 | ⏳ |
| L2-6 | `.github/workflows/autograde.yml` | L2 | ⏳ |

## Requests between laptops
- (none yet)

## Known failures / notes
- (none yet)
