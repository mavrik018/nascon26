"""Part II 5.5: co-stream session rules (in exact order), host-drop handoff, idempotent replay."""
import hashlib
import hmac
import json
import os

import pytest

from app.signing import sign_day2

URL = "/audit/v1/costream/session"
FOUR = ["player-alpha-1", "player-alpha-2", "player-beta-1", "player-beta-2"]
SPEC = {"session_id": "cs-session-101", "host_player_id": "player-alpha-1", "participants": FOUR,
        "layout": "grid_4", "simulate_host_drop": True}


def expected_sig(b):
    return sign_day2(b["session_id"], {k: b[k] for k in ("active_host", "handoff_occurred", "layout",
                                                         "participant_count", "session_id", "status")})


def test_spec_example_host_drop_hands_off_to_participant_1(api):
    api.reset()
    r = api.post(URL, json=SPEC)
    assert r.status_code == 201, r.text
    body = r.json()
    payload = {"active_host": "player-alpha-2", "handoff_occurred": True, "layout": "grid_4",
               "participant_count": 3, "session_id": "cs-session-101", "status": "active"}
    msg = "cs-session-101|" + json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    assert body == {
        "session_id": "cs-session-101", "status": "active", "active_host": "player-alpha-2",
        "handoff_occurred": True, "participant_count": 3,
        "active_participants": ["player-alpha-2", "player-beta-1", "player-beta-2"], "layout": "grid_4",
        "composite_playback_url": "http://localhost:8888/costream/cs-session-101/index.m3u8",
        "chat_room_id": "chat-cs-session-101",
        "signature": hmac.new(os.environ["DAY2_SALT"].encode(), msg.encode(), hashlib.sha256).hexdigest(),
    }


def test_no_drop_keeps_host_and_defaults(api):
    api.reset()
    r = api.post(URL, json={"session_id": "cs-2", "host_player_id": "player-alpha-2", "participants": FOUR})
    assert r.status_code == 201, r.text
    b = r.json()
    assert (b["status"], b["active_host"], b["handoff_occurred"], b["participant_count"], b["layout"]) == \
        ("active", "player-alpha-2", False, 4, "grid_4")
    assert b["active_participants"] == FOUR and b["signature"] == expected_sig(b)


def test_drop_with_two_participants_promotes_the_other(api):
    api.reset()
    r = api.post(URL, json={"session_id": "cs-3", "host_player_id": "player-alpha-2",
                            "participants": ["player-alpha-2", "player-alpha-3"], "simulate_host_drop": True,
                            "layout": "solo"})
    assert r.status_code == 201, r.text
    b = r.json()
    assert (b["active_host"], b["handoff_occurred"], b["participant_count"], b["active_participants"]) == \
        ("player-alpha-3", True, 1, ["player-alpha-3"])


def test_sole_host_drop_terminates(api):
    api.reset()
    r = api.post(URL, json={"session_id": "cs-4", "host_player_id": "player-alpha-1",
                            "participants": ["player-alpha-1"], "simulate_host_drop": True})
    assert r.status_code == 201, r.text
    b = r.json()
    assert (b["status"], b["active_host"], b["handoff_occurred"], b["participant_count"], b["active_participants"]) \
        == ("terminated", None, False, 0, [])
    assert b["chat_room_id"] == "chat-cs-4" and b["signature"] == expected_sig(b)


def test_identical_replay_is_200_and_changed_body_is_reevaluated(api):
    api.reset()
    first = api.post(URL, json=SPEC)
    replay = api.post(URL, json=SPEC)
    assert (first.status_code, replay.status_code) == (201, 200)
    assert replay.json() == first.json()
    changed = api.post(URL, json={**SPEC, "simulate_host_drop": False})
    assert changed.status_code == 201 and changed.json()["active_host"] == "player-alpha-1"
    public = api.get("/api/v1/public/costream/cs-session-101")
    assert public.status_code == 200 and "signature" not in public.json()
    assert public.json()["participant_count"] == 4
    missing = api.get("/api/v1/public/costream/cs-nope")
    assert missing.status_code == 404 and missing.json()["error"]["code"] == "STREAM_NOT_FOUND"


@pytest.mark.parametrize("change,fields", [
    ({"session_id": 5}, ["session_id"]),
    ({"host_player_id": None}, ["host_player_id"]),
    ({"participants": []}, ["participants"]),
    ({"participants": ["player-alpha-1", "player-alpha-1"]}, ["participants"]),
    ({"participants": "player-alpha-1"}, ["participants"]),
    ({"simulate_host_drop": "yes"}, ["simulate_host_drop"]),
    ({"layout": "grid_9"}, ["layout"]),
    ({"layout": "grid_9", "participants": ["ghost"] * 6}, ["participants", "layout"]),  # schema before 404/409
])
def test_schema_validation(api, change, fields):
    api.reset()
    r = api.post(URL, json={**SPEC, **change})
    assert r.status_code == 400, r.text
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"
    assert r.json()["error"]["details"]["fields"] == fields


def test_unknown_player_is_404_before_capacity(api):
    api.reset()
    r = api.post(URL, json={**SPEC, "participants": FOUR + ["player-ghost"]})
    assert r.status_code == 404 and r.json()["error"]["code"] == "PLAYER_NOT_FOUND"
    r = api.post(URL, json={**SPEC, "host_player_id": "player-ghost"})
    assert r.status_code == 404 and r.json()["error"]["code"] == "PLAYER_NOT_FOUND"


def test_host_not_in_participants_is_validation_error(api):
    api.reset()
    r = api.post(URL, json={**SPEC, "host_player_id": "player-alpha-5"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"
    assert r.json()["error"]["details"]["fields"] == ["host_player_id"]


def test_five_participants_is_session_full_before_layout(api):
    api.reset()
    r = api.post(URL, json={**SPEC, "layout": "solo", "participants": FOUR + ["player-alpha-3"]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "COSTREAM_SESSION_FULL"


@pytest.mark.parametrize("layout,parts,drop", [
    ("solo", FOUR[:2], False),
    ("grid_2", FOUR[:3], False),
    ("grid_2", FOUR, True),  # effective count 3 after the drop
])
def test_unsupported_layout(api, layout, parts, drop):
    api.reset()
    r = api.post(URL, json={**SPEC, "layout": layout, "participants": parts, "simulate_host_drop": drop})
    assert r.status_code == 400 and r.json()["error"]["code"] == "UNSUPPORTED_LAYOUT"


def test_layout_fits_after_drop(api):
    api.reset()
    r = api.post(URL, json={**SPEC, "layout": "grid_2", "participants": FOUR[:3]})
    assert r.status_code == 201 and r.json()["participant_count"] == 2
    assert api.post(URL, json={**SPEC, "session_id": "cs-sp", "layout": "spotlight"}).status_code == 201
