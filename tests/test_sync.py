"""Spec 5.14: offline sync replay, ordering, dedup, base-version conflicts."""
from app.signing import sign
from conftest import SALT


def setup_match(api, started=True):
    api.reset()
    api.post("/audit/v1/events", json={"event_id": "i", "match_id": "m1", "type": "match_init",
                                       "payload": {"sport_id": "football", "home_team_id": "t1", "away_team_id": "t2"}})
    if started:
        api.post("/audit/v1/events", json={"event_id": "s", "match_id": "m1", "type": "match_start", "payload": {}})


def score_action(action_id, event_id, base, queued="2026-10-17T11:00:00Z", team="t1", match_id="m1"):
    return {"action_id": action_id, "type": "score_event", "queued_at": queued, "base_version": base,
            "payload": {"event_id": event_id, "match_id": match_id, "type": "score",
                        "payload": {"team_id": team, "event_type": "goal"}}}


def sync(api, *actions, device="dev-1"):
    r = api.post("/audit/v1/offline-sync", json={"device_id": device, "actions": list(actions)})
    assert r.status_code == 200, r.text
    return r.json()


def test_appended_and_rebased(api):
    setup_match(api)
    out = sync(api, score_action("a1", "e1", 2), score_action("a2", "e2", 2, queued="2026-10-17T11:05:00Z"))
    r1, r2 = out["results"]
    assert r1 == {"action_id": "a1", "status": "applied", "resolution": "appended", "error_code": None,
                  "processed_order": 1, "server_version": 3,
                  "signature": sign("e1", {"team_id": "t1", "event_type": "goal"}, salt=SALT)}
    assert r2["resolution"] == "rebased_append" and r2["server_version"] == 4
    assert out["summary"] == {"applied": 2, "rejected": 0, "duplicate": 0}
    assert out["device_id"] == "dev-1"


def test_processing_order_is_queued_at_but_results_in_request_order(api):
    setup_match(api)
    late = score_action("late", "e-late", 2, queued="2026-10-17T12:00:00Z")
    early = score_action("early", "e-early", 2, queued="2026-10-17T10:00:00Z")
    out = sync(api, late, early)
    assert [r["action_id"] for r in out["results"]] == ["late", "early"]
    assert [r["processed_order"] for r in out["results"]] == [2, 1]
    assert out["results"][1]["resolution"] == "appended"
    assert out["results"][0]["resolution"] == "rebased_append"


def test_resend_is_all_duplicate_and_changes_nothing(api):
    setup_match(api)
    batch = [score_action("a1", "e1", 2), score_action("bad", "e2", 2, team="t9")]
    first = sync(api, *batch)
    assert [r["status"] for r in first["results"]] == ["applied", "rejected"]
    version = api.get("/audit/v1/score/m1").json()["version"]
    again = sync(api, *batch)
    assert [r["status"] for r in again["results"]] == ["duplicate", "duplicate"]
    assert [r["resolution"] for r in again["results"]] == ["skipped_duplicate"] * 2
    assert again["summary"] == {"applied": 0, "rejected": 0, "duplicate": 2}
    assert api.get("/audit/v1/score/m1").json()["version"] == version


def test_same_event_id_from_another_device_is_duplicate(api):
    setup_match(api)
    sync(api, score_action("a1", "e1", 2))
    out = sync(api, score_action("x9", "e1", 3), device="dev-2")
    assert out["results"][0]["status"] == "duplicate"
    out = sync(api, {**score_action("x10", "e1", 3), "payload": {
        "event_id": "e1", "match_id": "m1", "type": "score", "payload": {"team_id": "t2", "event_type": "goal"}}},
        device="dev-2")
    assert out["results"][0]["error_code"] == "DUPLICATE_EVENT_ID"


def test_rejections(api):
    setup_match(api, started=False)
    out = sync(api,
               score_action("a1", "e1", 1),                                   # not in progress
               score_action("a2", "e2", 9, queued="2026-10-17T11:01:00Z"),   # base ahead of server
               score_action("a3", "e3", 0, match_id="ghost", queued="2026-10-17T11:02:00Z"))
    codes = [(r["status"], r["resolution"], r["error_code"], r["server_version"]) for r in out["results"]]
    assert codes == [("rejected", "server_wins", "MATCH_NOT_IN_PROGRESS", 1),
                     ("rejected", "server_wins", "INVALID_BASE_VERSION", 1),
                     ("rejected", "server_wins", "MATCH_NOT_FOUND", 0)]
    assert all(r["signature"] is None for r in out["results"])


def test_each_action_sees_previous_state(api):
    setup_match(api, started=False)
    start = {"action_id": "st", "type": "score_event", "queued_at": "2026-10-17T10:00:00Z", "base_version": 1,
             "payload": {"event_id": "st", "match_id": "m1", "type": "match_start", "payload": {}}}
    out = sync(api, score_action("g", "g", 2, queued="2026-10-17T10:01:00Z"), start)
    assert [r["status"] for r in out["results"]] == ["applied", "applied"]


def test_malformed_envelope_is_400(api):
    for body in ({"device_id": "d", "actions": []}, {"device_id": "d", "actions": [{"action_id": "a"}]},
                 {"actions": [score_action("a", "e", 0)]}, [1, 2],
                 {"device_id": "d", "actions": [score_action("a", "e", 0, queued="yesterday")]},
                 {"device_id": "d", "actions": [score_action("a", "e", -1)]},
                 {"device_id": "d", "actions": [score_action(f"a{i}", f"e{i}", 0) for i in range(101)]}):
        r = api.post("/audit/v1/offline-sync", json=body)
        assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"


def test_invalid_event_payload_is_rejected_not_400(api):
    setup_match(api)
    bad = {"action_id": "a1", "type": "score_event", "queued_at": "2026-10-17T11:00:00Z", "base_version": 2,
           "payload": {"event_id": "e1", "match_id": "m1", "type": "score", "payload": {"team_id": "t1",
                                                                                        "event_type": "slam"}}}
    out = sync(api, bad)
    assert out["results"][0]["error_code"] == "UNKNOWN_EVENT_TYPE"
