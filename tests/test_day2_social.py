"""FR-3.1 athlete profile and concurrency-safe follow graph; FR-4.3 guest/anonymous writes are 403."""
import random
import threading

PASSWORD = "Nascon@26"
USERS = ["player", "viewer", "manager", "organizer", "admin"]
ATHLETE = "player-alpha-1"


def token(api, user="player"):
    r = api.post("/api/v1/auth/login", json={"email": f"{user}@nascon.test", "password": PASSWORD})
    assert r.status_code == 200, r.text
    return r.json()["token"]


def auth(tok):
    return {"Authorization": f"Bearer {tok}"}


def event(api, event_id, match_id, type_, payload=None):
    r = api.post("/audit/v1/events", json={"event_id": event_id, "match_id": match_id, "type": type_,
                                           "payload": payload or {}})
    assert r.status_code in (200, 201), r.text


def test_profile_shape_career_upcoming_and_404(api):
    api.reset()
    event(api, "soc-m1-end", "match-m1", "match_end")  # seeded 1 - 0 to club-alpha-1
    event(api, "soc-up-init", "match-soc-up", "match_init",
          {"sport_id": "football", "home_team_id": "club-alpha-3", "away_team_id": "club-alpha-1",
           "league_id": "league-alpha-1"})
    r = api.get(f"/api/v1/athletes/{ATHLETE}")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["player_id"] == ATHLETE and body["name"] == "Ahmed Raza" and body["position"] == "fw"
    assert body["clubs"] == [{"club_id": "club-alpha-1", "league_id": "league-alpha-1",
                              "squad_id": "club-alpha-1", "role": "captain"}]
    m1 = next(m for m in body["career"]["matches"] if m["match_id"] == "match-m1")
    assert m1 == {"match_id": "match-m1", "opponent": "club-alpha-2", "result": "win", "score": "1-0"}
    c = body["career"]
    assert c["played"] == len(c["matches"]) == c["won"] + c["drawn"] + c["lost"] and c["won"] >= 1
    assert {"match_id": "match-soc-up", "opponent": "club-alpha-3", "scheduled_at": None} in body["upcoming"]
    assert body["vod"] == [] and body["followers_count"] == 0

    # The away side sees the same match as a loss.
    other = api.get("/api/v1/athletes/player-alpha-2").json()
    assert {"match_id": "match-m1", "opponent": "club-alpha-1", "result": "loss", "score": "0-1"} \
        in other["career"]["matches"]

    r = api.get("/api/v1/athletes/player-nobody")
    assert r.status_code == 404 and r.json()["error"]["code"] == "PLAYER_NOT_FOUND"


def test_follow_unfollow_idempotent(api):
    api.reset()
    h = auth(token(api))
    url = f"/api/v1/athletes/{ATHLETE}/follow"
    for _ in range(2):
        r = api.put(url, headers=h)
        assert r.status_code == 200, r.text
        assert r.json() == {"athlete_id": ATHLETE, "follower_id": "user-player", "following": True,
                            "followers_count": 1}
    assert api.get(f"/api/v1/athletes/{ATHLETE}").json()["followers_count"] == 1
    for _ in range(2):
        r = api.delete(url, headers=h)
        assert r.status_code == 200 and r.json()["following"] is False and r.json()["followers_count"] == 0
    assert api.post(url + "/toggle", headers=h).json()["following"] is True
    assert api.post(url + "/toggle", headers=h).json() == {"athlete_id": ATHLETE, "follower_id": "user-player",
                                                           "following": False, "followers_count": 0}
    r = api.put("/api/v1/athletes/player-nobody/follow", headers=h)
    assert r.status_code == 404 and r.json()["error"]["code"] == "PLAYER_NOT_FOUND"


def test_guest_and_anonymous_cannot_follow(api):
    api.reset()
    url = f"/api/v1/athletes/{ATHLETE}/follow"
    for method, path in [("PUT", url), ("DELETE", url), ("POST", url + "/toggle")]:
        r = api.request(method, path, headers=auth("guest_anon_tok_7721"))
        assert r.status_code == 403 and r.json()["error"]["code"] == "GUEST_WRITE_FORBIDDEN"
        r = api.request(method, path)
        assert r.status_code == 403 and r.json()["error"]["code"] == "GUEST_WRITE_FORBIDDEN"
    assert api.put(url, headers=auth("not-a-jwt")).status_code == 401
    assert api.get(f"/api/v1/athletes/{ATHLETE}").json()["followers_count"] == 0


def test_toggle_burst_has_zero_count_drift(api):
    api.reset()
    tokens = {u: token(api, u) for u in USERS}
    url = f"/api/v1/athletes/{ATHLETE}/follow"
    barrier = threading.Barrier(20)
    errors = []
    rng = random.Random(26)
    plans = [[rng.choice(USERS) for _ in range(3)] for _ in range(20)]  # 60 toggles: under the 100 per 10 s per-IP limit

    def worker(i):
        barrier.wait()
        for user in plans[i]:
            r = api.post(url + "/toggle", headers=auth(tokens[user]))
            if r.status_code != 200:
                errors.append((r.status_code, r.text))

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(60)
    assert errors == []
    # Each user's final state is the parity of their toggles; PUT reports it without changing it.
    toggles = {u: sum(p.count(u) for p in plans) for u in USERS}
    expected = sum(1 for u in USERS if toggles[u] % 2)
    assert api.get(f"/api/v1/athletes/{ATHLETE}").json()["followers_count"] == expected
    for u in USERS:  # idempotent re-assertion of each final state leaves the counter untouched
        method = api.put if toggles[u] % 2 else api.delete
        b = method(url, headers=auth(tokens[u])).json()
        assert b["following"] is bool(toggles[u] % 2) and b["followers_count"] == expected
    # Unfollowing everyone brings the counter back to exactly zero (never negative, never drifted).
    for u in USERS:
        api.delete(url, headers=auth(tokens[u]))
    assert api.get(f"/api/v1/athletes/{ATHLETE}").json()["followers_count"] == 0


def test_profile_remembers_that_the_viewer_follows(api):
    """Opening the profile again shows the saved follow (the app's button starts in the right state)."""
    api.reset()
    tok = token(api, "viewer")
    assert api.get(f"/api/v1/athletes/{ATHLETE}", headers=auth(tok)).json()["following"] is False
    assert api.put(f"/api/v1/athletes/{ATHLETE}/follow", headers=auth(tok)).status_code == 200
    again = api.get(f"/api/v1/athletes/{ATHLETE}", headers=auth(tok)).json()
    assert again["following"] is True and again["followers_count"] == 1
    assert api.get(f"/api/v1/athletes/{ATHLETE}").json()["following"] is False  # anonymous reader
    assert api.get(f"/api/v1/athletes/{ATHLETE}", headers=auth("guest_anon_tok_7721")).json()["following"] is False
    assert api.get(f"/api/v1/athletes/{ATHLETE}", headers=auth("not-a-jwt")).json()["following"] is False
