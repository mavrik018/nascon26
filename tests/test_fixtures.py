"""Spec 5.7 POST /audit/v1/fixtures: round robin, swiss, single and double elimination.

Pure functions are tested directly (properties over many team counts) and the
HTTP contract is tested through the `api` fixture (status codes, envelope).
"""
import itertools
import math
import random
from collections import Counter

import pytest

from app.errors import ApiError
from app.modules import fixtures as fx

URL = "/audit/v1/fixtures"
MATCH_KEYS = {"match_id", "bracket", "round", "index", "home", "away", "home_seed", "away_seed",
              "bye", "winner", "loser", "winner_to", "loser_to"}


def teams(n):
    return [f"t{i}" for i in range(1, n + 1)]


def error_of(fn, *args):
    with pytest.raises(ApiError) as exc:
        fn(*args)
    return exc.value


# --------------------------------------------------------------------------- #
# Round robin                                                                 #
# --------------------------------------------------------------------------- #

def check_round_robin(n, legs):
    t = teams(n)
    r = fx.generate_round_robin(t, {"legs": legs})
    per_leg = n - 1 if n % 2 == 0 else n
    assert (r["format"], r["legs"], r["team_count"], r["round_count"]) == ("round_robin", legs, n, per_leg * legs)
    assert [rd["round"] for rd in r["rounds"]] == list(range(1, per_leg * legs + 1))
    unordered, ordered = Counter(), Counter()
    byes = {leg: Counter() for leg in range(1, legs + 1)}
    for rd in r["rounds"]:
        assert len(rd["matches"]) == n // 2
        assert len(rd["byes"]) == n % 2
        playing = [x for m in rd["matches"] for x in (m["home"], m["away"])] + rd["byes"]
        assert sorted(playing) == sorted(t)  # each team exactly once per round
        leg = rd["matches"][0]["leg"]
        assert leg == (rd["round"] - 1) // per_leg + 1
        for b in rd["byes"]:
            byes[leg][b] += 1
        for i, m in enumerate(rd["matches"], 1):
            assert m["match_id"] == f"RR-L{leg}-R{rd['round']}-M{i}"
            assert m["status"] == "scheduled" and m["awarded_to"] is None and m["leg"] == leg
            unordered[frozenset((m["home"], m["away"]))] += 1
            ordered[(m["home"], m["away"])] += 1
    assert len(unordered) == n * (n - 1) // 2 and set(unordered.values()) == {legs}
    if legs == 2:
        assert len(ordered) == n * (n - 1) and set(ordered.values()) == {1}
    if n % 2:
        for leg in byes:
            assert byes[leg] == Counter({x: 1 for x in t})
    for leg in range(1, legs + 1):
        home = Counter(m["home"] for rd in r["rounds"] for m in rd["matches"] if m["leg"] == leg)
        away = Counter(m["away"] for rd in r["rounds"] for m in rd["matches"] if m["leg"] == leg)
        assert all(abs(home[x] - away[x]) <= 1 for x in t)
    assert r["summary"] == {"total": legs * n * (n - 1) // 2, "scheduled": legs * n * (n - 1) // 2,
                            "forfeit": 0, "voided": 0}


@pytest.mark.parametrize("n", list(range(2, 17)) + [25, 39, 40])
@pytest.mark.parametrize("legs", [1, 2])
def test_round_robin_properties(n, legs):
    check_round_robin(n, legs)


def test_round_robin_default_legs_and_shape_over_http(api):
    r = api.post(URL, json={"format": "round_robin", "teams": teams(4)})
    assert r.status_code == 200
    body = r.json()
    assert list(body) == ["format", "legs", "team_count", "round_count", "rounds", "summary"]
    assert body["legs"] == 1 and body["round_count"] == 3
    assert list(body["rounds"][0]) == ["round", "matches", "byes"] and body["rounds"][0]["byes"] == []
    assert list(body["rounds"][0]["matches"][0]) == ["match_id", "leg", "home", "away", "status", "awarded_to"]


def test_round_robin_spec_example_forfeit_remaining(api):
    r = api.post(URL, json={"format": "round_robin", "teams": teams(5), "params": {
        "legs": 1, "withdrawals": [{"team_id": "t3", "after_round": 2}],
        "withdrawal_policy": "forfeit_remaining"}})
    assert r.status_code == 200
    body = r.json()
    assert body["summary"] == {"total": 10, "scheduled": 8, "forfeit": 2, "voided": 0}
    for rd in body["rounds"]:
        for m in rd["matches"]:
            if "t3" in (m["home"], m["away"]) and rd["round"] > 2:
                other = m["away"] if m["home"] == "t3" else m["home"]
                assert (m["status"], m["awarded_to"]) == ("forfeit", other)
            else:
                assert (m["status"], m["awarded_to"]) == ("scheduled", None)


