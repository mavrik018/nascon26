# Clubline / NaSCon '26 — Project Guide for the Team

Read this top to bottom once. Then keep it open during Day 2 and the viva.
Everything here is about the folder **`Desktop\nascon26-local`** (the offline copy). Where something exists only
in this copy and **not** in the graded Day 1 commit `11b52ef`, it is marked **(local copy only)**.

---

## 0. The 30-second picture

```
 Phone (Flutter app)  ──HTTP/JSON──►  API (FastAPI, Python)  ──SQL──►  PostgreSQL 16
   mobile/                              api/app/                       Docker volume "pgdata"
   - SQLite cache + offline queue       - one module per area          - 26+ tables
   - secure token storage               - /audit/v1/*  (autograder)
                                        - /api/v1/*    (the app)
 Everything server-side runs in Docker:  docker compose up -d --build   →  http://localhost:8080
```

* **Autograder** talks only to `/audit/v1/*` (exact shapes from the spec).
* **The app** talks only to `/api/v1/*` (needs a login token).
* Both call the **same domain functions**, so rules are never written twice.

---

## 1. Start, stop, look around

| What | Command (run in `Desktop\nascon26-local` or `Desktop\nascon26`) |
|---|---|
| Start Docker | open **Docker Desktop** and wait until it says "Engine running" |
| Start backend | `$env:DAY1_SALT="<salt from the slip>"; docker compose up -d --build` |
| Is it up? | open http://localhost:8080/health → `{"status":"ok"}` |
| See every route + try them | open **http://localhost:8080/docs** (Swagger UI, click "Try it out") |
| API logs (live) | `docker compose logs -f api` |
| Stop | `docker compose down` (keeps data) · `docker compose down -v` (also **deletes the database**) |
| Reset demo data | `curl.exe -X POST http://localhost:8080/audit/v1/reset` |
| After changing Python code | `docker compose up -d --build` (rebuilds the `api` image) |

> Both folders use the compose project name `league`, so starting one **replaces** the other's containers.
> Use `nascon26` for what is graded, `nascon26-local` to try tonight's improvements.

Demo accounts (password for all: `Nascon@26`):

| Role | Email | Owns |
|---|---|---|
| Platform Super-Admin | admin@nascon.test | everything |
| League Organizer | organizer@nascon.test | league `league-alpha-1` |
| Club Manager | manager@nascon.test | club `club-alpha-1` |
| Player | player@nascon.test | `player-alpha-1` |
| General Viewer | viewer@nascon.test | read-only |

Get a token by hand (PowerShell):
```powershell
$t = (Invoke-RestMethod -Method Post http://localhost:8080/api/v1/auth/login -ContentType 'application/json' `
      -Body '{"email":"admin@nascon.test","password":"Nascon@26"}').token
Invoke-RestMethod http://localhost:8080/api/v1/sports -Headers @{Authorization="Bearer $t"}
```

---

## 1b. Run it live: backend in Docker + app on the emulator (or a phone)

Do these in order, each in its own PowerShell window.

**Step 1 — backend in Docker**
```powershell
# open Docker Desktop first and wait for "Engine running"
cd C:\Users\Administrator\Desktop\nascon26           # graded code (or nascon26-local for tonight's version)
$env:DAY1_SALT = "<salt from your slip>"             # see "About the salt" below
docker compose up -d --build
curl.exe http://localhost:8080/health                # must print {"status":"ok"}
```

**Step 2 — start the Android emulator**
```powershell
& "$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe" -avd Medium_Phone_API_36.0
adb devices                                          # wait until it shows: emulator-5554  device
```
(Or Android Studio → Device Manager → press Play on "Medium Phone API 36".)

**Step 3a — run the app from source (live, with hot reload)**
```powershell
cd C:\Users\Administrator\Desktop\nascon26-local\mobile
flutter devices                                      # the emulator must be listed
flutter run                                          # first build takes 1-3 minutes
```
While it runs: **r** = hot reload (UI change shows in ~1 s), **R** = full restart, **q** = quit.

**Step 3b — or install the ready-made APK (what the judges use)**
```powershell
adb install -r C:\Users\Administrator\Desktop\nascon26\mobile\release\app-release.apk
```

**Server address inside the app**
* Emulator → `http://10.0.2.2:8080` (already the default; `10.0.2.2` means "the laptop" from inside the emulator).
* Real phone on the same Wi-Fi → `http://<laptop IP>:8080` (IPv4 from `ipconfig`). Set it on the sign-in screen
  (**Server**) or in Profile. If the phone can't connect, allow the port (admin PowerShell):
  `netsh advfirewall firewall add rule name="league8080" dir=in action=allow protocol=TCP localport=8080`
