"""cs-session-101 exists right after reset (guest page / app deep link can join it); POST still evaluates it."""
CS = "cs-session-101"
FOUR = ["player-alpha-1", "player-alpha-2", "player-beta-1", "player-beta-2"]


def test_reset_seeds_spec_session_and_post_still_creates(api):
    api.reset()
    r = api.get(f"/api/v1/public/costream/{CS}")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["active_host"] == "player-alpha-1" and body["participant_count"] == 4 and body["layout"] == "grid_4"
    # The seed never counts as an idempotent replay: the spec example is evaluated afresh.
    req = {"session_id": CS, "host_player_id": "player-alpha-1", "participants": FOUR, "layout": "grid_4",
           "simulate_host_drop": False}
    assert api.post("/audit/v1/costream/session", json=req).status_code == 201
    assert api.post("/audit/v1/costream/session", json=req).status_code == 200
