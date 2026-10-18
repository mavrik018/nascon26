"""FR-1.2: season-scoped competitions built from ordinary leagues.

* divisions: leagues ordered top to bottom. Each season the top `promotion_spots` of a lower
  division go up and the bottom `relegation_spots` of the division above go down.
* hybrid: group leagues, then a seeded single-elimination knockout of the top
  `advance_per_group` of every group (group winners seeded first, so A1 meets the last runner-up).

Each division / group is a normal league (scoring.register_league, circle-method round robin), so
scoring, standings, rescheduling and SSE work on it unchanged. Promotion, relegation and the knockout
are derived from the live standings on every read: a postponed or corrected group match changes
them automatically, and they stay `provisional` until every stage match is final."""
from fastapi import APIRouter, Depends, Request
from psycopg.types.json import Jsonb

from .. import auth
from ..db import pool
from ..errors import conflict, not_found, validation
from . import fixtures, scoring, sports, standings
from .util import is_id, is_int, read_json

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS competitions (
    competition_id TEXT PRIMARY KEY,
    tenant_id      TEXT,
    name           TEXT NOT NULL,
    season         TEXT NOT NULL,
    sport_id       TEXT NOT NULL,
    format         TEXT NOT NULL,
    stages         JSONB NOT NULL,   -- [{league_id, name}] top division first / groups in order
    rules          JSONB NOT NULL
);
"""

FINAL = {"completed", "cancelled", "abandoned"}


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM competitions")


def _validate(body) -> dict:
    if not isinstance(body, dict):
        raise validation("body")
    bad = [k for k in ("competition_id", "sport_id") if not is_id(body.get(k))]
    for k in ("name", "season"):
        if not (isinstance(body.get(k), str) and 1 <= len(body[k].strip()) <= 120):
            bad.append(k)
    fmt = body.get("format")
    if fmt not in ("divisions", "hybrid"):
        bad.append("format")
    stages = body.get("stages")
    if not (isinstance(stages, list) and 2 <= len(stages) <= 8 and all(
            isinstance(s, dict) and is_id(s.get("league_id")) and isinstance(s.get("teams"), list)
            and 2 <= len(s["teams"]) <= 40 for s in stages)):
        bad.append("stages")
        stages = None
    if stages:
        teams = [t for s in stages for t in s["teams"]]
        if not all(is_id(t) for t in teams) or len(set(teams)) != len(teams):
            bad.append("stages")  # a team plays in exactly one division / group
    smallest = min(len(s["teams"]) for s in stages) if stages else 2
    rules = {}
    keys = ("promotion_spots", "relegation_spots") if fmt == "divisions" else ("advance_per_group",)
    for k in keys:
        if not is_int(body.get(k), 1, smallest - 1 if fmt == "divisions" else smallest):
            bad.append(k)
        else:
            rules[k] = body[k]
    if bad:
        raise validation(sorted(set(bad)), "Invalid competition")
    return {**body, "rules": rules}


@router.post("/api/v1/competitions", status_code=201)
async def create_competition(request: Request, user: dict = Depends(auth.current_user)):
    # Spec FR-1.2: "Admins configure" league structures.
    if user["role"] != "super_admin":
        raise auth.forbidden("Only the platform admin can set up competitions")
    body = _validate(await read_json(request))
    tenant_id = body.get("tenant_id")  # None = visible to every tenant, like audit-registered leagues
    if tenant_id is not None and not is_id(tenant_id):
        raise validation("tenant_id")
    with pool.connection() as conn:
        sports.get_sport(body["sport_id"], conn)  # 404 SPORT_NOT_FOUND
        if conn.execute("SELECT 1 FROM competitions WHERE competition_id = %s",
                        (body["competition_id"],)).fetchone():
            raise conflict("COMPETITION_EXISTS", competition_id=body["competition_id"])
        spots = body["rules"].get("promotion_spots") or body["rules"]["advance_per_group"]
        for stage in body["stages"]:
            league_id = stage["league_id"]
            pairs = [p for rnd in fixtures.circle_rounds(list(stage["teams"])) for p in rnd if None not in p]
            scoring.register_league(conn, {
                "league_id": league_id, "sport_id": body["sport_id"], "teams": stage["teams"],
                "fixtures": [{"match_id": f"{league_id}-m{i + 1}", "home": h, "away": a}
                             for i, (h, a) in enumerate(pairs)],
                "qualification": {"spots": spots}}, tenant_id=tenant_id, name=stage.get("name") or league_id)
        conn.execute("INSERT INTO competitions VALUES (%s, %s, %s, %s, %s, %s, %s, %s)", (
            body["competition_id"], tenant_id, body["name"].strip(), body["season"].strip(), body["sport_id"],
            body["format"], Jsonb([{"league_id": s["league_id"], "name": s.get("name") or s["league_id"]}
                                   for s in body["stages"]]), Jsonb(body["rules"])))
        return view(conn, body["competition_id"], user)


def _stage(conn, stage: dict) -> dict:
    table = standings.compute(conn, stage["league_id"])["table"]
    matches = conn.execute("SELECT * FROM scoring_matches WHERE league_id = %s", (stage["league_id"],)).fetchall()
    done = all(scoring.project_state(m, scoring.match_sport(conn, m), scoring.load_events(conn, m["match_id"]))
               ["status"] in FINAL for m in matches)
    return {**stage, "complete": done, "table": [{k: r[k] for k in ("rank", "team_id", "played", "points")}
                                                 for r in table]}


def view(conn, competition_id: str, user: dict) -> dict:
    comp = conn.execute("SELECT * FROM competitions WHERE competition_id = %s", (competition_id,)).fetchone()
    if not comp:
        raise not_found("COMPETITION_NOT_FOUND", competition_id=competition_id)
    if user["role"] != "super_admin" and comp["tenant_id"] not in (None, user.get("tenant_id")):
        raise auth.forbidden("This competition belongs to another tenant")
    stages = [_stage(conn, s) for s in comp["stages"]]
    rules = comp["rules"]
    result = {k: comp[k] for k in ("competition_id", "name", "season", "sport_id", "format", "rules")}
    result["provisional"] = not all(s["complete"] for s in stages)
    if comp["format"] == "divisions":
        moves = []
        for upper, lower in zip(stages, stages[1:]):
            moves += [{"team_id": r["team_id"], "type": "relegated", "from_league_id": upper["league_id"],
                       "to_league_id": lower["league_id"]} for r in upper["table"][-rules["relegation_spots"]:]]
            moves += [{"team_id": r["team_id"], "type": "promoted", "from_league_id": lower["league_id"],
                       "to_league_id": upper["league_id"]} for r in lower["table"][:rules["promotion_spots"]]]
        return {**result, "divisions": stages, "movements": moves}
    k = rules["advance_per_group"]
    seeds = [g["table"][rank]["team_id"] for rank in range(k) for g in stages]
    return {**result, "groups": stages, "qualifiers": seeds,
            "knockout": fixtures.generate_single_elim(seeds, {})}


@router.get("/api/v1/competitions/{competition_id}")
def get_competition(competition_id: str, user: dict = Depends(auth.current_user)):
    with pool.connection() as conn:
        return view(conn, competition_id, user)
