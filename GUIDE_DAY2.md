# Day 2 team guide: live demo, viva prep, QA tools

Use this on the day. It covers:

- what we built and where each piece lives;
- why we made each design choice (the viva answers);
- how to run and verify everything live on Laptop 1;
- how Selenium, Appium and k6 work, and how to show them to judges.

Addresses used below:

| What | Address |
|---|---|
| Laptop 1 (backend, Grid) | `172.15.33.181` |
| Laptop 2 (MinIO, Appium, emulator) | `172.15.33.178` |

If the Wi-Fi gives new addresses, change them everywhere, including the app's **Server address** button.

---

## 1. The system in one picture

```
 Phone app (Flutter)          Browser (guest, no login)        Judges' tools
 nascon:// deep links         /web/* Guest Web Player          Selenium Grid :4444
 sign-up / sign-in            QR /q/{code} -> 302              Appium :4723, k6
        |                            |                                |
        +--------------- HTTP / SSE / WebSocket ----------------------+
                                     |
                        Core API (FastAPI, 8 uvicorn workers)  :8080
                        api/app/main.py  +  api/app/modules/*.py
                          |          |            |              |
                    PostgreSQL     Redis      MediaMTX         MinIO (S3)
                    (all data)   (shared     RTMP 1935        172.15.33.178:9000
                                  rate limit, HLS 8888         bucket "vod"
                                  WS count)   WebRTC 8889
                                              records -> /recordings volume
```

- **One command starts everything except MinIO:** `docker compose up -d --build`. That is db, redis, mediamtx, api, selenium-hub and 3 browser nodes.
- **Every module is the same shape.** Each file in `api/app/modules/` exposes three things:
  - `router`: its HTTP routes;
  - `SCHEMA`: the tables it creates;
  - `reset()`: what it seeds when `POST /audit/v1/reset` runs.
- **Registration order:** `api/app/modules/__init__.py` lists the modules in reset order. `main.py` mounts every router.

## 2. Where each component lives

| Component | Spec | Files | Tests |
|---|---|---|---|
| Signing: Day 2 uses only `DAY2_SALT` | 5.3 | `api/app/signing.py` (`sign_day2`) | `tests/test_day2_foundation.py` |
| Guest guard: `guest_*` token can never write | FR-4.3 | `api/app/main.py` (`Guards` middleware), `modules/day2.py` | `test_day2_foundation.py`, Selenium test 2 |
| Stream keys, publish auth, revoke kicks the live stream | FR-3.2 | `modules/streaming.py`, `infra/mediamtx.yml` | `test_day2_streaming.py` |
| Recording → MinIO + VOD list | FR-3.2 | `modules/recording.py`, `infra/mediamtx.yml` (`pathDefaults.record`) | `test_day2_recording.py` |
| 4-way co-stream + host hand-off | FR-3.3 | `modules/costream.py` (seeds `cs-session-101`) | `test_day2_costream.py`, `test_day2_costream_seed.py` |
| Host controls: invite, join, mute, spotlight, kick | FR-3.3 | `modules/hostctl.py` | `test_day2_hostctl.py` |
| Athlete profile + follow / unfollow | FR-3.1 | `modules/social.py` | `test_day2_social.py` |
| Player sign-up | — | `modules/rbac.py` (`/api/v1/auth/register`); app `presentation/profile_screens.dart` (`SignUpPage`) | `tests/test_signup.py` |
| Dynamic QR, exports, `/q/` redirect, cart merge | FR-4.1, 4.4 | `modules/qr_guest.py` | `test_day2_qr_guest.py` |
| Chat moderation + DLQ | FR-5.3, 5.2 | `modules/moderation_dlq.py` | `test_day2_moderation.py` |
| Notification bus (SSE + WebSocket), retries, DLQ | FR-5.2 | `modules/notify.py`; `store.py` publishes order status | `test_day2_notify.py` |
| Live score push | NFR-1 | `modules/realtime.py` (`/ws/matches/{id}`, SSE) | `test_day2_realtime.py` |
| `/metrics`, privacy erase | NFR-6, NFR-9 | `modules/observability.py` | `test_day2_observability.py` |
| Guest Web Player | 6.2.2 | `api/app/web/match.html`, `costream.html`, `web.js`, `web.css`; routes in `modules/web.py` | `tests/selenium/test_guest_grid.py` |
| App deep links | 6.3 | `AndroidManifest.xml` (intent-filter), `MainActivity.kt` (MethodChannel), `lib/core/deep_links.dart`, `lib/presentation/guest_screens.dart` | `mobile/test/deep_links_test.dart`, `tests/appium/test_mobile_deeplink.py` |
| Load test | NFR-2 | `tests/k6_load.js` | `tests/reports/k6-summary.json` |
| Autograder workflow | 1.x | `.github/workflows/autograde.yml` | runs on push to `main` |
| Requirement → code → test map | — | `TRACEABILITY.md` (Part II section) | — |

