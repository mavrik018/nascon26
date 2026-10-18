"""Day 1 gaps: FR-1.2 competitions (divisions, hybrid), FR-2.2 add player, FR-2.3 scheduled prices and
live product pinning, and the demo seed for every sport."""
import pytest

from test_mobile_api import login


def checkout(api, h, order_id, variant_id):
    return api.post("/api/v1/store/checkout", headers=h, json={
        "order_id": order_id, "items": [{"variant_id": variant_id, "quantity": 1}], "discount_code": None,
        "payment": {"token": "tok_success"}})


# ------------------------------------------------------------------ FR-2.3 scheduled price changes

def test_price_change_applies_from_its_time_everywhere(api):
    api.reset()
    mgr, buyer = login(api, "manager"), login(api, "player")
    url = "/api/v1/store/variants/var-scarf-001-STD/price-changes"
    assert api.post(url, json={"price_minor": 99000, "effective_at": "2099-01-01T00:00:00Z"},
                    headers=mgr).status_code == 201
    price = lambda: next(v["price_minor"] for p in api.get("/api/v1/store/products", headers=buyer).json()
                         for v in p["variants"] if v["variant_id"] == "var-scarf-001-STD")
    assert price() == 150000  # future change: not yet
    assert api.post(url, json={"price_minor": 100000, "effective_at": "2026-01-01T00:00:00Z"},
                    headers=mgr).status_code == 201
    assert price() == 100000
    r = checkout(api, buyer, "ord-price-1", "var-scarf-001-STD")
    assert r.status_code == 201 and r.json()["receipt"]["payload"]["items"][0]["unit_price_minor"] == 100000


@pytest.mark.parametrize("body,field", [
    ({"price_minor": -1, "effective_at": "2026-01-01T00:00:00Z"}, "price_minor"),
    ({"price_minor": 10, "effective_at": "tomorrow"}, "effective_at"),
])
def test_price_change_validation_and_roles(api, body, field):
    api.reset()
    url = "/api/v1/store/variants/var-scarf-001-STD/price-changes"
    r = api.post(url, json=body, headers=login(api, "manager"))
    assert r.status_code == 400 and r.json()["error"]["details"]["fields"] == [field]
    ok = {"price_minor": 10, "effective_at": "2026-01-01T00:00:00Z"}
    assert api.post(url, json=ok, headers=login(api, "player")).status_code == 403
    assert api.post("/api/v1/store/variants/var-jersey-b01-M/price-changes", json=ok,
                    headers=login(api, "manager")).status_code == 403   # another tenant
    assert api.post("/api/v1/store/variants/nope/price-changes", json=ok,
                    headers=login(api, "admin")).status_code == 404


# ------------------------------------------------------------------ FR-2.3 pinning a product on a match

def test_organizer_pins_and_unpins_a_product(api):
    api.reset()
    h = login(api, "organizer")
    r = api.post("/api/v1/matches/alpha1-m05/pin", json={"product_id": "prod-scarf-001"}, headers=h)
    assert r.status_code == 200 and r.json()["pinned_product"]["product_id"] == "prod-scarf-001"
    assert api.get("/api/v1/matches/alpha1-m05", headers=login(api, "viewer")).json()["pinned_product"][
        "name"] == "Alpha FC Supporter Scarf"
    assert api.post("/api/v1/matches/alpha1-m05/pin", json={"product_id": None}, headers=h).json()[
        "pinned_product"] is None
    assert api.post("/api/v1/matches/alpha1-m05/pin", json={"product_id": "ghost"}, headers=h).status_code == 404
    assert api.post("/api/v1/matches/alpha1-m05/pin", json={}, headers=h).status_code == 400
    assert api.post("/api/v1/matches/alpha1-m05/pin", json={"product_id": "prod-cap-001"},
                    headers=login(api, "manager")).status_code == 403


# ------------------------------------------------------------------ FR-2.2 add player

def test_manager_adds_a_player_to_own_squad(api):
    api.reset()
    h = login(api, "manager")
    r = api.post("/api/v1/roster/players", headers=h, json={
        "league_id": "league-alpha-1", "squad_id": "club-alpha-1", "name": "New Signing", "position": "mf",
        "reason": "academy graduate"})
    assert r.status_code == 201, r.text
    pid = r.json()["player_id"]
    roster = api.get("/api/v1/clubs/club-alpha-1", headers=h).json()["roster"]
    assert any(p["player_id"] == pid and p["role"] == "substitute" for p in roster)
    history = api.get(f"/api/v1/roster/players/{pid}/history", headers=h).json()["history"]
    assert [e["action"] for e in history] == ["add"] and history[0]["why"] == "academy graduate"


