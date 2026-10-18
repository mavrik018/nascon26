"""Part II FR-3.1: public athlete profile and a concurrency-safe follow graph.

Profile: career record from the Phase I event logs of the player's current squad, club affiliations,
upcoming fixtures and the VOD archive (vod_recordings belongs to the streaming work; [] while absent).

Follow: every change takes a per-athlete transaction advisory lock, then INSERT ... ON CONFLICT DO NOTHING
or DELETE ... RETURNING, and moves athlete_stats.followers_count only when a row really changed, so the
counter always equals the follows row count under any burst of simultaneous toggles.
"""
from fastapi import APIRouter, Request

from .. import auth
from ..db import pool
from ..errors import ApiError
from . import day2, roster, scoring

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS follows (
    follower_id TEXT NOT NULL,
    athlete_id  TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_id, athlete_id)
);
CREATE INDEX IF NOT EXISTS follows_athlete ON follows (athlete_id);
CREATE TABLE IF NOT EXISTS athlete_stats (
    athlete_id      TEXT PRIMARY KEY,
    followers_count INTEGER NOT NULL DEFAULT 0 CHECK (followers_count >= 0)
);
"""


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM follows")
    conn.execute("DELETE FROM athlete_stats")


def _followers(conn, athlete_id: str) -> int:
    row = conn.execute("SELECT followers_count FROM athlete_stats WHERE athlete_id = %s", (athlete_id,)).fetchone()
    return row["followers_count"] if row else 0


# --------------------------------------------------------------------------- profile

def _clubs(conn, player: dict) -> list[dict]:
    state = roster._state_at(roster._latest_registrations(conn, player["league_id"]).get(player["player_id"]),
                             roster._today())
    if not state["squad_id"]:
        return []
    squad = conn.execute("SELECT club_id FROM roster_squads WHERE league_id = %s AND squad_id = %s",
                         (player["league_id"], state["squad_id"])).fetchone()
    return [{"club_id": squad["club_id"] if squad else state["squad_id"], "league_id": player["league_id"],
             "squad_id": state["squad_id"], "role": state["role"]}]


def _fixtures(conn, league_id: str, squad_id: str) -> tuple[dict, list[dict]]:
    career = {"played": 0, "won": 0, "drawn": 0, "lost": 0, "matches": []}
    upcoming = []
    for m in conn.execute("SELECT * FROM scoring_matches WHERE league_id = %s AND (home = %s OR away = %s) "
                          "ORDER BY scheduled_at NULLS LAST, created_seq", (league_id, squad_id, squad_id)).fetchall():
        p = scoring.build_projection(m, scoring.match_sport(conn, m), scoring.load_events(conn, m["match_id"]))
        own, opp = (p["home"], p["away"]) if m["home"] == squad_id else (p["away"], p["home"])
        if p["status"] == "upcoming":
            upcoming.append({"match_id": m["match_id"], "opponent": opp["team_id"], "scheduled_at": m["scheduled_at"]})
        elif p["status"] == "completed":
            if p["outcome"] == "draw" or p["winner_team_id"] is None:
                result = "draw"
            else:
                result = "win" if p["winner_team_id"] == squad_id else "loss"
            career["played"] += 1
            career[{"win": "won", "draw": "drawn", "loss": "lost"}[result]] += 1
            career["matches"].append({"match_id": m["match_id"], "opponent": opp["team_id"], "result": result,
                                      "score": f"{own['score']}-{opp['score']}"})
    return career, upcoming


def _vod(conn, player_id: str) -> list[dict]:
    """vod_recordings is another module's table: tolerate it being absent or shaped differently."""
    if conn.execute("SELECT to_regclass('vod_recordings') AS t").fetchone()["t"] is None:
        return []
    try:
        with conn.transaction():  # savepoint: a column mismatch must not poison the outer transaction
            return conn.execute(
                "SELECT stream_key, object_url, started_at, ended_at FROM vod_recordings "
                "WHERE player_id = %s AND ended_at IS NOT NULL ORDER BY started_at DESC", (player_id,)).fetchall()
    except Exception:
        return []


