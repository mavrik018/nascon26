"""FR-1.3: match status changes and manual rescheduling with conflict detection.

Status changes are `status_change` events in the scoring log (scoring.STATUS_TRANSITIONS
rejects illegal ones), so they are event-sourced and reach /matches/{id}/stream clients
like any other event. A reschedule is checked for venue double-booking, team overlap,
player overlap across squads, minimum rest and venue opening hours; every conflict is
returned together in one 409 SCHEDULE_CONFLICT naming the conflicting ids."""
import datetime
import uuid

from fastapi import APIRouter, Depends, Request

from .. import auth
from ..db import pool
from ..errors import ApiError, not_found, validation
from . import roster, scoring
from .util import is_id, read_json

router = APIRouter()

SCHEMA = """
ALTER TABLE scoring_matches ADD COLUMN IF NOT EXISTS venue_id TEXT;
CREATE TABLE IF NOT EXISTS schedule_venues (
    venue_id TEXT PRIMARY KEY,
    name     TEXT NOT NULL,
    opens    TIME NOT NULL,    -- availability window, UTC
    closes   TIME NOT NULL
);
"""

# shortcut: fixed slot and rest for every sport, move into the sport/league config if Part II asks for it
SLOT = datetime.timedelta(hours=3)
MIN_REST = datetime.timedelta(hours=24)
INACTIVE = {"postponed", "cancelled", "abandoned"}

# Hours are UTC: Alpha Arena 08:00-24:00 PKT, Rovers Ground 10:00-23:00 PKT.
DEMO_VENUES = [("alpha-arena", "Alpha Arena", "03:00", "19:00", "club-alpha-1"),
               ("rovers-ground", "Rovers Ground", "05:00", "18:00", "club-alpha-2")]


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM schedule_venues")
    for venue_id, name, opens, closes, home_club in DEMO_VENUES:
        conn.execute("INSERT INTO schedule_venues VALUES (%s, %s, %s, %s)", (venue_id, name, opens, closes))
        conn.execute("UPDATE scoring_matches SET venue_id = %s WHERE home = %s", (venue_id, home_club))


def _parse_when(value):
    """ISO-8601 UTC timestamp ending in Z -> aware datetime, or None."""
    if not isinstance(value, str) or not value.endswith("Z"):
        return None
    try:
        return datetime.datetime.fromisoformat(value)
    except ValueError:
        return None


def _status(conn, match) -> str:
    return scoring.project_state(match, scoring.match_sport(conn, match),
                                 scoring.load_events(conn, match["match_id"]))["status"]


def find_conflicts(conn, match: dict, when: datetime.datetime, venue_id: str | None) -> list[dict]:
    conflicts = []
    if venue_id:
        venue = conn.execute("SELECT * FROM schedule_venues WHERE venue_id = %s", (venue_id,)).fetchone()
        if not venue:
            raise not_found("VENUE_NOT_FOUND", venue_id=venue_id)
        end = when + SLOT
        if not (end.date() == when.date() and venue["opens"] <= when.time() and end.time() <= venue["closes"]):
            conflicts.append({"type": "venue_unavailable", "venue_id": venue_id,
                              "opens": venue["opens"].strftime("%H:%MZ"), "closes": venue["closes"].strftime("%H:%MZ")})
    teams = {match["home"], match["away"]}
    day = when.date()
    players = {(p["player_id"], t) for t in teams for p in roster._club_roster(conn, t, day)}
    # shortcut: scans every scheduled match, add a time-range index if match counts reach the thousands
    for other in conn.execute("SELECT * FROM scoring_matches WHERE match_id <> %s AND scheduled_at IS NOT NULL"
                              " ORDER BY created_seq",
                              (match["match_id"],)).fetchall():
        other_when = _parse_when(other["scheduled_at"])
        if other_when is None or abs(other_when - when) >= MIN_REST or _status(conn, other) in INACTIVE:
            continue
        overlaps = abs(other_when - when) < SLOT
        mid = other["match_id"]
        if overlaps and venue_id and other["venue_id"] == venue_id:
            conflicts.append({"type": "venue_double_booking", "match_id": mid, "venue_id": venue_id})
        for team in sorted(teams & {other["home"], other["away"]}):
            conflicts.append({"type": "team_overlap" if overlaps else "rest_period", "match_id": mid, "team_id": team,
                              "hours_apart": round(abs(other_when - when).total_seconds() / 3600, 1)})
        if overlaps:  # one player registered in two different squads (a shared squad is a team overlap)
            other_players = {(p["player_id"], t) for t in (other["home"], other["away"])
                             for p in roster._club_roster(conn, t, day)}
            conflicts += [{"type": "player_overlap", "match_id": mid, "player_id": pid}
                          for pid in sorted({pid for pid, t in players for qid, u in other_players
                                             if pid == qid and t != u})]
    return conflicts