def test_add_player_rules(api):
    api.reset()
    base = {"league_id": "league-alpha-1", "squad_id": "club-alpha-2", "name": "X", "position": "mf"}
    assert api.post("/api/v1/roster/players", json=base, headers=login(api, "manager")).status_code == 403
    assert api.post("/api/v1/roster/players", json=base, headers=login(api, "player")).status_code == 403
    assert api.post("/api/v1/roster/players", json={**base, "role": "boss"},
                    headers=login(api, "admin")).status_code == 400
    assert api.post("/api/v1/roster/players", json={**base, "squad_id": "nope"},
                    headers=login(api, "admin")).status_code == 404
    api.post("/audit/v1/roster/setup", json={
        "league": {"league_id": "tiny", "tenant_id": "tenant-alpha", "sport_id": "football",
                   "transfer_window": {"open": "2026-01-01", "close": "2099-12-31"}, "max_squad_size": 1,
                   "required_positions": {}},
        "squads": [{"squad_id": "tiny-a"}], "players": [{"player_id": "tiny-1", "name": "A", "position": "gk",
                                                         "squad_id": "tiny-a"}]})
    full = api.post("/api/v1/roster/players", json={**base, "league_id": "tiny", "squad_id": "tiny-a"},
                    headers=login(api, "admin"))
    assert full.status_code == 409 and full.json()["error"]["code"] == "SQUAD_FULL"


# ------------------------------------------------------------------ FR-1.2 competitions

def divisions_body(**extra):
    return {"competition_id": "pl-2026", "name": "Pro League", "season": "2026", "sport_id": "football",
            "format": "divisions", "promotion_spots": 1, "relegation_spots": 1, "tenant_id": "tenant-alpha",
            "stages": [{"league_id": "pl-d1", "name": "Division 1", "teams": ["a1", "a2", "a3"]},
                       {"league_id": "pl-d2", "name": "Division 2", "teams": ["b1", "b2", "b3"]}], **extra}


def play(api, match_id, home_goals, away_goals, home, away):
    events = [("match_start", {})] + [("score", {"team_id": home, "event_type": "goal"})] * home_goals \
        + [("score", {"team_id": away, "event_type": "goal"})] * away_goals + [("match_end", {})]
    for i, (t, p) in enumerate(events):
        r = api.post("/audit/v1/events", json={"event_id": f"{match_id}-e{i}", "match_id": match_id, "type": t,
                                               "payload": p})
        assert r.status_code == 201, r.text


def test_divisions_promote_and_relegate_from_live_standings(api):
    api.reset()
    admin = login(api, "admin")
    r = api.post("/api/v1/competitions", json=divisions_body(), headers=admin)
    assert r.status_code == 201, r.text
    comp = r.json()
    assert comp["provisional"] is True and [d["league_id"] for d in comp["divisions"]] == ["pl-d1", "pl-d2"]
    fixtures = api.get("/api/v1/leagues/pl-d2/fixtures", headers=admin).json()
    assert len(fixtures) == 3   # circle-method single round robin of 3 teams
    for f in api.get("/api/v1/leagues/pl-d1/fixtures", headers=admin).json() + fixtures:
        home_wins = f["home"] < f["away"]  # x1 beats everyone, x2 beats x3
        play(api, f["match_id"], int(home_wins), int(not home_wins), f["home"], f["away"])
    comp = api.get("/api/v1/competitions/pl-2026", headers=login(api, "viewer")).json()
    assert comp["provisional"] is False
    assert comp["movements"] == [
        {"team_id": "a3", "type": "relegated", "from_league_id": "pl-d1", "to_league_id": "pl-d2"},
        {"team_id": "b1", "type": "promoted", "from_league_id": "pl-d2", "to_league_id": "pl-d1"}]


def test_hybrid_seeds_group_winners_against_runners_up(api):
    api.reset()
    admin = login(api, "admin")
    body = {**divisions_body(competition_id="cup-2026", format="hybrid", advance_per_group=2),
            "stages": [{"league_id": "cup-ga", "teams": ["ga1", "ga2", "ga3"]},
                       {"league_id": "cup-gb", "teams": ["gb1", "gb2", "gb3"]}]}
    r = api.post("/api/v1/competitions", json=body, headers=admin)
    assert r.status_code == 201, r.text
    for league in ("cup-ga", "cup-gb"):
        for f in api.get(f"/api/v1/leagues/{league}/fixtures", headers=admin).json():
            home_wins = f["home"] < f["away"]
            play(api, f["match_id"], int(home_wins), int(not home_wins), f["home"], f["away"])
    comp = api.get("/api/v1/competitions/cup-2026", headers=admin).json()
    assert comp["qualifiers"] == ["ga1", "gb1", "ga2", "gb2"]
    first_round = comp["knockout"]["rounds"][0]["matches"]
    assert {(m["home"], m["away"]) for m in first_round} == {("ga1", "gb2"), ("gb1", "ga2")}


