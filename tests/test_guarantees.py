"""Cross-module guarantees from the pre-submission checklist (spec Appendix C)."""
import json

KABADDI = {
    "sport_id": "kabaddi", "name": "Kabaddi", "scoring_model": "event",
    "periods": {"count": 2, "duration_minutes": 20},
    "scoring_events": {"raid_point": {"points": 1}, "tackle_point": {"points": 1}, "all_out": {"points": 2}},
    "draw_allowed": False, "overtime": {"policy": "golden_score", "duration_minutes": 5},
    "roster": {"min_squad_size": 7, "max_squad_size": 12, "required_positions": {"raider": 2, "defender": 3}},
}


def snapshot(api):
    """Everything a grader can observe about the baseline, minus time-dependent fields."""
    matrix = api.post("/audit/v1/rbac-matrix").json()
    history = api.get("/audit/v1/roster/history/player-alpha-1", params={"as_of": "2026-10-17"}).json()
    return json.dumps({
        "inventory": [api.get(f"/audit/v1/inventory/{v}").json() for v in ("var-jersey-001-M", "var-jersey-001-L")],
        "score": api.get("/audit/v1/score/alpha1-m01").json(),
        "standings": api.get("/audit/v1/standings/league-alpha-1").json(),
        "rbac_context": matrix["context"],
        "roles": sorted(matrix["tokens"]),
        "history": history,
    }, sort_keys=True)


def test_reset_twice_leaves_identical_state(api):
    api.reset()
    first = snapshot(api)
    # dirty every area
    api.post("/audit/v1/sports", json=KABADDI)
    api.post("/audit/v1/checkout", json={"order_id": "o1", "customer_id": "c1",
                                         "items": [{"variant_id": "var-jersey-001-L", "quantity": 2}],
                                         "discount_code": None, "payment": {"token": "tok_success"}})
    api.post("/audit/v1/events", json={"event_id": "x1", "match_id": "alpha1-m05", "type": "match_start",
                                       "payload": {}})
    api.post("/audit/v1/offline-sync", json={"device_id": "d", "actions": [
        {"action_id": "a", "type": "score_event", "queued_at": "2026-10-17T11:00:00Z", "base_version": 1,
         "payload": {"event_id": "x2", "match_id": "alpha1-m05", "type": "score",
                     "payload": {"team_id": "club-alpha-1", "event_type": "goal"}}}]})
    api.reset()
    api.reset()
    assert snapshot(api) == first
    assert api.post("/audit/v1/sports", json=KABADDI).status_code == 201  # custom sport was wiped


def test_demo_accounts_exist_after_reset(api):
    api.reset()
    for who in ("admin", "organizer", "manager", "player", "viewer"):
        r = api.post("/api/v1/auth/login", json={"email": f"{who}@nascon.test", "password": "Nascon@26"})
        assert r.status_code == 200, who


def test_mystery_sport_through_league_and_standings(api):
    api.reset()
    assert api.post("/audit/v1/sports", json=KABADDI).status_code == 201
    r = api.post("/audit/v1/leagues", json={
        "league_id": "kab-league", "sport_id": "kabaddi", "teams": ["a", "b", "c"],
        "fixtures": [{"match_id": "k1", "home": "a", "away": "b"}, {"match_id": "k2", "home": "b", "away": "c"}],
        "qualification": {"spots": 1}})
    assert r.status_code == 201
    for i, (type_, payload) in enumerate([("match_start", {}), ("score", {"team_id": "a", "event_type": "all_out"}),
                                          ("score", {"team_id": "b", "event_type": "raid_point"}),
                                          ("match_end", {})]):
        assert api.post("/audit/v1/events", json={"event_id": f"k1-{i}", "match_id": "k1", "type": type_,
                                                  "payload": payload}).status_code == 201
    table = api.get("/audit/v1/standings/kab-league").json()["table"]
    assert table[0]["team_id"] == "a" and table[0]["points"] == 3 and table[0]["diff"] == 1
    assert api.post("/audit/v1/fixtures", json={"format": "round_robin", "teams": ["a", "b", "c"]}).status_code == 200
