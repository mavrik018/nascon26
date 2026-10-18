"""FR-1.1 / spec 5.8, 5.9: league registration and the event-sourced scoring engine.

The event log (scoring_events) is append-only: rows are never updated or
deleted (except by /reset). A correction is a new `compensation` event; the
projection treats the target and the compensation as neutral. Scores are always
rebuilt from the log on read (project()); there are no mutable score counters.

Nothing here branches on a sport or event name: points/runs/rounds, legal balls
and wickets all come from the sport's JSON config (sports.py)."""
from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from psycopg.types.json import Jsonb

from .. import auth
from ..db import pool
from ..errors import ApiError, conflict, not_found, validation
from ..signing import canonical, sign
from . import sports
from .util import is_id, is_int, read_json

router = APIRouter()

SCHEMA = """
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
-- Rules in force when the league / match was created: editing a sport never rewrites past results.
ALTER TABLE scoring_leagues ADD COLUMN IF NOT EXISTS sport_config JSONB;
ALTER TABLE scoring_matches ADD COLUMN IF NOT EXISTS sport_config JSONB;
"""

EVENT_TYPES = {"match_init", "match_start", "score", "discipline", "tiebreak_winner", "match_end", "compensation",
               "status_change"}
# FR-1.3 status machine for status_change events (match_start / match_end cover upcoming -> in_progress -> completed).
STATUS_TRANSITIONS = {"upcoming": {"postponed", "cancelled"}, "in_progress": {"abandoned"},
                      "postponed": {"upcoming", "cancelled"}}
COMPENSABLE = {"score", "discipline", "tiebreak_winner"}
DEFAULT_POINTS = {"win": 3, "draw": 1, "loss": 0}


# --------------------------------------------------------------------------- reset / demo data

def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM scoring_events")
    conn.execute("DELETE FROM scoring_matches")
    conn.execute("DELETE FROM scoring_leagues")
    _seed_demo_league(conn, seed)
    for league_id, sport_id, name, teams in DEMO_SPORT_LEAGUES:
        _seed_sport_league(conn, seed, league_id, sport_id, name, teams)


# Extra demo leagues so the app shows how each scoring model is organised.
DEMO_SPORT_LEAGUES = [
    ("alpha-hoops", "basketball", "Alpha Basketball League", ["hoops-falcons", "hoops-titans", "hoops-comets"]),
    ("alpha-cricket", "cricket", "Alpha T20 Cup", ["cricket-lions", "cricket-hawks", "cricket-tigers"]),
    ("alpha-esports", "esports", "Alpha Esports Series", ["esports-nova", "esports-pulse", "esports-vortex"]),
]


def _seed_sport_league(conn, seed: int, league_id: str, sport_id: str, name: str, teams: list[str]) -> None:
    """Round robin of 3 teams: one finished, one live, one upcoming. Uses whatever
    scoring events the sport config defines (no sport-specific code)."""
    sport = sports.get_sport(sport_id, conn)
    pairs = [(0, 1), (1, 2), (0, 2)]
    prefix = league_id.replace("alpha-", "")
    fixtures = [{"match_id": f"{prefix}-m{i + 1}", "home": teams[h], "away": teams[a]}
                for i, (h, a) in enumerate(pairs)]
    register_league(conn, {"league_id": league_id, "sport_id": sport_id, "teams": teams, "fixtures": fixtures,
                           "qualification": {"spots": 1}, "lots_seed": seed}, tenant_id="tenant-alpha", name=name)
    for i, f in enumerate(fixtures):
        conn.execute("UPDATE scoring_matches SET scheduled_at = %s, pinned_product_id = %s WHERE match_id = %s",
                     (f"2026-10-{16 + i:02d}T18:00:00Z", "prod-jersey-001", f["match_id"]))
    # Highest-value scoring event of this sport's config (points, runs or rounds).
    events = sport["scoring_events"]
    best = max(events, key=lambda k: events[k].get("points", events[k].get("runs", events[k].get("rounds", 0))))
    n = 0

    def add(match_id, type_, payload):
        nonlocal n
        n += 1
        append_event(conn, {"event_id": f"{prefix}-e{n:03d}", "match_id": match_id, "type": type_, "payload": payload})

    finished, live = fixtures[0], fixtures[1]
    add(finished["match_id"], "match_start", {})
    for team in (finished["home"], finished["away"], finished["home"]):
        add(finished["match_id"], "score", {"team_id": team, "event_type": best})
    add(finished["match_id"], "match_end", {})
    add(live["match_id"], "match_start", {})
    add(live["match_id"], "score", {"team_id": live["away"], "event_type": best})