@pytest.mark.parametrize("change,field", [
    ({"format": "ladder"}, "format"),
    ({"promotion_spots": 3}, "promotion_spots"),     # must leave someone behind in a 3-team division
    ({"stages": [{"league_id": "x", "teams": ["a", "b"]}]}, "stages"),
    ({"stages": [{"league_id": "x", "teams": ["a", "b"]}, {"league_id": "y", "teams": ["a", "c"]}]}, "stages"),
])
def test_competition_validation(api, change, field):
    api.reset()
    r = api.post("/api/v1/competitions", json=divisions_body(**change), headers=login(api, "admin"))
    assert r.status_code == 400 and field in r.json()["error"]["details"]["fields"]


def test_competition_roles_and_lookup(api):
    api.reset()
    assert api.post("/api/v1/competitions", json=divisions_body(),
                    headers=login(api, "organizer")).status_code == 403
    assert api.post("/api/v1/competitions", json=divisions_body(), headers=login(api, "admin")).status_code == 201
    again = api.post("/api/v1/competitions", json=divisions_body(), headers=login(api, "admin"))
    assert again.status_code == 409 and again.json()["error"]["code"] == "COMPETITION_EXISTS"
    assert api.get("/api/v1/competitions/nope", headers=login(api, "admin")).status_code == 404


# ------------------------------------------------------------------ demo seed covers every sport

@pytest.mark.parametrize("club_id,min_players", [
    ("club-alpha-3", 5), ("club-alpha-4", 5), ("hoops-falcons", 5), ("cricket-hawks", 6), ("esports-vortex", 5)])
def test_every_demo_team_has_a_club_page_and_roster(api, club_id, min_players):
    api.reset()
    club = api.get(f"/api/v1/clubs/{club_id}", headers=login(api, "viewer")).json()
    assert club["home_venue"]["name"] and len(club["staff"]) == 3 and len(club["roster"]) >= min_players
    assert any(p["role"] == "captain" for p in club["roster"])


# ------------------------------------------------------------------ validation branches of the store / roster routes

@pytest.mark.parametrize("change,field", [
    ({"name": " "}, "name"), ({"category": ""}, "category"), ({"image_url": "ftp://x"}, "image_url"),
    ({"description": 5}, "description"), ({"variants": [{"label": "M", "price_minor": -1, "stock": 1}]}, "variants"),
])
def test_add_product_validation(api, change, field):
    api.reset()
    body = {"name": "Mug", "category": "accessories", "variants": [{"label": "One", "price_minor": 100, "stock": 1}],
            **change}
    r = api.post("/api/v1/store/products", json=body, headers=login(api, "manager"))
    assert r.status_code == 400 and field in r.json()["error"]["details"]["fields"]
    assert api.post("/api/v1/store/products", json=[1], headers=login(api, "manager")).status_code == 400


def test_price_change_rejects_impossible_dates_and_bad_bodies(api):
    api.reset()
    url = "/api/v1/store/variants/var-scarf-001-STD/price-changes"
    h = login(api, "manager")
    assert api.post(url, json={"price_minor": 1, "effective_at": "2026-13-40T00:00:00Z"},
                    headers=h).json()["error"]["details"]["fields"] == ["effective_at"]
    assert api.post(url, json=[1], headers=h).status_code == 400


def test_add_player_league_window_and_body_checks(api):
    api.reset()
    admin = login(api, "admin")
    base = {"league_id": "league-alpha-1", "squad_id": "club-alpha-1", "name": "X", "position": "mf"}
    assert api.post("/api/v1/roster/players", json=[1], headers=admin).status_code == 400
    assert api.post("/api/v1/roster/players", json={**base, "reason": ""}, headers=admin).status_code == 400
    assert api.post("/api/v1/roster/players", json={**base, "league_id": "nope"}, headers=admin).status_code == 404
    api.post("/audit/v1/roster/setup", json={
        "league": {"league_id": "closed", "tenant_id": "tenant-alpha", "sport_id": "football",
                   "transfer_window": {"open": "2020-01-01", "close": "2020-12-31"}, "max_squad_size": 5,
                   "required_positions": {}},
        "squads": [{"squad_id": "closed-a"}], "players": []})
    r = api.post("/api/v1/roster/players", json={**base, "league_id": "closed", "squad_id": "closed-a"},
                 headers=admin)
    assert r.status_code == 409 and r.json()["error"]["code"] == "TRANSFER_WINDOW_CLOSED"