def _editable_match(conn, match_id: str, user: dict) -> dict:
    match = scoring.load_match(conn, match_id)
    if not match:
        raise not_found("MATCH_NOT_FOUND", match_id=match_id)
    if not scoring.can_score(user, match["league_id"]):
        raise auth.forbidden("Only the league organizer can change this match")
    return match


def _status_event(conn, match_id: str, status: str, reason: str) -> dict:
    return scoring.append_event(conn, {"event_id": str(uuid.uuid4()), "match_id": match_id,
                                       "type": "status_change", "payload": {"status": status, "reason": reason}},
                                rescheduled=status == "upcoming")[1]


@router.post("/api/v1/matches/{match_id}/status")
async def change_status(match_id: str, request: Request, user: dict = Depends(auth.current_user)):
    body = await read_json(request)
    if not isinstance(body, dict) or body.get("status") not in ("postponed", "abandoned", "cancelled"):
        raise validation("status", "status must be postponed, abandoned or cancelled")
    reason = body.get("reason") or ""
    if not isinstance(reason, str) or len(reason) > 500:
        raise validation("reason")
    with pool.connection() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("match:" + match_id,))
        match = _editable_match(conn, match_id, user)
        if _status(conn, match) == body["status"]:  # a repeated tap is not an error
            return {"match_id": match_id, "status": body["status"], "event": None}
        event = _status_event(conn, match_id, body["status"], reason)
    return {"match_id": match_id, "status": body["status"], "event": event}


@router.post("/api/v1/matches/{match_id}/reschedule")
async def reschedule(match_id: str, request: Request, user: dict = Depends(auth.current_user)):
    body = await read_json(request)
    if not isinstance(body, dict):
        raise validation("body")
    when = _parse_when(body.get("scheduled_at"))
    venue_id = body.get("venue_id")
    bad = ([] if when else ["scheduled_at"]) + ([] if venue_id is None or is_id(venue_id) else ["venue_id"])
    if bad:
        raise validation(bad)
    with pool.connection() as conn:
        # One schedule-wide lock, taken before reading: two reschedules checked in parallel could each
        # miss the other's new slot.
        conn.execute("SELECT pg_advisory_xact_lock(hashtext('schedule'))")
        match = _editable_match(conn, match_id, user)
        status = _status(conn, match)
        if status not in ("upcoming", "postponed"):
            raise ApiError(409, "ILLEGAL_TRANSITION", f"Cannot reschedule a match that is {status}",
                           {"match_id": match_id, "status": status})
        venue_id = venue_id or match["venue_id"]
        conflicts = find_conflicts(conn, match, when, venue_id)
        if conflicts:
            raise ApiError(409, "SCHEDULE_CONFLICT", "The new time clashes with other fixtures",
                           {"match_id": match_id, "conflicts": conflicts})
        conn.execute("UPDATE scoring_matches SET scheduled_at = %s, venue_id = %s WHERE match_id = %s",
                     (when.strftime("%Y-%m-%dT%H:%M:%SZ"), venue_id, match_id))
        if status == "postponed":
            _status_event(conn, match_id, "upcoming", "rescheduled")
    return {"match_id": match_id, "status": "upcoming", "scheduled_at": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "venue_id": venue_id}
