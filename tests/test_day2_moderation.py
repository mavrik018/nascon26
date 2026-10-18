"""Part II 5.8 / FR-5.2 / FR-5.3: chat moderation probe, DLQ, live chat endpoints."""
import hashlib
import hmac
import json
import os
import threading

import pytest

ROOM = "chat-cs-session-101"
SPEC_REQUEST = {
    "chat_room_id": ROOM,
    "incoming_messages": [
        {"message_id": "msg-1", "sender": "user-guest-1", "text": "Clean sports commentary"},
        {"message_id": "msg-2", "sender": "user-spammer", "text": "Watch this illegal stream b@d_w0rd now!"},
        {"message_id": "msg-3", "sender": "user-flooder", "text": "GOAL! AAAA!!!"},
    ],
    "check_dlq": True,
    "simulate_failed_notifications": 0,
}


def ref_sig(entity_id, payload):
    """Independent copy of the Appendix A reference recipe."""
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hmac.new(os.environ.get("DAY2_SALT", "").encode(), (entity_id + "|" + canonical).encode(),
                    hashlib.sha256).hexdigest()


def probe(api, messages, room="room-x", **extra):
    r = api.post("/audit/v1/moderation/test", json={"chat_room_id": room, "incoming_messages": messages, **extra})
    assert r.status_code == 200, r.text
    return r.json()


def one(api, text, sender="u1", mid="m1", room="room-x"):
    return probe(api, [{"message_id": mid, "sender": sender, "text": text}], room=room)


def test_spec_example_exact(api):
    api.reset()
    r = api.post("/audit/v1/moderation/test", json=SPEC_REQUEST)
    assert r.status_code == 200, r.text
    body = r.json()
    sig = body.pop("signature")
    assert body == {
        "chat_room_id": ROOM,
        "filtered_messages": [
            {"message_id": "msg-1", "sender": "user-guest-1", "text": "Clean sports commentary",
             "flagged": False, "reason": None},
            {"message_id": "msg-2", "sender": "user-spammer", "text": "Watch this illegal stream *** now!",
             "flagged": True, "reason": "profanity_leetspeak"},
        ],
        "kicked_users": ["user-spammer"],
        "muted_users": ["user-flooder"],
        "dlq_status": {"queue_depth": 0, "undelivered_events": []},
    }
    assert sig == ref_sig(ROOM, {"chat_room_id": ROOM, "flagged_count": 1, "kicked_users": ["user-spammer"],
                                 "queue_depth": 0})


@pytest.mark.parametrize("text,expected", [
    ("b@d_w0rd", "***"), ("bad_word", "***"), ("p.0.r.n now", "*** now"), ("total s!c@m", "total ***"),
    ("f*u*c*k this", "*** this"), ("you a$$h0le!", "you ***!"), ("1d10t_sp@m", "***"), ("sh!t", "***"),
    ("B1TCH.", "***."), ("p​0rn", "***"), ("scams everywhere", "*** everywhere"),
])
def test_leetspeak_variants_masked(api, text, expected):
    api.reset()
    msg = one(api, text)["filtered_messages"][0]
    assert (msg["text"], msg["flagged"], msg["reason"]) == (expected, True, "profanity_leetspeak")


@pytest.mark.parametrize("text", ["Great pass now!", "Score is 1-0", "scamper about", "What a goal?!", "100 fans"])
def test_clean_text_untouched(api, text):
    api.reset()
    body = one(api, text)
    assert body["filtered_messages"] == [{"message_id": "m1", "sender": "u1", "text": text, "flagged": False,
                                          "reason": None}]
    assert body["kicked_users"] == body["muted_users"] == []


@pytest.mark.parametrize("text", ["AAAA", "goooool", "wow!!!", "what???", "?!?", "....", "aAaA b@d_w0rd"])
def test_flood_dropped_and_muted(api, text):
    api.reset()
    body = one(api, text, sender="flooder")
    assert body["filtered_messages"] == [] and body["muted_users"] == ["flooder"] and body["kicked_users"] == []


def test_rate_limit_more_than_three_in_one_request(api):
    api.reset()
    msgs = [{"message_id": f"r{i}", "sender": "fast", "text": f"hi {i}"} for i in range(5)]
    body = probe(api, msgs)
    assert [m["message_id"] for m in body["filtered_messages"]] == ["r0", "r1", "r2"]
    assert body["muted_users"] == ["fast"]


def test_kicked_muted_accumulate_without_duplicates(api):
    api.reset()
    one(api, "b@d_w0rd", sender="a", mid="1")
    one(api, "scam", sender="b", mid="2")
    one(api, "AAAA", sender="c", mid="3")
    body = one(api, "porn", sender="a", mid="4")
    assert body["kicked_users"] == ["a", "b"] and body["muted_users"] == ["c"]
    assert one(api, "fine", room="other-room")["kicked_users"] == []


