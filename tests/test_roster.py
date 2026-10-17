"""Spec 5.11 roster scenarios, transfers, loans, releases, history; edge case 6; club/roster production routes."""
import re

import pytest

SETUP = "/audit/v1/roster/setup"
TRANSFER = "/audit/v1/roster/transfer"
HISTORY = "/audit/v1/roster/history/"
WHEN_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def scenario(**league_overrides):
    league = {"league_id": "lg-r1", "tenant_id": "tenant-alpha", "sport_id": "football",
              "transfer_window": {"open": "2026-09-01", "close": "2026-09-30"},
              "max_squad_size": 3, "required_positions": {"gk": 1}}
    league.update(league_overrides)
    return {
        "league": league,
        "squads": [{"squad_id": "sq-a", "club_id": "club-a", "tenant_id": "tenant-alpha", "name": "A"},
                   {"squad_id": "sq-b", "club_id": "club-b", "tenant_id": "tenant-alpha", "name": "B"},
                   {"squad_id": "sq-c", "club_id": "club-c", "tenant_id": "tenant-alpha", "name": "C"},
                   {"squad_id": "sq-x", "club_id": "club-x", "tenant_id": "tenant-beta", "name": "X"}],
        "players": [{"player_id": "p1", "name": "Ali", "position": "gk", "squad_id": "sq-a", "role": "captain"},
                    {"player_id": "p2", "name": "Bilal", "position": "df", "squad_id": "sq-a", "role": "starter"},
                    {"player_id": "p3", "name": "Chand", "position": "gk", "squad_id": "sq-b", "role": "captain"},
                    {"player_id": "p4", "name": "Daud", "position": "df", "squad_id": "sq-c", "role": "starter"},
                    {"player_id": "p5", "name": "Ehsan", "position": "mf", "squad_id": "sq-x", "role": "starter"}],
        "matches_in_progress": [],
    }


def move(request_id="tr-001", player_id="p2", type_="transfer", from_="sq-a", to="sq-b",
         effective="2026-09-30", loan_end=None, **extra):
    body = {"request_id": request_id, "league_id": "lg-r1", "player_id": player_id, "type": type_,
            "from_squad_id": from_, "to_squad_id": to, "effective_date": effective,
            "loan_end_date": loan_end, "reason": "Tactical move", "requested_by": "user-77"}
    body.update(extra)
    return body


def setup(api, body=None):
    api.reset()
    r = api.post(SETUP, json=body or scenario())
    assert r.status_code == 201, r.text
    return r.json()


def err(r, status, code):
    assert r.status_code == status, r.text
    assert r.json()["error"]["code"] == code, r.text
    return r.json()["error"]


def history(api, player_id="p2", as_of=None):
    return api.get(HISTORY + player_id, params={"as_of": as_of} if as_of else None)


# --------------------------------------------------------------------------- setup

def test_setup_response_shape(api):
    assert setup(api) == {"league_id": "lg-r1", "status": "configured",
                          "squad_counts": {"sq-a": 2, "sq-b": 1, "sq-c": 1, "sq-x": 1}}


def test_setup_spec_example(api):
    api.reset()
    body = {"league": {"league_id": "lg-r1", "tenant_id": "tenant-alpha", "sport_id": "football",
                       "transfer_window": {"open": "2026-09-01", "close": "2026-09-30"},
                       "max_squad_size": 3, "required_positions": {"gk": 1}},
            "squads": [{"squad_id": "sq-a", "club_id": "club-a", "tenant_id": "tenant-alpha", "name": "A"},
                       {"squad_id": "sq-b", "club_id": "club-b", "tenant_id": "tenant-alpha", "name": "B"}],
            "players": [{"player_id": "p1", "name": "Ali", "position": "gk", "squad_id": "sq-a", "role": "captain"},
                        {"player_id": "p2", "name": "Bilal", "position": "df", "squad_id": "sq-a",
                         "role": "starter"}],
            "matches_in_progress": [{"match_id": "m-live", "home_squad_id": "sq-a", "away_squad_id": "sq-b"}]}
    r = api.post(SETUP, json=body)
    assert r.status_code == 201
    assert r.json() == {"league_id": "lg-r1", "status": "configured", "squad_counts": {"sq-a": 2, "sq-b": 0}}


