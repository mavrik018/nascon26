-- =============================================================================
-- Multi-Sport League & Club Operations Platform — NaSCon '26
-- Database Schema (PostgreSQL 16)
-- Extracted from api/app/modules/{core,sports,scoring,roster,store,rbac,sync}.py
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Core / Application State (api/app/modules/core.py)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app_state (
    key   TEXT PRIMARY KEY,
    value JSONB NOT NULL
);

-- -----------------------------------------------------------------------------
-- 2. Sports Taxonomy & Configuration (api/app/modules/sports.py)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sports (
    sport_id   TEXT PRIMARY KEY,
    config     JSONB NOT NULL,
    baseline   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 3. Leagues, Matches & Event-Sourced Scoring (api/app/modules/scoring.py)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS scoring_leagues (
    league_id       TEXT PRIMARY KEY,
    sport_id        TEXT NOT NULL,
    tenant_id       TEXT,
    name            TEXT,
    teams           JSONB NOT NULL,
    points          JSONB NOT NULL,
    tie_break_order JSONB NOT NULL,
    spots           INTEGER NOT NULL,
    lots_seed       BIGINT NOT NULL,
    created_seq     BIGSERIAL
);

CREATE TABLE IF NOT EXISTS scoring_matches (
    match_id          TEXT PRIMARY KEY,
    league_id         TEXT,
    sport_id          TEXT NOT NULL,
    home              TEXT NOT NULL,
    away              TEXT NOT NULL,
    scheduled_at      TEXT,
    pinned_product_id TEXT,
    created_seq       BIGSERIAL
);

CREATE TABLE IF NOT EXISTS scoring_events (
    id          BIGSERIAL PRIMARY KEY,
    event_id    TEXT NOT NULL UNIQUE,
    match_id    TEXT NOT NULL,
    sequence    INTEGER NOT NULL,
    type        TEXT NOT NULL,
    payload     JSONB NOT NULL,
    request     TEXT NOT NULL,       -- canonical request, for idempotency comparison
    signature   TEXT NOT NULL,
    compensates TEXT,
    response    JSONB NOT NULL,
    UNIQUE (match_id, sequence)
);

CREATE INDEX IF NOT EXISTS scoring_matches_league_idx ON scoring_matches (league_id);

-- -----------------------------------------------------------------------------
-- 4. Club Profiles, Squads, Roster Transfers & Audit Trail (api/app/modules/roster.py)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS roster_leagues (
    league_id          TEXT PRIMARY KEY,
    tenant_id          TEXT NOT NULL,
    sport_id           TEXT NOT NULL,
    window_open        DATE NOT NULL,
    window_close       DATE NOT NULL,
    max_squad_size     INTEGER NOT NULL,
    required_positions JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS roster_squads (
    league_id TEXT NOT NULL,
    squad_id  TEXT NOT NULL,
    club_id   TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    name      TEXT NOT NULL,
    ord       INTEGER NOT NULL,
    PRIMARY KEY (league_id, squad_id)
);

CREATE TABLE IF NOT EXISTS roster_players (
    player_id TEXT PRIMARY KEY,
    league_id TEXT NOT NULL,
    name      TEXT NOT NULL,
    position  TEXT NOT NULL,
    ord       INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS roster_registrations (
    seq             BIGSERIAL PRIMARY KEY,
    player_id       TEXT NOT NULL,
    league_id       TEXT NOT NULL,
    reg_type        TEXT NOT NULL,
    squad_id        TEXT,
    parent_squad_id TEXT,
    start_date      DATE,
    loan_end_date   DATE,
    role            TEXT,
    return_logged   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS roster_registrations_player ON roster_registrations (player_id, seq);

CREATE TABLE IF NOT EXISTS roster_matches (
    league_id     TEXT NOT NULL,
    match_id      TEXT NOT NULL,
    home_squad_id TEXT NOT NULL,
    away_squad_id TEXT NOT NULL,
    ord           INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS roster_audit (
    seq       BIGINT PRIMARY KEY,
    player_id TEXT NOT NULL,
    league_id TEXT NOT NULL,
    entry     JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS roster_audit_player ON roster_audit (player_id, seq);

CREATE TABLE IF NOT EXISTS roster_requests (
    request_id TEXT PRIMARY KEY,
    league_id  TEXT NOT NULL,
    body       JSONB NOT NULL,
    response   JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS roster_clubs (
    club_id   TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    name      TEXT NOT NULL,
    profile   JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS roster_meta (
    key   TEXT PRIMARY KEY,
    value BIGINT NOT NULL
);

-- -----------------------------------------------------------------------------
-- 5. Merchandise Store, Orders & Transactional Outbox (api/app/modules/store.py)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS store_products (
    product_id  TEXT PRIMARY KEY,
    tenant_id   TEXT NOT NULL,
    name        TEXT NOT NULL,
    category    TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS store_variants (
    variant_id  TEXT PRIMARY KEY,
    product_id  TEXT NOT NULL REFERENCES store_products(product_id) ON DELETE CASCADE,
    position    INTEGER NOT NULL DEFAULT 0,
    label       TEXT NOT NULL,
    size        TEXT,
    color       TEXT,
    price_minor BIGINT NOT NULL CHECK (price_minor >= 0),
    currency    TEXT NOT NULL DEFAULT 'PKR',
    stock       INTEGER NOT NULL CHECK (stock >= 0),
    reserved    INTEGER NOT NULL DEFAULT 0 CHECK (reserved >= 0)
);

CREATE TABLE IF NOT EXISTS store_discount_codes (
    code    TEXT PRIMARY KEY,
    percent INTEGER NOT NULL CHECK (percent BETWEEN 0 AND 100)
);

CREATE TABLE IF NOT EXISTS store_orders (
    order_id    TEXT PRIMARY KEY,
    customer_id TEXT NOT NULL,
    request     JSONB NOT NULL,
    status      TEXT NOT NULL,
    error_code  TEXT,
    response    JSON,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS store_domain_events (
    event_seq    BIGSERIAL PRIMARY KEY,
    event_type   TEXT NOT NULL,
    aggregate_id TEXT NOT NULL,
    payload      JSONB NOT NULL,
    published    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS store_payment_seq;

-- -----------------------------------------------------------------------------
-- 6. Multi-Tenant Identity & Five-Tier RBAC Policy Matrix (api/app/modules/rbac.py)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rbac_tenants (
    tenant_id       TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    logo_url        TEXT NOT NULL,
    primary_color   TEXT NOT NULL,
    secondary_color TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rbac_leagues (
    league_id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES rbac_tenants (tenant_id),
    name      TEXT NOT NULL,
    sport_id  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rbac_clubs (
    club_id   TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES rbac_tenants (tenant_id),
    name      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rbac_players (
    player_id TEXT PRIMARY KEY,
    club_id   TEXT NOT NULL REFERENCES rbac_clubs (club_id),
    name      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rbac_users (
    user_id       TEXT PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL,
    display_name  TEXT NOT NULL,
    tenant_id     TEXT REFERENCES rbac_tenants (tenant_id),
    league_id     TEXT REFERENCES rbac_leagues (league_id),
    club_id       TEXT REFERENCES rbac_clubs (club_id),
    player_id     TEXT REFERENCES rbac_players (player_id)
);

CREATE TABLE IF NOT EXISTS rbac_policies (
    role   TEXT NOT NULL,
    action TEXT NOT NULL,
    scope  TEXT NOT NULL,
    PRIMARY KEY (role, action, scope)
);

-- -----------------------------------------------------------------------------
-- 7. Offline Action Replay & Deduplication (api/app/modules/sync.py)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sync_actions (
    device_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    result    JSONB NOT NULL,
    PRIMARY KEY (device_id, action_id)
);