def test_round_robin_void_all_and_both_withdrawn():
    r = fx.generate_round_robin(teams(6), {"legs": 2, "withdrawal_policy": "void_all",
                                           "withdrawals": [{"team_id": "t1", "after_round": 3}]})
    for m in (m for rd in r["rounds"] for m in rd["matches"]):
        if "t1" in (m["home"], m["away"]):
            assert (m["status"], m["awarded_to"]) == ("voided", None)
        else:
            assert m["status"] == "scheduled"
    assert r["summary"] == {"total": 30, "scheduled": 20, "forfeit": 0, "voided": 10}

    r = fx.generate_round_robin(teams(4), {"withdrawals": [{"team_id": "t1", "after_round": 0},
                                                           {"team_id": "t2", "after_round": 1}]})
    for rd in r["rounds"]:
        for m in rd["matches"]:
            pair = {m["home"], m["away"]}
            if pair == {"t1", "t2"}:
                expected = ("scheduled", None) if rd["round"] <= 0 else (
                    ("voided", None) if rd["round"] > 1 else ("forfeit", "t2"))
                assert (m["status"], m["awarded_to"]) == expected
            elif "t1" in pair:
                assert (m["status"], m["awarded_to"]) == ("forfeit", (pair - {"t1"}).pop())
            elif "t2" in pair and rd["round"] > 1:
                assert (m["status"], m["awarded_to"]) == ("forfeit", (pair - {"t2"}).pop())
    s = r["summary"]
    assert s["total"] == 6 and s["scheduled"] + s["forfeit"] + s["voided"] == 6


def test_round_robin_withdrawal_after_last_round_changes_nothing():
    r = fx.generate_round_robin(teams(5), {"withdrawals": [{"team_id": "t5", "after_round": 5}]})
    assert r["summary"]["scheduled"] == 10


@pytest.mark.parametrize("params,field", [
    ({"legs": 3}, "params.legs"),
    ({"legs": True}, "params.legs"),
    ({"legs": "1"}, "params.legs"),
    ({"withdrawal_policy": "drop"}, "params.withdrawal_policy"),
    ({"withdrawals": "t1"}, "params.withdrawals"),
    ({"withdrawals": ["t1"]}, "params.withdrawals"),
    ({"withdrawals": [{"team_id": "nope", "after_round": 1}]}, "params.withdrawals"),
    ({"withdrawals": [{"team_id": ["t1"], "after_round": 1}]}, "params.withdrawals"),
    ({"withdrawals": [{"team_id": "t1", "after_round": 6}]}, "params.withdrawals"),
    ({"withdrawals": [{"team_id": "t1", "after_round": -1}]}, "params.withdrawals"),
    ({"withdrawals": [{"team_id": "t1", "after_round": True}]}, "params.withdrawals"),
    ({"withdrawals": [{"team_id": "t1"}]}, "params.withdrawals"),
    ({"withdrawals": [{"team_id": "t1", "after_round": 1}, {"team_id": "t1", "after_round": 2}]},
     "params.withdrawals"),
])
def test_round_robin_validation(api, params, field):
    r = api.post(URL, json={"format": "round_robin", "teams": teams(5), "params": params})
    assert r.status_code == 400
    err = r.json()["error"]
    assert err["code"] == "VALIDATION_ERROR" and field in err["details"]["fields"]


def test_round_robin_after_round_upper_bound_counts_both_legs():
    r = fx.generate_round_robin(teams(5), {"legs": 2, "withdrawals": [{"team_id": "t1", "after_round": 10}]})
    assert r["round_count"] == 10 and r["summary"]["forfeit"] == 0


# --------------------------------------------------------------------------- #
# Envelope validation                                                         #
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("body,field", [
    ({"format": "league", "teams": teams(4)}, "format"),
    ({"format": ["swiss"], "teams": teams(4)}, "format"),
    ({"teams": teams(4)}, "format"),
    ({"format": "round_robin"}, "teams"),
    ({"format": "round_robin", "teams": "t1,t2"}, "teams"),
    ({"format": "round_robin", "teams": ["t1", "t1"]}, "teams"),
    ({"format": "round_robin", "teams": ["t1", 2]}, "teams"),
    ({"format": "round_robin", "teams": ["t1", "bad|id"]}, "teams"),
    ({"format": "round_robin", "teams": ["t1", "x" * 65]}, "teams"),
    ({"format": "round_robin", "teams": ["t1", "'; DROP TABLE x;--"]}, "teams"),
    ({"format": "round_robin", "teams": ["t1"]}, "teams"),
    ({"format": "round_robin", "teams": teams(41)}, "teams"),
    ({"format": "swiss", "teams": teams(65)}, "teams"),
    ({"format": "single_elim", "teams": teams(129)}, "teams"),
    ({"format": "single_elim", "teams": teams(1)}, "teams"),
    ({"format": "double_elim", "teams": teams(2)}, "teams"),
    ({"format": "double_elim", "teams": teams(129)}, "teams"),
    ({"format": "swiss", "teams": teams(4), "params": [1]}, "params"),
])
def test_envelope_validation(api, body, field):
    r = api.post(URL, json=body)
    assert r.status_code == 400
    err = r.json()["error"]
    assert err["code"] == "VALIDATION_ERROR" and field in err["details"]["fields"]