* Real phone over USB: Developer options → USB debugging on, plug in, accept the prompt, then `flutter run`.

**Stop everything:** `q` in the flutter window, close the emulator, `docker compose down`.

### About the salt (DAY1_SALT)
* The salt is the secret key that signs score events and receipts (HMAC-SHA256). **Our code contains no salt** —
  the server reads the environment variable `DAY1_SALT` at start (`docker-compose.yml`: `DAY1_SALT: ${DAY1_SALT}`).
* **Always use the salt printed on your team slip** (the one you wrote in the notebook from the slip). The grader starts
  our compose with that value and recomputes every signature with it.
* Any value used on the laptop on Day 1 was only for local testing and is not stored in the repo, so no code change is
  needed — just set the slip's salt in the shell before `docker compose up`.
* After changing the salt, run `curl.exe -X POST http://localhost:8080/audit/v1/reset` so the seeded events are
  re-signed with it. Check what the server uses: `docker compose exec api printenv DAY1_SALT`.

---

## 2. How to open the database

The database runs inside Docker. Its port is **not** published to Windows, so open it *through* Docker.

**Option A — psql inside the container (nothing to install):**
```powershell
cd Desktop\nascon26-local
docker compose exec db psql -U league -d league
```
Useful commands inside psql:

| Type | Does |
|---|---|
| `\dt` | list tables |
| `\d scoring_events` | show a table's columns |
| `SELECT * FROM sports;` | rows (end every SQL line with `;`) |
| `\x` | toggle "expanded" display (easier for wide rows) |
| `\q` | quit |

Handy queries:
```sql
SELECT email, role, tenant_id FROM rbac_users;                       -- who can log in
SELECT match_id, home, away, scheduled_at FROM scoring_matches ORDER BY created_seq;
SELECT sequence, type, payload, left(signature,12) FROM scoring_events
  WHERE match_id = 'alpha1-m04' ORDER BY sequence;                     -- a match's event log
SELECT variant_id, price_minor, stock, reserved FROM store_variants;  -- inventory
SELECT order_id, status, error_code FROM store_orders ORDER BY created_at DESC LIMIT 10;
SELECT seq, entry->>'action', entry->>'who', entry->>'why' FROM roster_audit ORDER BY seq DESC LIMIT 10;
SELECT role, action, scope FROM rbac_policies ORDER BY role;          -- the RBAC matrix
```

**Option B — a GUI (DBeaver / pgAdmin / VS Code):** add a port to the `db` service in `docker-compose.yml`
**only on your laptop** (do not commit it), then `docker compose up -d`:
```yaml
  db:
    ports:
      - "5433:5432"
```
Connect to host `localhost`, port `5433`, database `league`, user `league`, password `league-local-only`.

**Where each table comes from** (every module creates its own tables in its `SCHEMA` string):

| Tables | Created in | Holds |
|---|---|---|
| `app_state` | `core.py` | current reset seed |
| `sports` | `sports.py` | sport rules as JSON (`config`) |
| `scoring_leagues`, `scoring_matches`, `scoring_events` | `scoring.py` | leagues, fixtures, the **append-only** event log |
| `roster_*` (9 tables) | `roster.py` | squads, players, registrations, audit trail, club profiles |
| `store_*` | `store.py` | products, variants (stock), orders, discount codes, domain events, price changes |
| `rbac_*` | `rbac.py` | tenants, users (hashed passwords), policy matrix |
| `sync_actions` | `sync.py` | which offline actions were already applied (duplicates) |
| `schedule_venues` (local copy only) | `schedule.py` | venues + opening hours (UTC) |
| `competitions` (local copy only) | `competitions.py` | divisions / hybrid competitions |

