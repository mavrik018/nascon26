"""Part II FR-5.2: notification bus (SSE + WebSocket) with bounded retry and the dead-letter queue.

publish() stores every event in `notifications`, then "delivers" it through moderation_dlq.deliver()
(max 3 attempts, exponential backoff). A failed delivery (simulate_dlq, or a downstream error) parks it in
notification_dlq and marks the row undelivered, so subscribers never see it.
Subscribers poll the table every POLL_SECONDS, so delivery works across workers and processes.

Topics: match:<id> and costream:<id> are public; player:<id> needs that player's JWT (or super_admin);
anything else (order:<id>, ...) needs any member JWT."""
import asyncio
import json

from fastapi import APIRouter, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import StreamingResponse
from psycopg.types.json import Jsonb
from starlette.concurrency import run_in_threadpool

from ..auth import decode_token, forbidden, unauthenticated
from ..db import pool
from ..errors import ApiError, validation
from . import day2, moderation_dlq
from .util import is_id, read_json

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS notifications (
    id         BIGSERIAL PRIMARY KEY,
    topic      TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload    JSONB NOT NULL,
    delivered  BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notifications_topic_id ON notifications (topic, id);
"""

POLL_SECONDS = 0.2
PUBLIC_PREFIXES = ("match", "costream")


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("TRUNCATE notifications RESTART IDENTITY")


def _unreachable_subscriber(_payload):
    raise ConnectionError("simulated disconnected subscriber / downstream push failure")


def publish(conn, topic: str, event_type: str, payload: dict, simulate_dlq: bool = False) -> bool:
    """Store + deliver one event; returns True when delivered (False = it is in the DLQ).
    Runs in a savepoint so a failure here never poisons the caller's transaction."""
    with conn.transaction():
        nid = conn.execute("INSERT INTO notifications (topic, event_type, payload) VALUES (%s, %s, %s) RETURNING id",
                           (topic, event_type, Jsonb(payload))).fetchone()["id"]
        # Live subscribers read committed rows, so a successful send is a no-op here.
        send = _unreachable_subscriber if simulate_dlq else (lambda _p: None)
        ok = moderation_dlq.deliver(conn, event_type, {"topic": topic, "notification_id": nid, **payload}, send,
                                    sleep=lambda _s: None)
        if not ok:
            conn.execute("UPDATE notifications SET delivered = FALSE WHERE id = %s", (nid,))
    return ok


def publish_score(conn, match_id: str) -> bool:
    """Live score update for match:<id> (the caller wires it to score changes)."""
    from .realtime import public_match
    return publish(conn, f"match:{match_id}", "score_update", public_match(conn, match_id))


# --------------------------------------------------------------------------- subscribers

def authorize(topic: str, token: str | None) -> None:
    prefix, _, ident = topic.partition(":")
    if not is_id(topic) or not ident:
        raise validation("topic")
    if prefix in PUBLIC_PREFIXES:
        return
    if token is None or day2.is_guest_token(token):
        raise unauthenticated()
    claims = decode_token(token)
    if prefix == "player" and claims.get("role") != "super_admin" and claims.get("player_id") != ident:
        raise forbidden("This topic belongs to another player")


def _token(conn_obj) -> str | None:
    """Bearer header, or ?token= for EventSource / browser WebSocket clients that cannot set headers."""
    return day2.bearer(conn_obj) or conn_obj.query_params.get("token") or None


def _start_after(topic: str, after: str | None) -> int:
    if after is not None and after.isdigit():
        return int(after)
    with pool.connection() as conn:
        return conn.execute("SELECT COALESCE(MAX(id), 0) AS m FROM notifications WHERE topic = %s",
                            (topic,)).fetchone()["m"]


def _fetch(topic: str, after: int) -> list[dict]:
    with pool.connection() as conn:
        return conn.execute("SELECT id, event_type, payload FROM notifications WHERE topic = %s AND id > %s"
                            " AND delivered ORDER BY id LIMIT 100", (topic, after)).fetchall()


async def sse_events(topic: str, last: int, request):
    idle = 0.0
    while not await request.is_disconnected():
        rows = await run_in_threadpool(_fetch, topic, last)
        for r in rows:
            last = r["id"]
            yield f"id: {r['id']}\nevent: {r['event_type']}\ndata: {json.dumps(r['payload'])}\n\n"
        idle = 0.0 if rows else idle + POLL_SECONDS
        if idle >= 15:
            idle = 0.0
            yield ": keep-alive\n\n"
        await asyncio.sleep(POLL_SECONDS)


@router.get("/api/v1/notifications/stream")
async def notification_stream(request: Request, topic: str = ""):
    authorize(topic, _token(request))
    after = request.headers.get("last-event-id") or request.query_params.get("after")
    last = await run_in_threadpool(_start_after, topic, after)
    return StreamingResponse(sse_events(topic, last, request), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@router.websocket("/ws/notifications")
async def notification_socket(websocket: WebSocket):
    topic = websocket.query_params.get("topic", "")
    try:
        authorize(topic, _token(websocket))
        last = await run_in_threadpool(_start_after, topic, websocket.query_params.get("after"))
    except ApiError as e:
        await websocket.close(code=4000 + e.status)
        return
    await websocket.accept()
    try:
        while True:
            for r in await run_in_threadpool(_fetch, topic, last):
                last = r["id"]
                await websocket.send_json({"id": r["id"], "event": r["event_type"], "data": r["payload"]})
            await asyncio.sleep(POLL_SECONDS)
    except (WebSocketDisconnect, RuntimeError):
        pass


# --------------------------------------------------------------------------- audit probe

def _probe(body) -> dict:
    if not isinstance(body, dict):
        raise validation("body")
    bad = [k for k in ("topic", "event_type") if not is_id(body.get(k))]
    payload, simulate = body.get("payload", {}), body.get("simulate_dlq", False)
    bad += ([] if isinstance(payload, dict) else ["payload"]) + ([] if isinstance(simulate, bool) else ["simulate_dlq"])
    if bad:
        raise validation(bad)
    with pool.connection() as conn:
        ok = publish(conn, body["topic"], body["event_type"], payload, simulate_dlq=simulate)
        depth = moderation_dlq.dlq_status(conn)["queue_depth"]
    return {"delivered": ok, "attempts": 1 if ok else moderation_dlq.MAX_ATTEMPTS, "dlq_depth": depth}


@router.post("/audit/v1/notifications/test")
async def notifications_test(request: Request):
    return await run_in_threadpool(_probe, await read_json(request))