## 3. Architecture decisions: why we did it this way

1. **The guest read-only rule is enforced on the server, in one middleware.**
   - Any POST/PUT/PATCH/DELETE carrying a `guest_*` token gets `403 GUEST_WRITE_FORBIDDEN`, on every route.
   - The spec says hiding buttons earns zero credit.
   - The web page only *reacts* to the 403: that is what opens the login modal.
2. **Signatures use HMAC-SHA256 over `entity_id|canonical JSON` (sorted keys, no spaces).**
   - The salt comes only from the environment. It is never hard-coded and never committed (`.env` is git-ignored).
   - Day 1 and Day 2 use different salts and different functions, so they can't be mixed up.
3. **Concurrency is handled with Postgres advisory locks per entity.**
   - Follow toggles take a lock per athlete; co-stream writes take a lock per session; cart merges take a lock per token.
   - Counters only move when a row really changed, so the follower count always equals the number of follow rows, even when 50 people tap at once.
4. **Every probe is idempotent.**
   - Replaying the same request returns the stored answer (200).
   - Replaying with a different body is a conflict (409), or a re-evaluation for co-streams.
   - This covers the spec's "mobile switches from 4G to Wi-Fi mid-request" case.
5. **Real time works across 8 worker processes.**
   - Events are written to Postgres first.
   - SSE/WebSocket handlers poll the table every ~0.2 s, so it doesn't matter which worker a client is connected to.
   - Redis holds the shared rate-limit counters and the WebSocket count.
6. **Notification retries go to a dead-letter queue.**
   - A failed delivery is retried 3 times with exponential backoff (0.1, 0.2, 0.4 s), then parked in `notification_dlq`.
   - `/metrics` reports the DLQ depth (`nascon_dlq_depth`).
7. **QR codes are dynamic.**
   - A QR encodes a stable short link `/q/{code}`.
   - The *server* decides where it goes at scan time: preview, live, VOD or a notice, depending on the match state.
   - Scan analytics keep a count, the device family and a time bucket. No IP, no User-Agent, no cookie (NFR-9).
8. **The media server asks our API who may publish.**
   - MediaMTX calls `/internal/media/auth` before accepting a publish.
   - Revoking a key also kicks the live publisher through MediaMTX's control API.
9. **Performance (NFR-2) came from three changes:**
   - 8 uvicorn workers with `uvicorn[standard]` (uvloop + httptools);
   - one pure-ASGI guard middleware;
   - Redis-shared counters.
   - Measured: **p95 344 ms, 0 failed out of 27,643 requests** with the full 550-user profile, run inside the Docker network.
10. **The guest web player uses no framework and no build step.** It is plain HTML/JS, served by the API at `/web/static/`.
    - It exposes the 9 `data-testid`s from the spec, meets WCAG AA (contrast, keyboard, ARIA, 48 px targets) and never shows a login wall.
    - It never triggers a browser password popup: it probes the stream before attaching it. A 401 from the media server would otherwise freeze every click.
11. **Deep links need no extra package.**
    - The Android intent-filter catches `nascon://`, and a small MethodChannel in `MainActivity.kt` hands the link to Dart.
    - The Match Live / Co-Stream screens read only public endpoints, so they open even when signed out.
12. **Recording is index-based.**
    - MediaMTX writes 10 s fMP4 segments to a shared volume.
    - After a stream ends (key revoke), the API uploads finished segments to MinIO with a plain SigV4 PUT (no SDK) and writes `vod_recordings` rows.
    - The athlete profile lists those rows as the VOD archive.

## 4. Request flows (draw these on the whiteboard)

**Guest scans a QR**

1. The phone camera opens `http://<L1>:8080/q/m1-live`.
2. `qr_guest.py` checks match-m1's status (`in_progress`) and answers with a **302** redirect to `/web/matches/match-m1/live`. It counts the scan without storing any personal data.
3. `web.py` serves `match.html`. `web.js` then:
   - gets a guest token (`/api/v1/public/guest-token`);
   - loads the match (`/api/v1/public/matches/match-m1`);
   - opens the SSE stream `/api/v1/public/matches/match-m1/stream`;
   - polls the chat every 1 s.