def test_non_object_and_malformed_bodies(api):
    assert api.post(URL, json=[1, 2]).status_code == 400
    r = api.post(URL, data="{nope", headers={"Content-Type": "application/json"})
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"
    assert api.post(URL).status_code == 400


def test_limits_accepted_at_boundaries():
    assert fx.generate({"format": "round_robin", "teams": teams(40)})["team_count"] == 40
    assert fx.generate({"format": "swiss", "teams": teams(64), "params": None})["total_rounds"] == 6
    assert fx.generate({"format": "single_elim", "teams": teams(128)})["bracket_size"] == 128
    assert fx.generate({"format": "double_elim", "teams": teams(3)})["bracket_size"] == 4
    assert fx.generate({"format": "single_elim", "teams": teams(2)})["bracket_size"] == 2


def test_reset_is_noop():
    assert fx.SCHEMA == "" and fx.reset(None, 42, {}) is None


# --------------------------------------------------------------------------- #
# Swiss                                                                       #
# --------------------------------------------------------------------------- #

SPEC_SWISS = {"format": "swiss", "teams": teams(5), "params": {
    "total_rounds": 3, "round": 2,
    "history": [{"round": 1, "bye": "t5", "matches": [{"home": "t1", "away": "t3", "result": "home"},
                                                      {"home": "t2", "away": "t4", "result": "draw"}]}]}}


def test_swiss_spec_example_exact(api):
    r = api.post(URL, json=SPEC_SWISS)
    assert r.status_code == 200
    body = r.json()
    assert list(body) == ["format", "round", "total_rounds", "pairings", "bye", "standings"]
    assert body["standings"] == [
        {"rank": 1, "team_id": "t1", "score": 1.0, "buchholz": 0.0},
        {"rank": 2, "team_id": "t5", "score": 1.0, "buchholz": 0.0},
        {"rank": 3, "team_id": "t2", "score": 0.5, "buchholz": 0.5},
        {"rank": 4, "team_id": "t4", "score": 0.5, "buchholz": 0.5},
        {"rank": 5, "team_id": "t3", "score": 0.0, "buchholz": 1.0}]
    assert body["bye"] == "t3"
    assert body["pairings"] == [{"match_id": "SW-R2-M1", "home": "t1", "away": "t2"},
                                {"match_id": "SW-R2-M2", "home": "t5", "away": "t4"}]
    assert all(isinstance(s["score"], float) and isinstance(s["buchholz"], float) for s in body["standings"])


@pytest.mark.parametrize("n", range(2, 65))
def test_swiss_round_one_exact(n):
    r = fx.generate_swiss(teams(n), {})
    m = n // 2
    assert r["round"] == 1 and r["total_rounds"] == math.ceil(math.log2(n))
    assert r["pairings"] == [{"match_id": f"SW-R1-M{i}", "home": f"t{i}", "away": f"t{i + m}"}
                             for i in range(1, m + 1)]
    assert r["bye"] == (f"t{n}" if n % 2 else None)
    assert [s["team_id"] for s in r["standings"]] == teams(n)
    assert [s["rank"] for s in r["standings"]] == list(range(1, n + 1))


def test_swiss_no_valid_pairing(api):
    # Three rounds of K(3,3): the unplayed pairs form two triangles -> no perfect matching.
    rounds = [[("t1", "t4"), ("t2", "t5"), ("t3", "t6")],
              [("t1", "t5"), ("t2", "t6"), ("t3", "t4")],
              [("t1", "t6"), ("t2", "t4"), ("t3", "t5")]]
    history = [{"round": i + 1, "bye": None, "matches": [{"home": h, "away": a, "result": "draw"} for h, a in rd]}
               for i, rd in enumerate(rounds)]
    r = api.post(URL, json={"format": "swiss", "teams": teams(6),
                            "params": {"total_rounds": 5, "round": 4, "history": history}})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "NO_VALID_PAIRING"
    assert r.json()["error"]["details"] == {"round": 4}


def test_swiss_bye_falls_back_to_next_candidate():
    # t3 is the lowest-scoring team without a bye, but t1 and t2 have already
    # met, so with t3 out the rest (t1, t2) cannot be paired -> next candidate.
    history = [{"round": 1, "bye": None, "matches": [{"home": "t1", "away": "t2", "result": "draw"}]}]
    r = fx.generate_swiss(teams(3), {"total_rounds": 2, "round": 2, "history": history})
    assert r["bye"] == "t2"  # t1, t2 tie on score -> the largest seed index first
    assert {r["pairings"][0]["home"], r["pairings"][0]["away"]} == {"t1", "t3"}


def test_swiss_bye_prefers_lowest_score_then_largest_index():
    history = [{"round": 1, "bye": "t5", "matches": [{"home": "t1", "away": "t3", "result": "away"},
                                                    {"home": "t2", "away": "t4", "result": "away"}]}]
    r = fx.generate_swiss(teams(5), {"total_rounds": 4, "round": 2, "history": history})
    assert r["bye"] == "t2"  # t1 and t2 have 0 points; t2 has the larger index


