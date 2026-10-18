# Architecture Decision Records

Each record: context → decision → alternatives → why → trade-offs / limits. All describe code that exists.

## ADR-1 FastAPI with plain SQL (psycopg 3), no ORM
- **Context:** ~20 endpoints whose JSON is compared literally; hard concurrency rules; 4 h to build.
- **Decision:** FastAPI routes that parse the body themselves (`util.read_json`) and run hand-written SQL through one
  `psycopg_pool` pool (`db.py`).
- **Alternatives:** SQLAlchemy ORM; Django REST; Node/Express.
- **Why:** SQL makes locking and atomic updates explicit (`UPDATE … WHERE stock >= q`, advisory locks); manual
  validation lets us return the spec's 400 envelope with exact `details.fields` instead of FastAPI's 422.
- **Trade-offs:** more SQL to maintain, no migrations framework (idempotent `CREATE TABLE IF NOT EXISTS` per module).

## ADR-2 One PostgreSQL 16 instance for everything (data, event log, job queue)
- **Context:** spec allows Redis/RabbitMQ/NATS/MinIO; grader box has 8 GB RAM and 10 min to build.
- **Decision:** a single Postgres holds relational data, the append-only event log and the domain-event outbox
  (`store_domain_events`). No Redis/queue broker/object store.
- **Alternatives:** Redis Streams or RabbitMQ for domain events; MinIO for PDFs.
- **Why:** fewer moving parts → faster, more reproducible startup; queue writes commit atomically with the order
  (transactional outbox, no lost events).
- **Trade-offs:** no separate worker consumes the outbox yet; scaling reads needs replicas.

## ADR-3 Event sourcing for match scores, projection rebuilt on every read
- **Decision:** `scoring_events` is append-only; `project_state()` folds the log into scores, status, fair play and
  tie-break winner; corrections are `compensation` events that neutralise their target. Standings call the same
  projection, so they are always recomputed from scratch.
- **Alternatives:** mutable score columns updated per event; snapshot tables.
- **Why:** required by the spec; gives an audit trail, makes compensation after qualification (edge case 5) correct
  by construction.
- **Trade-offs:** reads are O(events); acceptable at competition scale, would need snapshots for very long matches.

## ADR-4 Sports and scoring rules as JSON data
- **Decision:** a sport is a JSON document (`sports.config`); the engine only knows the three scoring *models*
  (event / innings / round) and reads points, runs, legal balls, wickets and best-of from config.
- **Why:** mystery sports must work without code changes; a code branch on a sport name costs −8 points.
- **Trade-offs:** model-specific rules (innings limits, series decided) are generic, so exotic sports needing a
  fourth model would require code.

## ADR-5 Concurrency-safe checkout: conditional reservation + two short transactions
- **Decision:** transaction 1 reserves all items with `UPDATE store_variants SET stock = stock - q, reserved =
  reserved + q WHERE variant_id = … AND stock >= q` (rows locked in sorted order); the mock gateway runs outside
  any transaction; transaction 2 commits (`reserved -= q`) or releases (`stock += q`).
- **Alternatives:** `SERIALIZABLE` isolation with retries; Redis locks; one long transaction around the gateway.
- **Why:** the database guarantees no overselling (20 buyers → exactly 1 success); no lock is held during the
  payment call; `reserved` is real and returns to 0.
- **Trade-offs:** a crash between the two transactions leaves units reserved until reset (no reaper job).

## ADR-6 RBAC as a database policy matrix with signed JWT claims
- **Decision:** `rbac_policies(role, action, scope)` with scopes any / tenant / own_league / own_club / self;
  HS256 JWTs carry role, tenant and owned ids; `rbac.can()` evaluates every decision against the table.
  Foreign-tenant resources return 403, unknown ids 404 only for roles allowed to see everything.
- **Alternatives:** if-statements per route; Keycloak/Ory.
- **Why:** one place to audit; negative tests cover the full 5-role matrix; `alg:none`, tampered and expired
  tokens are rejected by pinning `algorithms=["HS256"]`.
- **Trade-offs:** policy changes need a reset or migration; token revocation is not implemented (short expiry).