def _viewer(request: Request) -> str | None:
    """The signed-in member reading a profile, if any (guests / anonymous / bad tokens read as None)."""
    token = day2.bearer(request)
    if token is None or day2.is_guest_token(token):
        return None
    try:
        return auth.decode_token(token)["sub"]
    except Exception:
        return None


@router.get("/api/v1/athletes/{player_id}")
def athlete_profile(player_id: str, request: Request):
    viewer = _viewer(request)
    with pool.connection() as conn:
        player = conn.execute("SELECT * FROM roster_players WHERE player_id = %s", (player_id,)).fetchone()
        if player is None:
            day2.require_player(conn, player_id)  # raises 404 PLAYER_NOT_FOUND
        clubs = _clubs(conn, player)
        career, upcoming = (_fixtures(conn, player["league_id"], clubs[0]["squad_id"]) if clubs else
                            ({"played": 0, "won": 0, "drawn": 0, "lost": 0, "matches": []}, []))
        return {"player_id": player_id, "name": player["name"], "position": player["position"], "clubs": clubs,
                "career": career, "upcoming": upcoming, "vod": _vod(conn, player_id),
                "followers_count": _followers(conn, player_id),
                # Whether the caller already follows this athlete, so the app shows the saved state on every visit.
                "following": viewer is not None and conn.execute(
                    "SELECT 1 FROM follows WHERE follower_id = %s AND athlete_id = %s",
                    (viewer, player_id)).fetchone() is not None}


# --------------------------------------------------------------------------- follow graph

def _follower(request: Request, athlete_id: str | None = None) -> str:
    token = day2.bearer(request)
    if token is None:  # FR-4.3: an anonymous caller is treated like a guest (the middleware covers guest_*)
        raise day2.guest_forbidden(None)
    claims = auth.decode_token(token)
    if athlete_id is not None and claims.get("player_id") == athlete_id:  # a player cannot follow himself
        raise ApiError(400, "CANNOT_FOLLOW_SELF", "You cannot follow your own profile", {"athlete_id": athlete_id})
    return claims["sub"]


def _apply(request: Request, athlete_id: str, want) -> dict:
    """want: True follow, False unfollow, None toggle. Serialised per athlete; counter moves only on a real change."""
    follower_id = _follower(request, athlete_id)
    with pool.connection() as conn:
        day2.require_player(conn, athlete_id)
        conn.execute("SELECT pg_advisory_xact_lock(hashtext('follow:' || %s))", (athlete_id,))
        if want is None:
            want = conn.execute("SELECT 1 FROM follows WHERE follower_id = %s AND athlete_id = %s",
                                (follower_id, athlete_id)).fetchone() is None
        if want:
            changed = conn.execute("INSERT INTO follows (follower_id, athlete_id) VALUES (%s, %s) "
                                   "ON CONFLICT DO NOTHING RETURNING 1", (follower_id, athlete_id)).fetchone()
            delta = 1
        else:
            changed = conn.execute("DELETE FROM follows WHERE follower_id = %s AND athlete_id = %s RETURNING 1",
                                   (follower_id, athlete_id)).fetchone()
            delta = -1
        if changed:
            conn.execute("INSERT INTO athlete_stats (athlete_id, followers_count) VALUES (%s, GREATEST(%s, 0)) "
                         "ON CONFLICT (athlete_id) DO UPDATE SET followers_count = athlete_stats.followers_count + %s",
                         (athlete_id, delta, delta))
        return {"athlete_id": athlete_id, "follower_id": follower_id, "following": want,
                "followers_count": _followers(conn, athlete_id)}


@router.put("/api/v1/athletes/{player_id}/follow")
def follow(player_id: str, request: Request):
    return _apply(request, player_id, True)


@router.delete("/api/v1/athletes/{player_id}/follow")
def unfollow(player_id: str, request: Request):
    return _apply(request, player_id, False)


@router.post("/api/v1/athletes/{player_id}/follow/toggle")
def toggle(player_id: str, request: Request):
    return _apply(request, player_id, None)
