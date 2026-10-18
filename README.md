# Multi-Sport League & Club Operations Platform — NaSCon '26 Part I

Self-hosted backend (FastAPI + PostgreSQL 16, Docker Compose) and a Flutter Android app (`mobile/`).

## Run

```bash
DAY1_SALT=<team-salt> docker compose up -d --build
```

- API on `http://localhost:8080`; `GET /health` → `{"status":"ok"}` once the database is reachable and the
  baseline is seeded (first start seeds automatically; `POST /audit/v1/reset` re-seeds).
- `DAY1_SALT` is read only from the environment. Every variable is listed in `.env.example`.
- No other host software is needed; nothing needs internet after the build.

## Tests and coverage

```bash
./run_tests.sh                                     # full suite in-process + per-area coverage
API_URL=http://localhost:8080 python -m pytest      # same tests against the running stack
```

`run_tests.sh` starts a throwaway PostgreSQL 16 container, runs pytest with coverage and prints the six
area figures in the `COVERAGE.json` format (`tools/coverage_report.py`). CI (`.github/workflows/ci.yml`) runs
both modes on a clean Ubuntu runner after `docker compose up --build`.

## Demo accounts (password for all: `Nascon@26`)

| Role | Email | Scope |
|---|---|---|
| Platform Super-Admin | admin@nascon.test | everything |
| League Organizer | organizer@nascon.test | league-alpha-1 |
| Club Manager | manager@nascon.test | club-alpha-1 |
| Player | player@nascon.test | player-alpha-1 |
| General Viewer | viewer@nascon.test | read-only, tenant-alpha |

## Architecture

```
api/app/
  main.py          wiring: 1 MB body limit, /api/v1 rate limit, error envelope, routers
  errors.py        spec error envelope; schema problems -> 400 VALIDATION_ERROR (details.fields)
  signing.py       HMAC-SHA256 signatures + drawing-of-lots key (Appendix A)
  auth.py          HS256 JWT create/verify (alg:none, tampered, expired -> 401)
  db.py            psycopg connection pool (connections health-checked before use)
  modules/         one file per area: router + SCHEMA + reset()
    core.py        /audit/v1/reset, bootstrap, readiness
    sports.py      sports as JSON data (no sport-specific code anywhere)
    fixtures.py    round robin, Swiss (blossom matching), single / double elimination — pure functions
    scoring.py     leagues, append-only event log, compensation, score projection, SSE stream
    standings.py   tables rebuilt from event logs, ordered tie-breaks, H2H mini-leagues, qualification
    roster.py      squads, transfer / loan / release rules, immutable audit trail, club profiles
    store.py       catalogue, atomic stock reservation, mock gateway, signed PDF receipts, domain events
    rbac.py        tenants, users, DB policy matrix, RBAC probes, login, rate limiter
    sync.py        offline action replay with dedup and base-version conflict handling
```

## Mobile integration API (`/api/v1/*`, `Authorization: Bearer <token>`, 100 requests / 10 s per IP)

