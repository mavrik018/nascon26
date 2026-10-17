"""FR-1.1 / spec 5.6: sports are pure data. Nothing in the domain branches on a
sport id or event name; scoring reads `scoring_model` + `scoring_events`."""
import re

from fastapi import APIRouter, Request
from psycopg.types.json import Jsonb

from ..db import pool
from ..errors import ApiError, not_found, validation
from .util import read_json

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS sports (
    sport_id   TEXT PRIMARY KEY,
    config     JSONB NOT NULL,
    baseline   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""

TIE_BREAKS = ["h2h_points", "h2h_diff", "overall_diff", "scored", "fair_play", "draw_lots"]
OVERTIME_POLICIES = {"none", "extra_time", "shootout", "golden_score", "super_over"}
SPORT_ID_RE = re.compile(r"^[a-z0-9_-]{2,40}\Z")
EVENT_KEY_RE = re.compile(r"^[a-z0-9_]{1,40}\Z")

BASELINE_SPORTS = [
    {"sport_id": "football", "name": "Football", "scoring_model": "event",
     "periods": {"count": 2, "duration_minutes": 45},
     "scoring_events": {"goal": {"points": 1}},
     "draw_allowed": True, "overtime": {"policy": "none"},
     "tie_break_order": TIE_BREAKS,
     "roster": {"min_squad_size": 11, "max_squad_size": 25, "required_positions": {"gk": 1}}},
    {"sport_id": "basketball", "name": "Basketball", "scoring_model": "event",
     "periods": {"count": 4, "duration_minutes": 12},
     "scoring_events": {"free_throw": {"points": 1}, "two_pointer": {"points": 2}, "three_pointer": {"points": 3}},
     "draw_allowed": False, "overtime": {"policy": "extra_time", "duration_minutes": 5},
     "tie_break_order": TIE_BREAKS,
     "roster": {"min_squad_size": 5, "max_squad_size": 15, "required_positions": {}}},
    {"sport_id": "cricket", "name": "Cricket", "scoring_model": "innings",
     "periods": {"innings_per_team": 1, "overs_per_innings": 20, "balls_per_over": 6, "wickets_per_innings": 10},
     "scoring_events": {
         "dot_ball": {"runs": 0, "legal_ball": True, "wicket": False},
         "single": {"runs": 1, "legal_ball": True, "wicket": False},
         "two": {"runs": 2, "legal_ball": True, "wicket": False},
         "four": {"runs": 4, "legal_ball": True, "wicket": False},
         "six": {"runs": 6, "legal_ball": True, "wicket": False},
         "wide": {"runs": 1, "legal_ball": False, "wicket": False},
         "no_ball": {"runs": 1, "legal_ball": False, "wicket": False},
         "wicket": {"runs": 0, "legal_ball": True, "wicket": True}},
     "draw_allowed": True, "overtime": {"policy": "super_over"},
     "tie_break_order": TIE_BREAKS,
     "roster": {"min_squad_size": 11, "max_squad_size": 18, "required_positions": {"wicketkeeper": 1}}},
    {"sport_id": "esports", "name": "Esports", "scoring_model": "round",
     "periods": {"best_of": 3},
     "scoring_events": {"round_win": {"rounds": 1}},
     "draw_allowed": False, "overtime": {"policy": "none"},
     "tie_break_order": TIE_BREAKS,
     "roster": {"min_squad_size": 5, "max_squad_size": 8, "required_positions": {}}},
]
BASELINE_SPORT_IDS = [s["sport_id"] for s in BASELINE_SPORTS]


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM sports")
    for sport in BASELINE_SPORTS:
        conn.execute("INSERT INTO sports (sport_id, config, baseline) VALUES (%s, %s, TRUE)",
                     (sport["sport_id"], Jsonb(sport)))


def get_sport(sport_id: str, conn=None) -> dict:
    """The stored config, or 404 SPORT_NOT_FOUND."""
    def _load(c):
        return c.execute("SELECT config FROM sports WHERE sport_id = %s", (sport_id,)).fetchone()
    row = _load(conn) if conn is not None else _with_pool(_load)
    if not row:
        raise not_found("SPORT_NOT_FOUND", sport_id=sport_id)
    return row["config"]


def _with_pool(fn):
    with pool.connection() as conn:
        return fn(conn)


def _is_int(v, minimum=None) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and (minimum is None or v >= minimum)


def validate_sport(body) -> dict:
    """Returns the normalized config or raises 400 VALIDATION_ERROR listing every bad field."""
    if not isinstance(body, dict):
        raise validation("body")
    bad: list[str] = []
    sport_id = body.get("sport_id")
    if not isinstance(sport_id, str) or not SPORT_ID_RE.match(sport_id):
        bad.append("sport_id")
    name = body.get("name")
    if not isinstance(name, str) or not 1 <= len(name) <= 80:
        bad.append("name")
    model = body.get("scoring_model")
    if model not in ("event", "innings", "round"):
        bad.append("scoring_model")

    periods = body.get("periods")
    if not isinstance(periods, dict):
        bad.append("periods")
    elif model == "event":
        if not (_is_int(periods.get("count"), 1) and _is_int(periods.get("duration_minutes"), 1)):
            bad.append("periods")
    elif model == "innings":
        keys = ("innings_per_team", "overs_per_innings", "balls_per_over", "wickets_per_innings")
        if not all(_is_int(periods.get(k), 1) for k in keys):
            bad.append("periods")
    elif model == "round":
        best_of = periods.get("best_of")
        if not (_is_int(best_of, 1) and best_of % 2 == 1):
            bad.append("periods")

    events = body.get("scoring_events")
    if not isinstance(events, dict) or not events:
        bad.append("scoring_events")
    else:
        for key, value in events.items():
            ok = isinstance(key, str) and EVENT_KEY_RE.match(key) and isinstance(value, dict)
            if ok and model == "event":
                ok = _is_int(value.get("points"), 1)
            elif ok and model == "innings":
                ok = _is_int(value.get("runs"), 0) and isinstance(value.get("legal_ball"), bool) \
                    and isinstance(value.get("wicket"), bool)
            elif ok and model == "round":
                ok = _is_int(value.get("rounds"), 1)
            if not ok:
                bad.append("scoring_events")
                break

    if not isinstance(body.get("draw_allowed"), bool):
        bad.append("draw_allowed")

    overtime = body.get("overtime")
    if not isinstance(overtime, dict) or overtime.get("policy") not in OVERTIME_POLICIES or (
        "duration_minutes" in overtime and overtime["duration_minutes"] is not None
        and not _is_int(overtime["duration_minutes"], 0)
    ):
        bad.append("overtime")

    order = body.get("tie_break_order")
    if order is not None and (
        not isinstance(order, list) or any(t not in TIE_BREAKS for t in order) or len(set(order)) != len(order)
    ):
        bad.append("tie_break_order")

    roster = body.get("roster")
    if not isinstance(roster, dict):
        bad.append("roster")
    else:
        mn, mx, req = roster.get("min_squad_size"), roster.get("max_squad_size"), roster.get("required_positions")
        if not (_is_int(mn, 1) and _is_int(mx, 1) and mn <= mx and isinstance(req, dict)
                and all(isinstance(k, str) and _is_int(v, 0) for k, v in req.items())):
            bad.append("roster")

    if bad:
        raise validation(bad, "Invalid sport configuration")

    config = {k: body[k] for k in ("sport_id", "name", "scoring_model", "periods", "scoring_events",
                                   "draw_allowed", "overtime", "roster")}
    config["tie_break_order"] = list(order) if order is not None else list(TIE_BREAKS)
    return config


@router.post("/audit/v1/sports", status_code=201)
async def create_sport(request: Request):
    config = validate_sport(await read_json(request))
    with pool.connection() as conn:
        inserted = conn.execute(
            "INSERT INTO sports (sport_id, config) VALUES (%s, %s) ON CONFLICT (sport_id) DO NOTHING RETURNING sport_id",
            (config["sport_id"], Jsonb(config)),
        ).fetchone()
    if not inserted:
        raise ApiError(409, "SPORT_EXISTS", f"Sport {config['sport_id']} already exists",
                       {"sport_id": config["sport_id"]})
    return {"sport_id": config["sport_id"], "status": "created", "config": config}
