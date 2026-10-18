"""Part II: 4-way co-stream orchestration and host handoff (spec 5.5).

Rules are checked in the spec's exact order: schema (400) -> players exist (404) /
host in participants (400) -> capacity (409) -> layout fit (400) -> handoff.
A session_id replayed with an identical request returns the stored response (200);
a different request for the same session_id is re-evaluated and replaces it (201)."""
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from psycopg.types.json import Jsonb

from ..db import pool
from ..errors import ApiError, conflict, not_found, validation
from ..signing import canonical, sign_day2
from .day2 import player_exists
from .util import read_json

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS costream_sessions (
    session_id TEXT PRIMARY KEY,
    request    TEXT NOT NULL,       -- canonical request, for idempotency comparison
    response   JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""

LAYOUTS = ("solo", "grid_2", "grid_4", "spotlight")
LAYOUT_MAX = {"solo": 1, "grid_2": 2}
MAX_PARTICIPANTS = 4


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM costream_sessions")


def _validate(body) -> dict:
    if not isinstance(body, dict):
        raise validation("body")
    bad = []
    if not isinstance(body.get("session_id"), str) or not body["session_id"]:
        bad.append("session_id")
    if not isinstance(body.get("host_player_id"), str) or not body["host_player_id"]:
        bad.append("host_player_id")
    parts = body.get("participants")
    if not (isinstance(parts, list) and parts and all(isinstance(p, str) and p for p in parts)
            and len(set(parts)) == len(parts)):
        bad.append("participants")
    drop = body.get("simulate_host_drop", False)
    if not isinstance(drop, bool):
        bad.append("simulate_host_drop")
    layout = body.get("layout", "grid_4")
    if layout not in LAYOUTS:
        bad.append("layout")
    if bad:
        raise validation(bad)
    return {"session_id": body["session_id"], "host_player_id": body["host_player_id"], "participants": parts,
            "simulate_host_drop": drop, "layout": layout}


def evaluate(req: dict) -> dict:
    """Rules 3-5 (pure): capacity, layout fit, deterministic host-drop handoff."""
    parts, host, layout = req["participants"], req["host_player_id"], req["layout"]
    if len(parts) > MAX_PARTICIPANTS:
        raise conflict("COSTREAM_SESSION_FULL", "Co-streaming supports at most 4 broadcasters",
                       max_participants=MAX_PARTICIPANTS, participant_count=len(parts))
    if not req["simulate_host_drop"]:
        active_host, handoff, active = host, False, list(parts)
    elif len(parts) >= 2:
        active = [p for p in parts if p != host]
        active_host, handoff = active[0], True
    else:
        active_host, handoff, active = None, False, []
    if len(active) > LAYOUT_MAX.get(layout, MAX_PARTICIPANTS):
        raise ApiError(400, "UNSUPPORTED_LAYOUT", f"Layout {layout} cannot fit {len(active)} active participants",
                       {"layout": layout, "participant_count": len(active)})
    sid = req["session_id"]
    status = "active" if active else "terminated"
    signed = {"active_host": active_host, "handoff_occurred": handoff, "layout": layout,
              "participant_count": len(active), "session_id": sid, "status": status}
    return {"session_id": sid, "status": status, "active_host": active_host, "handoff_occurred": handoff,
            "participant_count": len(active), "active_participants": active, "layout": layout,
            "composite_playback_url": f"http://localhost:8888/costream/{sid}/index.m3u8",
            "chat_room_id": f"chat-{sid}", "signature": sign_day2(sid, signed)}


@router.post("/audit/v1/costream/session", status_code=201)
async def costream_session(request: Request):
    req = _validate(await read_json(request))
    with pool.connection() as conn:
        for pid in [*req["participants"], req["host_player_id"]]:
            if not player_exists(conn, pid):
                raise not_found("PLAYER_NOT_FOUND", player_id=pid)
        if req["host_player_id"] not in req["participants"]:
            raise validation("host_player_id", "host_player_id must be one of participants")
        response = evaluate(req)
        key = canonical(req)
        conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("costream:" + req["session_id"],))
        row = conn.execute("SELECT request, response FROM costream_sessions WHERE session_id = %s",
                           (req["session_id"],)).fetchone()
        if row is not None and row["request"] == key:
            return JSONResponse(status_code=200, content=row["response"])
        conn.execute("""INSERT INTO costream_sessions (session_id, request, response) VALUES (%s, %s, %s)
                        ON CONFLICT (session_id) DO UPDATE SET request = EXCLUDED.request,
                        response = EXCLUDED.response, created_at = now()""",
                     (req["session_id"], key, Jsonb(response)))
    return JSONResponse(status_code=201, content=response)


@router.get("/api/v1/public/costream/{session_id}")
def public_costream(session_id: str):
    """Guest web page view: no auth, no signature."""
    with pool.connection() as conn:
        row = conn.execute("SELECT response FROM costream_sessions WHERE session_id = %s", (session_id,)).fetchone()
    if row is None:
        raise not_found("STREAM_NOT_FOUND", session_id=session_id)
    return {k: v for k, v in row["response"].items() if k != "signature"}