| Method & path | Body → response |
|---|---|
| `POST /api/v1/auth/login` | `{email, password}` → `{token, user{user_id,email,role,display_name,tenant_id,league_id,club_id,player_id}, tenant{tenant_id,name,logo_url,primary_color,secondary_color}}` |
| `GET /api/v1/me` | same `user` + `tenant` |
| `GET /api/v1/leagues` | `[{league_id,name,tenant_id,sport_id}]` (demo league with matches: `league-alpha-1`) |
| `GET /api/v1/leagues/{id}/fixtures` | `[{match_id,league_id,home,away,status,scheduled_at,home_score,away_score}]` |
| `GET /api/v1/leagues/{id}/standings` | same JSON as `GET /audit/v1/standings/{id}` |
| `GET /api/v1/matches/{id}` | same JSON as `GET /audit/v1/score/{id}` + `event_types`, `scheduled_at`, `venue_id`, `pinned_product` |
| `GET /api/v1/matches/{id}/stream` | Server-Sent Events: `event: match` with the `GET /api/v1/matches/{id}` body whenever it changes |
| `POST /api/v1/matches/{id}/status` | `{status: postponed / abandoned / cancelled, reason}`; organizer of that league / admin; illegal → 409 `ILLEGAL_TRANSITION` |
| `POST /api/v1/matches/{id}/reschedule` | `{scheduled_at: "…Z", venue_id?}` → 200, or 409 `SCHEDULE_CONFLICT` with `details.conflicts[]` (`venue_double_booking`, `team_overlap`, `player_overlap`, `rest_period`, `venue_unavailable`); venue hours are UTC |
| `POST /api/v1/matches/{id}/pin` | `{product_id}` (or `null` to unpin) → match view; stream clients see it within a second |
| `POST /api/v1/competitions` | admin: `{competition_id, name, season, sport_id, format: divisions / hybrid, stages[{league_id,name,teams}], promotion_spots + relegation_spots, or advance_per_group}` |
| `GET /api/v1/competitions/{id}` | stage tables + `movements` (divisions) or `qualifiers` + seeded `knockout` (hybrid); `provisional` until every stage match is final |
| `POST /api/v1/matches/{id}/events` | body of `POST /audit/v1/events` (match_id from the path); organizer of that league / admin |
| `GET /api/v1/clubs/{club_id}` | `{club_id,name,tenant_id,home_venue,social,staff,stats,roster[]}` |
| `POST /api/v1/roster/transfer` | body/response of `POST /audit/v1/roster/transfer`; club manager of the from-squad / admin |
| `POST /api/v1/roster/players` | `{league_id, squad_id, name, position, role?, reason?}` → new player; club manager of that squad / admin |
| `GET /api/v1/roster/players/{id}/history` | same as `GET /audit/v1/roster/history/{id}` |
| `GET /api/v1/store/products` | `[{product_id,tenant_id,name,category,description,variants[{variant_id,label,size,color,price_minor,currency,stock}]}]` |
| `DELETE /api/v1/store/products/{id}` | club manager of the tenant / admin; archives the product (past orders and receipts kept), unpins it from matches |
| `GET /api/v1/sports` · `POST /api/v1/sports` | list; add a sport (admin / organizer) — the server assigns `sport_id` (UUID), names are unique |
| `PUT /api/v1/sports/{id}` | edit rules: scoring events, periods, draws, overtime, tie-breaks, squad and position rules (admin / organizer); existing leagues and matches keep the rules they were created with |
| `DELETE /api/v1/sports/{id}` | admin; 409 `SPORT_IN_USE` for built-in sports or sports used by a league |
| `DELETE /api/v1/clubs/{id}` | admin; 409 `CLUB_IN_USE` while the club has fixtures or players |
| `POST /api/v1/store/variants/{id}/price-changes` | `{price_minor, effective_at: "…Z"}`; club manager of the tenant / admin |
| `POST /api/v1/store/checkout` | body of `POST /audit/v1/checkout` (customer_id defaults to the user) → same response |
| `GET /api/v1/store/orders/{order_id}/receipt.pdf` | `application/pdf` (the buyer or admin) |
| `POST /api/v1/sync` | body/response of `POST /audit/v1/offline-sync` (role-checked per action) |
| `GET /api/v1/ping` | `{"pong":true}` |

Errors always use `{"error":{"code","message","details"}}` (codes in spec Appendix B).

## Mobile

Source in `mobile/`, release build at `mobile/release/app-release.apk` (Android 10+). The backend address is
changeable in the app on the sign-in screen (**Server**) and in Profile; it is saved on the phone, so a new laptop IP needs no rebuild.
Emulator: `http://10.0.2.2:8080`. Phone: `http://<laptop LAN IP>:8080` with laptop and phone on the same network
(run `ipconfig` on the laptop). The app retries brief network failures and shows Online / Offline / Syncing (plus the pending count) in every page header.
Each signed-in account has its own offline queue: actions are stored with the user id, synced only with that account's
token, and never shown to another account on the same phone. Ids the phone must create before the server sees a request
(idempotency keys: event, request, order and action ids) are random UUID v4s; every other id is assigned by the server.
