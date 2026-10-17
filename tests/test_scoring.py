"""Spec 5.6, 5.8, 5.9: mystery sports, league registration, event log, score projection."""
import pytest

from app.signing import sign
from conftest import SALT

KABADDI = {
    "sport_id": "kabaddi", "name": "Kabaddi", "scoring_model": "event",
    "periods": {"count": 2, "duration_minutes": 20},
    "scoring_events": {"raid_point": {"points": 1}, "tackle_point": {"points": 1}, "all_out": {"points": 2}},
    "draw_allowed": False, "overtime": {"policy": "golden_score", "duration_minutes": 5},
    "tie_break_order": ["h2h_points", "h2h_diff", "overall_diff", "scored", "fair_play", "draw_lots"],
    "roster": {"min_squad_size": 7, "max_squad_size": 12, "required_positions": {"raider": 2, "defender": 3}},
}


def ev(api, event_id, match_id, type_, payload):
    return api.post("/audit/v1/events", json={"event_id": event_id, "match_id": match_id, "type": type_,
                                              "payload": payload})


def init(api, match_id="m1", sport="football", home="t1", away="t2", start=True):
    r = ev(api, f"{match_id}-init", match_id, "match_init",
           {"sport_id": sport, "home_team_id": home, "away_team_id": away})
    assert r.status_code == 201, r.text
    if start:
        assert ev(api, f"{match_id}-start", match_id, "match_start", {}).status_code == 201


def code(r):
    return r.json()["error"]["code"]


# ------------------------------------------------------------------ signature (Appendix A)

def test_appendix_a_signature_vector():
    assert sign("evt-1", {"team_id": "t1", "event_type": "goal"}, salt="demo-salt") == \
        "972a8b558690b19121cc5bea84978f85e8eb15a3735018db36616bab1d7ec501"


def test_signature_uses_unicode_unescaped_and_sorted_keys():
    a = sign("e", {"b": 1, "a": "ü"}, salt="s")
    b = sign("e", {"a": "ü", "b": 1}, salt="s")
    assert a == b and len(a) == 64 and a == a.lower()


# ------------------------------------------------------------------ sports (5.6)

def test_create_mystery_sport(api):
    api.reset()
    r = api.post("/audit/v1/sports", json=KABADDI)
    assert r.status_code == 201
    assert r.json()["sport_id"] == "kabaddi" and r.json()["status"] == "created"
    assert r.json()["config"]["scoring_events"] == KABADDI["scoring_events"]
    assert api.post("/audit/v1/sports", json=KABADDI).status_code == 409
    assert code(api.post("/audit/v1/sports", json=KABADDI)) == "SPORT_EXISTS"


@pytest.mark.parametrize("field,value", [
    ("sport_id", "x'; DROP TABLE sports;--"), ("sport_id", "A"), ("name", ""), ("scoring_model", "points"),
    ("periods", {"count": 0, "duration_minutes": 20}), ("scoring_events", {}),
    ("scoring_events", {"Bad Key": {"points": 1}}), ("scoring_events", {"x": {"points": 0}}),
    ("draw_allowed", "no"), ("overtime", {"policy": "sudden"}), ("tie_break_order", ["h2h_points", "h2h_points"]),
    ("roster", {"min_squad_size": 9, "max_squad_size": 3, "required_positions": {}}),
])
def test_invalid_sport_is_400_with_field(api, field, value):
    r = api.post("/audit/v1/sports", json={**KABADDI, "sport_id": "kab2", field: value})
    assert r.status_code == 400
    assert code(r) == "VALIDATION_ERROR" and field in r.json()["error"]["details"]["fields"]


def test_sport_models_validate_their_own_periods(api):
    api.reset()
    innings = {**KABADDI, "sport_id": "mini_cricket", "scoring_model": "innings",
               "periods": {"innings_per_team": 1, "overs_per_innings": 1, "balls_per_over": 2, "wickets_per_innings": 1},
               "scoring_events": {"super_six": {"runs": 6, "legal_ball": True, "wicket": False},
                                  "bye_run": {"runs": 1, "legal_ball": False, "wicket": False},
                                  "out": {"runs": 0, "legal_ball": True, "wicket": True}}}
    assert api.post("/audit/v1/sports", json=innings).status_code == 201
    rounds = {**KABADDI, "sport_id": "chess960", "scoring_model": "round", "periods": {"best_of": 4},
              "scoring_events": {"map_win": {"rounds": 1}}}
    assert api.post("/audit/v1/sports", json=rounds).status_code == 400
    rounds["periods"] = {"best_of": 3}
    assert api.post("/audit/v1/sports", json=rounds).status_code == 201