**A score happens**

1. `POST /audit/v1/events` (score) goes to `scoring.py`, which stores the event.
2. `realtime.py` pushes it over the SSE / WebSocket.
3. The banner changes in under 500 ms (NFR-1). Selenium test 3 measures exactly this.

**A guest tries to chat**

1. `POST /api/v1/chat` with a guest token gets **403** from the guard.
2. `web.js` does *not* show the message; it opens the `progressive-auth-modal` instead.
3. The guest logs in. `web.js` then:
   - calls `POST /audit/v1/guest/cart-merge`, which moves the staged cart into the member's cart atomically and only once;
   - restores the video position.

**A member chats**

1. `POST /api/v1/chat` → `moderation_dlq.py`, which runs the checks in this order: rate limit (more than 3 messages in 2 s), flood (`!!!!`, `aaaa`), then leetspeak profanity.
2. A rude word becomes `***`; a flooder is muted.
3. The message is stored with an increasing sequence number in `chat-{room}`.
4. Every viewer (web and app) polls `/api/v1/public/chat/{room}`.

**Co-stream**

1. `POST /audit/v1/costream/session` → `costream.py` checks, in spec order: schema, players exist, host is in the list, capacity of 4, layout fits.
2. If the host dropped, the next participant in array order becomes host.
3. The host's controls (`hostctl.py`) and notifications (`notify.py`, topic `costream:{id}`) build on that session.

**Deep link**

1. `adb ... -d nascon://entity/match-m1`: Android matches the intent-filter and starts `MainActivity`.
2. The MethodChannel `nascon/deeplink` passes the link to Dart.
3. `deep_links.dart` parses it and `clubline_app.dart` pushes `GuestMatchLivePage`, even on top of the sign-in screen.

## 5. Bring the stack up on Laptop 1 (do this first, about 5 min)

```bash
cd nascon26
git pull                                   # get everything Laptop 2 pushed
# .env (never commit it) must contain: DAY1_SALT=...  DAY2_SALT=...
# for recordings also: MINIO_URL=http://172.15.33.178:9000  MINIO_ACCESS_KEY=nascon  MINIO_SECRET_KEY=nascon-local-only
docker compose up -d --build --wait        # rebuilds the API with today's code
curl -X POST http://localhost:8080/audit/v1/reset
curl http://localhost:8080/health          # {"status":"ok"}
curl http://localhost:4444/status          # "ready": true and 3 nodes
```

**If the database has stale tables** (an "undefined column" error after the pull), recreate the database:

```bash
docker compose down -v
docker compose up -d --build --wait
```

That deletes the database volume, so only do it on a demo machine.

**Allow other devices through the Windows firewall.** The phone and Laptop 2 must reach port 8080 on Laptop 1:

```powershell
New-NetFirewallRule -DisplayName "nascon api 8080" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```

Run that in an admin PowerShell, once.

## 6. Verify every feature live: copy-paste checklist

Run from any laptop. Set `B=http://172.15.33.181:8080`, or `localhost:8080` on Laptop 1 itself.