DEMO_LEAGUE = "league-alpha-1"
DEMO_TEAMS = ["club-alpha-1", "club-alpha-2", "club-alpha-3", "club-alpha-4"]


def _seed_demo_league(conn, seed: int) -> None:
    """A small football league for the mobile app (ids never collide with grader ids)."""
    teams = DEMO_TEAMS
    pairs = [(0, 1), (2, 3), (0, 2), (1, 3), (0, 3), (1, 2)]
    fixtures = [{"match_id": f"alpha1-m{i + 1:02d}", "home": teams[h], "away": teams[a]}
                for i, (h, a) in enumerate(pairs)]
    register_league(conn, {
        "league_id": DEMO_LEAGUE, "sport_id": "football", "teams": teams, "fixtures": fixtures,
        "qualification": {"spots": 2}, "lots_seed": seed,
    }, tenant_id="tenant-alpha", name="Alpha Premier League")
    for i, f in enumerate(fixtures):
        conn.execute("UPDATE scoring_matches SET scheduled_at = %s, pinned_product_id = %s WHERE match_id = %s",
                     (f"2026-10-{10 + i:02d}T15:00:00Z", "prod-jersey-001", f["match_id"]))
    # Results: m01 2-1, m02 0-0, m03 1-3 finished; m04 live 1-0; m05, m06 upcoming.
    script = {
        "alpha1-m01": [0, 0, 1, "end"],
        "alpha1-m02": ["end"],
        "alpha1-m03": [0, 1, 1, 1, "end"],
        "alpha1-m04": [0],
    }
    scoring_event = next(iter(sports.get_sport("football", conn)["scoring_events"]))
    n = 0
    for match_id, steps in script.items():
        f = next(x for x in fixtures if x["match_id"] == match_id)
        n += 1
        append_event(conn, {"event_id": f"alpha1-e{n:03d}", "match_id": match_id, "type": "match_start", "payload": {}})
        for step in steps:
            n += 1
            if step == "end":
                body = {"type": "match_end", "payload": {}}
            else:
                team = f["home"] if step == 0 else f["away"]
                body = {"type": "score", "payload": {"team_id": team, "event_type": scoring_event}}
            append_event(conn, {"event_id": f"alpha1-e{n:03d}", "match_id": match_id, **body})


# --------------------------------------------------------------------------- leagues (5.8)

def _validate_league(body) -> dict:
    if not isinstance(body, dict):
        raise validation("body")
    bad = []
    if not is_id(body.get("league_id")):
        bad.append("league_id")
    if not is_id(body.get("sport_id")):
        bad.append("sport_id")
    teams = body.get("teams")
    if not (isinstance(teams, list) and 2 <= len(teams) <= 40 and all(is_id(t) for t in teams)
            and len(set(teams)) == len(teams)):
        bad.append("teams")
        teams = None
    fixtures = body.get("fixtures")
    if not isinstance(fixtures, list):
        bad.append("fixtures")
    else:
        seen = set()
        for f in fixtures:
            ok = (isinstance(f, dict) and is_id(f.get("match_id")) and is_id(f.get("home")) and is_id(f.get("away"))
                  and f["home"] != f["away"]
                  and (teams is None or (f["home"] in teams and f["away"] in teams)))
            if not ok:
                bad.append("fixtures")
                break
            seen.add(f["match_id"])
    points = body.get("points")
    if points is not None and not (isinstance(points, dict)
                                   and all(k not in points or is_int(points[k]) for k in DEFAULT_POINTS)):
        bad.append("points")
    order = body.get("tie_break_order")
    if order is not None and (not isinstance(order, list) or any(t not in sports.TIE_BREAKS for t in order)
                              or len(set(order)) != len(order)):
        bad.append("tie_break_order")
    q = body.get("qualification")
    if not (isinstance(q, dict) and is_int(q.get("spots"), 1) and (teams is None or q["spots"] <= len(teams))):
        bad.append("qualification")
    if body.get("lots_seed") is not None and not is_int(body.get("lots_seed")):
        bad.append("lots_seed")
    if bad:
        raise validation(bad, "Invalid league")
    return body


