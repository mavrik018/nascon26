"""Part II FR-3.3: co-stream host moderation controls.

* POST /api/v1/costream/{sid}/invites   host (or super_admin) issues a signed single-use invite for a player
* POST /api/v1/costream/{sid}/join      the invited player redeems it (max 4 broadcasters)
* POST /api/v1/costream/{sid}/controls  host mutes / unmutes / spotlights / kicks a participant
* GET  /api/v1/public/costream/{sid}/state  controls state, no auth

active_participants lives only in costream_sessions.response (one source of truth); this module keeps
muted / spotlight / kicked in costream_controls. The audience chat is the single room chat-{sid}
(moderation_dlq.chat_messages gives it a per-room monotonically increasing seq)."""
import datetime
import secrets

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from psycopg.types.json import Jsonb
from starlette.concurrency import run_in_threadpool

from ..auth import current_user, forbidden
from ..db import pool
from ..errors import conflict, not_found, validation
from ..signing import sign_day2
from . import day2, notify
from .costream import MAX_PARTICIPANTS
from .util import is_id, read_json

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS costream_invites (
    invite_token TEXT PRIMARY KEY,
    session_id   TEXT NOT NULL,
    player_id    TEXT NOT NULL,
    expires_at   TIMESTAMPTZ NOT NULL,
    used         BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE IF NOT EXISTS costream_controls (
    session_id TEXT PRIMARY KEY,
    state      JSONB NOT NULL
);
"""

INVITE_TTL = datetime.timedelta(hours=1)
ACTIONS = ("mute", "unmute", "spotlight", "kick")


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM costream_invites")
    conn.execute("DELETE FROM costream_controls")


def _session(conn, sid: str) -> dict:
    row = conn.execute("SELECT response FROM costream_sessions WHERE session_id = %s FOR UPDATE", (sid,)).fetchone()
    if row is None:
        raise not_found("STREAM_NOT_FOUND", session_id=sid)
    return row["response"]


def _controls(conn, sid: str) -> dict:
    row = conn.execute("SELECT state FROM costream_controls WHERE session_id = %s", (sid,)).fetchone()
    return {"muted": [], "spotlight": None, "kicked": [], **(row["state"] if row else {})}


def _view(sid: str, session: dict, ctl: dict) -> dict:
    return {"session_id": sid, "muted": ctl["muted"], "spotlight": ctl["spotlight"],
            "active_participants": session["active_participants"], "kicked": ctl["kicked"],
            "chat_room_id": f"chat-{sid}"}


def _save_participants(conn, sid: str, session: dict, parts: list) -> None:
    """Rewrite active_participants (and the costream signature that covers participant_count)."""
    session.update(active_participants=parts, participant_count=len(parts))
    signed = {k: session[k] for k in ("active_host", "handoff_occurred", "layout", "participant_count",
                                      "session_id", "status")}
    session["signature"] = sign_day2(sid, signed)
    conn.execute("UPDATE costream_sessions SET response = %s WHERE session_id = %s", (Jsonb(session), sid))


def _require_host(claims: dict, session: dict) -> None:
    if claims.get("role") != "super_admin" and (
            not claims.get("player_id") or claims.get("player_id") != session.get("active_host")):
        raise forbidden("Only the session's active host can do this")


def _player_body(body) -> str:
    if not isinstance(body, dict) or not is_id(body.get("player_id")):
        raise validation("player_id")
    return body["player_id"]


def invite(sid: str, claims: dict, body) -> dict:
    pid = _player_body(body)
    with pool.connection() as conn:
        session = _session(conn, sid)
        _require_host(claims, session)
        day2.require_player(conn, pid)
        token = "inv_" + secrets.token_hex(12)
        expires = (datetime.datetime.now(datetime.timezone.utc) + INVITE_TTL).replace(microsecond=0)
        conn.execute("INSERT INTO costream_invites (invite_token, session_id, player_id, expires_at)"
                     " VALUES (%s, %s, %s, %s)", (token, sid, pid, expires))
        out = {"session_id": sid, "player_id": pid, "invite_token": token,
               "expires_at": expires.isoformat().replace("+00:00", "Z"),
               "signature": sign_day2(token, {"invite_token": token, "player_id": pid, "session_id": sid})}
        notify.publish(conn, f"player:{pid}", "costream_invite", out)
    return out


def join(sid: str, claims: dict, body) -> dict:
    token = body.get("invite_token") if isinstance(body, dict) else None
    if not isinstance(token, str) or not token:
        raise validation("invite_token")
    with pool.connection() as conn:
        session = _session(conn, sid)
        inv = conn.execute("SELECT player_id FROM costream_invites WHERE invite_token = %s AND session_id = %s"
                           " AND NOT used AND expires_at > now() FOR UPDATE", (token, sid)).fetchone()
        if inv is None:
            raise forbidden("Invite token is invalid, expired or already used")
        pid = inv["player_id"]
        if claims.get("role") != "super_admin" and claims.get("player_id") != pid:
            raise forbidden("Invite belongs to another player")
        ctl = _controls(conn, sid)
        if pid in ctl["kicked"]:
            raise forbidden("Player was kicked from this session")
        parts = list(session["active_participants"])
        if pid not in parts:
            if len(parts) >= MAX_PARTICIPANTS:
                raise conflict("COSTREAM_SESSION_FULL", "Co-streaming supports at most 4 broadcasters",
                               max_participants=MAX_PARTICIPANTS, participant_count=len(parts))
            _save_participants(conn, sid, session, parts + [pid])
        conn.execute("UPDATE costream_invites SET used = TRUE WHERE invite_token = %s", (token,))
        view = _view(sid, session, ctl)
        notify.publish(conn, f"costream:{sid}", "costream_join", {"player_id": pid, **view})
    return view


def control(sid: str, claims: dict, body) -> dict:
    pid = _player_body(body)
    action = body.get("action")
    if action not in ACTIONS:
        raise validation("action")
    with pool.connection() as conn:
        session = _session(conn, sid)
        _require_host(claims, session)
        parts = list(session["active_participants"])
        if pid not in parts:
            raise validation("player_id", "player_id is not an active participant")
        ctl = _controls(conn, sid)
        if action == "mute" and pid not in ctl["muted"]:
            ctl["muted"].append(pid)
        elif action == "unmute":
            ctl["muted"] = [p for p in ctl["muted"] if p != pid]
        elif action == "spotlight":
            ctl["spotlight"] = pid
        elif action == "kick":
            if pid == session.get("active_host"):
                raise validation("player_id", "the active host cannot be kicked")
            ctl["muted"] = [p for p in ctl["muted"] if p != pid]
            ctl["spotlight"] = None if ctl["spotlight"] == pid else ctl["spotlight"]
            if pid not in ctl["kicked"]:
                ctl["kicked"].append(pid)
            _save_participants(conn, sid, session, [p for p in parts if p != pid])
        conn.execute("INSERT INTO costream_controls (session_id, state) VALUES (%s, %s)"
                     " ON CONFLICT (session_id) DO UPDATE SET state = EXCLUDED.state", (sid, Jsonb(ctl)))
        view = _view(sid, session, ctl)
        notify.publish(conn, f"costream:{sid}", "costream_control", {"action": action, "player_id": pid, **view})
    return view


def _member(request: Request) -> dict:
    token = day2.bearer(request)
    if day2.is_guest_token(token):
        raise day2.guest_forbidden(token)
    return current_user(request)


@router.post("/api/v1/costream/{session_id}/invites")
async def invite_route(session_id: str, request: Request):
    claims = _member(request)
    out = await run_in_threadpool(invite, session_id, claims, await read_json(request))
    return JSONResponse(out, status_code=201)


@router.post("/api/v1/costream/{session_id}/join")
async def join_route(session_id: str, request: Request):
    claims = _member(request)
    return await run_in_threadpool(join, session_id, claims, await read_json(request))


@router.post("/api/v1/costream/{session_id}/controls")
async def control_route(session_id: str, request: Request):
    claims = _member(request)
    return await run_in_threadpool(control, session_id, claims, await read_json(request))


@router.get("/api/v1/public/costream/{session_id}/state")
def public_state(session_id: str):
    with pool.connection() as conn:
        row = conn.execute("SELECT response FROM costream_sessions WHERE session_id = %s", (session_id,)).fetchone()
        if row is None:
            raise not_found("STREAM_NOT_FOUND", session_id=session_id)
        return _view(session_id, row["response"], _controls(conn, session_id))
