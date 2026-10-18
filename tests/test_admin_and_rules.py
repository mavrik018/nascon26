"""Server-assigned UUIDs, admin deletes (merchandise, sports, clubs) and editable sport rules that never
rewrite finished results."""
import uuid

from test_mobile_api import login

NETBALL = {"name": "Netball", "scoring_model": "event", "periods": {"count": 4, "duration_minutes": 15},
           "scoring_events": {"goal": {"points": 1}}, "draw_allowed": True, "overtime": {"policy": "none"},
           "roster": {"min_squad_size": 7, "max_squad_size": 12, "required_positions": {}}}


def new_sport(api, who="admin", **change):
    r = api.post("/api/v1/sports", json={**NETBALL, **change}, headers=login(api, who))
    assert r.status_code == 201, r.text
    return r.json()["sport_id"]


# ------------------------------------------------------------------ ids come from the server

def test_server_assigns_uuid_ids_for_products_players_and_sports(api):
    api.reset()
    mgr = login(api, "manager")
    product = api.post("/api/v1/store/products", headers=mgr, json={
        "name": "Mug", "category": "accessories", "variants": [{"label": "One", "price_minor": 100, "stock": 1}]})
    player = api.post("/api/v1/roster/players", headers=mgr, json={
        "league_id": "league-alpha-1", "squad_id": "club-alpha-1", "name": "New", "position": "mf"})
    for value in (product.json()["product_id"], player.json()["player_id"], new_sport(api)):
        assert str(uuid.UUID(value)) == value


# ------------------------------------------------------------------ sport rules can be edited and extended

def test_editing_rules_applies_to_new_matches_only(api):
    api.reset()
    sport_id = new_sport(api)
    api.post("/audit/v1/events", json={"event_id": "old-0", "match_id": "old", "type": "match_init", "payload": {
        "sport_id": sport_id, "home_team_id": "h", "away_team_id": "a"}})
    for i, (t, p) in enumerate([("match_start", {}), ("score", {"team_id": "h", "event_type": "goal"})]):
        api.post("/audit/v1/events", json={"event_id": f"old-{i + 1}", "match_id": "old", "type": t, "payload": p})
    # Organizer edits the rules: a goal is now worth 2 and a new "super_shot" rule is added.
    r = api.put(f"/api/v1/sports/{sport_id}", headers=login(api, "organizer"), json={
        **NETBALL, "scoring_events": {"goal": {"points": 2}, "super_shot": {"points": 3}}})
    assert r.status_code == 200 and r.json()["config"]["scoring_events"]["super_shot"] == {"points": 3}
    assert api.get("/audit/v1/score/old").json()["home"]["score"] == 1   # old match keeps its rules
    api.post("/audit/v1/events", json={"event_id": "new-0", "match_id": "new", "type": "match_init", "payload": {
        "sport_id": sport_id, "home_team_id": "h", "away_team_id": "a"}})
    api.post("/audit/v1/events", json={"event_id": "new-1", "match_id": "new", "type": "match_start", "payload": {}})
    for i, kind in enumerate(("goal", "super_shot")):
        r = api.post("/audit/v1/events", json={"event_id": f"new-s{i}", "match_id": "new", "type": "score",
                                               "payload": {"team_id": "h", "event_type": kind}})
        assert r.status_code == 201, r.text
    assert api.get("/audit/v1/score/new").json()["home"]["score"] == 5


def test_rule_edit_validation_and_roles(api):
    api.reset()
    sport_id = new_sport(api)
    assert api.put(f"/api/v1/sports/{sport_id}", json=NETBALL, headers=login(api, "manager")).status_code == 403
    bad = api.put(f"/api/v1/sports/{sport_id}", json={**NETBALL, "scoring_events": {}}, headers=login(api, "admin"))
    assert bad.status_code == 400 and bad.json()["error"]["details"]["fields"] == ["scoring_events"]
    assert api.put("/api/v1/sports/ghost", json=NETBALL, headers=login(api, "admin")).status_code == 404
    clash = api.put(f"/api/v1/sports/{sport_id}", json={**NETBALL, "name": "Football"}, headers=login(api, "admin"))
    assert clash.status_code == 409


# ------------------------------------------------------------------ admin deletes

def test_delete_sport_only_when_unused_and_custom(api):
    api.reset()
    sport_id = new_sport(api)
    assert api.delete(f"/api/v1/sports/{sport_id}", headers=login(api, "organizer")).status_code == 403
    builtin = api.delete("/api/v1/sports/football", headers=login(api, "admin"))
    assert builtin.status_code == 409 and builtin.json()["error"]["code"] == "SPORT_IN_USE"
    assert api.delete(f"/api/v1/sports/{sport_id}", headers=login(api, "admin")).status_code == 200
    assert api.delete(f"/api/v1/sports/{sport_id}", headers=login(api, "admin")).status_code == 404


def test_deleted_product_leaves_store_checkout_and_match_page(api):
    api.reset()
    buyer = login(api, "player")
    assert api.delete("/api/v1/store/products/prod-jersey-001", headers=buyer).status_code == 403
    assert api.delete("/api/v1/store/products/prod-jersey-b01", headers=login(api, "manager")).status_code == 403
    r = api.delete("/api/v1/store/products/prod-jersey-001", headers=login(api, "manager"))
    assert r.status_code == 200
    ids = [p["product_id"] for p in api.get("/api/v1/store/products", headers=buyer).json()]
    assert "prod-jersey-001" not in ids
    assert api.get("/api/v1/matches/alpha1-m04", headers=buyer).json()["pinned_product"] is None
    gone = api.post("/api/v1/store/checkout", headers=buyer, json={
        "order_id": "ord-del-1", "items": [{"variant_id": "var-jersey-001-L", "quantity": 1}], "discount_code": None,
        "payment": {"token": "tok_success"}})
    assert gone.status_code == 404
    assert api.delete("/api/v1/store/products/prod-jersey-001", headers=login(api, "admin")).status_code == 404


def test_delete_club_only_without_fixtures_or_players(api):
    api.reset()
    admin = login(api, "admin")
    assert api.delete("/api/v1/clubs/club-alpha-3", headers=login(api, "manager")).status_code == 403
    busy = api.delete("/api/v1/clubs/club-alpha-3", headers=admin)
    assert busy.status_code == 409 and busy.json()["error"]["details"]["fixtures"] > 0
    api.post("/audit/v1/roster/setup", json={
        "league": {"league_id": "spare", "tenant_id": "tenant-alpha", "sport_id": "football",
                   "transfer_window": {"open": "2026-01-01", "close": "2099-12-31"}, "max_squad_size": 5,
                   "required_positions": {}},
        "squads": [{"squad_id": "empty-club"}], "players": []})
    assert api.delete("/api/v1/clubs/empty-club", headers=admin).status_code == 200
    assert api.delete("/api/v1/clubs/empty-club", headers=admin).status_code == 404
