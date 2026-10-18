# CONTEXT — shared live tracker (both laptops)

**Resume anywhere:** `git pull`, read this file, continue your next unticked row. Update your rows + "Last updated"
and push at least once per window. Laptop 2's detailed instructions: `LAPTOP2_PLAN.md`.

_Last updated: Sun 18 Oct 2026, 11:40 PKT (Laptop 2)_

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
| 1 | Foundation: `sign_day2`, DAY2_SALT in compose, reset seeds (match-m1, player-beta-2, QR maps, guest_anon_tok_7721, empty cart), error codes | L1 | ✅ 86964f3 (tests pass) |
| 2 | Public guest API + `/web/*` file routes (contract in LAPTOP2_PLAN.md) | L1 | ✅ 52c414b — realtime.py + web.py; WS push <500 ms tested |
| 3 | `POST /audit/v1/stream/key` (+ MediaMTX auth hook, revoke cuts ingest) | L1 | 🔄 agent A (streaming.py) |
| 4 | `POST /audit/v1/costream/session` | L1 | 🔄 agent A (costream.py, also GET /api/v1/public/costream/{id}) |
| 5 | QR: `/audit/v1/qr/{id}`, exports svg/png/pdf, `/q/{code}` 302, scan telemetry | L1 | 🔄 agent B (qr_guest.py) |
| 6 | Guest 403 boundary + `/audit/v1/guest/cart-merge` | L1 | 🔄 403 middleware ✅ in foundation; cart-merge agent B |
| 7 | `/audit/v1/moderation/test` + DLQ | L1 | 🔄 agent C (moderation_dlq.py, also /api/v1/chat + /api/v1/public/chat) |
| 8 | `/metrics` + `DELETE /audit/v1/privacy/user/{id}` | L1 | 🔄 agent C (observability.py) |
| 9 | WebSocket `/ws/matches/{id}` score push (NFR-1) | L1 | ✅ /ws/matches/{id} in realtime.py |
| 10 | Compose: MediaMTX, MinIO, Redis, Selenium hub + 3 nodes; ≤120 s | L1 | ✅ redis + mediamtx (1935/8888/8889) + hub + 3 nodes 4.24.0; /health checks redis+media; MinIO blocked (image pull denied — waiting for team) |
| 11 | COVERAGE_DAY2.json (measured), TRACEABILITY.md Part II rows | L1 | ⏳ |
| L2-1 | Guest Web Player HTML/JS (9 data-testids, WCAG) | L2 | ✅ code in `api/app/web/` (assets via `/web/static/`). Verified 11:20 with the Selenium suite against a local mock of the contract (3/3); not yet against the real stack |
| L2-2 | `tests/selenium/test_guest_grid.py` (3 tests, -n 3) | L2 | 🟡 3/3 vs mock; vs real API (52c414b, local) tests 2+3 PASS, test 1 waited on `/q` (now pushed by L1, re-running) |
| L2-3 | `tests/k6_load.js` + real k6 summary | L2 | 🟡 script committed (spec 6.4 profile, `-e API_URL=`). Summary pending L1 rows 5 + 7 |
| L2-4 | Flutter `nascon://` deep links + APK | L2 | ✅ intent-filter + MethodChannel (no new dependency) + Match Live / Co-Stream guest screens. `flutter analyze` clean, `flutter test` 50/50. Release APK rebuilt 11:32 → `mobile/release/app-release.apk` |
| L2-5 | `tests/appium/test_mobile_deeplink.py` | L2 | 🟡 2 deep-link tests PASS on emulator (Pixel 9 Pro XL AVD, cold start WaitTime ~1.1 s). Cross-surface test waits on `/audit/v1/moderation/test` (L1 row 7) + public chat |
| L2-6 | `.github/workflows/autograde.yml` | L2 | ✅ written (YAML valid). Needs repo secrets `DAY1_SALT` / `DAY2_SALT` set on GitHub by the team |

## Requests between laptops
- **L2 → L1** (11:21): `GET /api/v1/public/chat/{room}` is still missing (**L1: agent C is building it with /api/v1/chat, merging ~12:00**). The web + app chat poll it every second. Messages accepted by
  `/audit/v1/moderation/test` should show up there, because the cross-surface Appium test posts through that route.
- **L2 → L1**: keep the compose service name `api`. The Grid browsers run in containers, so the Selenium suite probes the
  `WEB_BASE` env first, then `localhost:8080`, `api:8080`, `host.docker.internal:8080`.
- **L2 → L1**: `ci.yml` "Same tests over HTTP" now also collects `tests/selenium` + `tests/appium`. Add
  `--ignore=tests/selenium --ignore=tests/appium` (autograde.yml already does). **L1: done 11:36.**
- **L2 → L1**: `.gitignore` has `reports/`, which also ignores `tests/reports/`. Please add `!tests/reports/` (until then L2 uses `git add -f`). **L1: done 11:36.**

- **L1 → L2**: guest page must use the contract in LAPTOP2_PLAN.md; inside Grid nodes the backend is http://api:8080.

## Known failures / notes
- Laptop 2: `flutter build apk` fails from the repo path because the `&` in `SAEED & SONS` breaks `gradlew.bat`. Build from a
  `subst` drive instead (also: pinned NDK 28.2 not installable here, local build used NDK 30 without committing that change): `subst N: "<repo>"` then run the build in `N:\mobile`.
- Cold `docker compose up -d --build` took 227 s here (image build); warm start ~20 s. Needs trimming (≤120 s rule).
- DAY1_SALT not yet provided to Laptop 1 (.env blank).
- MinIO recording not started: docker.io and quay.io images unavailable.
