"""Part II realtime + guest read surface.

* GET  /api/v1/public/guest-token          -> issue an anonymous read-only guest token (FR-4.2)
* GET  /api/v1/public/matches/{id}         -> match view for the Guest Web Player (no login wall)
* GET  /api/v1/public/matches/{id}/stream  -> SSE: same body on every change (score, status, pin)
* WS   /ws/matches/{id}                    -> WebSocket push of the same body (NFR-1, p95 < 500 ms)

Change detection polls a cheap fingerprint (event count + status columns) every POLL_SECONDS, well inside
the 500 ms budget; the full view is rebuilt only when the fingerprint changes."""
import asyncio
import json
import secrets

from fastapi import APIRouter, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import StreamingResponse
from starlette.concurrency import run_in_threadpool

from ..db import pool
from ..errors import not_found
from . import scoring

router = APIRouter()

SCHEMA = ""
POLL_SECONDS = 0.2

_ws_connections = 0


def active_ws_connections() -> int:
    """Read by /metrics (nascon_active_ws_connections)."""
    return _ws_connections


def reset(conn, seed: int, body: dict) -> None:
    pass


def _fingerprint(conn, match_id: str):
    return conn.execute(
        "SELECT (SELECT count(*) FROM scoring_events WHERE match_id = %(m)s) AS n, m.pinned_product_id, "
        "m.scheduled_at FROM scoring_matches m WHERE m.match_id = %(m)s", {"m": match_id}).fetchone()


def public_match(conn, match_id: str) -> dict:
    match = scoring.load_match(conn, match_id)
    if not match:
        raise not_found("MATCH_NOT_FOUND", match_id=match_id)
    p = scoring.build_projection(match, scoring.match_sport(conn, match), scoring.load_events(conn, match_id))
    pinned = None
    if match["pinned_product_id"]:
        from .store import PRICE_SQL
        row = conn.execute(
            f"SELECT p.product_id, p.name, v.variant_id, {PRICE_SQL} AS price_minor FROM store_products p "
            "JOIN store_variants v USING (product_id) WHERE p.product_id = %s AND NOT p.archived "
            "ORDER BY v.stock DESC, v.variant_id DESC LIMIT 1", (match["pinned_product_id"],)).fetchone()
        if row:
            pinned = {**row, "currency": "PKR"}
    return {
        "match_id": match_id, "status": p["status"], "league_id": match["league_id"],
        "home": {"team_id": p["home"]["team_id"], "score": p["home"]["score"]},
        "away": {"team_id": p["away"]["team_id"], "score": p["away"]["score"]},
        "score_text": f"{p['home']['score']} - {p['away']['score']}",
        "version": p["version"],
        "playback_url": f"http://localhost:8888/matches/{match_id}/index.m3u8",
        "pinned_product": pinned,
        "chat_room_id": f"chat-{match_id}",
    }


def _snapshot(match_id: str):
    with pool.connection() as conn:
        return _fingerprint(conn, match_id), public_match(conn, match_id)


def _changed_view(match_id: str, last):
    with pool.connection() as conn:
        fp = _fingerprint(conn, match_id)
        if fp == last:
            return fp, None
        return fp, public_match(conn, match_id)


@router.get("/api/v1/public/guest-token")
def guest_token():
    token = "guest_anon_tok_" + secrets.token_hex(8)
    with pool.connection() as conn:
        conn.execute("INSERT INTO guest_tokens (guest_token) VALUES (%s)", (token,))
    return {"guest_token": token, "scope": "read_only"}


@router.get("/api/v1/public/matches/{match_id}")
def public_match_route(match_id: str):
    with pool.connection() as conn:
        return public_match(conn, match_id)


@router.get("/api/v1/public/matches/{match_id}/stream")
async def public_match_stream(match_id: str, request: Request):
    fp, first = await run_in_threadpool(_snapshot, match_id)  # 404 before the stream opens

    async def events():
        nonlocal fp
        yield f"event: match\ndata: {json.dumps(first)}\n\n"
        idle = 0.0
        while not await request.is_disconnected():
            await asyncio.sleep(POLL_SECONDS)
            fp, view = await run_in_threadpool(_changed_view, match_id, fp)
            if view is not None:
                idle = 0.0
                yield f"event: match\ndata: {json.dumps(view)}\n\n"
            else:
                idle += POLL_SECONDS
                if idle >= 15:
                    idle = 0.0
                    yield ": keep-alive\n\n"

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@router.websocket("/ws/matches/{match_id}")
async def match_socket(websocket: WebSocket, match_id: str):
    global _ws_connections
    try:
        fp, view = await run_in_threadpool(_snapshot, match_id)
    except Exception:
        await websocket.close(code=4404)
        return
    await websocket.accept()
    _ws_connections += 1
    try:
        await websocket.send_json(view)
        while True:
            await asyncio.sleep(POLL_SECONDS)
            fp, changed = await run_in_threadpool(_changed_view, match_id, fp)
            if changed is not None:
                await websocket.send_json(changed)
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        _ws_connections -= 1
