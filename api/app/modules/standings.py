"""FR-1.4 / spec 5.10: standings recomputed from scratch from the event logs on
every call (no stored table). Only completed matches whose outcome is not
`undecided` count as played; every other fixture is "remaining"."""
from fastapi import APIRouter, Depends

from .. import auth
from ..db import pool
from ..errors import not_found
from ..signing import lots_key
from . import scoring, sports

router = APIRouter()

SCHEMA = ""


def reset(conn, seed: int, body: dict) -> None:
    pass  # nothing stored: standings are pure projections of scoring_* tables


# --------------------------------------------------------------------------- per-match facts

def _overs(side: dict, sport: dict) -> float:
    """Overs faced as a decimal; an all-out innings counts as the full allocation (5.10)."""
    p = sport["periods"]
    if side["wickets"] >= p["innings_per_team"] * p["wickets_per_innings"]:
        return float(p["innings_per_team"] * p["overs_per_innings"])
    return side["balls"] / p["balls_per_over"]


def _played_matches(conn, league: dict, sport: dict) -> tuple[list[dict], dict]:
    """Returns (counted results, remaining fixture count per team)."""
    rows = conn.execute("SELECT * FROM scoring_matches WHERE league_id = %s ORDER BY created_seq",
                        (league["league_id"],)).fetchall()
    remaining = {t: 0 for t in league["teams"]}
    results = []
    innings = sport["scoring_model"] == "innings"
    for m in rows:
        p = scoring.build_projection(m, sport, scoring.load_events(conn, m["match_id"]))
        if p["status"] != "completed" or p["outcome"] == "undecided":
            for t in (m["home"], m["away"]):
                if t in remaining:
                    remaining[t] += 1
            continue
        results.append({
            "home": m["home"], "away": m["away"], "winner": p["winner_team_id"],
            "score": {m["home"]: p["home"]["score"], m["away"]: p["away"]["score"]},
            "fair_play": {m["home"]: p["home"]["fair_play"], m["away"]: p["away"]["fair_play"]},
            "overs": ({m["home"]: _overs(p["home"], sport), m["away"]: _overs(p["away"], sport)} if innings else None),
        })
    return results, remaining


# --------------------------------------------------------------------------- aggregates over a set of matches

def _points_for(team: str, matches: list[dict], pts: dict) -> int:
    total = 0
    for r in matches:
        if team not in (r["home"], r["away"]):
            continue
        if r["winner"] is None:
            total += pts["draw"]
        elif r["winner"] == team:
            total += pts["win"]
        else:
            total += pts["loss"]
    return total


def _scored_conceded(team: str, matches: list[dict]) -> tuple[int, int]:
    scored = conceded = 0
    for r in matches:
        if team in (r["home"], r["away"]):
            other = r["away"] if team == r["home"] else r["home"]
            scored += r["score"][team]
            conceded += r["score"][other]
    return scored, conceded


def _diff(team: str, matches: list[dict], sport: dict):
    """Goal/point/map differential, or net run rate (3 decimals) for innings sports."""
    scored, conceded = _scored_conceded(team, matches)
    if sport["scoring_model"] != "innings":
        return scored - conceded
    faced = bowled = 0.0
    for r in matches:
        if team in (r["home"], r["away"]):
            other = r["away"] if team == r["home"] else r["home"]
            faced += r["overs"][team]
            bowled += r["overs"][other]
    rate_for = scored / faced if faced else 0.0
    rate_against = conceded / bowled if bowled else 0.0
    return round(rate_for - rate_against, 3)


def _among(group: list[str], matches: list[dict]) -> list[dict]:
    members = set(group)
    return [r for r in matches if r["home"] in members and r["away"] in members]


# --------------------------------------------------------------------------- ordering (exact algorithm of 5.10)

def _criterion_value(name: str, team: str, group: list[str], ctx: dict):
    if name == "h2h_points":
        return _points_for(team, _among(group, ctx["matches"]), ctx["points"])
    if name == "h2h_diff":
        return _diff(team, _among(group, ctx["matches"]), ctx["sport"])
    if name == "overall_diff":
        return ctx["stats"][team]["diff"]
    if name == "scored":
        return ctx["stats"][team]["scored"]
    if name == "fair_play":
        return ctx["stats"][team]["fair_play"]
    raise ValueError(name)