| What to show | Command | Expected |
|---|---|---|
| Health | `curl $B/health` | `{"status":"ok"}` |
| QR resolves by match state | `curl "$B/audit/v1/qr/match-m1?inspect=true"` | `target_route: /web/matches/match-m1/live`, `signature` |
| QR short link | `curl -i $B/q/m1-live` | `302`, `Location: /web/matches/match-m1/live` |
| QR exports | open `$B/audit/v1/qr/match-m1/export.svg` (also `.png`, `.pdf`) | an image or PDF |
| Guest cannot write | `curl -i -X POST $B/api/v1/chat -H "Authorization: Bearer guest_anon_tok_7721" -H "Content-Type: application/json" -d '{"chat_room_id":"chat-match-m1","text":"hi"}'` | `403 GUEST_WRITE_FORBIDDEN` |
| Moderation | `curl -X POST $B/audit/v1/moderation/test -H "Content-Type: application/json" -d '{"chat_room_id":"chat-x","incoming_messages":[{"message_id":"a","sender":"u1","text":"you b@d_w0rd"},{"message_id":"b","sender":"u2","text":"GOAL!!!!"}],"check_dlq":true}'` | `you ***` (`profanity_leetspeak`), `u1` kicked, `u2` muted (flood) |
| Notification + DLQ | `curl -X POST $B/audit/v1/notifications/test -H "Content-Type: application/json" -d '{"topic":"match:match-m1","event_type":"x","payload":{},"simulate_dlq":true}'` | 3 attempts, then in the DLQ |
| Co-stream seeded | `curl $B/api/v1/public/costream/cs-session-101/state` | 4 participants, host `player-alpha-1` |
| Metrics | `curl $B/metrics` | `nascon_dlq_depth`, `nascon_qr_scans_total`, … |
| Live score in the browser | open `$B/web/matches/match-m1/live`, then run the next row | the banner changes to `2 - 0` with no reload |
| Score event | `curl -X POST $B/audit/v1/events -H "Content-Type: application/json" -d '{"event_id":"demo-1","match_id":"match-m1","type":"score","payload":{"team_id":"club-alpha-1","event_type":"goal"}}'` | `201` |
| Athlete profile | `curl $B/api/v1/athletes/player-alpha-1` | career, clubs, followers |
| Sign-up | `curl -X POST $B/api/v1/auth/register -H "Content-Type: application/json" -d '{"email":"sara@nascon.test","password":"Strong#Pass1","display_name":"Sara Malik","position":"fw"}'` | `201` with a token |

PowerShell tip: use `curl.exe` (not `curl`), and put JSON in single quotes.

## 7. Phone and emulator: test chats with several player profiles

**The APK** is `mobile/release/app-release.apk`. Its default server is `http://172.15.33.181:8080` (Laptop 1). It is already installed on the TECNO phone.

**Install on another phone:**

```bash
adb devices
adb install -r mobile/release/app-release.apk
```

If you get `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, run `adb uninstall pk.nascon.league.league_app` first. That error means an old build signed on another laptop is installed.

**On the emulator (Laptop 2 has the `Pixel_9_Pro_XL` AVD):**

```bash
C:\Users\Public\Android\Sdk\emulator\emulator.exe -avd Pixel_9_Pro_XL -no-audio -no-boot-anim
```

Wait for boot, then `adb install -r mobile/release/app-release.apk`. Open the app once by hand: the first launch after an install is slow, about 3–4 s.

**Wrong server?** On the sign-in screen, tap the server icon (top right) and enter `http://<Laptop 1 IP>:8080`.

**Make several player profiles:**

1. On the sign-in screen, tap **New player? Create an account**.
2. Enter a name, an email such as `p1@nascon.test`, a password of 8 or more characters, and pick a position. Tap **Create account**.
3. The app signs in straight away. The player exists in the club **Alpha United** and has a public profile at `/api/v1/athletes/{player_id}`.
4. Repeat with `p2@…`, `p3@…`. **Continue as** on the sign-in screen switches between accounts saved on this phone.

The demo accounts (password `Nascon@26`) also work: `player@`, `manager@`, `organizer@`, `admin@`, `viewer@nascon.test`.

**Test chat across devices:**

1. On the phone, open the Co-Stream screen with:

   ```bash
   adb shell am start -a android.intent.action.VIEW -d "nascon://stream/cs-session-101"
   ```

   The phone shows the participants and the live chat (read-only).
   The link is used once: reopening the app from Recents or from its icon goes to the normal start screen.
2. On a laptop browser, open `http://172.15.33.181:8080/web/costream/cs-session-101`.
3. As a guest, type a message and press **Send**. The **login modal** appears and the message is not posted: that's the 403 rule.
4. Log in inside the modal with a signed-up player (or `player@nascon.test` / `Nascon@26`) and send again. The message appears in the browser and, within about 1 s, on the phone.
5. Send `you b@d_w0rd`. Everyone sees `you ***`.
6. Send `GOAL!!!!`. It is blocked and you are muted.

## 8. Selenium, Appium and k6: what they are and how to show them

### Selenium Grid: automated browsers

- **What it is.** Selenium drives a real Chrome or Firefox by code: open a page, click, type, read the page.
- **What the Grid adds.** The **hub** (port 4444) hands each test to one of several **nodes**, separate browser containers (2 Chrome + 1 Firefox here). That is how 3 tests run in parallel (`-n 3`, from pytest-xdist).
- **Our 3 tests** (`tests/selenium/test_guest_grid.py`, spec 6.2.3):
  1. Open `/q/m1-live`. Check the redirect to `/web/matches/match-m1/live`, that the video and score show within 3 s, and that no login modal is shown.
  2. As a guest, type a chat message and click Send. The message must **not** appear, and the auth modal must open (the server answered 403).
  3. Click **Add to cart**; the count must become `1`. Post a score event; the banner must change within **500 ms** with no reload.