def test_setup_resend_replaces_league_state(api):
    setup(api)
    assert api.post(TRANSFER, json=move()).status_code == 201
    body = scenario()
    body["players"] = body["players"][:1]
    r = api.post(SETUP, json=body)
    assert r.status_code == 201
    assert r.json()["squad_counts"] == {"sq-a": 1, "sq-b": 0, "sq-c": 0, "sq-x": 0}
    err(history(api, "p2"), 404, "PLAYER_NOT_FOUND")
    assert history(api, "p1").json()["history"] == []
    # idempotency entries of the replaced league are gone: the same request id is a new request
    body = scenario()
    api.post(SETUP, json=body)
    r = api.post(TRANSFER, json=move())
    assert r.status_code == 201
    assert r.json()["audit_entry"]["audit_id"] == "au-0002"  # audit ids are never reused


def test_setup_moves_player_from_other_league(api):
    setup(api)
    other = scenario(league_id="lg-r2")
    other["squads"] = [{"squad_id": "sq-z", "tenant_id": "tenant-alpha"}]
    other["players"] = [{"player_id": "p2", "name": "Bilal", "position": "df", "squad_id": "sq-z"}]
    r = api.post(SETUP, json=other)
    assert r.json()["squad_counts"] == {"sq-z": 1}
    h = history(api, "p2").json()
    assert h["league_id"] == "lg-r2" and h["current_squad_id"] == "sq-z"


def test_setup_defaults_from_sport_roster_config(api):
    api.reset()
    body = scenario()
    del body["league"]["max_squad_size"]
    del body["league"]["required_positions"]
    body["players"] = [{"player_id": f"q{i}", "name": f"Q{i}", "position": "df", "squad_id": "sq-b"}
                       for i in range(24)] + [{"player_id": "mover", "name": "M", "position": "gk",
                                               "squad_id": "sq-a"}]
    assert api.post(SETUP, json=body).status_code == 201
    # football max 25: 24 + 1 fits
    assert api.post(TRANSFER, json=move(player_id="mover", effective="2026-09-02")).status_code == 409  # gk >= 1
    body["players"].append({"player_id": "gk2", "name": "G", "position": "gk", "squad_id": "sq-a"})
    api.post(SETUP, json=body)
    assert api.post(TRANSFER, json=move(player_id="mover")).status_code == 201
    err(api.post(TRANSFER, json=move("tr-2", player_id="gk2", effective="2026-09-30")), 409, "SQUAD_FULL")


def test_setup_unknown_sport_404(api):
    api.reset()
    err(api.post(SETUP, json=scenario(sport_id="curling")), 404, "SPORT_NOT_FOUND")


@pytest.mark.parametrize("mutate,field", [
    (lambda b: b.pop("league"), "league"),
    (lambda b: b["league"].update(league_id="bad id!"), "league.league_id"),
    (lambda b: b["league"].update(sport_id="x'; DROP TABLE sports;--"), "league.sport_id"),
    (lambda b: b["league"].update(transfer_window="2026"), "league.transfer_window"),
    (lambda b: b["league"]["transfer_window"].update(open="2026-13-01"), "league.transfer_window.open"),
    (lambda b: b["league"]["transfer_window"].update(close=20260930), "league.transfer_window.close"),
    (lambda b: b["league"]["transfer_window"].update(open="2026-10-01"), "league.transfer_window"),
    (lambda b: b["league"].update(max_squad_size=True), "league.max_squad_size"),
    (lambda b: b["league"].update(max_squad_size=0), "league.max_squad_size"),
    (lambda b: b["league"].update(required_positions={"gk": -1}), "league.required_positions"),
    (lambda b: b.update(squads="nope"), "squads"),
    (lambda b: b["squads"].append("x"), "squads[4]"),
    (lambda b: b["squads"].append({"squad_id": "sq-a"}), "squads[4].squad_id"),
    (lambda b: b["squads"][0].update(club_id=5), "squads[0].club_id"),
    (lambda b: b["squads"][0].update(name=""), "squads[0].name"),
    (lambda b: b.update(players={}), "players"),
    (lambda b: b["players"].append(7), "players[5]"),
    (lambda b: b["players"].append(dict(b["players"][0])), "players[5].player_id"),
    (lambda b: b["players"][0].update(name=None), "players[0].name"),
    (lambda b: b["players"][0].update(position=1), "players[0].position"),
    (lambda b: b["players"][0].update(squad_id="sq-missing"), "players[0].squad_id"),
    (lambda b: b["players"][0].update(role="coach"), "players[0].role"),
    (lambda b: b.update(matches_in_progress={}), "matches_in_progress"),
    (lambda b: b.update(matches_in_progress=[{"match_id": "m1"}]), "matches_in_progress[0]"),
])
def test_setup_validation(api, mutate, field):
    api.reset()
    body = scenario()
    mutate(body)
    e = err(api.post(SETUP, json=body), 400, "VALIDATION_ERROR")
    assert field in e["details"]["fields"]


