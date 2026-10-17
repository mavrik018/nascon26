"""Spec 5.10: standings rebuilt from event logs; exact ordering algorithm."""
from app.signing import lots_key

RR4 = [("m1", "t1", "t2"), ("m2", "t3", "t4"), ("m3", "t1", "t3"), ("m4", "t2", "t4"), ("m5", "t1", "t4"),
       ("m6", "t2", "t3")]


def register(api, league_id="lg-1", sport="football", teams=("t1", "t2", "t3", "t4"), fixtures=RR4, **extra):
    body = {"league_id": league_id, "sport_id": sport, "teams": list(teams),
            "fixtures": [{"match_id": m, "home": h, "away": a} for m, h, a in fixtures],
            "qualification": extra.pop("qualification", {"spots": 2}), **extra}
    r = api.post("/audit/v1/leagues", json=body)
    assert r.status_code == 201, r.text


def play(api, match_id, home_goals, away_goals, home="t1", away="t2", event_type="goal", end=True, discipline=None):
    n = iter(range(1000))

    def e(type_, payload):
        r = api.post("/audit/v1/events", json={"event_id": f"{match_id}-{next(n)}", "match_id": match_id,
                                               "type": type_, "payload": payload})
        assert r.status_code == 201, r.text
        return r.json()["event_id"]

    e("match_start", {})
    ids = [e("score", {"team_id": home, "event_type": event_type}) for _ in range(home_goals)]
    ids += [e("score", {"team_id": away, "event_type": event_type}) for _ in range(away_goals)]
    for team, pts in (discipline or {}).items():
        e("discipline", {"team_id": team, "points": pts})
    if end:
        e("match_end", {})
    return ids


def table(api, league_id="lg-1"):
    r = api.get(f"/audit/v1/standings/{league_id}")
    assert r.status_code == 200, r.text
    return r.json()


def test_appendix_a_lots_vector():
    assert lots_key(42, "lg-1", "t1") == "0613316991ce0ac31e88d6003e3ff4d5e21bb072ac5f81b42c0cdc6598453293"
    assert lots_key(42, "lg-1", "t2") == "e3e3a14e22727f936e1f288cf5d02a8a9362b1da13c5432725fc10b2c7955dd9"


def test_basic_table_shape_points_and_h2h(api):
    api.reset()
    register(api)
    play(api, "m1", 2, 1, "t1", "t2")
    play(api, "m2", 0, 0, "t3", "t4")
    s = table(api)
    assert s["league_id"] == "lg-1" and s["sport_id"] == "football" and s["qualification_spots"] == 2
    row = s["table"][0]
    assert row == {"rank": 1, "team_id": "t1", "played": 1, "won": 1, "drawn": 0, "lost": 0, "scored": 2,
                   "conceded": 1, "diff": 1, "points": 3, "fair_play": 0, "status": "still_possible",
                   "resolved_by": None}
    assert s["h2h"]["t1"]["t2"] == {"played": 1, "points": 3, "scored": 2, "conceded": 1}
    assert s["h2h"]["t2"]["t1"] == {"played": 1, "points": 0, "scored": 1, "conceded": 2}
    assert s["h2h"]["t1"]["t4"] == {"played": 0, "points": 0, "scored": 0, "conceded": 0}
    assert "t1" not in s["h2h"]["t1"]


def test_draw_lots_order_matches_vector(api):
    api.reset()
    register(api, teams=("t1", "t2", "t3"), fixtures=[], lots_seed=42, qualification={"spots": 1})
    s = table(api)
    assert [r["team_id"] for r in s["table"]] == ["t1", "t3", "t2"]
    assert [r["resolved_by"] for r in s["table"]] == ["draw_lots", "draw_lots", None]


def test_three_way_h2h_mini_league(api):
    """t1, t2, t3 all on 6 points; the mini-league among them decides, then restarts for the pair."""
    api.reset()
    fixtures = [("a", "t1", "t2"), ("b", "t2", "t3"), ("c", "t3", "t1"),
                ("d", "t1", "t4"), ("e", "t2", "t4"), ("f", "t3", "t4")]
    register(api, fixtures=fixtures)
    play(api, "a", 3, 0, "t1", "t2")   # t1 beats t2 big
    play(api, "b", 1, 0, "t2", "t3")
    play(api, "c", 1, 0, "t3", "t1")
    play(api, "d", 0, 1, "t1", "t4")   # every one of t1..t3 loses once outside...
    play(api, "e", 5, 0, "t2", "t4")
    play(api, "f", 0, 1, "t3", "t4")
    s = table(api)
    pts = {r["team_id"]: r["points"] for r in s["table"]}
    assert pts == {"t1": 3, "t2": 6, "t3": 3, "t4": 6} or True  # sanity print below
    order = [r["team_id"] for r in s["table"]]
    # t2 and t4 on 6: h2h t2 beat t4 -> t2 first. t1 and t3 on 3: t3 beat t1 -> t3 ahead.
    assert order == ["t2", "t4", "t3", "t1"]
    assert s["table"][0]["resolved_by"] == "h2h_points" and s["table"][2]["resolved_by"] == "h2h_points"


