# Laptop 2 — Day 2 plan (frontend surfaces + automated QA)

Read `CONTEXT.md` first (shared tracker: tick your rows there, nowhere else).
Spec = `App Dev Day 2 Problem Statement.pdf` (section numbers below refer to it). Freeze 14:00, final push 14:05 PKT.

## Ground rules (avoid breaking each other)
* **You own only these paths:** `api/app/web/**` (static HTML/JS/CSS), `tests/selenium/**`, `tests/appium/**`,
  `tests/k6_load.js`, `tests/reports/**`, `mobile/**`, `.github/workflows/autograde.yml`.
* **Never edit** `api/app/modules/**`, `api/app/main.py`, `docker-compose.yml`, `signing.py`, `tests/test_*.py` — Laptop 1 owns them.
  Need a backend change? Write it under "Requests to Laptop 1" in `CONTEXT.md` and push.
* Git: `git pull --rebase` before you start and before every push; small commits; author must be **mavrik018**
  (`git config user.name mavrik018`), no co-author lines. Never force-push. Push at least once per window:
  W2 11:30–12:45 · W3 12:45–13:45 · W4 13:45–14:05.
* Salts: never in code. Create a local `.env` (git-ignored) only if you run the stack yourself:
  `DAY1_SALT=<slip>` / `DAY2_SALT=<slip>` (ask the team lead).
* No ffmpeg / MinIO needed for anything below. Point tests at Laptop 1 over the LAN:
  `API=http://<laptop1-ip>:8080`, Grid `http://<laptop1-ip>:4444` (Laptop 1 runs the full compose stack).

## Backend you can rely on (Laptop 1 delivers these first; until then code against this contract)
| Call | Answer |
|---|---|
| `GET /web/matches/{id}/live` (also `/preview`, `/vod`), `/web/matches/{id}/notice?state=…`, `/web/costream/{id}`, `/web/players/{id}`, `/web/clubs/{id}` | serves your files: `api/app/web/match.html` (all match routes), `costream.html`, `entity.html` (players/clubs), `notice.html` |
| `GET /api/v1/public/guest-token` | `{"guest_token": "guest_anon_tok_…"}` (store in `sessionStorage`) |
| `GET /api/v1/public/matches/{id}` | `{match_id, status, home:{team_id,score}, away:{team_id,score}, playback_url, pinned_product:{product_id,name,price_minor,variant_id:"var-jersey-001-L"}, chat_room_id}` |
| `GET /api/v1/public/matches/{id}/stream` | SSE `event: match` with the same body on every change (score ≤500 ms) |
| `GET /api/v1/public/chat/{chat_room_id}` | `[{message_id, sender, text, flagged}]` (profanity already `***`) |
| `POST /api/v1/chat` `{chat_room_id, text}` + `Authorization: Bearer <guest token>` | **403** `{"error":{"code":"GUEST_WRITE_FORBIDDEN",…}}` for guests |
| `GET /api/v1/public/costream/{session_id}` | `{session_id, active_host, active_participants, layout, composite_playback_url, chat_room_id}` |

## Tasks (in this order) — tick in CONTEXT.md
**L2-1 Guest Web Player (Selenium grades it; 20% frontend)** — plain HTML + vanilla JS, no framework, no build step.
`api/app/web/match.html` + `web.js` + `web.css`. Must contain exactly these `data-testid`s (spec 6.2.2):
`guest-video-player` (`<video>`; HLS: load `hls.js` from a CDN only if the browser can't play `.m3u8` natively),
`live-score-banner` (text like `1 - 0`, updated from the SSE stream without reload),
`pinned-merch-card`, `add-to-guest-cart-btn` (adds var-jersey-001-L qty 1 to a cart in `sessionStorage`),
`guest-cart-count` (integer text), `chat-message-list`, `chat-input-field`, `chat-send-btn`
(POST /api/v1/chat with the guest token → on 403 do **not** append the message, show the modal),
`progressive-auth-modal` (hidden initially; login/register prompt; cart preserved).
NFR-8: contrast ≥ 4.5:1, every control reachable by Tab/Enter, `aria-label`s on media controls, buttons ≥ 48×48 px.
No login wall on load. Same page for `costream.html` (use the costream JSON, same testids for video/chat).

**L2-2 `tests/selenium/test_guest_grid.py`** (spec 6.2.3) — 3 tests, runnable with `pytest -n 3 tests/selenium/`,
`webdriver.Remote(GRID_URL)`; base URL from env `WEB_BASE` (inside Grid containers use `http://api:8080`).
Test 1 `/q/m1-live` → redirected to `/web/matches/match-m1/live`, video + score visible ≤3 s, modal hidden.
Test 2 chat send as guest → message not appended, modal visible. Test 3 add to cart → count `1`; POST
`/audit/v1/events` score for match-m1 → banner updates ≤500 ms. Write JUnit XML to
`tests/reports/selenium-report.xml` (`--junitxml`).

**L2-3 `tests/k6_load.js`** — copy the exact profile from spec 6.4 (500 viewers + 50 chat posters, 15 s,
thresholds `rate==0.00`, `p(95)<800`); read base URL from `__ENV.API_URL` defaulting to `http://localhost:8080`.
Run: `k6 run --summary-export=tests/reports/k6-summary.json tests/k6_load.js` against Laptop 1. Commit the real summary only.

**L2-4 Flutter deep links (spec 6.3)** — `mobile/android/app/src/main/AndroidManifest.xml`: add the `nascon` VIEW/
BROWSABLE intent-filter to the main activity. In Dart, handle `nascon://entity/match-m1` → open the Match page for
`match-m1`, `nascon://stream/cs-session-101` → a simple Co-Stream screen (participants + chat from
`/api/v1/public/costream/{id}`). Use the platform's initial link + link stream (e.g. `app_links` package — ask before
adding a dependency). Must not crash or stop on the login screen (open read-only as guest). Run `flutter test` +
`flutter analyze`; build `flutter build apk --release` and copy to `mobile/release/app-release.apk`.

**L2-5 `tests/appium/test_mobile_deeplink.py`** — Appium 2 at `:4723` (uiautomator2): fire
`adb shell am start -W -a android.intent.action.VIEW -d "nascon://entity/match-m1"` and the co-stream one; assert the
app is foreground within 2 s on the right screen. JUnit to `tests/reports/appium-report.xml`.
Cross-surface (optional if time): app joins `cs-session-101` while a Selenium session opens `/web/costream/cs-session-101`
and sees the same chat ≤3 s.

**L2-6 `.github/workflows/autograde.yml`** — on push to `main`: checkout, write `.env` from repo secrets
`DAY1_SALT`/`DAY2_SALT` (never literal values), `docker compose up -d --build --wait`, curl `/health`,
check `http://localhost:4444/status` has ≥3 nodes, run `pytest -q` (backend), `pytest -n 3 tests/selenium/`, k6 smoke.

## When you finish a task
Tick it in `CONTEXT.md` (who/when/what was actually run and passed), `git pull --rebase`, push.
Never write a test report or coverage number you did not actually produce.