def test_setup_rejects_non_object_and_malformed(api):
    err(api.post(SETUP, json=[1]), 400, "VALIDATION_ERROR")
    err(api.post(SETUP, data="{oops", headers={"Content-Type": "application/json"}), 400, "VALIDATION_ERROR")


# --------------------------------------------------------------------------- transfer: success shapes

def test_transfer_spec_shape(api):
    setup(api)
    r = api.post(TRANSFER, json=move())
    assert r.status_code == 201, r.text
    body = r.json()
    when = body["audit_entry"].pop("when")
    assert WHEN_RE.match(when)
    assert body == {
        "request_id": "tr-001", "status": "accepted", "state": "active", "blocking_match_id": None,
        "registration": {"player_id": "p2", "league_id": "lg-r1", "squad_id": "sq-b", "parent_squad_id": None,
                         "registration_type": "transfer", "start_date": "2026-09-30", "loan_end_date": None,
                         "role": "substitute"},
        "audit_entry": {"audit_id": "au-0001", "action": "transfer", "player_id": "p2", "league_id": "lg-r1",
                        "from_squad_id": "sq-a", "to_squad_id": "sq-b", "effective_date": "2026-09-30",
                        "state": "active", "who": "user-77", "why": "Tactical move"}}
    h = history(api, "p2", "2026-10-01").json()
    assert h["current_squad_id"] == "sq-b" and h["parent_squad_id"] is None
    assert [e["audit_id"] for e in h["history"]] == ["au-0001"]


def test_replay_returns_200_and_identical_body(api):
    setup(api)
    first = api.post(TRANSFER, json=move())
    again = api.post(TRANSFER, json=move())
    assert again.status_code == 200
    assert again.json() == first.json()
    assert len(history(api, "p2").json()["history"]) == 1


def test_same_request_id_different_body_409(api):
    setup(api)
    api.post(TRANSFER, json=move())
    err(api.post(TRANSFER, json=move(reason="other")), 409, "DUPLICATE_REQUEST_ID")
    assert len(history(api, "p2").json()["history"]) == 1


def test_unknown_fields_ignored_and_replay_still_matches(api):
    setup(api)
    assert api.post(TRANSFER, json=move(extra_field=1)).status_code == 201
    assert api.post(TRANSFER, json=move(extra_field=2)).status_code == 200


def test_audit_ids_sequential_and_deterministic_after_reset(api):
    for _ in range(2):
        setup(api)
        a = api.post(TRANSFER, json=move()).json()
        b = api.post(TRANSFER, json=move("tr-002", player_id="p4", from_="sq-c", to="sq-a")).json()
        assert a["audit_entry"]["audit_id"] == "au-0001"
        assert b["audit_entry"]["audit_id"] == "au-0002"


def test_transfer_of_captain_vacates_slot(api):
    setup(api, {**scenario(), "players": scenario()["players"] + [
        {"player_id": "p6", "name": "Faraz", "position": "gk", "squad_id": "sq-a", "role": "substitute"}]})
    r = api.post(TRANSFER, json=move(player_id="p1", to="sq-c"))
    assert r.status_code == 201
    assert r.json()["registration"]["role"] == "substitute"


def test_loan_shape_history_and_auto_return_once(api):
    setup(api)
    r = api.post(TRANSFER, json=move(type_="loan", effective="2026-09-10", loan_end="2026-12-31"))
    assert r.status_code == 201, r.text
    reg = r.json()["registration"]
    assert reg == {"player_id": "p2", "league_id": "lg-r1", "squad_id": "sq-b", "parent_squad_id": "sq-a",
                   "registration_type": "loan", "start_date": "2026-09-10", "loan_end_date": "2026-12-31",
                   "role": "substitute"}
    assert r.json()["audit_entry"]["action"] == "loan"

    during = history(api, "p2", "2026-12-31").json()  # loan_end_date inclusive
    assert during["current_squad_id"] == "sq-b" and during["parent_squad_id"] == "sq-a"
    assert len(during["history"]) == 1

    after = history(api, "p2", "2027-01-05").json()
    assert after["player_id"] == "p2" and after["as_of"] == "2027-01-05" and after["league_id"] == "lg-r1"
    assert after["current_squad_id"] == "sq-a" and after["parent_squad_id"] is None
    assert [e["action"] for e in after["history"]] == ["loan", "loan_return"]
    ret = after["history"][1]
    assert ret["who"] == "system" and ret["audit_id"] == "au-0002"
    assert ret["from_squad_id"] == "sq-b" and ret["to_squad_id"] == "sq-a"
    assert ret["effective_date"] == "2027-01-01" and WHEN_RE.match(ret["when"])

    again = history(api, "p2", "2027-02-01").json()
    assert again["history"] == after["history"]  # never duplicated
    before = history(api, "p2", "2026-09-05").json()
    assert before["current_squad_id"] == "sq-a"  # before the loan started