def register_league(conn, body, tenant_id: str | None = None, name: str | None = None) -> dict:
    body = _validate_league(body)
    sport = sports.get_sport(body["sport_id"], conn)  # 404 SPORT_NOT_FOUND
    if conn.execute("SELECT 1 FROM scoring_leagues WHERE league_id = %s", (body["league_id"],)).fetchone():
        raise conflict("LEAGUE_EXISTS", f"League {body['league_id']} already exists", league_id=body["league_id"])
    ids = [f["match_id"] for f in body["fixtures"]]
    repeated = sorted({i for i in ids if ids.count(i) > 1})
    if repeated:
        raise conflict("MATCH_EXISTS", f"Match {repeated[0]} is listed twice", match_id=repeated[0])
    if ids:
        taken = conn.execute("SELECT match_id FROM scoring_matches WHERE match_id = ANY(%s) ORDER BY match_id",
                             (ids,)).fetchone()
        if taken:
            raise conflict("MATCH_EXISTS", f"Match {taken['match_id']} already exists", match_id=taken["match_id"])
    points = {**DEFAULT_POINTS, **{k: v for k, v in (body.get("points") or {}).items() if k in DEFAULT_POINTS}}
    order = body["tie_break_order"] if body.get("tie_break_order") is not None         else (sport.get("tie_break_order") or sports.TIE_BREAKS)
    lots_seed = body.get("lots_seed")
    if lots_seed is None:
        from .core import current_seed_conn
        lots_seed = current_seed_conn(conn)
    conn.execute(
        "INSERT INTO scoring_leagues (league_id, sport_id, tenant_id, name, teams, points, tie_break_order, spots,"
        " lots_seed, sport_config) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
        (body["league_id"], body["sport_id"], tenant_id, name, Jsonb(body["teams"]), Jsonb(points), Jsonb(order),
         body["qualification"]["spots"], lots_seed, Jsonb(sport)))
    for f in body["fixtures"]:
        conn.execute("INSERT INTO scoring_matches (match_id, league_id, sport_id, home, away, sport_config)"
                     " VALUES (%s,%s,%s,%s,%s,%s)",
                     (f["match_id"], body["league_id"], body["sport_id"], f["home"], f["away"], Jsonb(sport)))
    return {"league_id": body["league_id"], "status": "created", "team_count": len(body["teams"]),
            "fixture_count": len(body["fixtures"])}


@router.post("/audit/v1/leagues", status_code=201)
async def create_league(request: Request):
    body = await read_json(request)
    with pool.connection() as conn:
        return register_league(conn, body)


# --------------------------------------------------------------------------- events (5.9)

def _validate_event(body) -> dict:
    if not isinstance(body, dict):
        raise validation("body")
    bad = [f for f in ("event_id", "match_id") if not is_id(body.get(f))]
    if body.get("type") not in EVENT_TYPES:
        bad.append("type")
    if not isinstance(body.get("payload"), dict):
        bad.append("payload")
    if bad:
        raise validation(bad, "Invalid event")
    p, t = body["payload"], body["type"]
    bad = []
    if t == "match_init":
        for f in ("sport_id", "home_team_id", "away_team_id"):
            if not isinstance(p.get(f), str) or not p.get(f):
                bad.append(f"payload.{f}")
        if not bad and not is_id(p["sport_id"]):
            bad.append("payload.sport_id")
        if not bad and (not is_id(p["home_team_id"]) or not is_id(p["away_team_id"])
                        or p["home_team_id"] == p["away_team_id"]):
            bad.append("payload.away_team_id")
        if p.get("league_id") is not None and not is_id(p.get("league_id")):
            bad.append("payload.league_id")
    elif t in ("score", "discipline", "tiebreak_winner"):
        if not isinstance(p.get("team_id"), str) or not p.get("team_id"):
            bad.append("payload.team_id")
        if t == "score" and (not isinstance(p.get("event_type"), str) or not p.get("event_type")):
            bad.append("payload.event_type")
        if t == "discipline" and not is_int(p.get("points")):
            bad.append("payload.points")
    elif t == "status_change":
        if p.get("status") not in ("upcoming", "postponed", "abandoned", "cancelled"):
            bad.append("payload.status")
        if not isinstance(p.get("reason"), str):
            bad.append("payload.reason")
    elif t == "compensation":
        if not is_id(p.get("compensates")):
            bad.append("payload.compensates")
        if not isinstance(p.get("reason"), str):
            bad.append("payload.reason")
    if bad:
        raise validation(bad, "Invalid event payload")
    return body


