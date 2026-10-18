"""Part II FR-5.2: notification bus, bounded retry, DLQ, SSE / WebSocket subscribers, order events."""
import asyncio

import pytest

from test_store import _status, order

PROBE = "/audit/v1/notifications/test"


def test_probe_delivers_and_dlq_after_three_attempts(api):
    api.reset()
    r = api.post(PROBE, json={"topic": "match:match-m1", "event_type": "score_update", "payload": {"x": 1}})
    assert r.status_code == 200 and r.json() == {"delivered": True, "attempts": 1, "dlq_depth": 0}, r.text
    r = api.post(PROBE, json={"topic": "player:player-alpha-1", "event_type": "costream_invite", "payload": {},
                              "simulate_dlq": True})
    assert r.json() == {"delivered": False, "attempts": 3, "dlq_depth": 1}
    dlq = api.post("/audit/v1/moderation/test", json={"chat_room_id": "chat-x", "incoming_messages": []}).json()
    assert dlq["dlq_status"]["undelivered_events"][0]["attempts"] == 3
    assert api.post(PROBE, json={"topic": "bad topic", "event_type": "x"}).status_code == 400


@pytest.mark.in_process
def test_sse_stream_yields_published_event_but_not_dead_letters(api):
    from app.db import pool
    from app.modules import notify
    api.reset()
    with pool.connection() as conn:
        assert notify.publish(conn, "match:match-m1", "lost", {}, simulate_dlq=True) is False
        assert notify.publish_score(conn, "match-m1") is True

    class Live:
        async def is_disconnected(self):
            return False

    async def first():
        gen = notify.sse_events("match:match-m1", 0, Live())
        try:
            return await gen.__anext__()
        finally:
            await gen.aclose()

    chunk = asyncio.run(first())
    assert chunk.startswith("id: 2\nevent: score_update\ndata: ") and '"score_text": "1 - 0"' in chunk


@pytest.mark.in_process
def test_websocket_receives_new_event_and_private_topic_needs_owner(api):
    from starlette.websockets import WebSocketDisconnect
    api.reset()
    with api.client.websocket_connect("/ws/notifications?topic=costream:cs-9") as ws:
        api.post(PROBE, json={"topic": "costream:cs-9", "event_type": "costream_control", "payload": {"a": 1}})
        assert ws.receive_json()["data"] == {"a": 1}
    with pytest.raises(WebSocketDisconnect):
        with api.client.websocket_connect("/ws/notifications?topic=player:player-alpha-1") as ws:
            ws.receive_json()
    r = api.get("/api/v1/notifications/stream?topic=player:player-alpha-2",
                headers={"Authorization": "Bearer " + _token(api)})
    assert r.status_code == 403


def _token(api):
    return api.post("/api/v1/auth/login", json={"email": "player@nascon.test", "password": "Nascon@26"}).json()["token"]


@pytest.mark.in_process
def test_order_status_change_publishes_notification(api):
    from app.db import pool
    api.reset()
    assert api.post("/audit/v1/checkout", json=order(order_id="ord-n1")).status_code == 201
    assert _status(api, "ord-n1", "packed").status_code == 200
    with pool.connection() as conn:
        rows = conn.execute("SELECT event_type, payload FROM notifications WHERE topic = 'order:ord-n1'").fetchall()
    assert [(r["event_type"], r["payload"]) for r in rows] == \
        [("order_status", {"order_id": "ord-n1", "status": "packed", "previous": "paid"})]