def test_loan_counts_toward_borrower_not_lender(api):
    setup(api)
    # sq-b: p3 + loanee p2 = 2; max 3 -> one more fits, then full
    assert api.post(TRANSFER, json=move(type_="loan", effective="2026-09-10", loan_end="2026-12-31")).status_code == 201
    assert api.post(TRANSFER, json=move("tr-2", player_id="p4", from_="sq-c", to="sq-b",
                                        effective="2026-09-11")).status_code == 201
    err(api.post(TRANSFER, json=move("tr-3", player_id="p1", from_="sq-a", to="sq-b",
                                     effective="2026-09-12")), 409, "SQUAD_FULL")
    # lender sq-a has only p1 now; p2 does not count there: sq-a can take two more
    assert api.post(TRANSFER, json=move("tr-4", player_id="p4", from_="sq-b", to="sq-a",
                                        effective="2026-09-13")).status_code == 201


def test_transfer_after_loan_ended_from_lender_logs_return_first(api):
    setup(api)
    api.post(TRANSFER, json=move(type_="loan", effective="2026-09-05", loan_end="2026-09-20"))
    err(api.post(TRANSFER, json=move("tr-2", from_="sq-b", to="sq-c", effective="2026-09-25")), 409, "NOT_IN_SQUAD")
    r = api.post(TRANSFER, json=move("tr-3", from_="sq-a", to="sq-c", effective="2026-09-25"))
    assert r.status_code == 201
    assert r.json()["audit_entry"]["audit_id"] == "au-0003"
    h = history(api, "p2", "2027-01-05").json()
    assert [e["action"] for e in h["history"]] == ["loan", "loan_return", "transfer"]
    assert h["current_squad_id"] == "sq-c"


def test_release(api):
    setup(api)
    r = api.post(TRANSFER, json=move(type_="release", to=None, effective="2027-03-01"))
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["registration"] is None
    assert body["audit_entry"]["action"] == "release" and body["audit_entry"]["to_squad_id"] is None
    h = history(api, "p2", "2027-03-02").json()
    assert h["current_squad_id"] is None
    assert history(api, "p2", "2027-02-01").json()["current_squad_id"] == "sq-a"
    err(api.post(TRANSFER, json=move("tr-2", from_="sq-a", to="sq-b")), 409, "NOT_IN_SQUAD")


def test_release_without_to_squad_key(api):
    setup(api)
    body = move(type_="release", effective="2025-01-01")
    del body["to_squad_id"]
    del body["loan_end_date"]
    assert api.post(TRANSFER, json=body).status_code == 201


def test_deferred_until_match_end(api):
    body = scenario()
    body["matches_in_progress"] = [{"match_id": "m-other", "home_squad_id": "sq-b", "away_squad_id": "sq-c"},
                                   {"match_id": "m-live", "home_squad_id": "sq-c", "away_squad_id": "sq-a"}]
    setup(api, body)
    r = api.post(TRANSFER, json=move(effective="2026-09-30"))  # last window day
    assert r.status_code == 201, r.text
    assert r.json()["state"] == "deferred_until_match_end"
    assert r.json()["blocking_match_id"] == "m-live"
    assert r.json()["audit_entry"]["state"] == "deferred_until_match_end"
    # player not in a live match -> active
    r = api.post(TRANSFER, json=move("tr-2", player_id="p5", from_="sq-x", to="sq-a"))
    assert r.status_code == 409  # sq-x is cross-tenant
    body["matches_in_progress"] = [{"match_id": "m-x", "home_squad_id": "sq-b", "away_squad_id": "sq-b"}]
    setup(api, body)
    r = api.post(TRANSFER, json=move("tr-3", player_id="p4", from_="sq-c", to="sq-a"))
    assert r.json()["state"] == "active" and r.json()["blocking_match_id"] is None


# --------------------------------------------------------------------------- transfer: rule 1 validation

