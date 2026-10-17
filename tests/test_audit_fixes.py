"""Regression tests for contract details found by the spec audit."""


def code(r):
    return r.json()["error"]["code"]


def test_injected_sport_id_is_400_not_404(api):
    api.reset()
    evil = "x'; DROP TABLE sports;--"
    r = api.post("/audit/v1/events", json={"event_id": "e", "match_id": "m", "type": "match_init",
                                           "payload": {"sport_id": evil, "home_team_id": "a", "away_team_id": "b"}})
    assert r.status_code == 400 and code(r) == "VALIDATION_ERROR"
    r = api.post("/audit/v1/leagues", json={"league_id": "l", "sport_id": evil, "teams": ["a", "b"], "fixtures": [],
                                            "qualification": {"spots": 1}})
    assert r.status_code == 400 and "sport_id" in r.json()["error"]["details"]["fields"]
    assert api.get("/health").status_code == 200


def test_body_just_over_one_megabyte_is_413(api):
    r = api.post("/audit/v1/checkout", data=b"x" * 1_000_001, headers={"Content-Type": "application/json"})
    assert r.status_code == 413 and code(r) == "PAYLOAD_TOO_LARGE"


def test_duplicate_match_id_in_one_league_request_is_409(api):
    api.reset()
    r = api.post("/audit/v1/leagues", json={
        "league_id": "l1", "sport_id": "football", "teams": ["a", "b"], "qualification": {"spots": 1},
        "fixtures": [{"match_id": "x", "home": "a", "away": "b"}, {"match_id": "x", "home": "b", "away": "a"}]})
    assert r.status_code == 409 and code(r) == "MATCH_EXISTS"


def test_empty_tie_break_order_means_draw_lots_only(api):
    api.reset()
    api.post("/audit/v1/leagues", json={
        "league_id": "l2", "sport_id": "football", "teams": ["t1", "t2", "t3"], "qualification": {"spots": 1},
        "fixtures": [{"match_id": "a", "home": "t1", "away": "t2"}], "tie_break_order": [], "lots_seed": 42})
    table = api.get("/audit/v1/standings/l2").json()["table"]
    assert {row["resolved_by"] for row in table} <= {"draw_lots", None}


def test_ids_with_trailing_newline_are_rejected(api):
    r = api.post("/audit/v1/fixtures", json={"format": "round_robin", "teams": ["t1\n", "t2"]})
    assert r.status_code == 400


def test_explicit_null_fixture_params_use_defaults(api):
    r = api.post("/audit/v1/fixtures", json={"format": "round_robin", "teams": ["a", "b", "c"],
                                             "params": {"legs": None, "withdrawals": None}})
    assert r.status_code == 200 and r.json()["legs"] == 1


def test_health_503_uses_error_envelope():
    from app import main
    body = main.errors.envelope(503, "SERVICE_UNAVAILABLE", "x")
    assert body.status_code == 503


def test_single_elim_results_in_any_order(api):
    teams = ["t1", "t2", "t3", "t4"]
    in_order = [{"match_id": "R1M1", "winner": "t1"}, {"match_id": "R1M2", "winner": "t2"},
                {"match_id": "R2M1", "winner": "t2"}]
    a = api.post("/audit/v1/fixtures", json={"format": "single_elim", "teams": teams, "params": {"results": in_order}})
    b = api.post("/audit/v1/fixtures", json={"format": "single_elim", "teams": teams,
                                             "params": {"results": in_order[::-1]}})
    assert a.status_code == b.status_code == 200 and a.json() == b.json()
    bad = api.post("/audit/v1/fixtures", json={"format": "single_elim", "teams": teams,
                                               "params": {"results": [{"match_id": "R2M1", "winner": "t9"}]}})
    assert bad.status_code == 400