def resolve(group: list[str], ctx: dict) -> list[tuple[str, str | None]]:
    """Order a group of teams tied on points. Returns [(team, criterion that separates it from
    the next team in this group or None)]. Every sub-group restarts from the first criterion."""
    if len(group) == 1:
        return [(group[0], None)]
    for name in ctx["order"]:
        if name == "draw_lots":
            keyed = sorted(group, key=lambda t: lots_key(ctx["lots_seed"], ctx["league_id"], t))
            return [(t, "draw_lots" if i < len(keyed) - 1 else None) for i, t in enumerate(keyed)]
        values = {t: _criterion_value(name, t, group, ctx) for t in group}
        distinct = sorted(set(values.values()), reverse=True)  # higher is better
        if len(distinct) == 1:
            continue
        ordered: list[tuple[str, str | None]] = []
        for i, value in enumerate(distinct):
            bucket = [t for t in group if values[t] == value]
            part = resolve(bucket, ctx)
            if i < len(distinct) - 1:
                last_team, _ = part[-1]
                part[-1] = (last_team, name)
            ordered.extend(part)
        return ordered
    return [(t, None) for t in group]


def compute(conn, league_id: str) -> dict:
    league = conn.execute("SELECT * FROM scoring_leagues WHERE league_id = %s", (league_id,)).fetchone()
    if not league:
        raise not_found("LEAGUE_NOT_FOUND", league_id=league_id)
    sport = league.get("sport_config") or sports.get_sport(league["sport_id"], conn)
    teams, pts = league["teams"], league["points"]
    matches, remaining = _played_matches(conn, league, sport)

    stats = {}
    for t in teams:
        mine = [r for r in matches if t in (r["home"], r["away"])]
        won = sum(1 for r in mine if r["winner"] == t)
        drawn = sum(1 for r in mine if r["winner"] is None)
        scored, conceded = _scored_conceded(t, mine)
        stats[t] = {
            "played": len(mine), "won": won, "drawn": drawn, "lost": len(mine) - won - drawn,
            "scored": scored, "conceded": conceded, "diff": _diff(t, mine, sport),
            "points": won * pts["win"] + drawn * pts["draw"] + (len(mine) - won - drawn) * pts["loss"],
            "fair_play": sum(r["fair_play"][t] for r in mine),
        }

    order = [c for c in league["tie_break_order"] if c != "draw_lots"] + ["draw_lots"]
    ctx = {"matches": matches, "points": pts, "sport": sport, "stats": stats, "order": order,
           "lots_seed": league["lots_seed"], "league_id": league_id}

    ranked: list[tuple[str, str | None]] = []
    for value in sorted({s["points"] for s in stats.values()}, reverse=True):
        ranked.extend(resolve([t for t in teams if stats[t]["points"] == value], ctx))

    # Qualification (points only, tie-breaks ignored): clinched checked first.
    k, win = league["spots"], pts["win"]
    best = {t: stats[t]["points"] + win * remaining[t] for t in teams}

    def status_of(t):
        if sum(1 for x in teams if x != t and best[x] >= stats[t]["points"]) < k:
            return "clinched"
        if sum(1 for x in teams if x != t and stats[x]["points"] > best[t]) >= k:
            return "eliminated"
        return "still_possible"

    table = [{"rank": i + 1, "team_id": t, **stats[t], "status": status_of(t), "resolved_by": sep}
             for i, (t, sep) in enumerate(ranked)]

    h2h = {}
    for a in teams:
        h2h[a] = {}
        for b in teams:
            if a == b:
                continue
            between = _among([a, b], matches)
            scored, conceded = _scored_conceded(a, between)
            h2h[a][b] = {"played": len(between), "points": _points_for(a, between, pts),
                         "scored": scored, "conceded": conceded}

    return {"league_id": league_id, "sport_id": league["sport_id"], "qualification_spots": k,
            "table": table, "h2h": h2h}


@router.get("/audit/v1/standings/{league_id}")
def get_standings(league_id: str):
    with pool.connection() as conn:
        return compute(conn, league_id)


@router.get("/api/v1/leagues/{league_id}/standings")
def league_standings(league_id: str, user: dict = Depends(auth.current_user)):
    with pool.connection() as conn:
        scoring.league_for_user(conn, league_id, user)
        return compute(conn, league_id)