@pytest.mark.parametrize("override,field", [
    ({"request_id": None}, "request_id"),
    ({"request_id": "a" * 65}, "request_id"),
    ({"league_id": "lg|1"}, "league_id"),
    ({"player_id": 12}, "player_id"),
    ({"type": "swap"}, "type"),
    ({"from_squad_id": ""}, "from_squad_id"),
    ({"to_squad_id": None}, "to_squad_id"),
    ({"to_squad_id": "sq-a"}, "to_squad_id"),
    ({"effective_date": "2026-02-30"}, "effective_date"),
    ({"effective_date": "30-09-2026"}, "effective_date"),
    ({"effective_date": None}, "effective_date"),
    ({"type": "loan", "loan_end_date": None}, "loan_end_date"),
    ({"type": "loan", "loan_end_date": "2026-09-30"}, "loan_end_date"),
    ({"type": "loan", "loan_end_date": "2026-09-29"}, "loan_end_date"),
    ({"type": "loan", "loan_end_date": "soon"}, "loan_end_date"),
    ({"reason": 5}, "reason"),
    ({"requested_by": None}, "requested_by"),
    ({"requested_by": True}, "requested_by"),
])
def test_transfer_validation(api, override, field):
    setup(api)
    e = err(api.post(TRANSFER, json=move(**{k: v for k, v in override.items() if k != "type"},
                                         **({"type_": override["type"]} if "type" in override else {}))),
            400, "VALIDATION_ERROR")
    assert field in e["details"]["fields"]
    assert history(api, "p2").json()["history"] == []


def test_transfer_validation_before_404(api):
    setup(api)
    e = err(api.post(TRANSFER, json=move(league_id="nope", effective_date="bad")), 400, "VALIDATION_ERROR")
    assert e["details"]["fields"] == ["effective_date"]


def test_transfer_non_object_and_malformed(api):
    setup(api)
    err(api.post(TRANSFER, json="x"), 400, "VALIDATION_ERROR")
    err(api.post(TRANSFER, data="{", headers={"Content-Type": "application/json"}), 400, "VALIDATION_ERROR")


def test_sqlish_strings_are_plain_data(api):
    setup(api)
    r = api.post(TRANSFER, json=move(reason="'; DROP TABLE roster_players;-- <script>", requested_by="o'brien"))
    assert r.status_code == 201
    assert r.json()["audit_entry"]["why"] == "'; DROP TABLE roster_players;-- <script>"
    assert r.json()["audit_entry"]["who"] == "o'brien"
    err(history(api, "x';DROP"), 404, "PLAYER_NOT_FOUND")


# --------------------------------------------------------------------------- transfer: rules 2..8 and order

def test_rule2_not_found_order(api):
    setup(api)
    err(api.post(TRANSFER, json=move(league_id="lg-none", player_id="nobody")), 404, "LEAGUE_NOT_FOUND")
    err(api.post(TRANSFER, json=move(player_id="nobody", from_="sq-none")), 404, "PLAYER_NOT_FOUND")
    err(api.post(TRANSFER, json=move(from_="sq-none", to="sq-none2")), 404, "SQUAD_NOT_FOUND")
    e = err(api.post(TRANSFER, json=move(to="sq-none")), 404, "SQUAD_NOT_FOUND")
    assert e["details"] == {"squad_id": "sq-none"}


def test_rule3_cross_tenant(api):
    setup(api)
    err(api.post(TRANSFER, json=move(to="sq-x")), 409, "CROSS_TENANT_TRANSFER")
    err(api.post(TRANSFER, json=move(player_id="p5", from_="sq-x", to="sq-a")), 409, "CROSS_TENANT_TRANSFER")
    # cross-tenant beats NOT_IN_SQUAD and window closed
    err(api.post(TRANSFER, json=move(player_id="p4", to="sq-x", effective="2027-01-01")), 409,
        "CROSS_TENANT_TRANSFER")


def test_rule3_squad_of_foreign_tenant_league(api):
    setup(api)
    # club-beta-1 is a baseline squad of league-beta-1 (tenant-beta)
    err(api.post(TRANSFER, json=move(to="club-beta-1")), 409, "CROSS_TENANT_TRANSFER")
    # same-tenant squad of another league is not part of lg-r1
    err(api.post(TRANSFER, json=move(to="club-alpha-1")), 404, "SQUAD_NOT_FOUND")


def test_rule4_not_in_squad_beats_window(api):
    setup(api)
    err(api.post(TRANSFER, json=move(player_id="p4", effective="2027-01-01")), 409, "NOT_IN_SQUAD")