There is **no migrations tool**: a module adds a column with `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` inside its
`SCHEMA`; it runs on every startup and every reset (`core.py → apply_schemas`).

---

## 3. Which file contains what

### Backend — `api/app/`

| File | Job |
|---|---|
| `main.py` | creates the FastAPI app, 1 MB body limit (`MAX_BODY_BYTES`), rate-limit middleware, `/health`, mounts every module's `router` |
| `db.py` | the connection pool (`with pool.connection() as conn:` = one transaction, commit at the end) |
| `errors.py` | the spec error envelope `{"error":{"code","message","details"}}`; `validation()` → 400, `not_found()` → 404, `conflict()` → 409 |
| `signing.py` | `sign()` = HMAC-SHA256(DAY1_SALT, id + "\|" + canonical JSON); `lots_key()` = SHA-256 for drawing of lots |
| `auth.py` | JWT create/verify (HS256, rejects `alg:none`, tampered, expired) and `current_user` dependency |
| `modules/__init__.py` | `MODULES` list = order of schema creation and reset |
| `modules/core.py` | `/audit/v1/reset`, schema bootstrap, seed |
| `modules/sports.py` | sports as data: `validate_sport`, baseline sports, `/audit/v1/sports`, `/api/v1/sports` (+ edit/delete — local copy only) |
| `modules/fixtures.py` | **algorithms**: round robin (circle method), Swiss (blossom matching), single/double elimination |
| `modules/scoring.py` | leagues, event log (`append_event`), projection (`project_state`, `build_projection`), match routes, SSE stream, pin product (local copy only) |
| `modules/standings.py` | points table + tie-breaks (`compute`, `resolve`, `_criterion_value`), qualification |
| `modules/roster.py` | transfers / loans / releases (`apply_transfer`, 8 rules in spec order), history, clubs, add player (local copy only) |
| `modules/store.py` | catalogue, **concurrency-safe checkout**, mock gateway (`tok_success` / `tok_declined` / `tok_capture_fail`), PDF receipt, order lifecycle |
| `modules/rbac.py` | users, tenants, **policy matrix** (`POLICIES`, `can()`), login, rate limiter (`RATE_LIMIT`, `RATE_WINDOW_SECONDS`) |
| `modules/sync.py` | offline sync (`process` → `_apply` per action) for `/audit/v1/offline-sync` and `/api/v1/sync` |
| `modules/schedule.py` (local copy only) | postpone / abandon / cancel, reschedule with conflict detection |
| `modules/competitions.py` (local copy only) | divisions with promotion/relegation, hybrid groups → knockout |
| `modules/util.py` | id/date validators, `read_json` (bad JSON → 400) |

### Tests — `tests/`
One file per area (`test_store.py`, `test_roster.py`, …). `conftest.py` runs the same tests either **in-process**
(fast, real Postgres) or **over HTTP** against a running stack (`API_URL=http://localhost:8080`).

### App — `mobile/lib/`

