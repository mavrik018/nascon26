"""FR-1.3: match status machine (postponed / abandoned / cancelled) and rescheduling with conflict detection.

Demo league-alpha-1 (seeded, times UTC): m03 club-alpha-1 v club-alpha-3 done 10-12 15:00,
m04 club-alpha-2 v club-alpha-4 live 10-13 15:00 at rovers-ground (05-18),
m05 club-alpha-1 v club-alpha-4 upcoming 10-14 15:00 at alpha-arena (03-19),
m06 club-alpha-2 v club-alpha-3 upcoming 10-15 15:00 at rovers-ground."""
import pytest

from test_mobile_api import login


def move(api, match_id, when, who="organizer", **extra):
    return api.post(f"/api/v1/matches/{match_id}/reschedule", json={"scheduled_at": when, **extra},
                    headers=login(api, who))


def set_status(api, match_id, status, who="organizer"):
    return api.post(f"/api/v1/matches/{match_id}/status", json={"status": status, "reason": "weather"},
                    headers=login(api, who))


def conflicts(r):
    assert r.status_code == 409 and r.json()["error"]["code"] == "SCHEDULE_CONFLICT", r.text
    return r.json()["error"]["details"]["conflicts"]


def test_each_conflict_type_names_the_clashing_ids(api):
    api.reset()
    assert conflicts(move(api, "alpha1-m05", "2026-10-13T12:00:00Z")) == [
        {"type": "rest_period", "match_id": "alpha1-m03", "team_id": "club-alpha-1", "hours_apart": 21.0},
        {"type": "rest_period", "match_id": "alpha1-m04", "team_id": "club-alpha-4", "hours_apart": 3.0}]
    assert conflicts(move(api, "alpha1-m05", "2026-10-13T16:00:00Z")) == [
        {"type": "team_overlap", "match_id": "alpha1-m04", "team_id": "club-alpha-4", "hours_apart": 1.0}]
    assert conflicts(move(api, "alpha1-m05", "2026-10-15T14:00:00Z", venue_id="rovers-ground")) == [
        {"type": "venue_double_booking", "match_id": "alpha1-m06", "venue_id": "rovers-ground"}]
    assert conflicts(move(api, "alpha1-m05", "2026-10-20T21:00:00Z")) == [
        {"type": "venue_unavailable", "venue_id": "alpha-arena", "opens": "03:00Z", "closes": "19:00Z"}]


def test_postpone_then_reschedule_back_to_upcoming(api):
    api.reset()
    h = login(api, "organizer")
    r = set_status(api, "alpha1-m05", "postponed")
    assert r.status_code == 200 and r.json()["status"] == "postponed"
    assert api.get("/api/v1/matches/alpha1-m05", headers=h).json()["status"] == "postponed"
    start = api.post("/api/v1/matches/alpha1-m05/events", json={"event_id": "go-1", "type": "match_start",
                                                               "payload": {}}, headers=h)
    assert start.status_code == 409 and start.json()["error"]["code"] == "ILLEGAL_TRANSITION"
    r = move(api, "alpha1-m05", "2026-10-20T12:00:00Z")
    assert r.status_code == 200 and r.json()["status"] == "upcoming"
    fixture = next(f for f in api.get("/api/v1/leagues/league-alpha-1/fixtures", headers=h).json()
                   if f["match_id"] == "alpha1-m05")
    assert (fixture["status"], fixture["scheduled_at"]) == ("upcoming", "2026-10-20T12:00:00Z")


def test_repeat_postpone_is_ok_and_events_route_cannot_skip_reschedule(api):
    api.reset()
    assert set_status(api, "alpha1-m05", "postponed").json()["event"] is not None
    again = set_status(api, "alpha1-m05", "postponed")
    assert again.status_code == 200 and again.json()["event"] is None
    back = api.post("/api/v1/matches/alpha1-m05/events", headers=login(api, "organizer"), json={
        "event_id": "sneak", "type": "status_change", "payload": {"status": "upcoming", "reason": ""}})
    assert back.status_code == 409 and back.json()["error"]["code"] == "ILLEGAL_TRANSITION"


