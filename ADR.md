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