| Path | Job |
|---|---|
| `main.dart` | starts the app: `AppState(SqliteLocalStore, SecureTokenStore, connectivity)` |
| `core/app_state.dart` | the brain: login, session, server URL, `load()` with cache fallback, offline queue (per user — local copy only), sync |
| `core/api_client.dart` | HTTP + retries (GET ×2), 8 s timeout, error mapping, SSE `events()` (local copy only) |
| `core/local_store.dart` | SQLite: settings, cache, `pending_actions`, `sync_log`; secure token storage |
| `core/errors.dart` | **plain-language message for every error code** (`friendlyByCode`) |
| `core/models.dart` | `AppUser`, `Tenant`, `Session`, `PendingAction` (5.14 format), `SyncLogEntry` |
| `core/format.dart` | money, dates, `humanize`, `newId()` (UUID v4 — local copy only) |
| `presentation/clubline_app.dart` | app root: sign-in gate, 5-tab shell, tenant theme |
| `presentation/ocean_widgets.dart` | theme (`oceanTheme`), page scaffold `OceanPage` (header + status chip), cards, tags |
| `presentation/ios_ui.dart` (local copy only) | toasts, iOS picker sheet, grouped form rows, alerts, date wheel, motion |
| `presentation/league_screens.dart` | Fixtures, Match (live score, scoring desk, corrections), Standings |
| `presentation/club_screens.dart` | Club profile, Manage roster, Add player |
| `presentation/shop_screens.dart` | Store, product, cart, checkout, receipt, Add merchandise |
| `presentation/profile_screens.dart` | Sign in, Profile, Sync queue page, server address dialog |
| `presentation/sport_screens.dart` | Sports list, add / edit rules |
| `widgets/sync_banner.dart` | Online / Offline / Syncing indicator |
| `toolkit/` | our reusable widgets (Pressable, chips, search field, tokens) |
| `features/` | older Day-1 screens kept as fallback (not used by `main.dart`) |
| `test/` | widget + unit tests (`flutter test`) |

---

## 4. How a request flows (know these 4 by heart)

**A. Score a goal (event sourcing)** — `POST /api/v1/matches/{id}/events`
1. `scoring.match_post_event` checks the user may score (`can_score`).
2. `append_event` takes a lock for that match (`pg_advisory_xact_lock`), validates, checks the state machine.
3. `_store` inserts a **new row** into `scoring_events` with `signature = sign(event_id, payload)`.
4. Nothing is ever updated. The score is **recomputed** from all events on every read (`project_state`).
5. A correction is a `compensation` event that cancels an earlier one (both stay in the log).

**B. Buy the last jersey (no overselling)** — `POST /audit/v1/checkout`
1. Validate the order, look up variants and the discount.
2. `_reserve`: **one conditional UPDATE** `stock = stock - q, reserved = reserved + q WHERE stock >= q`.
   If 0 rows changed → `409 OUT_OF_STOCK`. The database does the check-and-write atomically, so 20 buyers can't all win.
   Items are reserved in sorted `variant_id` order, so two multi-item orders can never deadlock each other.
3. Call the mock gateway. Declined → release the reservation. Success → commit, sign the receipt, build the PDF.

**C. Transfer a player** — `roster.apply_transfer`: locks the league row, then checks 8 rules **in spec order**
(schema → ids exist → same tenant → player in from-squad → window → not on loan → squad not full → positions),
writes a registration + an immutable audit entry. Same `request_id` again → same answer (idempotent).

**D. Offline action** — the app saves the action in SQLite (`pending_actions`, 5.14 format). When online,
`AppState.syncNow` sends `/api/v1/sync`; the server replays each action through the **same** functions (A or C)
and answers `applied` / `duplicate` / `rejected` + reason per action.

---

## 5. Run the tests

**Backend (in-process, fastest):**
```powershell
docker run -d --rm --name league-test-db -p 55433:5432 -e POSTGRES_USER=league -e POSTGRES_PASSWORD=test -e POSTGRES_DB=league postgres:16-alpine
cd Desktop\nascon26-local
$env:TEST_DATABASE_URL="postgresql://league:test@localhost:55433/league"; $env:DAY1_SALT="test-salt"
python -m pytest -q                                  # everything (~1,200 tests)
python -m pytest tests/test_store.py -q              # one file
python -m pytest tests/test_store.py -k last_unit -q # tests whose name contains "last_unit"
docker rm -f league-test-db                          # when done
```
**Against the running stack:** `$env:API_URL="http://localhost:8080"; python -m pytest -q`
(white-box tests marked `in_process` are skipped automatically).

**App:** `cd mobile; flutter test` and `flutter analyze`.

---

## 6. QA tools the organisers asked for (all verified working on this laptop)