def spec_brute_force(t, history):
    """Reference: bye candidate order + exhaustive minimum over rematch-free pairings."""
    score = {x: 0.0 for x in t}
    played, had_bye = set(), set()
    for h in history:
        for m in h["matches"]:
            score[m["home"]] += {"home": 1, "draw": 0.5, "away": 0}[m["result"]]
            score[m["away"]] += {"home": 0, "draw": 0.5, "away": 1}[m["result"]]
            played |= {(m["home"], m["away"]), (m["away"], m["home"])}
        if h["bye"]:
            score[h["bye"]] += 1
            had_bye.add(h["bye"])

    def best(rest):
        if not rest:
            return 0.0
        a, out = rest[0], None
        for b in rest[1:]:
            if (a, b) not in played:
                sub = best([x for x in rest[1:] if x != b])
                if sub is not None and (out is None or abs(score[a] - score[b]) + sub < out):
                    out = abs(score[a] - score[b]) + sub
        return out

    if len(t) % 2 == 0:
        return None, best(t), score, played
    cands = sorted([x for x in t if x not in had_bye] or t, key=lambda x: (score[x], -t.index(x)))
    for c in cands:
        cost = best([x for x in t if x != c])
        if cost is not None:
            return c, cost, score, played
    return None, None, score, played