# ------------------------------------------------------------------ events (5.9)

def test_event_response_and_signature(api):
    api.reset()
    init(api)
    r = ev(api, "evt-0003", "m1", "score", {"team_id": "t1", "event_type": "goal"})
    assert r.status_code == 201
    assert r.json() == {"event_id": "evt-0003", "match_id": "m1", "type": "score", "sequence": 3,
                        "match_version": 3,
                        "signature": sign("evt-0003", {"team_id": "t1", "event_type": "goal"}, salt=SALT)}


def test_idempotent_replay_and_duplicate_event_id(api):
    api.reset()
    init(api)
    body = {"team_id": "t1", "event_type": "goal"}
    first = ev(api, "e1", "m1", "score", body)
    again = ev(api, "e1", "m1", "score", body)
    assert again.status_code == 200 and again.json() == first.json()
    assert api.get("/audit/v1/score/m1").json()["home"]["score"] == 1
    other = ev(api, "e1", "m1", "score", {"team_id": "t2", "event_type": "goal"})
    assert other.status_code == 409 and code(other) == "DUPLICATE_EVENT_ID"


def test_state_machine(api):
    api.reset()
    init(api, start=False)
    r = ev(api, "s1", "m1", "score", {"team_id": "t1", "event_type": "goal"})
    assert r.status_code == 409 and code(r) == "MATCH_NOT_IN_PROGRESS"
    assert code(ev(api, "end0", "m1", "match_end", {})) == "ILLEGAL_TRANSITION"
    assert ev(api, "st", "m1", "match_start", {}).status_code == 201
    assert code(ev(api, "st2", "m1", "match_start", {})) == "ILLEGAL_TRANSITION"
    assert ev(api, "end", "m1", "match_end", {}).status_code == 201
    assert api.get("/audit/v1/score/m1").json()["outcome"] == "draw"
    assert code(ev(api, "s2", "m1", "score", {"team_id": "t1", "event_type": "goal"})) == "MATCH_NOT_IN_PROGRESS"
    assert code(ev(api, "init2", "m1", "match_init",
                   {"sport_id": "football", "home_team_id": "a", "away_team_id": "b"})) == "MATCH_EXISTS"


def test_errors_for_missing_and_invalid(api):
    api.reset()
    assert code(ev(api, "x", "nope", "match_start", {})) == "MATCH_NOT_FOUND"
    assert code(ev(api, "x", "m9", "match_init",
                   {"sport_id": "curling", "home_team_id": "a", "away_team_id": "b"})) == "SPORT_NOT_FOUND"
    init(api)
    assert code(ev(api, "x1", "m1", "score", {"team_id": "t9", "event_type": "goal"})) == "VALIDATION_ERROR"
    r = ev(api, "x2", "m1", "score", {"team_id": "t1", "event_type": "touchdown"})
    assert r.status_code == 400 and code(r) == "UNKNOWN_EVENT_TYPE"
    assert code(ev(api, "x3", "m1", "teleport", {})) == "VALIDATION_ERROR"
    assert code(ev(api, "bad|id", "m1", "match_start", {})) == "VALIDATION_ERROR"
    assert api.post("/audit/v1/events", data="{", headers={"Content-Type": "application/json"}).status_code == 400
    assert code(api.get("/audit/v1/score/ghost")) == "MATCH_NOT_FOUND"


def test_compensation_rules(api):
    api.reset()
    init(api)
    init(api, match_id="m2")
    ev(api, "g1", "m1", "score", {"team_id": "t1", "event_type": "goal"})
    ev(api, "g2", "m1", "score", {"team_id": "t1", "event_type": "goal"})
    assert code(ev(api, "c0", "m1", "compensation", {"compensates": "ghost", "reason": "x"})) == "EVENT_NOT_FOUND"
    assert code(ev(api, "c1", "m1", "compensation", {"compensates": "m1-start", "reason": "x"})) == \
        "INVALID_COMPENSATION"
    assert code(ev(api, "c2", "m2", "compensation", {"compensates": "g1", "reason": "x"})) == "INVALID_COMPENSATION"
    r = ev(api, "c3", "m1", "compensation", {"compensates": "g2", "reason": "VAR: offside"})
    assert r.status_code == 201 and r.json()["sequence"] == 5
    assert code(ev(api, "c4", "m1", "compensation", {"compensates": "g2", "reason": "again"})) == \
        "INVALID_COMPENSATION"
    assert code(ev(api, "c5", "m1", "compensation", {"compensates": "c3", "reason": "x"})) == "INVALID_COMPENSATION"
    ev(api, "end", "m1", "match_end", {})
    score = api.get("/audit/v1/score/m1").json()
    assert score["home"]["score"] == 1 and score["outcome"] == "home_win" and score["version"] == 6
    g2 = next(e for e in score["events"] if e["event_id"] == "g2")
    assert g2["compensated"] is True and g2["compensated_by"] == "c3"
    # compensation after completion still allowed
    assert ev(api, "c6", "m1", "compensation", {"compensates": "g1", "reason": "late"}).status_code == 201
    assert api.get("/audit/v1/score/m1").json()["outcome"] == "draw"