- **Elements are found by `data-testid` attributes** in `match.html`, e.g. `[data-testid="live-score-banner"]`. If you rename one, the test fails. That makes a good live-change demo.
- **Show it to judges (on Laptop 1):**

  ```bash
  curl http://localhost:4444/status          # 3 nodes, ready: true
  pip install -r tests/selenium/requirements.txt
  python -m pytest -n 3 tests/selenium/ -v   # 3 passed; report in tests/reports/selenium-report.xml
  ```

  Open `http://localhost:4444/ui` while it runs. You'll see 3 sessions appear, one per node.
- **The suite needs no settings.** It works out by itself which URL the containerised browsers can use to reach the API (`localhost:8080`, `api:8080` or `host.docker.internal:8080`).

### Appium: automated phone

- **What it is.** Appium is Selenium for mobile apps. The Appium server (port 4723) talks to the phone through **UiAutomator2**, an Android helper that can read the screen and find elements by text or accessibility label.
- **Our 3 tests** (`tests/appium/test_mobile_deeplink.py`, spec 6.3):
  1. Fire `adb shell am start -W -a android.intent.action.VIEW -d nascon://entity/match-m1`. The app must reach the foreground within **2 s** and show the **Match Live** screen, not the sign-in screen. The time is read from Android's own `WaitTime`.
  2. The same for `nascon://stream/cs-session-101`, which must show **Co-Stream**.
  3. Cross-surface: the app opens `cs-session-101` while a Selenium Grid browser opens `/web/costream/cs-session-101`. One chat message must reach **both** within 3 s.
- **Show it to judges.** Laptop 2 has Appium + the emulator; Laptop 1 needs the Grid. Run from **Laptop 2**:

  ```bash
  appium                                     # in one terminal (if not already running): Appium 2 on :4723
  adb devices                                # the emulator or phone must be listed as "device"
  curl http://localhost:4723/status          # "ready": true
  set ANDROID_SERIAL=emulator-5554          # run on the EMULATOR, even if the phone is plugged in too
  set GRID_URL=http://172.15.33.181:4444
  set WEB_BASE=http://api:8080
  set API_URL=http://172.15.33.181:8080
  python -m pytest tests/appium/ -v          # 3 passed; report in tests/reports/appium-report.xml
  ```

  Those `set` lines are for cmd.exe. In Git Bash use `export GRID_URL=...` instead.

  `ANDROID_SERIAL` is required when more than one device is connected. Appium and `adb` then both drive the emulator,
  not the physical phone. `adb devices` lists the names. Measured on Laptop 2 at 13:09: **3 passed**.
  Keep the physical phone for hand-testing chats and sign-ups.
- **The app talks to Laptop 1 directly.** The APK's default server is Laptop 1, so no port forwarding is needed. Open the app once before the run; the first launch after installing is slow.

### k6: load test

- **What it is.** k6 runs many virtual users (VUs) at once, each looping over a small JavaScript function. At the end it reports latency percentiles and the error rate against **thresholds**.
- **Our profile** (`tests/k6_load.js`, copied exactly from spec 6.4), running for 15 s:
  - 500 VUs fetch `/audit/v1/qr/match-m1?inspect=true` every 0.1 s;
  - 50 VUs post chat to `/audit/v1/moderation/test` every 0.2 s.
- **Pass means both thresholds:** `http_req_failed rate==0.00` and `http_req_duration p(95)<800`. k6 prints ✓ or ✗ next to each.
- **Show it to judges.** Run it inside the Docker network. On Windows, k6 run from the host can get "connection refused" from Docker Desktop's port proxy under heavy load.

  ```bash
  MSYS_NO_PATHCONV=1 docker run --rm --network league_default -v "$PWD/tests:/t" grafana/k6:0.54.0 \
    run -e API_URL=http://api:8080 --summary-export=/t/reports/k6-summary.json /t/k6_load.js
  ```

  The network name is `<project>_default`, usually `league_default`; `docker network ls` shows it. Our measured result was p95 344 ms, 0 failed. Read out `http_req_duration p(95)` and `http_req_failed` from the output.
