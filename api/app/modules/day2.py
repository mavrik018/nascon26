"""Part II shared pieces: baseline seed (spec 5.2), guest-token rules and lookups used by every Day 2 module.

Seeded on every reset (after the Day 1 modules):
  * match-m1: football, league-alpha-1, club-alpha-1 (home) v club-alpha-2, in_progress, 1 - 0
  * anonymous guest token guest_anon_tok_7721 (read-only)
  * player-beta-2 already exists in club-beta-1 (roster.py baseline); player-alpha-1's member cart starts empty
"""
from fastapi import APIRouter, Request

from ..errors import ApiError, not_found
from . import scoring

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS guest_tokens (
    guest_token TEXT PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked     BOOLEAN NOT NULL DEFAULT FALSE
);
"""

GUEST_PREFIX = "guest_"
SEED_GUEST_TOKEN = "guest_anon_tok_7721"
SEED_MATCH = "match-m1"


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM guest_tokens")
    conn.execute("INSERT INTO guest_tokens (guest_token) VALUES (%s)", (SEED_GUEST_TOKEN,))
    for i, (type_, payload) in enumerate([
        ("match_init", {"sport_id": "football", "home_team_id": "club-alpha-1", "away_team_id": "club-alpha-2",
                        "league_id": "league-alpha-1"}),
        ("match_start", {}),
        ("score", {"team_id": "club-alpha-1", "event_type": "goal"}),
    ]):
        scoring.append_event(conn, {"event_id": f"m1-seed-{i + 1}", "match_id": SEED_MATCH, "type": type_,
                                    "payload": payload})
    conn.execute("UPDATE scoring_matches SET scheduled_at = %s, pinned_product_id = %s WHERE match_id = %s",
                 ("2026-10-18T10:00:00Z", "prod-jersey-001", SEED_MATCH))


def bearer(request: Request) -> str | None:
    scheme, _, token = request.headers.get("authorization", "").partition(" ")
    return token.strip() if scheme.lower() == "bearer" and token.strip() else None


def is_guest_token(token) -> bool:
    return isinstance(token, str) and token.startswith(GUEST_PREFIX)


def guest_forbidden(token: str | None) -> ApiError:
    return ApiError(403, "GUEST_WRITE_FORBIDDEN", "Anonymous guest tokens cannot perform write mutations.",
                    {"guest_token": token})


def player_exists(conn, player_id) -> bool:
    return isinstance(player_id, str) and conn.execute(
        "SELECT 1 FROM roster_players WHERE player_id = %s", (player_id,)).fetchone() is not None


def require_player(conn, player_id) -> None:
    if not player_exists(conn, player_id):
        raise not_found("PLAYER_NOT_FOUND", player_id=player_id)