## ADR-7 Swiss pairing via maximum-weight matching (Edmonds' blossom)
- **Decision:** after choosing the bye, pairings minimise the total score gap over all rematch-free pairings by
  running blossom maximum-weight matching with weight `W − |score difference|`, forcing a maximum-cardinality matching.
- **Alternatives:** greedy top-down pairing (fails the optimality rule); backtracking search (27 s for 64 teams).
- **Why:** exact optimum in polynomial time (~0.13 s for 64 teams after 63 rounds); a non-perfect matching proves
  that no valid pairing exists → `409 NO_VALID_PAIRING`.
- **Trade-offs:** the algorithm is intricate; it is covered by brute-force comparison tests.

## ADR-8 Offline sync through the same domain functions, one transaction per action
- **Decision:** `sync.process()` sorts actions by `queued_at`, runs each through `scoring.append_event` or
  `roster.apply_transfer` in its own transaction, and records every processed `(device_id, action_id)` so a re-sent
  batch is all `duplicate`. `base_version` > server → `INVALID_BASE_VERSION`; < server → `rebased_append`.
- **Why:** offline and online paths cannot drift apart; each action sees the state left by the previous one.
- **Trade-offs:** server-wins conflict policy only (no field-level merge); large batches are sequential.

## ADR-9 Match status changes are events in the score log
- **Decision:** postponed / abandoned / cancelled (and back to upcoming after a reschedule) are `status_change`
  events appended to `scoring_events`; `scoring.STATUS_TRANSITIONS` rejects illegal moves with 409. Only
  `schedule.reschedule` may append `status: upcoming`, after its conflict check passed.
- **Alternatives:** a mutable `status` column on `scoring_matches`.
- **Why:** one source of truth with the score; the change is replayable and audited, and the SSE stream already
  pushes every change of the match view, so the broadcast came for free.
- **Trade-offs:** reading a status means replaying the match's events (cheap at league size).

## ADR-10 Competitions are compositions of ordinary leagues, derived on read
- **Decision:** a division or group is a normal league (circle-method round robin). Promotion / relegation and the
  hybrid knockout seeding are computed from live standings on every `GET`, marked `provisional` until all
  stage matches are final.
- **Why:** scoring, standings, rescheduling and SSE work on divisions unchanged, and a postponed or corrected
  group match re-evaluates the downstream bracket automatically.
- **Trade-offs:** knockout match results are not stored yet; slot and rest rules (3 h, 24 h) are constants.

## ADR-11 Sport rules are snapshotted per league and match
- **Decision:** `scoring_leagues.sport_config` and `scoring_matches.sport_config` store the sport's rules when the league
  or match is created; projections and standings read that copy (`scoring.match_sport`). `PUT /api/v1/sports/{id}`
  edits the live sport, which only new leagues and matches pick up.
- **Why:** scores are rebuilt from events on every read (ADR-3), so without a snapshot changing "goal = 1" to
  "goal = 2" would silently rewrite every finished result and standings table.
- **Trade-offs:** an organizer who wants a running league on new rules creates a new season / league.

## ADR-12 Ids: server-assigned UUIDs, client UUID v4 only for idempotency keys
- **Decision:** products, players and sports get `uuid4` ids from the server; the app never invents them. The phone
  still creates `event_id`, `request_id`, `order_id` and offline `action_id` (spec 5.9 / 5.11 / 5.12 / 5.14), now as
  RFC 4122 v4 UUIDs from `Random.secure()` instead of timestamps.
- **Why:** an idempotency key must exist before the request reaches the server (offline queue, retries), so it cannot
  be server-assigned; a cryptographically random UUID cannot collide or be guessed.

## ADR-13 One offline queue per account on a shared phone
- **Decision:** every queued action and sync result stores the `user_id` that created it; the app shows and syncs only
  the signed-in account's actions, with that account's token. Others wait untouched until their owner signs in.
- **Why:** before, a viewer signing in after a manager saw the manager's queue and synced it with the viewer's token,
  so the server rightly rejected (and the app dropped) the manager's work.

# Part II (Day 2) decisions

ADR-2 still holds for Part I data. Part II adds Redis (shared counters, ADR-16), MediaMTX (ADR-20) and MinIO (ADR-21),
because the spec requires media, multi-worker scale and object storage. Postgres stays the system of record.