- **On the CI runner (Linux)** it runs simply as `k6 run --summary-export=tests/reports/k6-summary.json tests/k6_load.js`.

## 9. Live code-change drills (practise each once)

After a backend edit, run `docker compose up -d --build api` (about 20 s), then re-run the one test that covers it:
`TEST_DATABASE_URL=... python -m pytest -q -o addopts= tests/<file>.py -k <name>`.

| Judge asks | Where to change | How to prove it |
|---|---|---|
| "Add the word *cheat* to the profanity filter" | `api/app/modules/moderation_dlq.py`, the `PROFANITY` set | the moderation curl from section 6 with `ch3at` shows `***` |
| "Allow only 2 chat messages per 2 s" | `moderation_dlq.py`: `RATE_LIMIT, RATE_WINDOW_SECONDS = 3, 2` | `pytest tests/test_day2_moderation.py` (update the test's number too) |
| "Make the DLQ retry 5 times" | `moderation_dlq.py`, `MAX_ATTEMPTS` and `BACKOFF_SECONDS` | the notifications curl shows 5 attempts |
| "Change the score banner colour / add a new testid" | `api/app/web/web.css` / `match.html` | reload the page; the Selenium suite |
| "Co-stream max 3 people" | `costream.py`, `MAX_PARTICIPANTS` | `pytest tests/test_day2_costream.py` (adjust expectations) |
| "QR for a postponed match goes to …" | `qr_guest.py`, the route-by-status mapping | `curl $B/audit/v1/qr/match-m1?inspect=true` after a status change |
| "Change the deep-link screen title" | `mobile/lib/presentation/guest_screens.dart` | `flutter run` on the phone, or rebuild the APK (see below) |

**Rebuilding the APK on Laptop 2:**

1. The `&` in the folder path breaks Gradle, so build from a drive letter:

   ```bash
   subst N: "C:\Users\SAEED & SONS\Desktop\App_dev\nascon26"
   cd N:\mobile
   ```
2. Temporarily set `ndkVersion = "30.0.16248370"` in `android/app/build.gradle.kts`. Don't commit that change.
3. Build:

   ```bash
   flutter build apk --release --dart-define=API_BASE_URL=http://172.15.33.181:8080
   ```
4. Copy the result to `mobile/release/app-release.apk`.

## 10. Viva cheat sheet (short answers)

- **Why is the guest block done on the server?** The spec gives zero credit for UI hiding. Any client can call the API directly, so the 403 must come from the API: one middleware, every route.
- **How do you stop double follows or double merges under load?** A transaction-scoped advisory lock per entity, plus `INSERT ... ON CONFLICT DO NOTHING`. Counters change only when a row really changed. The test fires bursts of simultaneous toggles and checks counter == row count.
- **How does real time work with 8 worker processes?** Events go to Postgres first. Each SSE/WebSocket connection polls by id (`id > last_seen`) about every 0.2 s. Any worker can serve any client, and nothing is lost if a worker restarts.
- **What happens when a notification can't be delivered?** 3 attempts with exponential backoff, then a row in `notification_dlq`. It is visible in `dlq_status` and in `/metrics` as `nascon_dlq_depth`.
- **How does the host hand-off work?** If `simulate_host_drop` is true, the next participant in array order becomes host. If nobody is left, the session ends cleanly. The answer is signed with DAY2_SALT.
- **Why is the QR "dynamic"?** The printed code never changes. The server picks the destination at scan time from the match state.
- **What about privacy?** Scans store a count, mobile/desktop and a time bucket only. `DELETE /audit/v1/privacy/user/{id}` wipes personal data and invalidates guest tokens within 1 s.
- **How did you reach p95 < 800 ms?** Profiling showed queueing. We added more workers, uvloop/httptools, Redis-shared counters and one ASGI middleware instead of several. Result: p95 dropped from 6.1 s to 344 ms.
- **What did you not finish?** Recording upload and indexing are tested against the real MinIO, but we did not run a full RTMP → record → upload on a laptop with ffmpeg. Say so honestly.

## 11. Before 14:00 (final)

1. `git pull` on both laptops.
2. On Laptop 1: `docker compose up -d --build --wait`, then `POST /audit/v1/reset`.
3. Run the Selenium suite: 3 passed.
4. Push before **14:05:00** (Window 4 is 13:45–14:05). Never force-push; the author must be `mavrik018`.
