# CONTEXT — live handoff file (update after every step)

**If this session ends:** open the repo on any laptop, `git pull`, read this file top to bottom, continue from
"Next steps". Keep this file current: update it whenever a step finishes, before every push.

_Last updated: Sun 18 Oct 2026, 11:00 PKT_

## Hard rules for Day 2 (from `App Dev Day 2 Problem Statement.pdf`, binding)
- Window: 10:15 → **14:00 code freeze**, final push **14:05:00 PKT** (later commits ignored).
- **Push at least once in each window:** W1 10:15–11:30 · W2 11:30–12:45 · W3 12:45–13:45 · W4 13:45–14:05.
- Commits must descend from Day 1 SHA `11b52ef` (never rewrite history / force-push).
- `docker-compose.yml` must forward `DAY1_SALT: ${DAY1_SALT}` **and** `DAY2_SALT: ${DAY2_SALT}`; never hard-code
  salts (voids module credit). DAY2_SALT = 16-char value on the Day 2 venue slip.
- `docker compose up -d --build` must start in ≤120 s; `http://localhost:4444/status` must show ≥3 ready browser nodes.
- Required new paths: `.github/workflows/autograde.yml`, `tests/selenium/` (incl. `test_guest_grid.py`),
  `tests/appium/`, `tests/k6_load.js` (500 guest viewers + 50 chat posters), `tests/reports/`, `COVERAGE_DAY2.json`
  (modules: streaming, costream, qr_guest, moderation_dlq, observability).
- Weight: 80% backend + QA infra, 20% frontend (mobile + guest web `/web/*`). Viva 14:30.
- Commits: author mavrik018 only, no co-author lines (team rule).

## Status
- [x] Day 1 locked at `11b52ef` (Part I graded).
- [x] Day-2 start commit: brings in the Part I gap work (FR-1.2 competitions, FR-1.3 status/reschedule,
      FR-2.3 price changes / pin / delete, add player, editable sport rules, per-user offline queues, server UUIDs,
      iOS UI pass) + `qa/` smoke scripts + `PROJECT_GUIDE.md`. Backend suite green, flutter analyze clean, 48 flutter tests pass.
- [x] Pushed `8a26abe` in Window 1 (10:53 PKT), ancestry check vs `11b52ef` OK.
- [x] Read the whole Part II spec (21 pages). Plan below.

## Plan (priority = marks; backend is 80%) — tick as done
Spec page refs in brackets. Every new signed response: `sign_day2(DAY2_SALT, entity_id, sig_payload)` (§5.3, App. A).
1. [ ] **Foundation** — `signing.py` add `sign_day2` (reads DAY2_SALT env); compose forwards `DAY2_SALT`;
   reset seeds (§5.2): player-beta-2 in club-beta-1, match `match-m1` (football, league-alpha-1, club-alpha-1 v club-alpha-2,
   in_progress 1-0), QR maps match-m1→`/q/m1-live`, player-alpha-1→`/q/p-alpha-1`, club-alpha-1→`/q/c-alpha-1`,
   guest token `guest_anon_tok_7721`, empty cart for player-alpha-1. `/health` 200.
2. [ ] **stream key** `POST /audit/v1/stream/key` generate(201)/rotate(200)/revoke(200, 404 STREAM_NOT_FOUND) [§5.4].
3. [ ] **co-stream** `POST /audit/v1/costream/session` 5 ordered rules, handoff, idempotent replay 200 [§5.5].
4. [ ] **QR** `GET /audit/v1/qr/{id}` (+`?inspect=true`), dynamic target_route by live status, exports svg/png/pdf,
   `GET /q/{code}` 302, scan telemetry w/o PII [§5.6]. Need QR lib (check `segno`/`qrcode` — pure python, add to requirements).
5. [ ] **guest boundary + cart merge** `POST /audit/v1/guest/cart-merge` 6 rules, idempotent replay, 409 GUEST_TOKEN_ALREADY_MERGED;
   bearer `guest_anon_tok_*` → 403 GUEST_WRITE_FORBIDDEN on `/api/v1/chat`, `/audit/v1/checkout`, `/audit/v1/events` [§5.7].
6. [ ] **moderation + DLQ** `POST /audit/v1/moderation/test` leetspeak mask, flood drop, kicked/muted dedup, DLQ depth,
   concurrency-safe (10 parallel calls) [§5.8, §8 #3].
7. [ ] **observability** `GET /metrics` Prometheus text (5 metrics), `DELETE /audit/v1/privacy/user/{id}` [§5.9].
8. [ ] **compose infra** selenium hub 4.25 + node-chrome-1/-2 + node-firefox (shm 1gb, VNC off), MediaMTX (1935/8888/8889),
   Redis/MinIO only if needed; up ≤120 s [§6.1–6.2.1].
9. [ ] **guest web** `/web/matches/{id}/live|preview|vod|notice`, `/web/costream/{id}` etc. with the 9 `data-testid`s,
   live score via SSE/WS ≤500 ms, guest cart, chat 403 → `progressive-auth-modal`, WCAG AA [§6.2.2, NFR-8].
10. [ ] **WebSocket** `ws://localhost:8080/ws/matches/{id}` score broadcast p95<500 ms (NFR-1).
11. [ ] **QA suites** `tests/selenium/test_guest_grid.py` (3 tests, `pytest -n 3`), `tests/appium/test_mobile_deeplink.py`,
   `tests/k6_load.js` (exact profile §6.4), `tests/reports/`, `.github/workflows/autograde.yml`.
12. [ ] **mobile** AndroidManifest intent-filter `nascon://`, open match/co-stream screen from deep link [§6.3].
13. [ ] `COVERAGE_DAY2.json` (streaming, costream, qr_guest, moderation_dlq, observability ≥85%), TRACEABILITY.md Part II rows.
Push in every window: W2 by 12:45, W3 by 13:45, final by 14:05.

## Next steps
Start plan item 1 (foundation), then 2→7 one module each with tests, commit+push per window.

## Environment facts
- Repos: `Desktop\nascon26` (real, GitHub mavrik018/nascon26) · `Desktop\nascon26-local` (offline copy, no remote — don't push from it).
- Tools installed: Java 25, Selenium server 4.51.0 `C:\tools\selenium`, k6 v2.3.0 `C:\tools\k6`, Appium 2.19 + UiAutomator2,
  emulator `Medium_Phone_API_36.0`. How to run everything: `PROJECT_GUIDE.md` §1b and §6.
- Backend tests: Postgres container on 55433 (`PROJECT_GUIDE.md` §5).