def test_concurrent_identical_requests_idempotent(api):
    api.reset()
    barrier, results = threading.Barrier(10), []

    def fire():
        barrier.wait()
        results.append(api.post("/audit/v1/moderation/test", json=SPEC_REQUEST))

    threads = [threading.Thread(target=fire) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert [r.status_code for r in results] == [200] * 10
    assert all(r.json()["kicked_users"] == ["user-spammer"] and r.json()["muted_users"] == ["user-flooder"]
               for r in results)
    assert len({r.json()["signature"] for r in results}) == 1
    assert len(api.get(f"/api/v1/public/chat/{ROOM}").json()) == 2  # replays stored once


def test_dlq_simulated_failures_then_reset(api):
    api.reset()
    body = probe(api, [], simulate_failed_notifications=2)
    dlq = body["dlq_status"]
    assert dlq["queue_depth"] == 2
    assert [e["event_id"] for e in dlq["undelivered_events"]] == ["dlq-1", "dlq-2"]
    assert all(e["attempts"] == 3 and e["event_type"] == "chat_notification" and e["last_error"]
               for e in dlq["undelivered_events"])
    assert body["signature"] == ref_sig("room-x", {"chat_room_id": "room-x", "flagged_count": 0,
                                                   "kicked_users": [], "queue_depth": 2})
    assert "nascon_dlq_depth 2" in api.get("/metrics").text
    api.reset()
    assert probe(api, [])["dlq_status"] == {"queue_depth": 0, "undelivered_events": []}


@pytest.mark.in_process
def test_deliver_retries_with_backoff_then_succeeds_or_dlqs(api):
    from app.db import pool
    from app.modules.moderation_dlq import deliver
    api.reset()
    calls, waits = [], []

    def flaky(payload):
        calls.append(payload)
        if len(calls) < 3:
            raise TimeoutError("push gateway timeout")

    with pool.connection() as conn:
        assert deliver(conn, "score_update", {"x": 1}, flaky, sleep=waits.append) is True
        assert (len(calls), waits) == (3, [0.1, 0.2])
        assert deliver(conn, "score_update", {"x": 2}, lambda p: 1 / 0, sleep=lambda _: None) is False
        row = conn.execute("SELECT attempts, last_error FROM notification_dlq").fetchone()
    assert row["attempts"] == 3 and "ZeroDivisionError" in row["last_error"]


@pytest.mark.parametrize("body,fields", [
    ({}, ["chat_room_id", "incoming_messages"]),
    ({"chat_room_id": ROOM, "incoming_messages": [{"message_id": "a", "sender": "b"}]}, ["incoming_messages.text"]),
    ({"chat_room_id": ROOM, "incoming_messages": [], "simulate_failed_notifications": -1},
     ["simulate_failed_notifications"]),
    ({"chat_room_id": ROOM, "incoming_messages": [], "check_dlq": "yes"}, ["check_dlq"]),
    ([], ["body"]),
])
def test_probe_validation(api, body, fields):
    r = api.post("/audit/v1/moderation/test", json=body)
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "VALIDATION_ERROR" and r.json()["error"]["details"]["fields"] == fields


# --------------------------------------------------------------------------- live chat

def login(api):
    r = api.post("/api/v1/auth/login", json={"email": "player@nascon.test", "password": "Nascon@26"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer guest_anon_tok_7721"}])
def test_chat_post_forbidden_without_member_token(api, headers):
    api.reset()
    r = api.post("/api/v1/chat", json={"chat_room_id": ROOM, "text": "hi"}, headers=headers)
    assert r.status_code == 403 and r.json()["error"]["code"] == "GUEST_WRITE_FORBIDDEN"
    assert api.get(f"/api/v1/public/chat/{ROOM}").json() == []


def test_chat_post_bad_jwt_is_401(api):
    r = api.post("/api/v1/chat", json={"chat_room_id": ROOM, "text": "hi"}, headers={"Authorization": "Bearer x.y.z"})
    assert r.status_code == 401


def test_member_chat_moderated_and_listed(api):
    api.reset()
    auth = login(api)
    r1 = api.post("/api/v1/chat", json={"chat_room_id": ROOM, "text": "Nice goal"}, headers=auth)
    r2 = api.post("/api/v1/chat", json={"chat_room_id": ROOM, "text": "what a sc@m"}, headers=auth)
    r3 = api.post("/api/v1/chat", json={"chat_room_id": ROOM, "text": "AAAAAA"}, headers=auth)
    assert (r1.status_code, r2.status_code, r3.status_code) == (201, 201, 200)
    assert r1.json()["seq"] < r2.json()["seq"] < r3.json()["seq"]
    assert (r2.json()["text"], r2.json()["flagged"], r2.json()["reason"]) == ("what a ***", True,
                                                                             "profanity_leetspeak")
    assert r3.json()["dropped"] is True
    listed = api.get(f"/api/v1/public/chat/{ROOM}").json()
    assert [(m["text"], m["flagged"]) for m in listed] == [("Nice goal", False), ("what a ***", True)]
    assert set(listed[0]) == {"message_id", "sender", "text", "flagged"}
    r4 = api.post("/api/v1/chat", json={"chat_room_id": ROOM, "text": "fourth in 2 s"}, headers=auth)
    assert r4.status_code == 429 and r4.json()["error"]["code"] == "RATE_LIMITED"
    assert api.post("/api/v1/chat", json={"chat_room_id": ROOM}, headers=auth).status_code == 400