def test_tie_not_allowed_and_tiebreak(api):
    api.reset()
    init(api, sport="basketball")
    r = ev(api, "end", "m1", "match_end", {})
    assert r.status_code == 409 and code(r) == "TIE_NOT_ALLOWED"
    ev(api, "tb", "m1", "tiebreak_winner", {"team_id": "t2"})
    assert ev(api, "end2", "m1", "match_end", {}).status_code == 201
    s = api.get("/audit/v1/score/m1").json()
    assert s["outcome"] == "away_win" and s["winner_team_id"] == "t2" and s["tiebreak_winner_team_id"] == "t2"
    ev(api, "ctb", "m1", "compensation", {"compensates": "tb", "reason": "void"})
    s = api.get("/audit/v1/score/m1").json()
    assert s["outcome"] == "undecided" and s["winner_team_id"] is None


def test_basketball_points_and_discipline(api):
    api.reset()
    init(api, sport="basketball")
    for i, t in enumerate(["three_pointer", "two_pointer", "free_throw"]):
        ev(api, f"b{i}", "m1", "score", {"team_id": "t1", "event_type": t})
    ev(api, "d1", "m1", "discipline", {"team_id": "t2", "points": -2})
    s = api.get("/audit/v1/score/m1").json()
    assert s["home"]["score"] == 6 and s["away"]["fair_play"] == -2
    assert s["home"]["wickets"] is None and s["home"]["overs"] is None
    assert code(ev(api, "d2", "m1", "discipline", {"team_id": "t2", "points": "x"})) == "VALIDATION_ERROR"


def test_innings_model_limits_and_overs(api):
    api.reset()
    sport = {**KABADDI, "sport_id": "mini_cricket", "scoring_model": "innings",
             "periods": {"innings_per_team": 1, "overs_per_innings": 1, "balls_per_over": 3, "wickets_per_innings": 2},
             "scoring_events": {"hit": {"runs": 4, "legal_ball": True, "wicket": False},
                                "extra": {"runs": 1, "legal_ball": False, "wicket": False},
                                "out": {"runs": 0, "legal_ball": True, "wicket": True}},
             "draw_allowed": True}
    assert api.post("/audit/v1/sports", json=sport).status_code == 201
    init(api, sport="mini_cricket")
    for i, t in enumerate(["hit", "extra", "hit"]):
        assert ev(api, f"h{i}", "m1", "score", {"team_id": "t1", "event_type": t}).status_code == 201
    s = api.get("/audit/v1/score/m1").json()["home"]
    assert (s["score"], s["balls"], s["wickets"], s["overs"]) == (9, 2, 0, "0.2")
    assert ev(api, "h3", "m1", "score", {"team_id": "t1", "event_type": "hit"}).status_code == 201
    r = ev(api, "h4", "m1", "score", {"team_id": "t1", "event_type": "extra"})
    assert r.status_code == 409 and code(r) == "INNINGS_COMPLETE"
    # compensated events do not count toward the limit
    ev(api, "ch", "m1", "compensation", {"compensates": "h3", "reason": "no ball"})
    assert ev(api, "h5", "m1", "score", {"team_id": "t1", "event_type": "out"}).status_code == 201
    assert ev(api, "w1", "m1", "score", {"team_id": "t2", "event_type": "out"}).status_code == 201
    assert ev(api, "w2", "m1", "score", {"team_id": "t2", "event_type": "out"}).status_code == 201
    assert code(ev(api, "w3", "m1", "score", {"team_id": "t2", "event_type": "hit"})) == "INNINGS_COMPLETE"
    s = api.get("/audit/v1/score/m1").json()["away"]
    assert s["wickets"] == 2 and s["overs"] == "0.2"