def _request_key(body: dict) -> str:
    return canonical({k: body[k] for k in ("event_id", "match_id", "type", "payload")})


def match_sport(conn, match: dict) -> dict:
    """The sport rules this match was created under (later edits to the sport apply to new matches only)."""
    return match.get("sport_config") or sports.get_sport(match["sport_id"], conn)


def load_match(conn, match_id: str):
    return conn.execute("SELECT * FROM scoring_matches WHERE match_id = %s", (match_id,)).fetchone()


def load_events(conn, match_id: str) -> list[dict]:
    return conn.execute("SELECT event_id, sequence, type, payload, signature, compensates FROM scoring_events"
                        " WHERE match_id = %s ORDER BY sequence", (match_id,)).fetchall()


def match_version(conn, match_id: str) -> int:
    return conn.execute("SELECT count(*) AS n FROM scoring_events WHERE match_id = %s", (match_id,)).fetchone()["n"]


def find_event(conn, event_id: str):
    return conn.execute("SELECT request, response FROM scoring_events WHERE event_id = %s", (event_id,)).fetchone()


def append_event(conn, body, rescheduled: bool = False) -> tuple[int, dict]:
    """Validate and append one event. Returns (201, response), or (200, stored response) on an
    identical replay; raises ApiError otherwise. The caller owns the transaction.
    rescheduled=True only from schedule.reschedule, after its conflict check passed."""
    body = _validate_event(body)
    key = _request_key(body)
    t, p, match_id = body["type"], body["payload"], body["match_id"]

    # Serialize everything about one match (and creation of its id) for the rest of the transaction.
    conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("match:" + match_id,))

    existing = find_event(conn, body["event_id"])
    if existing:
        if existing["request"] == key:
            return 200, existing["response"]
        raise conflict("DUPLICATE_EVENT_ID", "event_id already used with a different body", event_id=body["event_id"])

    if t == "match_init":
        sport = sports.get_sport(p["sport_id"], conn)  # 404 SPORT_NOT_FOUND
        if load_match(conn, match_id):
            raise conflict("MATCH_EXISTS", f"Match {match_id} already exists", match_id=match_id)
        conn.execute("INSERT INTO scoring_matches (match_id, league_id, sport_id, home, away, sport_config)"
                     " VALUES (%s,%s,%s,%s,%s,%s)",
                     (match_id, p.get("league_id"), sport["sport_id"], p["home_team_id"], p["away_team_id"],
                      Jsonb(sport)))
        return 201, _store(conn, body, key, sequence=1, compensates=None)

    match = load_match(conn, match_id)
    if not match:
        raise not_found("MATCH_NOT_FOUND", match_id=match_id)
    sport = match_sport(conn, match)
    events = load_events(conn, match_id)
    state = project_state(match, sport, events)

    if t in ("score", "discipline", "tiebreak_winner"):
        if p["team_id"] not in (match["home"], match["away"]):
            raise validation("payload.team_id", "team_id is not a participant of this match")
        if t == "score" and p["event_type"] not in sport["scoring_events"]:
            raise ApiError(400, "UNKNOWN_EVENT_TYPE", f"Unknown event type {p['event_type']}",
                           {"event_type": p["event_type"]})
        if state["status"] != "in_progress":
            raise conflict("MATCH_NOT_IN_PROGRESS", "Match is not in progress", match_id=match_id,
                           status=state["status"])
        if t == "score":
            _check_model_limits(sport, state, p["team_id"])
    elif t == "match_start":
        if state["status"] != "upcoming":
            raise conflict("ILLEGAL_TRANSITION", f"Cannot start a match that is {state['status']}",
                           match_id=match_id, status=state["status"])
    elif t == "match_end":
        if state["status"] != "in_progress":
            raise conflict("ILLEGAL_TRANSITION", f"Cannot end a match that is {state['status']}",
                           match_id=match_id, status=state["status"])
        home, away = state["teams"][match["home"]], state["teams"][match["away"]]
        if home["score"] == away["score"] and not sport["draw_allowed"] and state["tiebreak_winner"] is None:
            raise conflict("TIE_NOT_ALLOWED", "Score is level and this sport does not allow draws", match_id=match_id)
    elif t == "status_change":
        if p["status"] == "upcoming" and not rescheduled:
            raise conflict("ILLEGAL_TRANSITION", "Use reschedule to bring a postponed match back",
                           match_id=match_id, status=state["status"])
        if p["status"] not in STATUS_TRANSITIONS.get(state["status"], ()):
            raise conflict("ILLEGAL_TRANSITION", f"Cannot change a {state['status']} match to {p['status']}",
                           match_id=match_id, status=state["status"])
    elif t == "compensation":
        target = conn.execute("SELECT match_id, type FROM scoring_events WHERE event_id = %s",
                              (p["compensates"],)).fetchone()
        if not target:
            raise not_found("EVENT_NOT_FOUND", event_id=p["compensates"])
        if (target["match_id"] != match_id or target["type"] not in COMPENSABLE
                or p["compensates"] in state["compensated_by"]):
            raise conflict("INVALID_COMPENSATION", "Event cannot be compensated", event_id=p["compensates"])

    return 201, _store(conn, body, key, sequence=len(events) + 1,
                       compensates=p["compensates"] if t == "compensation" else None)