## ADR-14 Guest read-only boundary enforced in one ASGI middleware
- **Context:** FR-4.3: any write with a `guest_anon_tok_*` token must get `403 GUEST_WRITE_FORBIDDEN`. Hiding UI earns no credit.
- **Decision:** the pure-ASGI `Guards` middleware (`main.py`) rejects every POST/PUT/PATCH/DELETE carrying a guest token,
  on every route, before any handler runs. It also applies the per-IP rate limit (`/audit/v1/*` exempt).
  Routes that need a member (follow, host controls) also refuse anonymous callers.
- **Alternatives:** a check inside each write handler; a FastAPI dependency per router.
- **Why:** one place that new routes cannot forget. The guest web page only reacts to the 403 (it opens the login modal).
- **Trade-offs:** the middleware must stay cheap (it runs on every request), so it does no DB work.

## ADR-15 Separate Day 2 signing function and salt
- **Decision:** `signing.sign_day2(entity_id, payload)` = HMAC-SHA256(`DAY2_SALT`, `entity_id|canonical JSON`). It is used by
  every Part II module. Day 1 keeps `sign` with `DAY1_SALT`. Both salts come only from the environment (`.env`, CI secrets).
- **Why:** mixing salts silently breaks every vector; two functions make the choice explicit in code review.
- **Trade-offs:** none beyond keeping both salts in `.env`.

## ADR-16 Real time through Postgres rows polled by SSE / WebSocket; Redis for shared counters
- **Context:** NFR-1 (score push p95 < 500 ms) with 8 uvicorn workers; a client may be connected to any worker.
- **Decision:** events (scores, notifications) are committed to Postgres first. Each SSE / WebSocket connection polls
  `id > last_seen` about every 0.2 s. The rate-limit counters and the active-WebSocket count live in Redis (`redis_kv.py`).
- **Alternatives:** in-process pub/sub (breaks across workers); Redis pub/sub or a broker for every event.
- **Why:** correct across processes and restarts, with no lost events, and simple to test. Latency stays far under 500 ms.
- **Trade-offs:** small constant DB load per open connection.

## ADR-17 Per-entity advisory locks and stored responses for idempotent probes
- **Decision:** writes that must be exact under bursts take `pg_advisory_xact_lock(hashtext(<entity>))`: follow per
  athlete, co-stream per session, cart merge per guest token, chat per room. Probes store their canonical request and
  response. An identical replay returns the stored answer (200); a different body is a 409 (or re-evaluation for co-streams).
- **Why:** follower count == row count and single cart merges are guaranteed by the database, not by timing. Replays
  cover the "4G → Wi-Fi mid-request" edge case.
- **Trade-offs:** contention is serialised per entity (fine at this scale).

## ADR-18 Notification bus with bounded retry and a Postgres dead-letter queue
- **Decision:** `notify.publish()` stores the event, then delivers it via `moderation_dlq.deliver()`: 3 attempts with
  0.1 / 0.2 / 0.4 s backoff, then a `notification_dlq` row. Dead letters are never shown to subscribers.
  `/metrics` exports `nascon_dlq_depth`. Order status changes publish `order:{id}`; host controls publish `costream:{id}`.
- **Alternatives:** RabbitMQ / Redis Streams with a DLX.
- **Why:** inspectable through the audit contract and durable, with no extra broker to run.
- **Trade-offs:** delivery retries run inline (bounded to under 1 s).

## ADR-19 Dynamic QR: stable short link, destination decided at scan time
- **Decision:** a QR encodes `/q/{short_code}`. `qr_guest.py` picks preview / live / vod / notice from the live match
  status and answers 302. Exports (SVG / PNG / PDF) are generated on request. Scan telemetry stores a count, the
  device family and a UTC time bucket only.
- **Why:** printed codes keep working as the match state changes (FR-4.1). Storing no IP / UA / cookie satisfies NFR-9.

## ADR-20 MediaMTX as the media server; the API decides who may publish
- **Decision:** MediaMTX serves RTMP 1935, HLS 8888 and WebRTC 8889. It calls `POST /internal/media/auth` before accepting
  a publish, so only an active stream key can go live. Revoking a key also kicks the live publisher through MediaMTX's control API.
  Guest HLS reads need no credentials.