def test_inactive_matches_do_not_block_a_slot(api):
    api.reset()
    assert set_status(api, "alpha1-m06", "postponed").status_code == 200
    assert move(api, "alpha1-m05", "2026-10-15T14:00:00Z", venue_id="rovers-ground").status_code == 200


@pytest.mark.parametrize("match_id,status", [
    ("alpha1-m01", "cancelled"),   # completed is final
    ("alpha1-m05", "abandoned"),   # only a live match can be abandoned
])
def test_illegal_transitions_are_rejected(api, match_id, status):
    api.reset()
    r = set_status(api, match_id, status)
    assert r.status_code == 409 and r.json()["error"]["code"] == "ILLEGAL_TRANSITION"


def test_abandoned_match_cannot_be_rescheduled(api):
    api.reset()
    assert set_status(api, "alpha1-m04", "abandoned").status_code == 200
    r = move(api, "alpha1-m04", "2026-10-25T12:00:00Z")
    assert r.status_code == 409 and r.json()["error"]["code"] == "ILLEGAL_TRANSITION"


def test_only_the_owning_organizer_or_admin(api):
    api.reset()
    for who in ("viewer", "player", "manager"):
        assert set_status(api, "alpha1-m05", "postponed", who=who).status_code == 403
        assert move(api, "alpha1-m05", "2026-10-20T12:00:00Z", who=who).status_code == 403
    assert set_status(api, "hoops-m3", "postponed").status_code == 403   # another league
    assert set_status(api, "hoops-m3", "postponed", who="admin").status_code == 200
    assert api.post("/api/v1/matches/alpha1-m05/status", json={"status": "postponed"}).status_code == 401


@pytest.mark.parametrize("path,body,field", [
    ("status", {"status": "upcoming"}, "status"),
    ("status", {"status": "postponed", "reason": 5}, "reason"),
    ("reschedule", {"scheduled_at": "2026-10-20 12:00"}, "scheduled_at"),
    ("reschedule", {"scheduled_at": "2026-10-20T12:00:00Z", "venue_id": "bad id"}, "venue_id"),
])
def test_validation(api, path, body, field):
    api.reset()
    r = api.post(f"/api/v1/matches/alpha1-m05/{path}", json=body, headers=login(api, "organizer"))
    assert r.status_code == 400 and field in r.json()["error"]["details"]["fields"]


def test_unknown_match_and_venue_are_404(api):
    api.reset()
    assert set_status(api, "ghost", "postponed").status_code == 404
    r = move(api, "alpha1-m05", "2026-10-20T12:00:00Z", venue_id="nowhere")
    assert r.status_code == 404 and r.json()["error"]["code"] == "VENUE_NOT_FOUND"


def test_status_change_event_payload_is_validated(api):
    api.reset()
    r = api.post("/audit/v1/events", json={"event_id": "s1", "match_id": "alpha1-m05", "type": "status_change",
                                           "payload": {"status": "paused", "reason": ""}})
    assert r.status_code == 400 and r.json()["error"]["details"]["fields"] == ["payload.status"]


@pytest.mark.in_process
def test_player_registered_in_both_squads_is_a_player_overlap(api, monkeypatch):
    from app.modules import roster
    real = roster._club_roster
    # The seed has no dual registration, so give club-alpha-3 one of club-alpha-1's players.
    monkeypatch.setattr(roster, "_club_roster", lambda conn, club, day: real(conn, club, day) + (
        [{"player_id": "player-alpha-1"}] if club == "club-alpha-3" else []))
    api.reset()
    found = conflicts(move(api, "alpha1-m05", "2026-10-15T15:30:00Z", venue_id="alpha-arena"))
    assert found == [{"type": "player_overlap", "match_id": "alpha1-m06", "player_id": "player-alpha-1"}]
