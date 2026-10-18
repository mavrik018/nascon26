"""Part II realtime + guest read surface: guest token, public match view, WebSocket score push (NFR-1),
/web/* page routes."""
import time

import pytest


def test_guest_token_is_read_only(api):
    api.reset()
    token = api.get("/api/v1/public/guest-token").json()["guest_token"]
    assert token.startswith("guest_anon_tok_")
    r = api.post("/audit/v1/events", headers={"Authorization": f"Bearer {token}"}, json={})
    assert r.status_code == 403 and r.json()["error"]["code"] == "GUEST_WRITE_FORBIDDEN"


def test_public_match_view_without_login(api):
    api.reset()
    m = api.get("/api/v1/public/matches/match-m1").json()
    assert (m["status"], m["score_text"], m["chat_room_id"]) == ("in_progress", "1 - 0", "chat-match-m1")
    assert m["pinned_product"]["product_id"] == "prod-jersey-001"
    assert m["pinned_product"]["variant_id"] == "var-jersey-001-L"
    assert api.get("/api/v1/public/matches/ghost").status_code == 404


@pytest.mark.parametrize("path", ["/web/matches/match-m1/live", "/web/matches/match-m1/preview",
                                  "/web/matches/match-m1/vod", "/web/matches/match-m1/notice?state=postponed",
                                  "/web/costream/cs-session-101", "/web/players/player-alpha-1",
                                  "/web/clubs/club-alpha-1"])
def test_web_routes_serve_html(api, path):
    r = api.get(path)
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/html")


def test_web_rejects_unknown_view_and_traversal(api):
    assert api.get("/web/matches/match-m1/admin").status_code == 404
    assert api.get("/web/static/..%2F..%2Fmain.py").status_code == 404


@pytest.mark.in_process
def test_websocket_pushes_score_within_500ms(api):
    api.reset()
    with api.client.websocket_connect("/ws/matches/match-m1") as ws:
        assert ws.receive_json()["score_text"] == "1 - 0"
        start = time.monotonic()
        r = api.post("/audit/v1/events", json={"event_id": "ws-goal", "match_id": "match-m1", "type": "score",
                                               "payload": {"team_id": "club-alpha-2", "event_type": "goal"}})
        assert r.status_code == 201
        update = ws.receive_json()
        assert update["score_text"] == "1 - 1"
        assert time.monotonic() - start < 0.5


@pytest.mark.in_process
def test_websocket_unknown_match_closes(api):
    from starlette.websockets import WebSocketDisconnect
    with pytest.raises(WebSocketDisconnect):
        with api.client.websocket_connect("/ws/matches/ghost") as ws:
            ws.receive_json()