def test_rule5_window_boundaries_inclusive(api):
    setup(api)
    err(api.post(TRANSFER, json=move("t0", effective="2026-08-31")), 409, "TRANSFER_WINDOW_CLOSED")
    err(api.post(TRANSFER, json=move("t1", effective="2026-10-01")), 409, "TRANSFER_WINDOW_CLOSED")
    err(api.post(TRANSFER, json=move("t2", type_="loan", effective="2026-10-01", loan_end="2026-12-01")), 409,
        "TRANSFER_WINDOW_CLOSED")
    assert api.post(TRANSFER, json=move("t3", effective="2026-09-01")).status_code == 201
    assert api.post(TRANSFER, json=move("t4", from_="sq-b", to="sq-c", effective="2026-09-30")).status_code == 201


def test_rule5_window_beats_full(api):
    setup(api, scenario(max_squad_size=2))
    assert api.post(TRANSFER, json=move("t1", player_id="p4", from_="sq-c", to="sq-b",
                                        effective="2026-09-02")).status_code == 201
    # sq-b is now full (2) AND the date is outside the window -> window wins
    err(api.post(TRANSFER, json=move("t3", effective="2026-10-05")), 409, "TRANSFER_WINDOW_CLOSED")
    err(api.post(TRANSFER, json=move("t4", effective="2026-09-05")), 409, "SQUAD_FULL")


def test_rule6_player_on_loan(api):
    setup(api)
    assert api.post(TRANSFER, json=move("ln", type_="loan", effective="2026-09-10",
                                        loan_end="2026-12-31")).status_code == 201
    err(api.post(TRANSFER, json=move("t1", from_="sq-b", to="sq-c", effective="2026-09-20")), 409, "PLAYER_ON_LOAN")
    err(api.post(TRANSFER, json=move("t2", type_="loan", from_="sq-b", to="sq-c", effective="2026-09-20",
                                     loan_end="2026-11-01")), 409, "PLAYER_ON_LOAN")
    err(api.post(TRANSFER, json=move("t3", type_="release", from_="sq-b", to=None, effective="2026-11-20")), 409,
        "PLAYER_ON_LOAN")
    # the lender is not the current squad
    err(api.post(TRANSFER, json=move("t4", from_="sq-a", to="sq-c", effective="2026-09-20")), 409, "NOT_IN_SQUAD")
    # window closed beats on-loan
    err(api.post(TRANSFER, json=move("t5", from_="sq-b", to="sq-c", effective="2026-10-20")), 409,
        "TRANSFER_WINDOW_CLOSED")
    assert len(history(api, "p2", "2026-10-01").json()["history"]) == 1


def test_rule6_on_loan_beats_full_and_min_position(api):
    body = scenario()
    body["players"].append({"player_id": "p6", "name": "Fahad", "position": "gk", "squad_id": "sq-b"})
    setup(api, body)
    assert api.post(TRANSFER, json=move("ln", player_id="p6", from_="sq-b", to="sq-c", type_="loan",
                                        effective="2026-09-10", loan_end="2026-12-31")).status_code == 201
    assert api.post(TRANSFER, json=move("f1", player_id="p4", from_="sq-c", to="sq-a",
                                        effective="2026-09-11")).status_code == 201
    # sq-a is full (p1, p2, p4) and p6 is sq-c's only gk, but the loan check comes first
    err(api.post(TRANSFER, json=move("t1", player_id="p6", from_="sq-c", to="sq-a", effective="2026-09-12")), 409,
        "PLAYER_ON_LOAN")


def test_rule7_squad_full(api):
    setup(api, {**scenario(max_squad_size=1)})
    e = err(api.post(TRANSFER, json=move()), 409, "SQUAD_FULL")
    assert e["details"]["squad_id"] == "sq-b"
    assert history(api, "p2").json()["history"] == []


def test_rule7_full_beats_min_position(api):
    setup(api, {**scenario(max_squad_size=1)})
    err(api.post(TRANSFER, json=move(player_id="p1")), 409, "SQUAD_FULL")


def test_rule8_min_position(api):
    setup(api)
    err(api.post(TRANSFER, json=move(player_id="p1")), 409, "MIN_POSITION_VIOLATION")
    err(api.post(TRANSFER, json=move("t2", player_id="p1", type_="release", to=None)), 409,
        "MIN_POSITION_VIOLATION")
    err(api.post(TRANSFER, json=move("t3", player_id="p1", type_="loan", loan_end="2026-12-01",
                                     effective="2026-09-02")), 409, "MIN_POSITION_VIOLATION")
    # no requirement for df
    assert api.post(TRANSFER, json=move("t4")).status_code == 201


def test_rule8_required_zero_or_unlisted_position(api):
    setup(api, scenario(required_positions={"gk": 0}))
    assert api.post(TRANSFER, json=move(player_id="p1")).status_code == 201


