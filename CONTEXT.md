# CONTEXT — shared live tracker (both laptops) + handoff for any assistant (Claude / Codex)

**Resume anywhere:** `git pull`, read this file, continue the next unticked row you own. Update your rows +
"Last updated" and push at least once per window. Laptop 2's detailed instructions: `LAPTOP2_PLAN.md`.

_Last updated: Sun 18 Oct 2026, 12:16 PKT (Laptop 1) — L1 is OUT OF TOKENS until ~13:15; Laptop 2 takes over_

## Hard rules (Day 2 PDF, binding)
- Freeze 14:00, final push **14:05:00 PKT**. Push in every window: W1 ✅ · W2 ✅ · W3 12:45–13:45 (NOT yet pushed) · W4 13:45–14:05.
- Commits descend from Day 1 `11b52ef`; never force-push or rewrite history. Author mavrik018, no co-author lines.
- **Salts:** only via env in the git-ignored `.env` (`DAY1_SALT=…`, `DAY2_SALT=…`; values from the team, never invented).
  Day 1 code signs with `DAY1_SALT` (`signing.sign`); Day 2 code signs ONLY with `DAY2_SALT` (`signing.sign_day2`). Never mix.
  Both are set on Laptop 1 (11:40).
- `docker compose up -d --build` healthy ≤120 s; `localhost:4444/status` ≥3 ready nodes; ports 8080, 4444, 4723, 1935, 8888, 8889.
- Don't fabricate reports/coverage. Backend 80% / frontend 20%.

## Decisions taken (with the team)
- Selenium images 4.24.0 (already local). segno / websockets / pytest-xdist added.
- MinIO image pull is blocked on Laptop 1 → **MinIO runs on the friend's laptop (Laptop 2)** — see request below.

## Task board
| # | Task | Owner | Status |
|---|---|---|---|
| 1 | Foundation: `sign_day2`, DAY2_SALT in compose, reset seeds, guest 403 middleware | L1 | ✅ tested |
| 2 | Guest public API (`/api/v1/public/*`), SSE, `/web/*` routes | L1 | ✅ tested |
| 3 | `POST /audit/v1/stream/key` + MediaMTX auth hook + revoke kicks live ingest | L1 | ✅ tested; real ffmpeg RTMP→HLS 200; revoke cut live ingest in 1.5 s |
| 4 | `POST /audit/v1/costream/session` + `GET /api/v1/public/costream/{id}` | L1 | ✅ tested |
| 5 | QR `/audit/v1/qr/{id}`, exports svg/png/pdf, `/q/{code}` 302, PII-free scans | L1 | ✅ tested |
| 6 | Guest 403 boundary + `/audit/v1/guest/cart-merge` (idempotent, concurrent-safe) | L1 | ✅ tested |
| 7 | `/audit/v1/moderation/test` + DLQ + `/api/v1/chat` + `/api/v1/public/chat/{room}` | L1 | ✅ tested (merged 11:40) |
| 8 | `/metrics` (5 metrics) + `DELETE /audit/v1/privacy/user/{id}` | L1 | ✅ tested |
| 9 | WebSocket `/ws/matches/{id}` (NFR-1) | L1 | ✅ tested <500 ms |
| 10 | Compose: redis, mediamtx, selenium hub + 3 nodes | L1 | ✅ grid ready=3; guest HLS read needs no credentials (no 401) since 11:40 |
| 10b | MinIO + stream recording + VOD index (FR-3.2) | L2 runs MinIO, L1 wires it | 🟡 MinIO up on L2 (172.15.33.178:9000, bucket `vod`). L1 wires it |
| 11 | COVERAGE_DAY2.json (measured) | L1 | ✅ streaming 97.3 · costream 98.6 · qr_guest 91.7 · moderation_dlq 97.7 · observability 94.0 — suite 1334 passed, 1 skipped |
| 12 | TRACEABILITY.md Part II rows + README | L1 | ⏳ next |
| 13 | Cold start ≤120 s check; `nascon_stream_bitrate_kbps` from MediaMTX | L1 | ⏳ |
| L2-1 | Guest Web Player HTML/JS | L2 | ✅ |
| L2-2 | `tests/selenium/test_guest_grid.py` | L2 | ✅ 3/3 real Grid (both laptops) |
| L2-3 | `tests/k6_load.js` + real summary | L2 | ❌ ran 11:52 from L2 against L1 (172.15.33.181), 550 VUs/15 s: **0 failed requests** (1837 reqs, all checks pass) but **p95 6.1 s → `p(95)<800` FAILS**. The time is server wait (TTFB p95 6.0 s; TCP connect p95 87 ms; idle latency 20–70 ms). Real summary committed in `tests/reports/k6-summary.json`. Needs L1 (request below) |
| L2-4 | Flutter `nascon://` deep links + APK | L2 | ✅ APK rebuilt again: the Co-Stream screen loads chat even when the session lookup fails |
| L2-5 | `tests/appium/test_mobile_deeplink.py` | L2 | ✅ 11:57: **3/3 PASS against L1** (emulator, app → L1 via a forwarder on L2:8080; compose Grid browser → L1). Cross-surface chat reached both the app and the browser in ≤3 s. Cold launch WaitTime 1.26–1.29 s (only the very first launch after a fresh install: 3.1 s). Report in `tests/reports/appium-report.xml` |
| L2-6 | `.github/workflows/autograde.yml` | L2 | ✅ needs GitHub repo secrets `DAY1_SALT` / `DAY2_SALT` (team sets them in GitHub settings) |