def test_round_model_series_decided(api):
    api.reset()
    init(api, sport="esports")
    assert ev(api, "r1", "m1", "score", {"team_id": "t1", "event_type": "round_win"}).status_code == 201
    assert ev(api, "r2", "m1", "score", {"team_id": "t1", "event_type": "round_win"}).status_code == 201
    r = ev(api, "r3", "m1", "score", {"team_id": "t1", "event_type": "round_win"})
    assert r.status_code == 409 and code(r) == "SERIES_ALREADY_DECIDED"
    assert ev(api, "r4", "m1", "score", {"team_id": "t2", "event_type": "round_win"}).status_code == 201


def test_mystery_sport_end_to_end(api):
    api.reset()
    api.post("/audit/v1/sports", json=KABADDI)
    init(api, sport="kabaddi")
    ev(api, "k1", "m1", "score", {"team_id": "t2", "event_type": "all_out"})
    ev(api, "k2", "m1", "score", {"team_id": "t1", "event_type": "raid_point"})
    assert code(ev(api, "k3", "m1", "score", {"team_id": "t1", "event_type": "goal"})) == "UNKNOWN_EVENT_TYPE"
    ev(api, "kend", "m1", "match_end", {})
    s = api.get("/audit/v1/score/m1").json()
    assert (s["home"]["score"], s["away"]["score"], s["outcome"]) == (1, 2, "away_win")
    assert [e["sequence"] for e in s["events"]] == [1, 2, 3, 4, 5]
    assert all(e["signature"] == sign(e["event_id"], e["payload"], salt=SALT) for e in s["events"])


# ------------------------------------------------------------------ leagues (5.8)

def league(**over):
    body = {"league_id": "lg-1", "sport_id": "football", "teams": ["t1", "t2", "t3", "t4"],
            "fixtures": [{"match_id": "m1", "home": "t1", "away": "t2"}, {"match_id": "m2", "home": "t3", "away": "t4"}],
            "qualification": {"spots": 2}}
    body.update(over)
    return body


def test_register_league(api):
    api.reset()
    r = api.post("/audit/v1/leagues", json=league())
    assert r.status_code == 201
    assert r.json() == {"league_id": "lg-1", "status": "created", "team_count": 4, "fixture_count": 2}
    assert api.get("/audit/v1/score/m1").json()["status"] == "upcoming"
    assert code(api.post("/audit/v1/leagues", json=league())) == "LEAGUE_EXISTS"
    assert code(api.post("/audit/v1/leagues", json=league(league_id="lg-2"))) == "MATCH_EXISTS"
    assert code(api.post("/audit/v1/leagues", json=league(league_id="lg-3", sport_id="polo"))) == "SPORT_NOT_FOUND"
    r = ev(api, "s", "m1", "match_start", {})
    assert r.status_code == 201 and r.json()["sequence"] == 1
    assert api.get("/audit/v1/score/m1").json()["league_id"] == "lg-1"


@pytest.mark.parametrize("over,field", [
    ({"teams": ["t1"]}, "teams"), ({"teams": ["t1", "t1"]}, "teams"),
    ({"fixtures": [{"match_id": "m1", "home": "t1", "away": "t1"}]}, "fixtures"),
    ({"fixtures": [{"match_id": "m1", "home": "t1", "away": "zz"}]}, "fixtures"),
    ({"qualification": {"spots": 9}}, "qualification"), ({"qualification": None}, "qualification"),
    ({"points": {"win": "3"}}, "points"), ({"tie_break_order": ["coin_toss"]}, "tie_break_order"),
    ({"league_id": "a|b"}, "league_id"), ({"lots_seed": "x"}, "lots_seed"),
])
def test_league_validation(api, over, field):
    r = api.post("/audit/v1/leagues", json=league(league_id="lg-v", **{k: v for k, v in over.items() if k != "league_id"})
                 if "league_id" not in over else league(**over))
    assert r.status_code == 400 and field in r.json()["error"]["details"]["fields"]


def test_reset_is_repeatable(api):
    api.reset()
    first = api.get("/audit/v1/score/alpha1-m01").json()
    api.post("/audit/v1/sports", json=KABADDI)
    api.reset()
    assert api.get("/audit/v1/score/alpha1-m01").json() == first
    assert api.post("/audit/v1/sports", json=KABADDI).status_code == 201  # custom sport wiped