- **Alternatives:** nginx-rtmp; LiveKit SFU.
- **Why:** a single container covers all three protocols, recording and an auth hook.

## ADR-21 Recording: MediaMTX writes segments, the API uploads and indexes them
- **Context:** FR-3.2 asks for recordings in object storage and a VOD archive. The MediaMTX image has no shell for `runOn*` hooks.
- **Decision:** `pathDefaults.record` writes 10 s fMP4 segments to a shared `recordings` volume. `recording.py` indexes
  finished segments (untouched for 3 s): it uploads each to MinIO with a stdlib SigV4 PUT and inserts a `vod_recordings` row.
  This runs after a stream key is revoked and on `POST /internal/media/recordings/sync`. With no `MINIO_URL`, rows are
  indexed without upload. MinIO runs on Laptop 2 (`172.15.33.178:9000`, bucket `vod`).
- **Alternatives:** boto3 / minio SDK (extra package); a sidecar container with `mc mirror`.
- **Why:** no new dependency, testable without media, and safe on a CI runner with no MinIO.
- **Trade-offs / limits:** upload + index are tested against the real MinIO; the full RTMP → record → upload chain was not run
  end to end (no ffmpeg on Laptop 2).

## ADR-22 Guest Web Player in plain HTML / JS, served by the API
- **Decision:** `api/app/web/*.html` plus one `web.js` / `web.css` with no framework and no build step, served from
  `/web/static/`. It carries the 9 spec `data-testid`s and meets WCAG AA (contrast ≥ 4.5:1, keyboard, ARIA, 48 px targets).
  It probes the stream with `fetch(credentials:'omit')` before attaching it.
- **Why:** zero install, fastest load for QR scans, nothing to compile on the grader. The probe was added after a media
  server 401 made Chrome open a credential dialog that swallowed every click (FR-4.2 forbids credential dialogs).

## ADR-23 Native deep links without a plugin; each link is used once
- **Decision:** an Android `nascon` VIEW / BROWSABLE intent-filter plus a MethodChannel `nascon/deeplink` in
  `MainActivity.kt`. Dart parses the link (`deep_links.dart`) and opens the read-only Match Live / Co-Stream screens on top of
  any screen, sign-in included. `takeLink` clears the intent's data after reading it and ignores launches from Recents.
- **Alternatives:** `app_links` / `uni_links` packages.
- **Why:** no new dependency (the team rule: ask before adding one). Consuming the link stops Android from reopening an
  old deep link when the app is relaunched from Recents.

## ADR-24 Throughput: 8 workers with uvicorn[standard]
- **Context:** k6 (spec 6.4, 550 VUs) first measured p95 6.1 s, with all of it queueing in the server.
- **Decision:** 8 uvicorn workers, `uvicorn[standard]` (uvloop + httptools), one ASGI guard middleware instead of several,
  Redis-shared counters. The package was approved by the team.
- **Result:** p95 344 ms, 0 failed of 27,643 requests (k6 inside the compose network on Laptop 2).

## ADR-25 Player self sign-up creates the login and the player profile together
- **Decision:** `POST /api/v1/auth/register` (`rbac.py`) inserts `rbac_players`, `roster_players` and a `player`-role
  `rbac_users` row in one transaction (default club Alpha United) and returns the same body as login. The app's sign-in
  screen links to a sign-up form. The release APK's default server is Laptop 1's LAN address (changeable in the app).
- **Why:** FR-4.4's progressive registration needs a way to become a member. Demos need several real players for chat
  and co-streams.
- **Trade-offs:** no email verification (demo scope); emails are unique (409 `EMAIL_TAKEN`).

## ADR-26 QA harness choices: Grid URL probe, device-measured launch time
- **Decision:** the Selenium suite finds the API URL its containerised browsers can reach (`WEB_BASE`, `localhost`,
  `api`, `host.docker.internal`) and always writes JUnit XML. The Appium suite measures foreground time with Android's own
  `am start -W` `WaitTime`, not the test's clock.
- **Why:** the grader runs `pytest -n 3 tests/selenium/` with no settings. Host-side timing added adb start-up and

  Appium round trips (≈1 s) that are not app launch time.
