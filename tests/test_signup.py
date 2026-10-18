"""Player self sign-up: account + player profile; the new player can log in, follow, appear as an athlete."""


def register(api, email="new.player@nascon.test", **extra):
    body = {"email": email, "password": "Strong#Pass1", "display_name": "Sara Malik", **extra}
    return api.post("/api/v1/auth/register", json=body)


def test_register_creates_player_login_and_athlete_profile(api):
    api.reset()
    r = register(api, position="fw")
    assert r.status_code == 201, r.text
    body = r.json()
    user = body["user"]
    assert user["role"] == "player" and user["club_id"] == "club-alpha-1" and user["player_id"].startswith("player-")
    assert body["token"] and body["tenant"]["tenant_id"] == "tenant-alpha"

    login = api.post("/api/v1/auth/login", json={"email": "NEW.player@nascon.test", "password": "Strong#Pass1"})
    assert login.status_code == 200 and login.json()["user"]["user_id"] == user["user_id"]

    profile = api.get(f"/api/v1/athletes/{user['player_id']}")
    assert profile.status_code == 200 and profile.json()["name"] == "Sara Malik"
    assert profile.json()["position"] == "fw"


def test_register_errors(api):
    api.reset()
    assert register(api).status_code == 201
    dup = register(api)
    assert dup.status_code == 409 and dup.json()["error"]["code"] == "EMAIL_TAKEN"
    assert register(api, email="x@nascon.test", club_id="club-ghost").json()["error"]["code"] == "CLUB_NOT_FOUND"
    for bad in ({"email": "no-at-sign"}, {"password": "short"}, {"position": "striker"}, {"display_name": " "},
                {"club_id": 5}):
        assert register(api, **{"email": "y@nascon.test", **bad}).status_code == 400, bad
    assert api.post("/api/v1/auth/register", json=[]).status_code == 400
    assert api.post("/api/v1/auth/register", json={"email": "z@nascon.test"}).status_code == 400