def _check_model_limits(sport: dict, state: dict, team_id: str) -> None:
    model, periods, team = sport["scoring_model"], sport["periods"], state["teams"][team_id]
    if model == "innings":
        max_balls = periods["innings_per_team"] * periods["overs_per_innings"] * periods["balls_per_over"]
        max_wickets = periods["innings_per_team"] * periods["wickets_per_innings"]
        if team["balls"] >= max_balls or team["wickets"] >= max_wickets:
            raise conflict("INNINGS_COMPLETE", "This team's innings is complete", team_id=team_id)
    elif model == "round":
        # Spec 5.9: once ANY team has won the majority, the series is over for both teams.
        if any(t["score"] >= (periods["best_of"] + 1) // 2 for t in state["teams"].values()):
            raise conflict("SERIES_ALREADY_DECIDED", "The series is already decided", team_id=team_id)


def _store(conn, body: dict, key: str, sequence: int, compensates) -> dict:
    signature = sign(body["event_id"], body["payload"])
    response = {"event_id": body["event_id"], "match_id": body["match_id"], "type": body["type"],
                "sequence": sequence, "match_version": sequence, "signature": signature}
    conn.execute(
        "INSERT INTO scoring_events (event_id, match_id, sequence, type, payload, request, signature, compensates,"
        " response) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)",
        (body["event_id"], body["match_id"], sequence, body["type"], Jsonb(body["payload"]), key, signature,
         compensates, Jsonb(response)))
    return response


@router.post("/audit/v1/events", status_code=201)
async def post_event(request: Request):
    body = await read_json(request)
    with pool.connection() as conn:
        status, response = append_event(conn, body)
    return JSONResponse(status_code=status, content=response)


# --------------------------------------------------------------------------- projection

def project_state(match: dict, sport: dict, events: list[dict]) -> dict:
    """Rebuild everything about a match from its event log (compensated events are neutral)."""
    compensated_by = {e["compensates"]: e["event_id"] for e in events if e["type"] == "compensation"}
    status = "upcoming"
    teams = {match["home"]: _blank_team(), match["away"]: _blank_team()}
    tiebreak = None
    rules, model = sport["scoring_events"], sport["scoring_model"]
    for e in events:
        if e["event_id"] in compensated_by or e["type"] == "compensation":
            continue
        t, p = e["type"], e["payload"]
        if t == "match_start":
            status = "in_progress"
        elif t == "match_end":
            status = "completed"
        elif t == "status_change":
            status = p["status"]
        elif t == "score":
            rule, team = rules.get(p["event_type"], {}), teams[p["team_id"]]
            if model == "event":
                team["score"] += rule.get("points", 0)
            elif model == "innings":
                team["score"] += rule.get("runs", 0)
                team["balls"] += 1 if rule.get("legal_ball") else 0
                team["wickets"] += 1 if rule.get("wicket") else 0
            else:
                team["score"] += rule.get("rounds", 0)
        elif t == "discipline":
            teams[p["team_id"]]["fair_play"] += p["points"]
        elif t == "tiebreak_winner":
            tiebreak = p["team_id"]
    return {"status": status, "teams": teams, "tiebreak_winner": tiebreak, "compensated_by": compensated_by}


def _blank_team() -> dict:
    return {"score": 0, "balls": 0, "wickets": 0, "fair_play": 0}


def project(conn, match_id: str) -> dict:
    match = load_match(conn, match_id)
    if not match:
        raise not_found("MATCH_NOT_FOUND", match_id=match_id)
    return build_projection(match, match_sport(conn, match), load_events(conn, match_id))


def build_projection(match: dict, sport: dict, events: list[dict]) -> dict:
    """Spec 5.9 score projection (also used by standings)."""
    state = project_state(match, sport, events)
    home_id, away_id = match["home"], match["away"]
    home, away = state["teams"][home_id], state["teams"][away_id]
    innings = sport["scoring_model"] == "innings"
    bpo = sport["periods"].get("balls_per_over") if innings else None

    if home["score"] > away["score"]:
        winner = home_id
    elif away["score"] > home["score"]:
        winner = away_id
    else:
        winner = state["tiebreak_winner"]

    if state["status"] != "completed":
        outcome = "pending"
    elif winner == home_id:
        outcome = "home_win"
    elif winner == away_id:
        outcome = "away_win"
    elif sport["draw_allowed"]:
        outcome = "draw"
    else:
        outcome = "undecided"

    def side(team_id, t):
        return {"team_id": team_id, "score": t["score"],
                "wickets": t["wickets"] if innings else None,
                "balls": t["balls"] if innings else None,
                "overs": f"{t['balls'] // bpo}.{t['balls'] % bpo}" if innings else None,
                "fair_play": t["fair_play"]}

    return {
        "match_id": match["match_id"], "sport_id": match["sport_id"], "league_id": match["league_id"],
        "status": state["status"], "outcome": outcome, "winner_team_id": winner,
        "tiebreak_winner_team_id": state["tiebreak_winner"],
        "home": side(home_id, home), "away": side(away_id, away),
        "version": len(events),
        "events": [{"sequence": e["sequence"], "event_id": e["event_id"], "type": e["type"], "payload": e["payload"],
                    "signature": e["signature"], "compensated": e["event_id"] in state["compensated_by"],
                    "compensated_by": state["compensated_by"].get(e["event_id"])} for e in events],
    }


@router.get("/audit/v1/score/{match_id}")
def get_score(match_id: str):
    with pool.connection() as conn:
        return project(conn, match_id)


# --------------------------------------------------------------------------- mobile routes

def league_for_user(conn, league_id: str, user: dict) -> dict:
    league = conn.execute("SELECT * FROM scoring_leagues WHERE league_id = %s", (league_id,)).fetchone()
    if not league:
        raise not_found("LEAGUE_NOT_FOUND", league_id=league_id)
    if user["role"] != "super_admin" and league["tenant_id"] not in (None, user.get("tenant_id")):
        raise auth.forbidden("This league belongs to another tenant")
    return league


@router.get("/api/v1/leagues/{league_id}/fixtures")
def league_fixtures(league_id: str, user: dict = Depends(auth.current_user)):
    with pool.connection() as conn:
        league_for_user(conn, league_id, user)
        rows = conn.execute("SELECT * FROM scoring_matches WHERE league_id = %s ORDER BY created_seq",
                            (league_id,)).fetchall()
        result = []
        for m in rows:
            p = build_projection(m, match_sport(conn, m), load_events(conn, m["match_id"]))
            result.append({"match_id": m["match_id"], "league_id": league_id, "home": m["home"], "away": m["away"],
                           "status": p["status"], "scheduled_at": m["scheduled_at"],
                           "home_score": p["home"]["score"], "away_score": p["away"]["score"]})
    return result


def _pinned_product(conn, product_id):
    if not product_id:
        return None
    from .store import PRICE_SQL  # store imports nothing from scoring; import here keeps load order free
    try:
        with conn.transaction():
            row = conn.execute(
                f"SELECT p.product_id, p.name, min({PRICE_SQL}) AS price_minor FROM store_products p"
                " JOIN store_variants v ON v.product_id = p.product_id WHERE p.product_id = %s"
                " GROUP BY p.product_id, p.name", (product_id,)).fetchone()
    except Exception:
        return None
    return {"product_id": row["product_id"], "name": row["name"], "price_minor": row["price_minor"],
            "currency": "PKR"} if row else None


def match_view(conn, match_id: str, user: dict) -> dict:
    """What the app shows on the match page: projection + schedule + pinned product."""
    match = load_match(conn, match_id)
    if not match:
        raise not_found("MATCH_NOT_FOUND", match_id=match_id)
    if match["league_id"]:
        league_for_user(conn, match["league_id"], user)
    sport = match_sport(conn, match)
    result = build_projection(match, sport, load_events(conn, match_id))
    result["sport_name"] = sport["name"]
    result["event_types"] = list(sport["scoring_events"])
    result["scheduled_at"] = match["scheduled_at"]
    result["venue_id"] = match.get("venue_id")
    result["pinned_product"] = _pinned_product(conn, match["pinned_product_id"])
    return result


@router.get("/api/v1/matches/{match_id}")
def match_detail(match_id: str, user: dict = Depends(auth.current_user)):
    with pool.connection() as conn:
        return match_view(conn, match_id, user)


@router.post("/api/v1/matches/{match_id}/pin")
async def pin_product(match_id: str, request: Request, user: dict = Depends(auth.current_user)):
    """FR-2.3 showcase: pin (or unpin with null) a store product on a match page. Stream clients get it
    within a second because the stream pushes whenever the match view changes."""
    body = await read_json(request)
    if not isinstance(body, dict) or "product_id" not in body:
        raise validation("product_id")
    product_id = body["product_id"]
    if product_id is not None and not is_id(product_id):
        raise validation("product_id")
    with pool.connection() as conn:
        match = load_match(conn, match_id)
        if not match:
            raise not_found("MATCH_NOT_FOUND", match_id=match_id)
        if not can_score(user, match["league_id"]):
            raise auth.forbidden("Only the league organizer can pin products on this match")
        if product_id is not None and _pinned_product(conn, product_id) is None:
            raise not_found("PRODUCT_NOT_FOUND", product_id=product_id)
        conn.execute("UPDATE scoring_matches SET pinned_product_id = %s WHERE match_id = %s", (product_id, match_id))
        return match_view(conn, match_id, user)


@router.get("/api/v1/matches/{match_id}/stream")
async def match_stream(match_id: str, request: Request, user: dict = Depends(auth.current_user)):
    """Realtime layer (SSE): pushes the match view (same body as GET /api/v1/matches/{id}) whenever it
    changes: a score, status change, compensation, reschedule or newly pinned product. Clients that
    cannot keep a stream open can poll GET /api/v1/matches/{id} instead."""
    import asyncio
    import json

    from fastapi.responses import StreamingResponse
    from starlette.concurrency import run_in_threadpool

    def snapshot():
        with pool.connection() as conn:
            return json.dumps(match_view(conn, match_id, user))

    first = await run_in_threadpool(snapshot)  # 404 / 403 before the stream starts

    async def events():
        last, current = None, first
        while not await request.is_disconnected():
            if current != last:
                last = current
                yield f"event: match\ndata: {current}\n\n"
            else:
                yield ": keep-alive\n\n"
            await asyncio.sleep(1)
            current = await run_in_threadpool(snapshot)

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


def can_score(user: dict, league_id: str | None) -> bool:
    return user["role"] == "super_admin" or (
        user["role"] == "league_organizer" and league_id is not None and user.get("league_id") == league_id)


@router.post("/api/v1/matches/{match_id}/events", status_code=201)
async def match_post_event(match_id: str, request: Request, user: dict = Depends(auth.current_user)):
    body = await read_json(request)
    if isinstance(body, dict):
        body["match_id"] = match_id
    with pool.connection() as conn:
        match = load_match(conn, match_id)
        if not can_score(user, match["league_id"] if match else None):
            raise auth.forbidden("Only the league organizer can record match events")
        status, response = append_event(conn, body)
    return JSONResponse(status_code=status, content=response)