def random_history(rng, t, rounds):
    history = []
    for rnd in range(1, rounds + 1):
        order = t[:]
        rng.shuffle(order)
        bye = order.pop() if len(order) % 2 and rng.random() < 0.7 else None
        k = rng.randint(1, len(order) // 2)
        matches = [{"home": order[2 * i], "away": order[2 * i + 1], "result": rng.choice(["home", "away", "draw"])}
                   for i in range(k)]
        history.append({"round": rnd, "bye": bye, "matches": matches})
    return history


@pytest.mark.parametrize("seed", range(150))
def test_swiss_optimal_against_brute_force(seed):
    rng = random.Random(seed)
    n = rng.randint(3, 9)
    t = teams(n)
    rounds = rng.randint(1, n - 2)
    history = random_history(rng, t, rounds)
    bye, cost, score, played = spec_brute_force(t, history)
    params = {"total_rounds": n - 1, "round": rounds + 1, "history": history}
    if cost is None:
        assert error_of(fx.generate_swiss, t, params).code == "NO_VALID_PAIRING"
        return
    r = fx.generate_swiss(t, params)
    assert r["bye"] == bye
    seen = [x for p in r["pairings"] for x in (p["home"], p["away"])] + ([bye] if bye else [])
    assert sorted(seen) == sorted(t)
    assert all((p["home"], p["away"]) not in played for p in r["pairings"])
    assert sum(abs(score[p["home"]] - score[p["away"]]) for p in r["pairings"]) == cost
    assert [p["match_id"] for p in r["pairings"]] == [f"SW-R{rounds + 1}-M{i}" for i in range(1, n // 2 + 1)]
    # standings order and Buchholz
    games = [(m["home"], m["away"]) for h in history for m in h["matches"]]
    buchholz = {x: sum(score[b] for a, b in games if a == x) + sum(score[a] for a, b in games if b == x) for x in t}
    ranked = sorted(t, key=lambda x: (-score[x], -buchholz[x], t.index(x)))
    assert [s["buchholz"] for s in r["standings"]] == [buchholz[x] for x in ranked]
    assert [s["team_id"] for s in r["standings"]] == ranked


def test_swiss_full_event_64_teams_is_fast():
    import time
    rng = random.Random(7)
    t = teams(64)
    history = []
    for rnd in range(1, 21):
        start = time.perf_counter()
        r = fx.generate_swiss(t, {"total_rounds": 63, "round": rnd, "history": history})
        assert time.perf_counter() - start < 2
        pairs = {frozenset((p["home"], p["away"])) for p in r["pairings"]}
        assert len(pairs) == 32
        history.append({"round": rnd, "bye": r["bye"], "matches": [
            {"home": p["home"], "away": p["away"], "result": rng.choice(["home", "away", "draw"])}
            for p in r["pairings"]]})
    played = [frozenset((m["home"], m["away"])) for h in history for m in h["matches"]]
    assert len(played) == len(set(played))  # never a rematch


@pytest.mark.parametrize("params,field", [
    ({"total_rounds": 0}, "params.total_rounds"),
    ({"total_rounds": 4}, "params.total_rounds"),
    ({"total_rounds": True}, "params.total_rounds"),
    ({"round": 0}, "params.round"),
    ({"round": 4, "total_rounds": 3}, "params.round"),
    ({"round": 2}, "params.history"),
    ({"round": 1, "history": [{"round": 1, "bye": None, "matches": []}]}, "params.history"),
    ({"round": 2, "history": "x"}, "params.history"),
    ({"round": 2, "history": [1]}, "params.history"),
    ({"round": 2, "history": [{"round": 2, "bye": None, "matches": []}]}, "params.history"),
    ({"round": 2, "history": [{"round": 1, "bye": None, "matches": {}}]}, "params.history"),
    ({"round": 2, "history": [{"round": 1, "bye": "zz", "matches": []}]}, "params.history"),
    ({"round": 2, "history": [{"round": 1, "bye": ["t1"], "matches": []}]}, "params.history"),
    ({"round": 2, "history": [{"round": 1, "matches": [{"home": "t1", "away": "t9", "result": "home"}]}]},
     "params.history"),
    ({"round": 2, "history": [{"round": 1, "matches": [{"home": "t1", "away": "t2", "result": "win"}]}]},
     "params.history"),
    ({"round": 2, "history": [{"round": 1, "matches": [{"home": "t1", "away": "t2", "result": ["home"]}]}]},
     "params.history"),
    ({"round": 2, "history": [{"round": 1, "matches": ["t1"]}]}, "params.history"),
    ({"round": 2, "history": [{"round": 1, "bye": "t1",
                               "matches": [{"home": "t1", "away": "t2", "result": "home"}]}]}, "params.history"),
    ({"round": 3, "total_rounds": 3, "history": [{"round": 1, "matches": []}, {"round": 1, "matches": []}]},
     "params.history"),
])
def test_swiss_validation(api, params, field):
    r = api.post(URL, json={"format": "swiss", "teams": teams(4), "params": params})
    assert r.status_code == 400
    err = r.json()["error"]
    assert err["code"] == "VALIDATION_ERROR" and field in err["details"]["fields"]


def test_swiss_history_order_free_and_missing_bye_key():
    history = [{"round": 2, "matches": [{"home": "t1", "away": "t3", "result": "draw"}]},
               {"round": 1, "matches": [{"home": "t1", "away": "t2", "result": "home"},
                                        {"home": "t3", "away": "t4", "result": "home"}]}]
    r = fx.generate_swiss(teams(4), {"total_rounds": 3, "round": 3, "history": history})
    assert {frozenset((p["home"], p["away"])) for p in r["pairings"]} == {frozenset(("t1", "t4")),
                                                                          frozenset(("t2", "t3"))}
    assert r["bye"] is None


# --------------------------------------------------------------------------- #
# Single elimination                                                          #
# --------------------------------------------------------------------------- #

def test_seed_order():
    assert fx.seed_order(2) == [1, 2]
    assert fx.seed_order(4) == [1, 4, 2, 3]
    assert fx.seed_order(8) == [1, 8, 4, 5, 2, 7, 3, 6]
    assert fx.seed_order(16) == [1, 16, 8, 9, 4, 13, 5, 12, 2, 15, 7, 10, 3, 14, 6, 11]


def all_matches(r):
    return {m["match_id"]: m for rd in r["rounds"] for m in rd["matches"]}


def test_single_elim_spec_example(api):
    r = api.post(URL, json={"format": "single_elim", "teams": teams(6),
                            "params": {"third_place_match": False, "results": [{"match_id": "R1M2", "winner": "t4"}]}})
    assert r.status_code == 200
    body = r.json()
    assert list(body) == ["format", "bracket_size", "rounds"] and body["bracket_size"] == 8
    assert [rd["round"] for rd in body["rounds"]] == [1, 2, 3]
    ms = all_matches(body)
    assert all(set(m) == MATCH_KEYS for m in ms.values())
    assert ms["R1M1"] == {"match_id": "R1M1", "bracket": "main", "round": 1, "index": 1, "home": "t1", "away": None,
                          "home_seed": 1, "away_seed": None, "bye": True, "winner": "t1", "loser": None,
                          "winner_to": {"match_id": "R2M1", "slot": "home"}, "loser_to": None}
    assert ms["R1M2"] == {"match_id": "R1M2", "bracket": "main", "round": 1, "index": 2, "home": "t4", "away": "t5",
                          "home_seed": 4, "away_seed": 5, "bye": False, "winner": "t4", "loser": "t5",
                          "winner_to": {"match_id": "R2M1", "slot": "away"}, "loser_to": None}
    assert (ms["R1M3"]["home"], ms["R1M3"]["away"], ms["R1M3"]["bye"]) == ("t2", None, True)
    assert (ms["R1M4"]["home"], ms["R1M4"]["away"], ms["R1M4"]["bye"], ms["R1M4"]["winner"]) == ("t3", "t6", False, None)
    assert (ms["R2M1"]["home"], ms["R2M1"]["away"], ms["R2M1"]["home_seed"], ms["R2M1"]["away_seed"]) == ("t1", "t4", 1, 4)
    assert (ms["R2M2"]["home"], ms["R2M2"]["away"]) == ("t2", None)
    assert ms["R3M1"]["winner_to"] is None and ms["R3M1"]["home"] is None


@pytest.mark.parametrize("n", list(range(2, 34)) + [64, 100, 127, 128])
def test_single_elim_structure(n):
    r = fx.generate_single_elim(teams(n), {})
    size = 1 << (n - 1).bit_length() if n > 1 else 2
    assert r["bracket_size"] == size
    k = size.bit_length() - 1
    assert len(r["rounds"]) == k
    order = fx.seed_order(size)
    for rd in r["rounds"]:
        assert len(rd["matches"]) == size >> rd["round"]
        for i, m in enumerate(rd["matches"], 1):
            assert m["match_id"] == f"R{rd['round']}M{i}" and m["index"] == i and m["bracket"] == "main"
            if rd["round"] < k:
                assert m["winner_to"] == {"match_id": f"R{rd['round'] + 1}M{(i + 1) // 2}",
                                          "slot": "home" if i % 2 else "away"}
            else:
                assert m["winner_to"] is None
            assert m["loser_to"] is None
    first = r["rounds"][0]["matches"]
    assert sum(m["bye"] for m in first) == size - n
    for i, m in enumerate(first):
        hs, as_ = order[2 * i], order[2 * i + 1]
        assert (m["home_seed"], m["home"]) == (hs, f"t{hs}")
        if as_ > n:
            assert m["bye"] and m["away"] is None and m["away_seed"] is None and m["winner"] == m["home"]
        else:
            assert (m["away_seed"], m["away"], m["bye"], m["winner"]) == (as_, f"t{as_}", False, None)


def play_out(fn, t, params, pick="home"):
    """Feed results one at a time until nothing is playable; returns final response."""
    results = []
    while True:
        r = fn(t, dict(params, results=results))
        ms = elim_matches(r)
        ready = [m for m in ms.values() if m["winner"] is None and m["home"] and m["away"]
                 and m.get("required") is not False]
        if not ready:
            return r, results
        m = ready[0]
        results.append({"match_id": m["match_id"], "winner": m[pick]})


def elim_matches(r):
    if r["format"] == "single_elim":
        return all_matches(r)
    out = {m["match_id"]: m for b in ("winners", "losers") for rd in r[b] for m in rd["matches"]}
    out.update({m["match_id"]: m for m in r["grand_final"]})
    return out


@pytest.mark.parametrize("n", [3, 4, 5, 8, 11, 16])
def test_single_elim_third_place(n):
    r = fx.generate_single_elim(teams(n), {"third_place_match": True})
    ms = all_matches(r)
    k = len(r["rounds"])
    tp = ms["TP"]
    assert tp["bracket"] == "third_place" and tp["winner_to"] is None and tp["loser_to"] is None
    assert ms[f"R{k - 1}M1"]["loser_to"] == {"match_id": "TP", "slot": "home"}
    assert ms[f"R{k - 1}M2"]["loser_to"] == {"match_id": "TP", "slot": "away"}
    final, results = play_out(fx.generate_single_elim, teams(n), {"third_place_match": True}, pick="away")
    fm = all_matches(final)
    semis = [fm[f"R{k - 1}M1"], fm[f"R{k - 1}M2"]]
    assert fm[f"R{k}M1"]["winner"] is not None
    if all(not s["bye"] for s in semis):
        assert {fm["TP"]["home"], fm["TP"]["away"]} == {s["loser"] for s in semis}
        assert fm["TP"]["winner"] == fm["TP"]["away"]


def test_single_elim_two_teams_has_no_third_place():
    r = fx.generate_single_elim(teams(2), {"third_place_match": True, "results": [{"match_id": "R1M1", "winner": "t2"}]})
    assert [m["match_id"] for m in all_matches(r).values()] == ["R1M1"]
    assert all_matches(r)["R1M1"]["winner"] == "t2" and all_matches(r)["R1M1"]["loser"] == "t1"


def test_single_elim_full_play_top_seeds_win():
    final, results = play_out(fx.generate_single_elim, teams(13), {})
    assert all_matches(final)["R4M1"]["winner"] == "t1"
    decided = [m for m in all_matches(final).values() if m["winner"] and not m["bye"]]
    assert len(decided) == 12 and len(results) == 12


def test_single_elim_result_can_restate_bye_winner():
    r = fx.generate_single_elim(teams(3), {"results": [{"match_id": "R1M1", "winner": "t1"}]})
    assert all_matches(r)["R2M1"]["home"] == "t1"


@pytest.mark.parametrize("results", [
    [{"match_id": "R9M1", "winner": "t1"}],
    [{"match_id": ["R1M2"], "winner": "t4"}],
    [{"match_id": "R1M2", "winner": "t1"}],
    [{"match_id": "R1M2", "winner": None}],
    [{"match_id": "R2M1", "winner": "t1"}],  # opponent not known yet
    ["R1M2"],
    "R1M2",
])
def test_single_elim_bad_results(api, results):
    r = api.post(URL, json={"format": "single_elim", "teams": teams(6), "params": {"results": results}})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"
    assert "params.results" in r.json()["error"]["details"]["fields"]


def test_single_elim_bad_third_place_flag():
    assert error_of(fx.generate_single_elim, teams(4), {"third_place_match": "yes"}).details == {
        "fields": ["params.third_place_match"]}


# --------------------------------------------------------------------------- #
# Double elimination                                                          #
# --------------------------------------------------------------------------- #

def check_double_elim_graph(r):
    size = r["bracket_size"]
    k = size.bit_length() - 1
    assert [rd["round"] for rd in r["winners"]] == list(range(1, k + 1))
    for rd in r["winners"]:
        assert [m["match_id"] for m in rd["matches"]] == [f"WR{rd['round']}M{i}" for i in range(1, (size >> rd["round"]) + 1)]
        assert all(m["bracket"] == "winners" and m["loser_to"] is not None and m["winner_to"] is not None
                   for m in rd["matches"])
    assert [rd["round"] for rd in r["losers"]] == list(range(1, 2 * (k - 1) + 1))
    for rd in r["losers"]:
        j = (rd["round"] + 1) // 2
        assert [m["match_id"] for m in rd["matches"]] == [f"LR{rd['round']}M{i}" for i in range(1, (size >> (j + 1)) + 1)]
        assert all(m["bracket"] == "losers" and m["loser_to"] is None and m["winner_to"] is not None
                   for m in rd["matches"])
    assert sum(len(rd["matches"]) for rd in r["losers"]) == size - 2
    gf = r["grand_final"]
    assert [m["match_id"] for m in gf] == (["GF1", "GF2"] if r["bracket_reset"] else ["GF1"])
    assert all(m["bracket"] == "grand_final" for m in gf)
    ms = elim_matches(r)
    assert all(MATCH_KEYS <= set(m) for m in ms.values())
    feeds = Counter()
    for m in ms.values():
        for key in ("winner_to", "loser_to"):
            if m[key]:
                assert m[key]["match_id"] in ms and m[key]["slot"] in ("home", "away")
                feeds[(m[key]["match_id"], m[key]["slot"])] += 1
    for mid in ms:
        if not mid.startswith("WR1M"):
            assert feeds[(mid, "home")] == 1 and feeds[(mid, "away")] == 1, mid
    assert sum(feeds[(mid, s)] for mid in ms if mid.startswith("WR1M") for s in ("home", "away")) == 0
    last = 2 * (k - 1)
    assert ms[f"WR{k}M1"]["winner_to"] == {"match_id": "GF1", "slot": "home"}
    assert ms[f"WR{k}M1"]["loser_to"] == {"match_id": f"LR{last}M1", "slot": "away"}
    assert ms[f"LR{last}M1"]["winner_to"] == {"match_id": "GF1", "slot": "away"}
    for i in range(1, size // 2 + 1):  # WR1 losers meet each other in LR1
        assert ms[f"WR1M{i}"]["loser_to"]["match_id"].startswith("LR1M")
    for rr in range(2, k + 1):  # WRr losers drop into LR(2r-2)
        for m in r["winners"][rr - 1]["matches"]:
            assert m["loser_to"]["match_id"].startswith(f"LR{2 * rr - 2}M")
    return ms


@pytest.mark.parametrize("n", list(range(3, 17)) + [31, 64, 100, 128])
@pytest.mark.parametrize("reset_on", [True, False])
def test_double_elim_counts_and_routing(n, reset_on):
    r = fx.generate_double_elim(teams(n), {"bracket_reset": reset_on})
    assert list(r) == ["format", "bracket_size", "bracket_reset", "winners", "losers", "grand_final"]
    assert r["bracket_reset"] is reset_on
    ms = check_double_elim_graph(r)
    single = fx.generate_single_elim(teams(n), {})
    for a, b in zip(r["winners"][0]["matches"], single["rounds"][0]["matches"]):
        assert (a["home"], a["away"], a["home_seed"], a["away_seed"], a["bye"], a["winner"]) == \
               (b["home"], b["away"], b["home_seed"], b["away_seed"], b["bye"], b["winner"])
    gf1 = ms["GF1"]
    assert gf1["conditional"] is False and gf1["required"] is True
    if reset_on:
        assert ms["GF2"]["conditional"] is True and ms["GF2"]["required"] is None
    else:
        assert gf1["winner_to"] is None


@pytest.mark.parametrize("n", [3, 4, 5, 6, 7, 8, 12, 16])
@pytest.mark.parametrize("pick", ["home", "away"])
def test_double_elim_full_play_and_bracket_reset(n, pick):
    final, results = play_out(fx.generate_double_elim, teams(n), {"bracket_reset": True}, pick=pick)
    check_double_elim_graph(final)
    ms = elim_matches(final)
    gf1, gf2 = ms["GF1"], ms["GF2"]
    assert gf1["winner"] is not None
    assert (gf2["home"], gf2["away"]) == (gf1["home"], gf1["away"])  # same two teams
    losses = Counter(m["loser"] for m in ms.values() if m["loser"])
    if pick == "home":  # WB champion (GF1.home) wins GF1: event over, no reset
        assert gf1["winner"] == gf1["home"] and gf2["required"] is False and gf2["winner"] is None
        champion = gf1["winner"]
    else:  # losers-bracket champion wins GF1: reset required and played
        assert gf1["winner"] == gf1["away"] and gf2["required"] is True and gf2["winner"] is not None
        assert gf1["winner_to"] == {"match_id": "GF2", "slot": "away"}
        champion = gf2["winner"]
    # Every team except the champion is eliminated with exactly two losses.
    assert losses[champion] <= 1
    assert all(losses[t] == 2 for t in teams(n) if t != champion)


def test_double_elim_gf2_required_states():
    t = teams(4)
    base = [{"match_id": "WR1M1", "winner": "t1"}, {"match_id": "WR1M2", "winner": "t2"},
            {"match_id": "WR2M1", "winner": "t1"}, {"match_id": "LR1M1", "winner": "t3"},
            {"match_id": "LR2M1", "winner": "t2"}]
    r = fx.generate_double_elim(t, {"bracket_reset": True, "results": base})
    gf1, gf2 = r["grand_final"]
    assert (gf1["home"], gf1["away"], gf2["home"], gf2["away"]) == ("t1", "t2", "t1", "t2")
    assert gf2["required"] is None and gf2["conditional"] is True
    assert gf1["winner_to"] == {"match_id": "GF2", "slot": "home"}
    r = fx.generate_double_elim(t, {"bracket_reset": True, "results": base + [{"match_id": "GF1", "winner": "t1"}]})
    assert r["grand_final"][1]["required"] is False
    r = fx.generate_double_elim(t, {"bracket_reset": True, "results": base + [{"match_id": "GF1", "winner": "t2"}]})
    assert r["grand_final"][1]["required"] is True
    r = fx.generate_double_elim(t, {"bracket_reset": False, "results": base + [{"match_id": "GF1", "winner": "t2"}]})
    assert len(r["grand_final"]) == 1 and r["grand_final"][0]["winner"] == "t2"


def test_double_elim_losers_bracket_byes_advance():
    # n=5, B=8: WR1M1, M3, M4 are byes, so LR1M2 can never be played and
    # LR1M1 gets one team only (the WR1M2 loser) who advances at once.
    r = fx.generate_double_elim(teams(5), {"results": [{"match_id": "WR1M2", "winner": "t4"}]})
    ms = elim_matches(r)
    assert ms["LR1M1"]["away"] == "t5" and ms["LR1M1"]["bye"] is True and ms["LR1M1"]["winner"] == "t5"
    assert ms["LR2M1"]["home"] == "t5"
    assert ms["LR1M2"]["home"] is None and ms["LR1M2"]["away"] is None


def test_double_elim_over_http_and_errors(api):
    r = api.post(URL, json={"format": "double_elim", "teams": teams(8),
                            "params": {"bracket_reset": True, "results": [{"match_id": "WR1M1", "winner": "t1"}]}})
    assert r.status_code == 200
    body = r.json()
    ms = elim_matches(body)
    assert ms["WR1M1"]["winner"] == "t1" and ms["WR1M1"]["loser"] == "t8"
    assert ms["WR2M1"]["home"] == "t1" and ms["LR1M1"]["home"] == "t8" and ms["LR1M1"]["home_seed"] == 8
    for params, field in [({"bracket_reset": "true"}, "params.bracket_reset"),
                          ({"results": {"WR1M1": "t1"}}, "params.results"),
                          ({"results": [{"match_id": "LR1M1", "winner": "t8"}]}, "params.results"),
                          ({"results": [{"match_id": "GF2", "winner": "t1"}]}, "params.results")]:
        r = api.post(URL, json={"format": "double_elim", "teams": teams(8), "params": params})
        assert r.status_code == 400, params
        assert field in r.json()["error"]["details"]["fields"]


def test_double_elim_128_full_results_fast():
    import time
    final, results = play_out(fx.generate_double_elim, teams(128), {"bracket_reset": True}, pick="away")
    start = time.perf_counter()
    fx.generate_double_elim(teams(128), {"bracket_reset": True, "results": results})
    assert time.perf_counter() - start < 1
    assert len(results) == 2 * 128 - 1  # every team but the champion loses twice, plus the reset


# --------------------------------------------------------------------------- #
# Matching primitive                                                          #
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("seed", range(300))
def test_max_weight_matching_against_brute_force(seed):
    rng = random.Random(seed)
    n = rng.randint(1, 9)
    p = rng.random()
    edges = [(i, j, rng.randint(0, rng.choice([1, 4, 50]))) for i in range(n) for j in range(i + 1, n)
             if rng.random() < p]
    mate = fx.max_weight_matching(edges, n)
    weight = {(i, j): w for i, j, w in edges} | {(j, i): w for i, j, w in edges}
    assert all(mate[mate[v]] == v for v in range(n) if mate[v] >= 0)
    got = (sum(1 for v in range(n) if mate[v] > v), sum(weight[(v, mate[v])] for v in range(n) if mate[v] > v))
    best = (0, 0)
    for size in range(n // 2, 0, -1):
        for combo in itertools.combinations(edges, size):
            used = [x for e in combo for x in e[:2]]
            if len(used) == len(set(used)):
                best = max(best, (size, sum(e[2] for e in combo)))
        if best[0]:
            break
    assert got == best
