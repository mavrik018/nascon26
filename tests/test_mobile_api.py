"""Production /api/v1 routes the mobile app uses for leagues, matches, scoring and sync,
plus offline-sync roster actions and event-payload validation branches."""
import uuid

import pytest


def login(api, who):
    r = api.post("/api/v1/auth/login", json={"email": f"{who}@nascon.test", "password": "Nascon@26"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def test_fixtures_and_standings_for_tenant_user(api):
    api.reset()
    h = login(api, "viewer")
    r = api.get("/api/v1/leagues/league-alpha-1/fixtures", headers=h)
    assert r.status_code == 200
    fixtures = r.json()
    assert len(fixtures) == 7  # 6 Day 1 demo fixtures + match-m1 (Part II seed, spec 5.2)
    first = fixtures[0]
    assert set(first) == {"match_id", "league_id", "home", "away", "status", "scheduled_at", "home_score",
                          "away_score"}
    assert (first["status"], first["home_score"], first["away_score"]) == ("completed", 2, 1)
    assert {f["status"] for f in fixtures} == {"completed", "in_progress", "upcoming"}
    s = api.get("/api/v1/leagues/league-alpha-1/standings", headers=h)
    assert s.status_code == 200 and len(s.json()["table"]) == 4


def test_league_routes_need_auth_and_tenant(api):
    api.reset()
    assert api.get("/api/v1/leagues/league-alpha-1/fixtures").status_code == 401
    assert api.get("/api/v1/leagues/ghost/fixtures", headers=login(api, "viewer")).status_code == 404
    api.post("/audit/v1/leagues", json={"league_id": "lg-x", "sport_id": "football", "teams": ["a", "b"],
                                        "fixtures": [], "qualification": {"spots": 1}})
    # leagues registered through the audit route have no tenant: readable by any signed-in user
    assert api.get("/api/v1/leagues/lg-x/standings", headers=login(api, "viewer")).status_code == 200


def test_match_detail_has_event_types_and_pinned_product(api):
    api.reset()
    r = api.get("/api/v1/matches/alpha1-m04", headers=login(api, "player"))
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "in_progress" and body["event_types"] == ["goal"]
    assert body["pinned_product"]["product_id"] == "prod-jersey-001"
    assert body["pinned_product"]["price_minor"] == 450000
    assert api.get("/api/v1/matches/ghost", headers=login(api, "player")).status_code == 404


def test_only_owning_organizer_can_score(api):
    api.reset()
    body = {"event_id": "mob-1", "type": "score", "payload": {"team_id": "club-alpha-2", "event_type": "goal"}}
    assert api.post("/api/v1/matches/alpha1-m04/events", json=body, headers=login(api, "manager")).status_code == 403
    r = api.post("/api/v1/matches/alpha1-m04/events", json=body, headers=login(api, "organizer"))
    assert r.status_code == 201 and r.json()["match_id"] == "alpha1-m04"
    again = api.post("/api/v1/matches/alpha1-m04/events", json=body, headers=login(api, "organizer"))
    assert again.status_code == 200
    comp = {"event_id": "mob-2", "type": "compensation", "payload": {"compensates": "mob-1", "reason": "offside"}}
    assert api.post("/api/v1/matches/alpha1-m04/events", json=comp, headers=login(api, "admin")).status_code == 201


@pytest.mark.parametrize("payload", [
    {"sport_id": "", "home_team_id": "a", "away_team_id": "b"},
    {"sport_id": "football", "home_team_id": "a", "away_team_id": "a"},
    {"sport_id": "football", "home_team_id": "a", "away_team_id": "b", "league_id": "bad|id"},
])
def test_match_init_payload_validation(api, payload):
    r = api.post("/audit/v1/events", json={"event_id": "x", "match_id": "mx", "type": "match_init",
                                           "payload": payload})
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"


@pytest.mark.parametrize("type_,payload", [
    ("score", {"team_id": "t1"}), ("score", {"event_type": "goal"}), ("tiebreak_winner", {}),
    ("compensation", {"compensates": "e1"}), ("compensation", {"reason": "x"}),
])
def test_event_payload_validation(api, type_, payload):
    r = api.post("/audit/v1/events", json={"event_id": "x", "match_id": "m1", "type": type_, "payload": payload})
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"


def test_non_object_bodies_are_400(api):
    for path in ("/audit/v1/events", "/audit/v1/leagues", "/audit/v1/sports", "/audit/v1/offline-sync"):
        r = api.post(path, json=[1, 2])
        assert r.status_code == 400, path
        assert r.json()["error"]["code"] == "VALIDATION_ERROR"


# ------------------------------------------------------------------ offline sync: roster actions

def transfer(request_id, player="player-alpha-3", to="club-alpha-2", date="2026-10-17"):
    return {"request_id": request_id, "league_id": "league-alpha-1", "player_id": player, "type": "transfer",
            "from_squad_id": "club-alpha-1", "to_squad_id": to, "effective_date": date, "loan_end_date": None,
            "reason": "offline move", "requested_by": "manager"}


def roster_action(action_id, body, base, queued="2026-10-17T11:00:00Z"):
    return {"action_id": action_id, "type": "roster_transfer", "queued_at": queued, "base_version": base,
            "payload": body}


def test_sync_roster_transfer_applied_rejected_duplicate(api):
    api.reset()
    version = len(api.get("/audit/v1/roster/history/player-alpha-3").json()["history"])
    out = api.post("/audit/v1/offline-sync", json={"device_id": "phone", "actions": [
        roster_action("r1", transfer("tr-1"), version),
        roster_action("r2", transfer("tr-2"), version + 5, queued="2026-10-17T11:01:00Z"),
        roster_action("r3", transfer("tr-3", player="nobody"), 0, queued="2026-10-17T11:02:00Z"),
        roster_action("r4", transfer("tr-4", player="player-alpha-4", date="2025-01-01"), 0,
                      queued="2026-10-17T11:03:00Z"),
    ]}).json()
    r1, r2, r3, r4 = out["results"]
    assert (r1["status"], r1["resolution"], r1["server_version"], r1["signature"]) == \
        ("applied", "appended", version + 1, None)
    assert (r2["status"], r2["error_code"]) == ("rejected", "INVALID_BASE_VERSION")
    assert (r3["status"], r3["error_code"]) == ("rejected", "PLAYER_NOT_FOUND")
    assert (r4["status"], r4["error_code"]) == ("rejected", "TRANSFER_WINDOW_CLOSED")
    # the same transfer request_id from another device is a duplicate, not a second move
    again = api.post("/audit/v1/offline-sync", json={"device_id": "tablet", "actions": [
        roster_action("z1", transfer("tr-1"), version + 1)]}).json()
    assert again["results"][0]["status"] == "duplicate"


def test_sync_roster_rebased_when_device_is_stale(api):
    api.reset()
    api.post("/audit/v1/roster/transfer", json=transfer("first", player="player-alpha-5"))
    out = api.post("/audit/v1/offline-sync", json={"device_id": "phone", "actions": [
        roster_action("a", {**transfer("second", player="player-alpha-5"), "from_squad_id": "club-alpha-2",
                            "to_squad_id": "club-alpha-1"}, 0)]}).json()
    assert out["results"][0]["resolution"] == "rebased_append"


def test_mobile_sync_enforces_roles(api):
    api.reset()
    body = {"device_id": "phone", "actions": [
        {"action_id": "s1", "type": "score_event", "queued_at": "2026-10-17T11:00:00Z", "base_version": 2,
         "payload": {"event_id": "off-1", "match_id": "alpha1-m04", "type": "score",
                     "payload": {"team_id": "club-alpha-2", "event_type": "goal"}}},
        roster_action("s2", transfer("tr-m"), 0, queued="2026-10-17T11:01:00Z")]}
    out = api.post("/api/v1/sync", json=body, headers=login(api, "viewer")).json()
    assert [r["error_code"] for r in out["results"]] == ["FORBIDDEN", "FORBIDDEN"]
    body["device_id"] = "phone2"
    out = api.post("/api/v1/sync", json=body, headers=login(api, "organizer")).json()
    assert out["results"][0]["status"] == "applied", out["results"][0]["error_code"]
    assert out["results"][0]["resolution"] == "appended"   # m04 has 2 events: base 2 == server version
    assert out["results"][1]["error_code"] == "FORBIDDEN"
    assert api.post("/api/v1/sync", json=body).status_code == 401


def test_sports_list_and_role_based_create(api):
    api.reset()
    listed = api.get("/api/v1/sports", headers=login(api, "viewer")).json()
    assert [s["sport_id"] for s in listed][:4] == ["basketball", "cricket", "esports", "football"]
    body = {"sport_id": "netball", "name": "Netball", "scoring_model": "event",
            "periods": {"count": 4, "duration_minutes": 15}, "scoring_events": {"goal": {"points": 1}},
            "draw_allowed": True, "overtime": {"policy": "none"},
            "roster": {"min_squad_size": 7, "max_squad_size": 12, "required_positions": {}}}
    assert api.post("/api/v1/sports", json=body, headers=login(api, "player")).status_code == 403
    r = api.post("/api/v1/sports", json=body, headers=login(api, "organizer"))
    assert r.status_code == 201 and r.json()["config"]["tie_break_order"][-1] == "draw_lots"
    assert uuid.UUID(r.json()["sport_id"]) and r.json()["sport_id"] != "netball"  # the server assigns ids
    dup = api.post("/api/v1/sports", json={**body, "name": "NETBALL"}, headers=login(api, "admin"))
    assert dup.status_code == 409 and dup.json()["error"]["code"] == "SPORT_EXISTS"
    assert api.post("/api/v1/sports", json={**body, "name": ""}, headers=login(api, "admin")).status_code == 400
