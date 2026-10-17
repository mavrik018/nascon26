"""NFR-4 / spec 5.14: replay actions a device queued while offline.

Actions are processed in queued_at order (ties: array order), each in its own
transaction against the state left by the previous one, through the SAME code
as the online routes (scoring.append_event, roster.apply_transfer). Every
processed (device_id, action_id) is remembered, so re-sending a batch returns
`duplicate` for every action and changes nothing. Results come back in request
order; the request as a whole is always 200 unless the envelope is malformed."""
import re

from fastapi import APIRouter, Depends, Request
from psycopg.types.json import Jsonb

from .. import auth
from ..db import pool
from ..errors import ApiError, validation
from . import roster, scoring
from .util import is_id, is_int, read_json

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS sync_actions (
    device_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    result    JSONB NOT NULL,
    PRIMARY KEY (device_id, action_id)
);
"""

TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
ACTION_TYPES = {"score_event", "roster_transfer"}


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM sync_actions")


def _validate(body) -> dict:
    if not isinstance(body, dict):
        raise validation("body")
    bad = []
    if not is_id(body.get("device_id")):
        bad.append("device_id")
    actions = body.get("actions")
    if not isinstance(actions, list) or not 1 <= len(actions) <= 100:
        bad.append("actions")
    else:
        for i, a in enumerate(actions):
            if not isinstance(a, dict):
                bad.append(f"actions[{i}]")
                continue
            for field, ok in (("action_id", is_id(a.get("action_id"))),
                              ("type", a.get("type") in ACTION_TYPES),
                              ("queued_at", isinstance(a.get("queued_at"), str)
                               and bool(TIMESTAMP_RE.match(a["queued_at"]))),
                              ("base_version", is_int(a.get("base_version"), 0)),
                              ("payload", isinstance(a.get("payload"), dict))):
                if not ok:
                    bad.append(f"actions[{i}].{field}")
    if bad:
        raise validation(bad, "Malformed sync envelope")
    return body


def _result(action, status, resolution, error_code, order, version, signature=None) -> dict:
    return {"action_id": action["action_id"], "status": status, "resolution": resolution,
            "error_code": error_code, "processed_order": order, "server_version": version, "signature": signature}


def _rejected(action, code, order, version) -> dict:
    return _result(action, "rejected", "server_wins", code, order, version)


def _duplicate(action, order, version) -> dict:
    return _result(action, "duplicate", "skipped_duplicate", None, order, version)


def _current_version(conn, action) -> int | None:
    """Version of the entity the action touches, or None if it does not exist."""
    p = action["payload"]
    if action["type"] == "score_event":
        match_id = p.get("match_id")
        if not is_id(match_id) or not scoring.load_match(conn, match_id):
            return None
        return scoring.match_version(conn, match_id)
    player_id = p.get("player_id")
    if not is_id(player_id):
        return None
    try:
        return roster.player_version(conn, player_id)
    except ApiError:
        return None


def _apply(conn, action, order, user) -> dict:
    p, base = action["payload"], action["base_version"]
    current = _current_version(conn, action)

    if action["type"] == "score_event":
        try:
            scoring._validate_event(p)  # schema problems first (same order as the online route)
        except ApiError as e:
            return _rejected(action, e.code, order, current or 0)
        if current is None and p["type"] != "match_init":
            return _rejected(action, "MATCH_NOT_FOUND", order, 0)
        existing = scoring.find_event(conn, p["event_id"])
        if existing:
            if existing["request"] == scoring._request_key(p):
                return _duplicate(action, order, current or 0)
            return _rejected(action, "DUPLICATE_EVENT_ID", order, current or 0)
        if current is not None and base > current:
            return _rejected(action, "INVALID_BASE_VERSION", order, current)
        if user is not None:
            match = scoring.load_match(conn, p["match_id"])
            if not scoring.can_score(user, match["league_id"] if match else None):
                return _rejected(action, "FORBIDDEN", order, current or 0)
        try:
            with conn.transaction():
                status, response = scoring.append_event(conn, p)
        except ApiError as e:
            return _rejected(action, e.code, order, current or 0)
        if status == 200:
            return _duplicate(action, order, current or 0)
        resolution = "appended" if base == (current or 0) else "rebased_append"
        return _result(action, "applied", resolution, None, order, response["match_version"], response["signature"])

    # roster_transfer
    if current is not None and base > current:
        return _rejected(action, "INVALID_BASE_VERSION", order, current)
    if user is not None and user["role"] not in ("super_admin", "club_manager"):
        return _rejected(action, "FORBIDDEN", order, current or 0)
    try:
        with conn.transaction():
            status, _ = roster.apply_transfer(conn, p)
    except ApiError as e:
        return _rejected(action, e.code, order, current or 0)
    after = _current_version(conn, action) or 0
    if status == 200:
        return _duplicate(action, order, after)
    resolution = "appended" if base == (current or 0) else "rebased_append"
    return _result(action, "applied", resolution, None, order, after)


def process(body, user: dict | None = None) -> dict:
    body = _validate(body)
    device_id, actions = body["device_id"], body["actions"]
    processing = sorted(range(len(actions)), key=lambda i: (actions[i]["queued_at"], i))
    results: dict[int, dict] = {}
    for order, i in enumerate(processing, start=1):
        action = actions[i]
        with pool.connection() as conn:
            conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (f"sync:{device_id}:{action['action_id']}",))
            seen = conn.execute("SELECT result FROM sync_actions WHERE device_id = %s AND action_id = %s",
                                (device_id, action["action_id"])).fetchone()
            if seen:
                current = _current_version(conn, action)
                results[i] = _duplicate(action, order, current if current is not None
                                        else seen["result"]["server_version"])
                continue
            results[i] = _apply(conn, action, order, user)
            conn.execute("INSERT INTO sync_actions (device_id, action_id, result) VALUES (%s, %s, %s)",
                         (device_id, action["action_id"], Jsonb(results[i])))
    ordered = [results[i] for i in range(len(actions))]
    summary = {s: sum(1 for r in ordered if r["status"] == s) for s in ("applied", "rejected", "duplicate")}
    return {"device_id": device_id, "results": ordered, "summary": summary}


@router.post("/audit/v1/offline-sync")
async def offline_sync(request: Request):
    return process(await read_json(request))


@router.post("/api/v1/sync")
async def mobile_sync(request: Request, user: dict = Depends(auth.current_user)):
    return process(await read_json(request), user)