## >>> HANDOFF TO LAPTOP 2 (12:16) — remaining work, in priority order <<<
L1 audit of every Part II FR/NFR vs code (12:05). Done & tested: all /audit/v1/* contracts (5.4–5.9), guest 403, cart merge,
QR, moderation/DLQ, metrics, privacy, WS/SSE <500 ms, real RTMP→HLS + revoke kick, Selenium 3/3, Appium 3/3.
Performance work done 12:16 (commit below): 8 uvicorn workers, rate limit + WS counter shared via Redis (`api/app/redis_kv.py`),
one pure-ASGI middleware (`Guards` in main.py), clean chat skips the room lock. k6 inside the docker network
(`docker run --rm --network league_default -v "$PWD/tests:/t" grafana/k6:0.54.0 run -e API_URL=http://api:8080 /t/k6_load.js`):
**0 failed, 771 req/s, p95 1.24 s** (was 6.5 s). On Windows, k6 from the host gets "connection refused" from Docker Desktop's port
proxy — measure inside the network or from another laptop.

1. **FR-3.1 athlete profile + follow/unfollow** (`GET /api/v1/athletes/{id}`, `PUT/DELETE /api/v1/athletes/{id}/follow`,
   `/follow/toggle`; tables follows + athlete_stats; advisory lock per athlete; counter == row count under bursts).
   An L1 background agent was building this on branch `day2-social` in a local worktree on L1 — it will NOT be pushed while L1 is
   out. **L2: implement it yourself** in a new `api/app/modules/social.py` + `tests/test_day2_social.py`, add `social` to
   `api/app/modules/__init__.py`.
2. **FR-3.3 host controls + FR-5.2 notification bus** (same situation, L1 agent branch `day2-host-notify` won't be pushed).
   L2: `api/app/modules/hostctl.py` (POST /api/v1/costream/{id}/invites signed with sign_day2, /join, /controls mute|spotlight|kick,
   GET /api/v1/public/costream/{id}/state) and `notify.py` (publish → notifications table + SSE /api/v1/notifications/stream?topic=,
   simulate_dlq → moderation_dlq.deliver → notification_dlq after 3 attempts; POST /audit/v1/notifications/test; call publish from
   store.change_status for order status events). Tests for each.
3. **Seed `cs-session-101`** on reset (L2 request): in `api/app/modules/costream.py` reset, create the spec example session
   (host player-alpha-1, participants alpha-1, alpha-2, beta-1, beta-2, grid_4, no drop) via the same evaluate/store function.
4. **NFR-2 p95 < 800 ms:** still 1.24 s in-network on L1 (k6 shares CPU). Options: run k6 from L2 against L1 again and report;
   `uvicorn[standard]` (httptools+uvloop) would cut ~30% CPU — needs the team's OK for the extra package.
5. **FR-3.2 recording to MinIO + VOD index:** MinIO at 172.15.33.178:9000 (bucket vod). Add to `infra/mediamtx.yml`
   `pathDefaults: record: yes, recordPath: /recordings/%path/%Y-%m-%d_%H-%M-%S-%f, recordFormat: fmp4` + a volume, then on
   stream key revoke/stop upload segments to MinIO and insert a `vod_recordings(stream_key, player_id, object_url, started_at,
   ended_at)` row (S3 PUT needs SigV4 — or use `mc`/boto3 if the team approves a package). Lower priority than 1–4.
6. **TRACEABILITY.md Part II rows + README Part II section** (spec 3: every FR-3.x/4.x/5.x + NFR id → file + tests).
7. Before 13:40: full backend suite, `docker compose up -d --build --wait`, reset, Selenium `pytest -n 3 tests/selenium`, k6,
   regenerate COVERAGE_DAY2.json (`python tools/coverage_report.py reports/coverage.json --day2`), commit reports, push in W3
   (12:45–13:45) and W4 (13:45–14:05). Close the app's Co-Stream screen during rate-limit checks (it polls L1 /api/v1 and shares the IP).

## Requests between laptops
- **L2 → L1 (11:57, k6 / NFR-2):** under 550 VUs your API's p95 is 6.1 s (needs <800 ms). There are no errors; it's queueing. Likely causes: a single uvicorn
  worker, sync handlers on the threadpool (40 threads by default), a small DB pool, or a DB write per QR inspect (scan telemetry). Re-run:
  `k6 run -e API_URL=http://localhost:8080 --summary-export=tests/reports/k6-summary.json tests/k6_load.js` (or ask L2).
- **L2 → L1:** `cs-session-101` does not exist after `/audit/v1/reset` (public costream → 404). The Appium test now creates it via
  `POST /audit/v1/costream/session`. Consider seeding it if the grader opens `/web/costream/cs-session-101` without creating it first.
- **L1 → L2 (MinIO, 11:45) — please do first:** run MinIO on your laptop:
  `docker run -d --name minio -p 9000:9000 -p 9001:9001 -e MINIO_ROOT_USER=nascon -e MINIO_ROOT_PASSWORD=nascon-local-only <your-minio-image> server /data --console-address :9001`
  (or `minio.exe server C:\minio-data --console-address :9001`). Create bucket `vod`. Then write here: your LAN IP,
  the exact image name you used, and that `http://<ip>:9000/minio/health/live` returns 200. L1 then sends recordings + VOD index there
  and adds a `minio` service with that image to docker-compose.yml.
  - **L2 ✅ done (11:49):** MinIO running on Laptop 2. LAN IP **172.15.33.178** (Wi-Fi). S3 API `http://172.15.33.178:9000`, console
    `http://172.15.33.178:9001`. Image **`alpine/minio:RELEASE.2025-10-15T17-29-55Z`**, container `minio`, `--restart unless-stopped`,
    data in Docker volume `nascon-minio-data`. Credentials as in the command above. Bucket **`vod`** created (S3 PUT 200, HEAD 200).
    `http://172.15.33.178:9000/minio/health/live` → **200** (checked from Laptop 2 itself; L1, please curl it once from your side
    in case the Windows firewall blocks inbound traffic).
- **L1 → L2:** chat (`/api/v1/chat`, `/api/v1/public/chat/{room}`), costream, QR, moderation are all merged and running on L1 — run k6 + the
  Appium cross-surface test against L1.
- Done by L1: guest HLS read without credentials (11:40) · tests/reports un-ignored · ci.yml ignores selenium/appium.
- Keep compose service name `api` (Grid nodes reach the backend as `http://api:8080`).

## Known failures / notes
- A DB seeded before today lacks match-m1 → `POST /audit/v1/reset` (the grader resets anyway).
- Cold `docker compose up -d --build` took 227 s on L1 (image build + pulls); warm ~20 s.
- Laptop 2: build the APK from a `subst` drive (the `&` in the folder name breaks gradlew.bat); local NDK 30 used, not committed.

## How to continue (any assistant: Claude / Codex)
- Backend tests: `docker run -d --rm --name league-test-db -p 55433:5432 -e POSTGRES_USER=league -e POSTGRES_PASSWORD=test -e POSTGRES_DB=league postgres:16-alpine`,
  then `TEST_DATABASE_URL=postgresql://league:test@localhost:55433/league DAY1_SALT=test-salt DAY2_SALT=test-day2-salt python -m pytest -q -o addopts= --ignore=tests/selenium --ignore=tests/appium`.
- Coverage: add `--cov=app --cov-report=json:reports/coverage.json`, then `python tools/coverage_report.py reports/coverage.json --day2`.
- Stack: `docker compose up -d --build --wait` (reads `.env`), then `curl -X POST localhost:8080/audit/v1/reset`.
- Selenium: `GRID_URL=http://localhost:4444 WEB_BASE=http://api:8080 API_URL=http://localhost:8080 pytest -n 3 -o addopts= tests/selenium`.
- Day 2 code: `api/app/modules/{day2,streaming,costream,qr_guest,moderation_dlq,observability,realtime,web}.py`; tests `tests/test_day2_*.py`;
  guest pages `api/app/web/`; media config `infra/mediamtx.yml`.
