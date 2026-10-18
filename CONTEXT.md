# CONTEXT — live handoff file (update after every step)

**If this session ends:** open the repo on any laptop, `git pull`, read this file top to bottom, continue from
"Next steps". Keep this file current: update it whenever a step finishes, before every push.

_Last updated: Sun 18 Oct 2026, 10:50 PKT_

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
- [ ] Push for Window 1 (before 11:30).
- [ ] Read Part II spec fully (pages 4–21) and plan.

## Next steps
1. Push the start commit (W1).
2. Read spec sections 3–6, 8, A–C; write a task plan here.
3. Compose: add Selenium Grid 4 hub + 3 Chrome nodes, media server (MediaMTX 1935/8888/8889), Redis/MinIO if required, `DAY2_SALT`.
4. Implement `/audit/v1/*` Part II endpoints module by module (each with tests), then guest web `/web/*`, then mobile.

## Environment facts
- Repos: `Desktop\nascon26` (real, GitHub mavrik018/nascon26) · `Desktop\nascon26-local` (offline copy, no remote — don't push from it).
- Tools installed: Java 25, Selenium server 4.51.0 `C:\tools\selenium`, k6 v2.3.0 `C:\tools\k6`, Appium 2.19 + UiAutomator2,
  emulator `Medium_Phone_API_36.0`. How to run everything: `PROJECT_GUIDE.md` §1b and §6.
- Backend tests: Postgres container on 55433 (`PROJECT_GUIDE.md` §5).
