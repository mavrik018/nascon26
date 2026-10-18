"""Part II foundation: DAY2_SALT signing recipe (Appendix A), Day 2 baseline seed (5.2), guest write block (5.7)."""
import hashlib
import hmac
import json

import pytest

from app.signing import sign_day2


def reference_sign_day2(day2_salt, entity_id, sig_payload):
    """Verbatim from the Part II spec, Appendix A."""
    canonical = json.dumps(sig_payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hmac.new(day2_salt.encode("utf-8"), (entity_id + "|" + canonical).encode("utf-8"),
                    hashlib.sha256).hexdigest()


def test_vector_1_stream_key_full_payload():
    payload = {"action": "rotate", "player_id": "player-alpha-1", "status": "active",
               "stream_key": "sk_live_9f83a1b2c3d4e5f6"}
    got = sign_day2("sk_live_9f83a1b2c3d4e5f6", payload, salt="T01D27ad7ffff12e")
    assert got == reference_sign_day2("T01D27ad7ffff12e", "sk_live_9f83a1b2c3d4e5f6", payload)
    assert len(got) == 64 and got == got.lower()


def test_vector_2_legacy_two_key_payload_message_string():
    payload = {"action": "rotate", "player_id": "player-alpha-1"}
    msg = "sk_live_101|" + json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    assert msg == 'sk_live_101|{"action":"rotate","player_id":"player-alpha-1"}'
    assert sign_day2("sk_live_101", payload, salt="T01D27ad7ffff12e") == hmac.new(
        b"T01D27ad7ffff12e", msg.encode(), hashlib.sha256).hexdigest()


def test_reset_seeds_match_m1_in_progress_one_nil(api):
    api.reset()
    score = api.get("/audit/v1/score/match-m1").json()
    assert (score["status"], score["league_id"]) == ("in_progress", "league-alpha-1")
    assert (score["home"]["team_id"], score["home"]["score"]) == ("club-alpha-1", 1)
    assert (score["away"]["team_id"], score["away"]["score"]) == ("club-alpha-2", 0)
    assert api.get("/audit/v1/roster/history/player-beta-2").json()["current_squad_id"] == "club-beta-1"


@pytest.mark.parametrize("method,path", [
    ("POST", "/api/v1/chat"), ("POST", "/audit/v1/checkout"), ("POST", "/audit/v1/events"),
    ("POST", "/api/v1/store/checkout"), ("DELETE", "/api/v1/store/products/prod-jersey-001"),
])
def test_guest_bearer_can_never_write(api, method, path):
    api.reset()
    r = api.request(method, path, json={"anything": 1}, headers={"Authorization": "Bearer guest_anon_tok_7721"})
    assert r.status_code == 403, r.text
    assert r.json()["error"] == {"code": "GUEST_WRITE_FORBIDDEN",
                                 "message": "Anonymous guest tokens cannot perform write mutations.",
                                 "details": {"guest_token": "guest_anon_tok_7721"}}


def test_guest_bearer_can_still_read(api):
    api.reset()
    assert api.get("/audit/v1/score/match-m1", headers={"Authorization": "Bearer guest_anon_tok_7721"}).status_code == 200