def test_rejected_requests_write_nothing_and_are_retryable(api):
    setup(api, scenario(max_squad_size=1))
    err(api.post(TRANSFER, json=move()), 409, "SQUAD_FULL")
    # same request_id with a different (valid) body is a fresh request because nothing was stored
    r = api.post(TRANSFER, json=move(to="sq-c", effective="2026-09-15"))
    assert r.status_code == 409  # sq-c already has p4 -> full too
    setup(api)
    assert api.post(TRANSFER, json=move()).json()["audit_entry"]["audit_id"] == "au-0001"


# --------------------------------------------------------------------------- history

def test_history_unknown_player_and_bad_as_of(api):
    setup(api)
    err(history(api, "ghost"), 404, "PLAYER_NOT_FOUND")
    err(history(api, "p2", "2027-1-5"), 400, "VALIDATION_ERROR")
    err(api.get(HISTORY + "ghost", params={"as_of": "bad"}), 400, "VALIDATION_ERROR")


def test_history_default_today(api):
    setup(api)
    h = history(api, "p1").json()
    assert re.match(r"^\d{4}-\d{2}-\d{2}$", h["as_of"])
    assert h == {"player_id": "p1", "as_of": h["as_of"], "league_id": "lg-r1", "current_squad_id": "sq-a",
                 "parent_squad_id": None, "history": []}


def test_player_without_squad(api):
    body = scenario()
    body["players"].append({"player_id": "free", "name": "Free", "position": "df", "squad_id": None})
    setup(api, body)
    assert history(api, "free").json()["current_squad_id"] is None
    err(api.post(TRANSFER, json=move(player_id="free")), 409, "NOT_IN_SQUAD")


def test_player_of_other_league_not_in_squad(api):
    setup(api)
    err(api.post(TRANSFER, json=move(player_id="player-alpha-1")), 409, "NOT_IN_SQUAD")


# --------------------------------------------------------------------------- reuse by offline sync

def test_apply_transfer_and_player_version_direct(api):
    from app.db import pool
    from app.errors import ApiError
    from app.modules import core, roster
    core.run_reset()
    with pool.connection() as conn:
        assert roster.player_version(conn, "player-alpha-1") == 0
        body = {"request_id": "sync-1", "league_id": "league-alpha-1", "player_id": "player-alpha-1",
                "type": "transfer", "from_squad_id": "club-alpha-1", "to_squad_id": "club-alpha-2",
                "effective_date": "2026-10-17", "loan_end_date": None, "reason": "r", "requested_by": "u"}
        status, resp = roster.apply_transfer(conn, body)
        assert status == 201 and resp["registration"]["squad_id"] == "club-alpha-2"
        assert roster.apply_transfer(conn, body) == (200, resp)
        assert roster.player_version(conn, "player-alpha-1") == 1
        with pytest.raises(ApiError) as e:
            roster.player_version(conn, "ghost")
        assert e.value.code == "PLAYER_NOT_FOUND"
        with pytest.raises(ApiError) as e:
            roster.apply_transfer(conn, {**body, "request_id": "sync-2"})
        assert e.value.code == "NOT_IN_SQUAD"
    core.run_reset()


# --------------------------------------------------------------------------- baseline + production routes

def token(role, **claims):
    from app.auth import create_token
    base = {"sub": f"u-{role}", "role": role, "tenant_id": "tenant-alpha"}
    base.update(claims)
    return {"Authorization": f"Bearer {create_token(base)}"}


ADMIN = {"tenant_id": None}


def test_baseline_seeded(api):
    api.reset()
    h = history(api, "player-alpha-1").json()
    assert h["league_id"] == "league-alpha-1" and h["current_squad_id"] == "club-alpha-1"
    assert history(api, "player-alpha-2").json()["current_squad_id"] == "club-alpha-2"
    assert history(api, "player-beta-1").json()["league_id"] == "league-beta-1"


def test_club_profile(api):
    api.reset()
    r = api.get("/api/v1/clubs/club-alpha-1", headers=token("viewer"))
    assert r.status_code == 200, r.text
    club = r.json()
    assert set(club) == {"club_id", "name", "tenant_id", "home_venue", "social", "staff", "stats", "roster"}
    assert club["club_id"] == "club-alpha-1" and club["tenant_id"] == "tenant-alpha"
    assert set(club["home_venue"]) == {"name", "lat", "lng"}
    assert [s["role"] for s in club["staff"]] == ["coach", "manager", "physio"]
    assert len(club["stats"]) == 2 and set(club["stats"][0]) == {"season", "played", "won", "drawn", "lost"}
    captain = club["roster"][0]
    assert captain == {"player_id": "player-alpha-1", "name": "Ahmed Raza", "position": "fw", "role": "captain",
                       "squad_id": "club-alpha-1", "registration_type": "initial", "loan_end_date": None}
    assert len(club["roster"]) == 6