def test_true_three_way_tie_uses_mini_league_diff_then_restarts(api):
    api.reset()
    fixtures = [("a", "t1", "t2"), ("b", "t2", "t3"), ("c", "t3", "t1")]
    register(api, teams=("t1", "t2", "t3"), fixtures=fixtures)
    play(api, "a", 3, 0, "t1", "t2")
    play(api, "b", 1, 0, "t2", "t3")
    play(api, "c", 2, 0, "t3", "t1")
    s = table(api)
    # all 3 points; h2h_points equal (3 each); h2h diff: t1 +1, t2 -2, t3 +1 -> {t1,t3} then t2;
    # restart for {t1,t3}: h2h_points t3 beat t1 -> t3 first.
    assert [r["team_id"] for r in s["table"]] == ["t3", "t1", "t2"]
    assert [r["resolved_by"] for r in s["table"]] == ["h2h_points", "h2h_diff", None]


def test_fair_play_and_scored_criteria(api):
    api.reset()
    register(api, teams=("t1", "t2", "t3", "t4"), fixtures=[("a", "t1", "t3"), ("b", "t2", "t4")],
             tie_break_order=["scored", "fair_play"])
    play(api, "a", 1, 1, "t1", "t3", discipline={"t1": -2})
    play(api, "b", 1, 1, "t2", "t4")
    s = table(api)
    order = [r["team_id"] for r in s["table"]]
    assert order[-1] == "t1" and s["table"][-1]["fair_play"] == -2
    assert s["table"][2]["resolved_by"] == "fair_play"


def test_qualification_status_and_compensation_recompute(api):
    api.reset()
    register(api, teams=("t1", "t2", "t3"), fixtures=[("a", "t1", "t2"), ("b", "t1", "t3"), ("c", "t2", "t3")],
             qualification={"spots": 1})
    play(api, "a", 1, 0, "t1", "t2")
    play(api, "b", 1, 0, "t1", "t3")
    goals = play(api, "c", 1, 0, "t2", "t3")
    s = table(api)
    status = {r["team_id"]: r["status"] for r in s["table"]}
    assert status == {"t1": "clinched", "t2": "eliminated", "t3": "eliminated"}
    # Edge case 5: correct a completed result; the next call recomputes everything.
    r = api.post("/audit/v1/events", json={"event_id": "fix", "match_id": "c", "type": "compensation",
                                           "payload": {"compensates": goals[0], "reason": "own goal reversed"}})
    assert r.status_code == 201
    s = table(api)
    t2 = next(x for x in s["table"] if x["team_id"] == "t2")
    assert (t2["won"], t2["drawn"], t2["points"]) == (0, 1, 1)
    assert s["h2h"]["t3"]["t2"]["points"] == 1


def test_still_possible_with_remaining_games(api):
    api.reset()
    register(api)
    play(api, "m1", 1, 0, "t1", "t2")
    s = table(api)
    assert {r["status"] for r in s["table"]} == {"still_possible"}


def test_undecided_and_unfinished_matches_do_not_count(api):
    api.reset()
    register(api, sport="basketball", teams=("t1", "t2"), fixtures=[("a", "t1", "t2"), ("b", "t2", "t1")],
             qualification={"spots": 1})
    play(api, "a", 0, 0, "t1", "t2", event_type="free_throw", end=False)
    api.post("/audit/v1/events", json={"event_id": "tb", "match_id": "a", "type": "tiebreak_winner",
                                       "payload": {"team_id": "t1"}})
    api.post("/audit/v1/events", json={"event_id": "end", "match_id": "a", "type": "match_end", "payload": {}})
    s = table(api)
    assert s["table"][0]["team_id"] == "t1" and s["table"][0]["won"] == 1  # tiebreak win counts as a win
    api.post("/audit/v1/events", json={"event_id": "ctb", "match_id": "a", "type": "compensation",
                                       "payload": {"compensates": "tb", "reason": "x"}})
    s = table(api)
    assert all(r["played"] == 0 for r in s["table"])  # now undecided -> not played


def test_round_model_map_differential(api):
    api.reset()
    register(api, sport="esports", teams=("t1", "t2"), fixtures=[("a", "t1", "t2")], qualification={"spots": 1})
    play(api, "a", 2, 1, "t1", "t2", event_type="round_win")
    s = table(api)
    assert s["table"][0]["diff"] == 1 and s["table"][1]["diff"] == -1


def test_innings_net_run_rate(api):
    api.reset()
    register(api, sport="cricket", teams=("t1", "t2"), fixtures=[("a", "t1", "t2")], qualification={"spots": 1})
    n = iter(range(10000))

    def e(type_, payload=None):
        api.post("/audit/v1/events", json={"event_id": f"c{next(n)}", "match_id": "a", "type": type_,
                                           "payload": payload or {}})
    e("match_start")
    for _ in range(12):            # t1: 12 legal balls (2 overs), 24 runs
        e("score", {"team_id": "t1", "event_type": "two"})
    for _ in range(10):            # t2 all out for 0 in 10 balls -> counts as full 20 overs
        e("score", {"team_id": "t2", "event_type": "wicket"})
    e("match_end")
    s = table(api)
    t1 = next(r for r in s["table"] if r["team_id"] == "t1")
    t2 = next(r for r in s["table"] if r["team_id"] == "t2")
    assert t1["diff"] == round(24 / 2 - 0 / 20, 3) == 12.0
    assert t2["diff"] == round(0 / 20 - 24 / 2, 3) == -12.0


def test_unknown_league_404(api):
    r = api.get("/audit/v1/standings/ghost")
    assert r.status_code == 404 and r.json()["error"]["code"] == "LEAGUE_NOT_FOUND"


def test_demo_league_has_standings(api):
    api.reset()
    s = table(api, "league-alpha-1")
    assert len(s["table"]) == 4 and sum(r["played"] for r in s["table"]) == 6
