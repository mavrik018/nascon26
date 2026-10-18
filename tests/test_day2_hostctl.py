"""Part II FR-3.3: co-stream host invites, join, mute / spotlight / kick controls."""
import hashlib
import hmac
import json
import os

import pytest

SESSION = {"session_id": "cs-t1", "host_player_id": "player-alpha-1",
           "participants": ["player-alpha-1", "player-alpha-2"], "layout": "grid_4"}
FOUR = ["player-alpha-1", "player-alpha-2", "player-beta-1", "player-beta-2"]


def login(api, who="player"):
    r = api.post("/api/v1/auth/login", json={"email": f"{who}@nascon.test", "password": "Nascon@26"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def as_player(player_id):
    from app.auth import create_token
    return {"Authorization": "Bearer " + create_token({"sub": f"user-{player_id}", "role": "player",
                                                       "tenant_id": "tenant-alpha", "player_id": player_id})}


def setup(api, **over):
    api.reset()
    r = api.post("/audit/v1/costream/session", json={**SESSION, **over})
    assert r.status_code == 201, r.text


def invite(api, player_id="player-alpha-3", who="player", sid="cs-t1"):
    return api.post(f"/api/v1/costream/{sid}/invites", json={"player_id": player_id}, headers=login(api, who))


def test_host_invite_is_signed_with_day2_salt(api):
    setup(api)
    r = invite(api)
    assert r.status_code == 201, r.text
    b = r.json()
    assert (b["session_id"], b["player_id"]) == ("cs-t1", "player-alpha-3")
    assert b["invite_token"].startswith("inv_") and len(b["invite_token"]) == 28 and b["expires_at"].endswith("Z")
    payload = {"invite_token": b["invite_token"], "player_id": "player-alpha-3", "session_id": "cs-t1"}
    msg = b["invite_token"] + "|" + json.dumps(payload, sort_keys=True, separators=(",", ":"))
    assert b["signature"] == hmac.new(os.environ["DAY2_SALT"].encode(), msg.encode(), hashlib.sha256).hexdigest()
    assert invite(api, who="admin").status_code == 201  # super_admin may invite too


def test_invite_rejects_non_host_and_unknowns(api):
    setup(api)
    assert invite(api, who="viewer").json()["error"]["code"] == "FORBIDDEN"
    assert invite(api, who="viewer").status_code == 403
    assert invite(api, sid="cs-ghost").json()["error"]["code"] == "STREAM_NOT_FOUND"
    r = invite(api, player_id="player-ghost")
    assert r.status_code == 404 and r.json()["error"]["code"] == "PLAYER_NOT_FOUND"


@pytest.mark.in_process
def test_join_adds_player_and_token_is_single_use(api):
    setup(api)
    token = invite(api).json()["invite_token"]
    assert api.post("/api/v1/costream/cs-t1/join", json={"invite_token": token},
                    headers=as_player("player-alpha-2")).status_code == 403  # someone else's invite
    r = api.post("/api/v1/costream/cs-t1/join", json={"invite_token": token}, headers=as_player("player-alpha-3"))
    assert r.status_code == 200, r.text
    assert r.json()["active_participants"] == ["player-alpha-1", "player-alpha-2", "player-alpha-3"]
    pub = api.get("/api/v1/public/costream/cs-t1").json()
    assert pub["participant_count"] == 3 and "player-alpha-3" in pub["active_participants"]
    r = api.post("/api/v1/costream/cs-t1/join", json={"invite_token": token}, headers=as_player("player-alpha-3"))
    assert r.status_code == 403 and r.json()["error"]["code"] == "FORBIDDEN"


def test_join_bad_token_403_and_full_409(api):
    setup(api, participants=FOUR)
    r = api.post("/api/v1/costream/cs-t1/join", json={"invite_token": "inv_nope"}, headers=login(api))
    assert r.status_code == 403 and r.json()["error"]["code"] == "FORBIDDEN"
    token = invite(api).json()["invite_token"]
    r = api.post("/api/v1/costream/cs-t1/join", json={"invite_token": token}, headers=login(api, "admin"))
    assert r.status_code == 409 and r.json()["error"]["code"] == "COSTREAM_SESSION_FULL"


def test_controls_mute_spotlight_kick_persist_in_public_state(api):
    setup(api, participants=FOUR)
    h = login(api)

    def act(action, pid):
        r = api.post("/api/v1/costream/cs-t1/controls", json={"action": action, "player_id": pid}, headers=h)
        assert r.status_code == 200, r.text
        return r.json()

    act("mute", "player-beta-1")
    act("spotlight", "player-alpha-2")
    b = act("kick", "player-beta-2")
    assert b == {"session_id": "cs-t1", "muted": ["player-beta-1"], "spotlight": "player-alpha-2",
                 "active_participants": ["player-alpha-1", "player-alpha-2", "player-beta-1"],
                 "kicked": ["player-beta-2"], "chat_room_id": "chat-cs-t1"}
    assert api.get("/api/v1/public/costream/cs-t1/state").json() == b
    assert api.get("/api/v1/public/costream/cs-t1").json()["participant_count"] == 3
    assert act("unmute", "player-beta-1")["muted"] == []
    r = api.post("/api/v1/costream/cs-t1/controls", json={"action": "kick", "player_id": "player-alpha-1"}, headers=h)
    assert r.status_code == 400  # host cannot kick themself
    r = api.post("/api/v1/costream/cs-t1/controls", json={"action": "mute", "player_id": "player-alpha-1"},
                 headers=login(api, "viewer"))
    assert r.status_code == 403
    assert api.get("/api/v1/public/costream/cs-ghost/state").status_code == 404


def test_guest_bearer_cannot_write(api):
    setup(api)
    g = {"Authorization": "Bearer guest_anon_tok_7721"}
    for path, body in (("invites", {"player_id": "player-alpha-3"}), ("join", {"invite_token": "inv_x"}),
                       ("controls", {"action": "mute", "player_id": "player-alpha-2"})):
        r = api.post(f"/api/v1/costream/cs-t1/{path}", json=body, headers=g)
        assert r.status_code == 403 and r.json()["error"]["code"] == "GUEST_WRITE_FORBIDDEN"