def test_club_profile_access(api):
    api.reset()
    err(api.get("/api/v1/clubs/club-beta-1", headers=token("viewer")), 403, "FORBIDDEN")
    err(api.get("/api/v1/clubs/club-beta-1", headers=token("club_manager", club_id="club-alpha-1")), 403, "FORBIDDEN")
    assert api.get("/api/v1/clubs/club-beta-1", headers=token("super_admin", **ADMIN)).status_code == 200
    err(api.get("/api/v1/clubs/club-nope", headers=token("super_admin", **ADMIN)), 404, "CLUB_NOT_FOUND")
    err(api.get("/api/v1/clubs/club-alpha-1"), 401, "UNAUTHENTICATED")


def test_club_profile_for_setup_only_club_shows_loanee(api):
    setup(api)
    api.post(TRANSFER, json=move(type_="loan", effective="2026-09-10", loan_end="2099-12-31"))
    club = api.get("/api/v1/clubs/club-b", headers=token("viewer")).json()
    assert club["home_venue"] is None and club["staff"] == []
    loanee = [p for p in club["roster"] if p["player_id"] == "p2"][0]
    assert loanee["registration_type"] == "loan" and loanee["loan_end_date"] == "2099-12-31"


def prod_body(request_id="m-1", player="player-alpha-1", from_="club-alpha-1", to="club-alpha-2"):
    return {"request_id": request_id, "league_id": "league-alpha-1", "player_id": player, "type": "transfer",
            "from_squad_id": from_, "to_squad_id": to, "effective_date": "2026-10-17", "loan_end_date": None,
            "reason": "Mobile", "requested_by": "manager@nascon.test"}


def test_prod_transfer_by_own_club_manager(api):
    api.reset()
    headers = token("club_manager", club_id="club-alpha-1")
    r = api.post("/api/v1/roster/transfer", json=prod_body(), headers=headers)
    assert r.status_code == 201, r.text
    assert r.json()["registration"]["squad_id"] == "club-alpha-2"
    assert api.post("/api/v1/roster/transfer", json=prod_body(), headers=headers).status_code == 200
    h = api.get("/api/v1/roster/players/player-alpha-1/history", headers=token("viewer"))
    assert h.status_code == 200 and len(h.json()["history"]) == 1


def test_prod_transfer_forbidden(api):
    api.reset()
    url = "/api/v1/roster/transfer"
    err(api.post(url, json=prod_body(), headers=token("viewer")), 403, "FORBIDDEN")
    err(api.post(url, json=prod_body(), headers=token("league_organizer", league_id="league-alpha-1")), 403,
        "FORBIDDEN")
    err(api.post(url, json=prod_body("m-2", "player-alpha-2", "club-alpha-2", "club-alpha-1"),
                 headers=token("club_manager", club_id="club-alpha-1")), 403, "FORBIDDEN")
    err(api.post(url, json=prod_body(), headers={"Authorization": "Bearer junk"}), 401, "UNAUTHENTICATED")
    # super admin may move anyone; club manager with an invalid body still gets 400
    assert api.post(url, json=prod_body("m-3", "player-alpha-2", "club-alpha-2", "club-alpha-1"),
                    headers=token("super_admin", **ADMIN)).status_code == 201
    err(api.post(url, json={"type": "transfer"}, headers=token("club_manager", club_id="club-alpha-1")), 400,
        "VALIDATION_ERROR")


def test_prod_history_access(api):
    api.reset()
    url = "/api/v1/roster/players/{}/history"
    assert api.get(url.format("player-alpha-2"), headers=token("player", player_id="player-alpha-1"),
                   params={"as_of": "2026-10-17"}).json()["current_squad_id"] == "club-alpha-2"
    err(api.get(url.format("player-beta-1"), headers=token("viewer")), 403, "FORBIDDEN")
    assert api.get(url.format("player-beta-1"), headers=token("super_admin", **ADMIN)).status_code == 200
    err(api.get(url.format("ghost"), headers=token("viewer")), 404, "PLAYER_NOT_FOUND")
    err(api.get(url.format("player-alpha-1"), headers=token("viewer"), params={"as_of": "x"}), 400,
        "VALIDATION_ERROR")