Installed: Java 25 · Selenium Server **4.51.0** (`C:\tools\selenium`) · Appium **2.19.0** + UiAutomator2 driver 4.2.9 ·
k6 **v2.3.0** (`C:\tools\k6`, on PATH) · Android emulator `Medium_Phone_API_36.0`. Scripts live in `qa/`.

| Tool | Start | Test | What it proves |
|---|---|---|---|
| **Selenium Grid 4** | `java -jar C:\tools\selenium\selenium-server-4.51.0.jar standalone --port 4444` (Grid UI: http://localhost:4444/ui) | `python qa/selenium/grid_smoke.py` | Chrome driven through the Grid opens `/health` and Swagger `/docs`, finds the audit routes, saves a screenshot |
| **Appium 2** | emulator: `emulator -avd Medium_Phone_API_36.0` (or plug in a phone) · server: `appium --port 4723` | `python qa/appium/app_smoke.py` | installs `mobile/release/app-release.apk`, signs in as Viewer, sees the 5 tabs, saves `qa/appium/screenshots/home.png` |
| **k6** | nothing to start | `k6 run qa/k6/load_read.js` | 20 users / 40 s on read routes; thresholds p95 < 500 ms, errors < 1 % (measured: p95 107 ms, 0 %) |
| | | `k6 run qa/k6/rate_limit.js` | 130 fast calls → exactly 100 allowed, rest `429 RATE_LIMITED` |
| | | `k6 run qa/k6/checkout_race.js` | **NFR-3**: 20 buyers, 1 unit → exactly 1 paid, 19 `OUT_OF_STOCK`, stock 0. *Resets demo data first.* |

Point any test at another machine: `-e API_URL=http://<ip>:8080` (k6) or `$env:API_URL=...` (Python).
Appium tip: right after an emulator boots, wait ~1 minute (it is busy) or the first session can time out.

---

## 7. Everyday changes — where and how

| Change | File · what to edit | Then |
|---|---|---|
| Points for win/draw/loss default | `scoring.py` → `DEFAULT_POINTS` | rebuild + `pytest tests/test_standings.py` |
| Rate limit (100 per 10 s) | `rbac.py` → `RATE_LIMIT`, `RATE_WINDOW_SECONDS` | `k6 run qa/k6/rate_limit.js` |
| Max quantity per order line | `store.py` → `MAX_QUANTITY` | `pytest tests/test_store.py` |
| Add a discount code | `store.py` → `DISCOUNT_CODES = {"WELCOME10": 10}` (add `"FAN20": 20`) | reset, then checkout with it |
| Who may do what | `rbac.py` → `POLICIES` (role, action, scope) | `pytest tests/test_rbac.py` |
| Error wording in the app | `mobile/lib/core/errors.dart` → `friendlyByCode` | `flutter test` |
| App colours | `ocean_widgets.dart` → `ocean`, `ink`, `muted`; tenant colour comes from login | hot reload |
| Default server address in the app | `core/app_state.dart` → `defaultBaseUrl` (or `--dart-define=API_BASE_URL=...`) | rebuild APK |
| Live score refresh speed | `league_screens.dart` → `Timer.periodic(const Duration(seconds: 5)` | hot reload |
| Toast duration | `ios_ui.dart` → `Duration(milliseconds: ... 2800 : 5000)` | hot reload |
| A new DB column | the module's `SCHEMA`: `ALTER TABLE x ADD COLUMN IF NOT EXISTS y TEXT;` | rebuild (runs on startup) |

**Build and ship the APK:** `cd mobile; flutter build apk --release; copy build\app\outputs\flutter-apk\app-release.apk release\app-release.apk`.
**Run on a phone live:** USB debugging on → `cd mobile; flutter run` (press `r` = hot reload, `R` = restart).

---

## 8. Viva practice — likely live changes (do each one once tonight)

For each drill: find the place (section 3), make the change, run the named test, then **undo** with
`git checkout -- <file>` (we are not committing). Time yourselves: aim for under 5 minutes each.

1. **"Make a win worth 2 points by default."** `scoring.py` `DEFAULT_POINTS = {"win": 2, ...}`.
   Check: reset → `GET /audit/v1/standings/league-alpha-1` → points changed. Expect `test_standings.py` failures —
   explain *why* (tests encode the spec's 3 points).
2. **"Lower the rate limit to 50 requests."** `rbac.py RATE_LIMIT = 50` → `k6 run qa/k6/rate_limit.js` (threshold
   `count<=100` still passes; edit it to 50 to prove it).
3. **"Add a discount code FAN20 for 20 %."** `store.py DISCOUNT_CODES`. Reset, checkout with `"discount_code":"FAN20"`,
   receipt total drops 20 %.
4. **"Reject orders with more than 5 of one item."** `MAX_QUANTITY = 5`; send quantity 6 → 400 `VALIDATION_ERROR`.
5. **"Add a field to the fixtures list (e.g. `sport_id`)."** `scoring.py league_fixtures` → add `"sport_id": m["sport_id"]`
   to the dict. `test_mobile_api.py::test_fixtures_and_standings_for_tenant_user` checks the exact key set → update it.
6. **"New endpoint: list a league's teams."** In `scoring.py`:
   ```python
   @router.get("/api/v1/leagues/{league_id}/teams")
   def league_teams(league_id: str, user: dict = Depends(auth.current_user)):
       with pool.connection() as conn:
           return league_for_user(conn, league_id, user)["teams"]
   ```
   Rebuild, open `/docs`, try it. Add a 3-line test in `tests/test_mobile_api.py`.
7. **"Let players also read the store orders list."** Look at `store.py list_orders` role check; or add a policy
   row in `rbac.py POLICIES`. Run `test_rbac.py` and explain the negative tests.
8. **"Add a tie-break: most wins."** `sports.py TIE_BREAKS` add `"wins"`; `standings.py _criterion_value` add
   `if name == "wins": return ctx["stats"][team]["won"]`. Register a league with `tie_break_order: ["wins"]`.
9. **"Add a new sport without code."** `POST /audit/v1/sports` with JSON (spec 5.6 example) → use it in a match.
   This is the "mystery sport" — show it needs **zero** code changes.
10. **"Correct a wrong goal."** `POST /audit/v1/events` type `compensation` with `compensates: <event_id>`;
    show the row stays in `scoring_events` (psql) and the score drops.
11. **"Prove no overselling."** `k6 run qa/k6/checkout_race.js`; then in psql
    `SELECT stock, reserved FROM store_variants WHERE variant_id='var-jersey-001-M';`.
12. **"Add a column to products (e.g. `brand`)."** `store.py SCHEMA` → `ALTER TABLE store_products ADD COLUMN IF NOT
    EXISTS brand TEXT;`, include it in `create_product` insert + `list_products` select. Rebuild, `\d store_products`.
13. **App: "Show the venue on the match page."** `league_screens.dart` match details → add
    `DetailRow('Venue', asStr(data['venue_id'], '—'))` (local copy sends `venue_id`). Hot reload.
14. **App: "Change the primary button colour / text size."** `ocean_widgets.dart oceanTheme()` (`filledButtonTheme`,
    `textTheme`). Hot reload; run `flutter test` to show nothing broke.
15. **App: "Show a confirmation before logout"** — already there: `profile_screens.dart` `_logout` shows a
    `CupertinoAlertDialog` (and warns if offline actions are still pending). Change its text, hot reload.
16. **"Make transfers outside the window allowed for admins."** `roster.py apply_transfer` rule 5 — explain rule
    order (spec order is graded), add a bypass only for the prod route with `user["role"] == "super_admin"`.

**How to stay calm when asked for a change you don't know:**
1. Find the route in `/docs` → the path tells you the module (`/api/v1/store/...` → `store.py`).
2. `Ctrl+Shift+F` the path or the error code in VS Code.
3. Make the smallest change, rebuild, test in `/docs`, run that module's test file.

---

## 9. Complexity cheat-sheet (they ask "what is the complexity of …")

| Feature | Algorithm | Complexity | Why this choice |
|---|---|---|---|
| Round robin | circle method (fix one slot, rotate the rest) | O(n²) matches, O(n) per round | perfect home/away balance, byes for odd n |
| Swiss pairing | maximum-weight matching (Edmonds' blossom) | O(n³) per round | finds the optimal pairing with no repeats; greedy can fail |
| Single elimination | seeded bracket (`seed_order`), byes to top seeds | O(n) | 1 v n, 2 v n-1 … standard seeding |
| Double elimination | winners + losers bracket, grand final + optional reset | O(n) | routing graph built once |
| Standings | recompute from all completed matches on each read | O(M + T log T) | always consistent after corrections (event sourcing) |
| 3-way head-to-head | mini-league of the tied group, recursive on remaining ties | O(k·M) | spec tie-break order |
| Checkout | conditional UPDATE in Postgres | O(1) per item, no lost updates | the database row lock is the referee |
| Rate limit | per-IP sliding window (deque of timestamps) | O(1) amortised | simple, exact 100-in-10 s |

---

## 10. Architecture decisions in one line each (details in `ADR.md`)

1. **Plain SQL with psycopg**, no ORM — every query is visible; fewer surprises under concurrency.
2. **One Postgres** for data, event log and queue — one thing to run and back up.
3. **Event sourcing** for scores — corrections never delete; score = replay of the log; signed events.
4. **Sports as JSON data** — the mystery sport needs no code.
5. **Checkout = conditional reservation** — zero overselling under 20 concurrent buyers.
6. **RBAC as a database policy matrix** + signed JWT — rules are data, testable per role.
7. **Swiss via blossom matching** — provably optimal pairing.
8. **Offline sync reuses the online functions** — no second rule set to drift.
9–13 (local copy only): status changes as events; competitions built from leagues; sport-rule snapshots so edits
never rewrite results; server UUIDs (client UUID v4 only for idempotency keys); one offline queue per account.

---

## 11. Security & integrity — what to say

* **Signatures:** every score event and receipt has `HMAC-SHA256(DAY1_SALT, id|canonical JSON)`; the salt is only
  in the environment (`.env` is git-ignored, `.env.example` has it empty). Verified against the spec's test vector.
* **Passwords:** PBKDF2-SHA256, 120,000 iterations, per-user salt. **Tokens:** HS256 JWT; `alg:none`, tampered or
  expired → 401. **App:** token in Android Keystore (`flutter_secure_storage`).
* **Input:** every body validated → 400 with the list of bad fields; > 1 MB → 413; rate limit → 429.
* **Tenant isolation:** every read checks the user's tenant (`league_for_user`, club/product tenant checks).

---

## 12. Tonight's changes in the local copy (not in the graded commit)

| Area | What changed |
|---|---|
| FR-1.2 | divisions (promotion/relegation) + hybrid groups → seeded knockout (`competitions.py`) |
| FR-1.3 | postponed / abandoned / cancelled; reschedule with venue, team, player, rest and opening-hours conflicts |
| FR-2.2 | add player (API + app) |
| FR-2.3 | scheduled price changes; pin product → live push over SSE; delete (archive) merchandise |
| Admin | edit sport rules (add/remove rules), delete custom sports, delete empty clubs |
| Ids | server UUIDs for products/players/sports; client UUID v4 for idempotency keys |
| Offline | **one queue per account** (a viewer never sees or syncs a manager's actions) |
| App UI | iOS toasts, picker sheets instead of dropdowns, grouped forms, Cupertino alerts, segmented tabs, status chip in every header, tenant colour + logo, animations (entrance, tab cross-fade, iOS page slide, score pop), Reduce-Motion aware |
| QA | `qa/` scripts for Selenium Grid, Appium, k6 |

To use them on Day 2 (only if Part II allows), copy the changed files into `Desktop\nascon26` **after 10:15**,
run all tests, rebuild the APK, then commit and push.
