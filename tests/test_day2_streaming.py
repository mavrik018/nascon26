"""Part II 5.4: stream key generate / rotate / revoke, KEY_REVOKED, MediaMTX publish auth."""
import hashlib
import hmac
import json
import os
import re

import pytest

from app.signing import sign_day2

URL = "/audit/v1/stream/key"
KEY = "sk_live_9f83a1b2c3d4e5f6"


def expected_sig(action, player_id, status, key):
    return sign_day2(key, {"action": action, "player_id": player_id, "status": status, "stream_key": key})


def test_rotate_with_override_matches_spec_example_and_reference_hmac(api):
    api.reset()
    r = api.post(URL, json={"action": "rotate", "player_id": "player-alpha-1", "label": "OBS-Main-Desk",
                            "stream_key_override": KEY})
    assert r.status_code == 200, r.text
    body = r.json()
    msg = KEY + "|" + json.dumps({"action": "rotate", "player_id": "player-alpha-1", "status": "active",
                                  "stream_key": KEY}, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    reference = hmac.new(os.environ["DAY2_SALT"].encode(), msg.encode(), hashlib.sha256).hexdigest()
    assert body == {
        "player_id": "player-alpha-1", "label": "OBS-Main-Desk", "stream_key": KEY, "status": "active",
        "ingest_endpoints": {"rtmp": f"rtmp://localhost:1935/live/{KEY}",
                             "webrtc": f"http://localhost:8889/live/{KEY}/whip"},
        "playback_url": f"http://localhost:8888/live/{KEY}/index.m3u8",
        "signature": reference,
    }


def test_generate_is_201_with_default_label_and_random_key(api):
    api.reset()
    r = api.post(URL, json={"action": "generate", "player_id": "player-beta-2"})
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["label"] == "default" and body["status"] == "active"
    assert re.fullmatch(r"sk_live_[a-f0-9]{16}", body["stream_key"])
    assert body["signature"] == expected_sig("generate", "player-beta-2", "active", body["stream_key"])
    assert api.get(f"{URL}/{body['stream_key']}").json()["status"] == "active"


def test_rotate_and_generate_invalidate_the_previous_key(api):
    api.reset()
    old = api.post(URL, json={"action": "generate", "player_id": "player-alpha-1"}).json()["stream_key"]
    new = api.post(URL, json={"action": "rotate", "player_id": "player-alpha-1"}).json()["stream_key"]
    assert new != old
    r = api.get(f"{URL}/{old}")
    assert r.status_code == 409 and r.json()["error"]["code"] == "KEY_REVOKED"
    newer = api.post(URL, json={"action": "generate", "player_id": "player-alpha-1"})
    assert newer.status_code == 201
    assert api.get(f"{URL}/{new}").status_code == 409
    assert api.get(f"{URL}/{newer.json()['stream_key']}").status_code == 200


def test_revoke_then_revoke_again_is_stream_not_found(api):
    api.reset()
    api.post(URL, json={"action": "generate", "player_id": "player-alpha-1", "stream_key_override": KEY})
    r = api.post(URL, json={"action": "revoke", "player_id": "player-alpha-1"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert (body["status"], body["stream_key"], body["ingest_endpoints"], body["playback_url"]) == \
        ("revoked", KEY, None, None)
    assert body["signature"] == expected_sig("revoke", "player-alpha-1", "revoked", KEY)
    again = api.post(URL, json={"action": "revoke", "player_id": "player-alpha-1"})
    assert again.status_code == 404 and again.json()["error"]["code"] == "STREAM_NOT_FOUND"


def test_revoke_without_any_key_is_stream_not_found(api):
    api.reset()
    r = api.post(URL, json={"action": "revoke", "player_id": "player-alpha-2"})
    assert r.status_code == 404 and r.json()["error"]["code"] == "STREAM_NOT_FOUND"


def test_reusing_a_revoked_key_is_key_revoked(api):
    api.reset()
    api.post(URL, json={"action": "rotate", "player_id": "player-alpha-1", "stream_key_override": KEY})
    api.post(URL, json={"action": "revoke", "player_id": "player-alpha-1"})
    r = api.post(URL, json={"action": "rotate", "player_id": "player-alpha-1", "stream_key_override": KEY})
    assert r.status_code == 409 and r.json()["error"]["code"] == "KEY_REVOKED"
    assert api.get(f"{URL}/sk_live_0000000000000000").json()["error"]["code"] == "STREAM_NOT_FOUND"


def test_replayed_rotate_with_same_override_is_stable(api):
    api.reset()
    body = {"action": "rotate", "player_id": "player-alpha-1", "stream_key_override": KEY}
    first, second = api.post(URL, json=body), api.post(URL, json=body)
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()


@pytest.mark.parametrize("body,fields", [
    ({"action": "explode", "player_id": "player-alpha-1"}, ["action"]),
    ({"player_id": "player-alpha-1"}, ["action"]),
    ({"action": "generate"}, ["player_id"]),
    ({"action": "generate", "player_id": 7}, ["player_id"]),
    ({"action": "generate", "player_id": "player-alpha-1", "label": ""}, ["label"]),
    ({"action": "generate", "player_id": "player-alpha-1", "label": "x" * 65}, ["label"]),
    ({"action": "generate", "player_id": "player-alpha-1", "stream_key_override": "sk_live_XYZ"},
     ["stream_key_override"]),
    ({"action": "nope", "player_id": "ghost-player"}, ["action"]),  # schema before existence
])
def test_validation_errors(api, body, fields):
    api.reset()
    r = api.post(URL, json=body)
    assert r.status_code == 400, r.text
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"
    assert r.json()["error"]["details"]["fields"] == fields


def test_malformed_json_is_validation_error(api):
    api.reset()
    r = api.post(URL, data="{not json", headers={"Content-Type": "application/json"})
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"


@pytest.mark.parametrize("action", ["generate", "rotate", "revoke"])
def test_unknown_player_is_player_not_found(api, action):
    api.reset()
    r = api.post(URL, json={"action": action, "player_id": "player-ghost-99"})
    assert r.status_code == 404 and r.json()["error"]["code"] == "PLAYER_NOT_FOUND"


def test_mediamtx_publish_auth(api):
    api.reset()
    api.post(URL, json={"action": "generate", "player_id": "player-alpha-1", "stream_key_override": KEY})
    hook = {"user": "", "password": "", "ip": "127.0.0.1", "action": "publish", "path": f"live/{KEY}",
            "protocol": "rtmp", "id": None, "query": ""}
    assert api.post("/internal/media/auth", json=hook).status_code == 200
    assert api.post("/internal/media/auth", json={**hook, "path": "live/sk_live_0000000000000000"}).status_code == 401
    assert api.post("/internal/media/auth", json={**hook, "path": "other/" + KEY}).status_code == 401
    for action in ("read", "playback"):
        assert api.post("/internal/media/auth", json={**hook, "action": action, "path": "live/x"}).status_code == 200
    api.post(URL, json={"action": "revoke", "player_id": "player-alpha-1"})
    denied = api.post("/internal/media/auth", json=hook)
    assert denied.status_code == 409 and denied.json()["error"]["code"] == "KEY_REVOKED"
    assert api.post("/internal/media/auth", data="garbage").status_code == 401
