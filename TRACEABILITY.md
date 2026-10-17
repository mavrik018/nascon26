# Traceability — Part I requirements → code → tests

Backend modules live in `api/app/modules/`; tests in `tests/` (run all with `./run_tests.sh`,
which also prints the per-area coverage used for `COVERAGE.json`). Mobile code lives in `mobile/`.
Status: **Done** = implemented and covered by passing automated tests; **Partial** = what is and is
not implemented is stated; **Not done** = not implemented.

| ID | Requirement | Endpoint / feature | Source | Automated tests | Status |
|---|---|---|---|---|---|
| FR-1.1 | Multi-sport taxonomy as data; mystery sport via JSON | `POST /audit/v1/sports`; 4 baseline sports seeded on reset | `sports.py` (`validate_sport`, `BASELINE_SPORTS`) | `test_scoring.py::test_create_mystery_sport`, `test_invalid_sport_is_400_with_field`, `test_mystery_sport_end_to_end`, `test_sport_models_validate_their_own_periods` | Done |
| FR-1.1 | Event-sourced scoring, 3 scoring models, compensating events, signatures | `POST /audit/v1/events`, `GET /audit/v1/score/{id}` | `scoring.py` (`append_event`, `project_state`, `build_projection`), `signing.py` | `test_scoring.py` (state machine, compensation, innings/round limits, idempotency, Appendix A vector) | Done |
| FR-1.2 | League setup (single stage, scoped to registration) | `POST /audit/v1/leagues` | `scoring.py` (`register_league`) | `test_scoring.py::test_register_league`, `test_league_validation` | Partial — single-stage leagues for standings; multi-division promotion/relegation and hybrid formats not implemented |
| FR-1.3 | Fixture generation: round-robin, Swiss, single & double elimination | `POST /audit/v1/fixtures` | `fixtures.py` | `test_fixtures.py` | See fixtures row status below |
| FR-1.3 | Match status state machine | event types `match_init/start/end` | `scoring.py` (`append_event`) | `test_scoring.py::test_state_machine` | Partial — upcoming/in_progress/completed; postponed/abandoned/cancelled and manual rescheduling conflict detection not implemented |
| FR-1.3 | Real-time status broadcast | `GET /api/v1/matches/{id}/stream` (SSE) | `scoring.py` (`match_stream`) | — (manual) | Partial |
| FR-1.4 | Standings, ordered tie-breaks, 3-way H2H, lots, qualification | `GET /audit/v1/standings/{id}` | `standings.py` (`compute`, `resolve`) | `test_standings.py` (Appendix A lots vector, 3-way mini-league, NRR, compensation recompute) | Done |
| FR-2.1 | Club profiles, tenant isolation | `GET /api/v1/clubs/{id}` | `roster.py` | `test_roster.py` | See roster |
| FR-2.2 | Roster: transfer / loan / release, rule order, audit trail, loan return | `POST /audit/v1/roster/setup`, `/transfer`, `GET /audit/v1/roster/history/{id}` | `roster.py` | `test_roster.py` | See roster |
| FR-2.3 | Store: variants, discount, concurrency-safe checkout, mock gateway, PDF receipt, domain events | `POST /audit/v1/checkout`, `GET /audit/v1/inventory/{id}`, `/api/v1/store/*` | `store.py` | `test_store.py` (20-thread burst, 402 paths, replay, PDF text) | Done (order states beyond `paid`/`cancelled` not exposed) |
| FR-5.1 | Five-tier RBAC, DB policy matrix, tenant isolation | `POST /audit/v1/rbac-matrix`, probes P1–P7 | `rbac.py` (`rbac_policies`, `can`), `auth.py` | `test_rbac.py` (full 5×17 matrix, tampered / alg:none / expired tokens) | Done |
| NFR-3 | No overselling under 20 concurrent buyers | `POST /audit/v1/checkout` | `store.py` (conditional UPDATE reservation) | `test_store.py` burst tests | Done |
| NFR-4 | Offline tolerance: replay queue with conflict handling | `POST /audit/v1/offline-sync`, `POST /api/v1/sync`; mobile SQLite cache + queue | `sync.py`; `mobile/` | `test_sync.py`; mobile tests | Done (backend); mobile see `mobile/` |
| NFR-5 | Security: rate limiting, validation, RBAC, secure token storage | `GET /api/v1/ping`, global 1 MB limit, 400 envelope | `main.py` middleware, `rbac.py`, `errors.py` | `test_rbac.py` (rate limit), `test_core.py` (413, 400) | Done |
| NFR-7 | One-command reproducible stack | `docker compose up -d --build` | `docker-compose.yml`, `api/Dockerfile`, `core.py` (`bootstrap`) | CI workflow (clean ubuntu, compose, HTTP test run), `test_core.py::test_reset_*` | Done |
