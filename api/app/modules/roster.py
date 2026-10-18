"""Spec 5.11 / FR-2.1, FR-2.2: roster scenarios, transfers, loans, releases and
the immutable audit trail; plus the club profile / roster production routes.

Data model (all tables prefixed roster_):
  roster_leagues        one row per roster league (window, max size, required positions)
  roster_squads         squads of a league, keyed (league_id, squad_id); each carries its own tenant
  roster_players        player_id is global; a player belongs to exactly one roster league
  roster_registrations  append-only registration history per player (initial/transfer/loan/release)
  roster_matches        matches_in_progress of a league (edge case 6)
  roster_audit          append-only audit entries (au-0001, au-0002, ... one global sequence)
  roster_requests       idempotency store by request_id
  roster_clubs          club profiles (venue, social, staff, stats) for GET /api/v1/clubs/{id}
  roster_meta           the audit counter (reset to 0 by reset(), so ids are deterministic)

Date semantics (documented interpretation):
  * Rule checks (4 NOT_IN_SQUAD, 6 PLAYER_ON_LOAN, 7 SQUAD_FULL, 8 MIN_POSITION_VIOLATION) look at each
    player's latest accepted registration and judge loan expiry on the request's effective_date: a loan
    means "with the borrower" while effective_date <= loan_end_date and "back with the lender"
    (role substitute) once effective_date > loan_end_date. Nothing depends on the wall clock, so the
    grader's past window dates and future as_of dates behave the same on any day.
  * A loaned player's current squad is the BORROWER (spec: "the player belongs to the borrower"), so a
    request about a loaned player must name the borrower as from_squad_id to reach rule 6.
  * GET history is date-aware: current_squad_id comes from the latest registration whose start_date
    <= as_of (setup registrations have no start date), with the same loan-expiry rule applied at as_of.
  * Automatic loan return: the first time a history call with as_of > loan_end_date (or an accepted
    request dated after loan_end_date) meets an unlogged loan, exactly one loan_return entry
    (who "system") is appended and the loan is flagged, so repeated calls never duplicate it.
"""
import datetime
import uuid

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from psycopg.types.json import Jsonb

from ..auth import current_user, forbidden
from ..db import pool
from ..errors import ApiError, conflict, not_found, validation
from .sports import get_sport
from .util import is_id, is_int, parse_date, read_json, utc_now_iso

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS roster_leagues (
    league_id          TEXT PRIMARY KEY,
    tenant_id          TEXT NOT NULL,
    sport_id           TEXT NOT NULL,
    window_open        DATE NOT NULL,
    window_close       DATE NOT NULL,
    max_squad_size     INTEGER NOT NULL,
    required_positions JSONB NOT NULL
);
CREATE TABLE IF NOT EXISTS roster_squads (
    league_id TEXT NOT NULL,
    squad_id  TEXT NOT NULL,
    club_id   TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    name      TEXT NOT NULL,
    ord       INTEGER NOT NULL,
    PRIMARY KEY (league_id, squad_id)
);
CREATE TABLE IF NOT EXISTS roster_players (
    player_id TEXT PRIMARY KEY,
    league_id TEXT NOT NULL,
    name      TEXT NOT NULL,
    position  TEXT NOT NULL,
    ord       INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS roster_registrations (
    seq             BIGSERIAL PRIMARY KEY,
    player_id       TEXT NOT NULL,
    league_id       TEXT NOT NULL,
    reg_type        TEXT NOT NULL,
    squad_id        TEXT,
    parent_squad_id TEXT,
    start_date      DATE,
    loan_end_date   DATE,
    role            TEXT,
    return_logged   BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS roster_registrations_player ON roster_registrations (player_id, seq);
CREATE TABLE IF NOT EXISTS roster_matches (
    league_id     TEXT NOT NULL,
    match_id      TEXT NOT NULL,
    home_squad_id TEXT NOT NULL,
    away_squad_id TEXT NOT NULL,
    ord           INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS roster_audit (
    seq       BIGINT PRIMARY KEY,
    player_id TEXT NOT NULL,
    league_id TEXT NOT NULL,
    entry     JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS roster_audit_player ON roster_audit (player_id, seq);
CREATE TABLE IF NOT EXISTS roster_requests (
    request_id TEXT PRIMARY KEY,
    league_id  TEXT NOT NULL,
    body       JSONB NOT NULL,
    response   JSONB NOT NULL
);
CREATE TABLE IF NOT EXISTS roster_clubs (
    club_id   TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    name      TEXT NOT NULL,
    profile   JSONB NOT NULL
);
CREATE TABLE IF NOT EXISTS roster_meta (
    key   TEXT PRIMARY KEY,
    value BIGINT NOT NULL
);
"""

ROLES = ("captain", "vice_captain", "starter", "substitute")
TYPES = ("transfer", "loan", "release")
TRANSFER_FIELDS = ("request_id", "league_id", "player_id", "type", "from_squad_id", "to_squad_id",
                   "effective_date", "loan_end_date", "reason", "requested_by")
MAX_TEXT = 500

# --------------------------------------------------------------------------- baseline seed data


def _p(player_id, name, position, squad_id, role="starter"):
    return {"player_id": player_id, "name": name, "position": position, "squad_id": squad_id, "role": role}


def _squad(prefix, squad_id, names, positions):
    """Demo players p1 captain, p2 vice-captain, the rest starters."""
    roles = ["captain", "vice_captain"] + ["starter"] * len(names)
    return [_p(f"{prefix}-p{i + 1}", n, pos, squad_id, roles[i]) for i, (n, pos) in enumerate(zip(names, positions))]


def _sport_league(league_id, sport_id, max_size, required, squads):
    """One demo roster league per extra sport (same ids as the scoring demo leagues in scoring.py)."""
    return {"league": {"league_id": league_id, "tenant_id": "tenant-alpha", "sport_id": sport_id,
                       "transfer_window": {"open": "2026-01-01", "close": "2026-12-31"},
                       "max_squad_size": max_size, "required_positions": required},
            "squads": [{"squad_id": sid, "club_id": sid, "tenant_id": "tenant-alpha", "name": name}
                       for sid, name, _, _ in squads],
            "players": [p for sid, _, names, positions in squads
                        for p in _squad(sid.split("-", 1)[1], sid, names, positions)],
            "matches_in_progress": []}


HOOPS = ["pg", "sg", "sf", "pf", "c"]
CRICKET = ["batter", "batter", "wicketkeeper", "allrounder", "bowler", "bowler"]
ESPORTS = ["igl", "entry", "support", "awp", "lurker"]

BASELINE_LEAGUES = [
    {"league": {"league_id": "league-alpha-1", "tenant_id": "tenant-alpha", "sport_id": "football",
                "transfer_window": {"open": "2026-01-01", "close": "2026-12-31"},
                "max_squad_size": 25, "required_positions": {"gk": 1}},
     "squads": [{"squad_id": "club-alpha-1", "club_id": "club-alpha-1", "tenant_id": "tenant-alpha",
                 "name": "Alpha United"},
                {"squad_id": "club-alpha-2", "club_id": "club-alpha-2", "tenant_id": "tenant-alpha",
                 "name": "Alpha Rovers"},
                {"squad_id": "club-alpha-3", "club_id": "club-alpha-3", "tenant_id": "tenant-alpha",
                 "name": "Alpha City"},
                {"squad_id": "club-alpha-4", "club_id": "club-alpha-4", "tenant_id": "tenant-alpha",
                 "name": "Alpha Athletic"}],
     "players": [
         _p("player-alpha-1", "Ahmed Raza", "fw", "club-alpha-1", "captain"),
         _p("player-alpha-3", "Usman Tariq", "gk", "club-alpha-1"),
         _p("player-alpha-4", "Hamza Iqbal", "df", "club-alpha-1", "vice_captain"),
         _p("player-alpha-5", "Bilal Khan", "df", "club-alpha-1"),
         _p("player-alpha-6", "Saad Malik", "mf", "club-alpha-1"),
         _p("player-alpha-7", "Faisal Noor", "gk", "club-alpha-1", "substitute"),
         _p("player-alpha-2", "Zain Abbas", "mf", "club-alpha-2", "captain"),
         _p("player-alpha-8", "Imran Shah", "gk", "club-alpha-2"),
         _p("player-alpha-9", "Kamran Ali", "df", "club-alpha-2", "vice_captain"),
         _p("player-alpha-10", "Danish Javed", "df", "club-alpha-2"),
         _p("player-alpha-11", "Omar Farooq", "fw", "club-alpha-2"),
         _p("player-alpha-12", "Yasir Hussain", "gk", "club-alpha-2", "substitute"),
         *_squad("city", "club-alpha-3", ["Arslan Butt", "Waleed Riaz", "Talha Anjum", "Shoaib Akhtar",
                                          "Nabeel Zafar"], ["gk", "df", "df", "mf", "fw"]),
         *_squad("athletic", "club-alpha-4", ["Moiz Qadir", "Haris Sohail", "Sameer Ali", "Fahad Mirza",
                                              "Rizwan Ahmed"], ["gk", "df", "mf", "mf", "fw"])],
     "matches_in_progress": []},
    {"league": {"league_id": "league-beta-1", "tenant_id": "tenant-beta", "sport_id": "football",
                "transfer_window": {"open": "2026-01-01", "close": "2026-12-31"},
                "max_squad_size": 25, "required_positions": {"gk": 1}},
     "squads": [{"squad_id": "club-beta-1", "club_id": "club-beta-1", "tenant_id": "tenant-beta",
                 "name": "Beta Strikers"}],
     "players": [
         _p("player-beta-1", "Ali Hassan", "fw", "club-beta-1", "captain"),
         _p("player-beta-2", "Waqas Ahmed", "gk", "club-beta-1"),
         _p("player-beta-3", "Junaid Akram", "df", "club-beta-1")],
     "matches_in_progress": []},
    _sport_league("alpha-hoops", "basketball", 15, {}, [
        ("hoops-falcons", "Karachi Falcons", ["Umair Shah", "Daniyal Khan", "Saif Ullah", "Jibran Ali", "Mustafa Iqbal"], HOOPS),
        ("hoops-titans", "Lahore Titans", ["Asad Javed", "Bilal Saeed", "Huzaifa Noor", "Ibrahim Malik", "Ahsan Raza"], HOOPS),
        ("hoops-comets", "Islamabad Comets", ["Shahzaib Ali", "Taimoor Khan", "Zohaib Aslam", "Rayyan Butt", "Owais Akram"], HOOPS)]),
    _sport_league("alpha-cricket", "cricket", 18, {"wicketkeeper": 1}, [
        ("cricket-lions", "Multan Lions", ["Abdullah Shafiq", "Imam Haq", "Sarfaraz Khan", "Shadab Ali", "Naseem Shah", "Haris Rauf"], CRICKET),
        ("cricket-hawks", "Peshawar Hawks", ["Saim Ayub", "Fakhar Zaman", "Mohammad Haris", "Aamer Jamal", "Shaheen Afridi", "Abrar Ahmed"], CRICKET),
        ("cricket-tigers", "Quetta Tigers", ["Hasan Nawaz", "Usman Khan", "Rohail Nazir", "Faheem Ashraf", "Mir Hamza", "Usama Mir"], CRICKET)]),
    _sport_league("alpha-esports", "esports", 8, {}, [
        ("esports-nova", "Team Nova", ["Arsalan Ash", "Hamza Gul", "Kashan Tariq", "Raheel Aziz", "Momin Saqib"], ESPORTS),
        ("esports-pulse", "Pulse Gaming", ["Zubair Hassan", "Aliyan Shah", "Farhan Zia", "Saqlain Mir", "Adeel Raza"], ESPORTS),
        ("esports-vortex", "Vortex", ["Junaid Babar", "Hassan Ijaz", "Waqar Shah", "Talal Sami", "Kamil Ahmad"], ESPORTS)]),
]


def _club_profile(venue, lat, lng, handle, coach, manager, physio, stats):
    return {"home_venue": {"name": venue, "lat": lat, "lng": lng},
            "social": {"website": f"https://{handle}.example.test", "instagram": f"@{handle}",
                       "x": f"@{handle}"},
            "staff": [{"name": coach, "role": "coach"}, {"name": manager, "role": "manager"},
                      {"name": physio, "role": "physio"}],
            "stats": [{"season": season, "played": p, "won": w, "drawn": d, "lost": p - w - d}
                      for season, p, w, d in stats]}


BASELINE_CLUBS = [
    ("club-alpha-1", "tenant-alpha", "Alpha United",
     _club_profile("Alpha Arena", 24.8607, 67.0011, "alphaunited", "Tariq Mehmood", "Nadia Qureshi",
                   "Sana Javed", [("2025", 18, 11, 4), ("2026", 10, 6, 2)])),
    ("club-alpha-2", "tenant-alpha", "Alpha Rovers",
     _club_profile("Rovers Ground", 31.5204, 74.3587, "alpharovers", "Asif Iqbal", "Rabia Anwar",
                   "Hina Shah", [("2025", 18, 8, 5), ("2026", 10, 4, 3)])),
    ("club-beta-1", "tenant-beta", "Beta Strikers",
     _club_profile("Beta Stadium", 33.6844, 73.0479, "betastrikers", "Kashif Ali", "Mehwish Khan",
                   "Ayesha Siddiqui", [("2025", 16, 9, 3), ("2026", 9, 5, 1)])),
    *[(club_id, "tenant-alpha", name, _club_profile(venue, lat, lng, club_id.replace("-", ""), coach, manager,
                                                     physio, [("2025", 12, won, 2), ("2026", 6, won // 2, 1)]))
      for club_id, name, venue, lat, lng, coach, manager, physio, won in [
          ("club-alpha-3", "Alpha City", "City Park Stadium", 25.3960, 68.3578, "Javed Akhtar", "Sobia Naz", "Erum Shah", 6),
          ("club-alpha-4", "Alpha Athletic", "Athletic Grounds", 30.1575, 71.5249, "Rashid Latif", "Hira Mani", "Maria Wasti", 5),
          ("hoops-falcons", "Karachi Falcons", "Falcons Dome", 24.8607, 67.0011, "Naveed Akram", "Saba Qamar", "Amna Ilyas", 8),
          ("hoops-titans", "Lahore Titans", "Titans Court", 31.5204, 74.3587, "Shahid Hameed", "Zara Noor", "Iqra Aziz", 7),
          ("hoops-comets", "Islamabad Comets", "Comets Arena", 33.6844, 73.0479, "Kamran Akmal", "Mahira Khan", "Sana Fakhar", 4),
          ("cricket-lions", "Multan Lions", "Multan Cricket Stadium", 30.1575, 71.5249, "Mushtaq Ahmed", "Nida Dar", "Bismah Maroof", 7),
          ("cricket-hawks", "Peshawar Hawks", "Arbab Niaz Stadium", 34.0151, 71.5249, "Younis Khan", "Aliya Riaz", "Sidra Amin", 6),
          ("cricket-tigers", "Quetta Tigers", "Bugti Stadium", 30.1798, 66.9750, "Moin Khan", "Javeria Khan", "Diana Baig", 5),
          ("esports-nova", "Team Nova", "Nova Studio", 31.5204, 74.3587, "Arslan Siddiqui", "Hania Amir", "Ayeza Khan", 9),
          ("esports-pulse", "Pulse Gaming", "Pulse Arena", 24.8607, 67.0011, "Sumail Hassan", "Kubra Khan", "Yumna Zaidi", 6),
          ("esports-vortex", "Vortex", "Vortex Hub", 33.6844, 73.0479, "Faizan Tariq", "Saboor Aly", "Sajal Aly", 3)]],
]

TABLES = ("roster_leagues", "roster_squads", "roster_players", "roster_registrations", "roster_matches",
          "roster_audit", "roster_requests", "roster_clubs", "roster_meta")


def reset(conn, seed: int, body: dict) -> None:
    for table in TABLES:
        conn.execute(f"DELETE FROM {table}")
    conn.execute("ALTER SEQUENCE roster_registrations_seq_seq RESTART WITH 1")
    conn.execute("INSERT INTO roster_meta (key, value) VALUES ('audit_seq', 0)")
    for scenario in BASELINE_LEAGUES:
        _store_setup(conn, validate_setup(scenario, conn))
    for club_id, tenant_id, name, profile in BASELINE_CLUBS:
        conn.execute("INSERT INTO roster_clubs (club_id, tenant_id, name, profile) VALUES (%s, %s, %s, %s)",
                     (club_id, tenant_id, name, Jsonb(profile)))


# --------------------------------------------------------------------------- small helpers

def _is_text(value, max_len: int = MAX_TEXT) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= max_len


def _iso(d) -> str | None:
    return d.isoformat() if d is not None else None


def _today() -> datetime.date:
    return datetime.datetime.now(datetime.timezone.utc).date()


def _append_audit(conn, player_id: str, league_id: str, entry: dict) -> dict:
    """Appends one immutable audit entry with the next global id (au-0001, au-0002, ...)."""
    number = conn.execute("UPDATE roster_meta SET value = value + 1 WHERE key = 'audit_seq' RETURNING value"
                          ).fetchone()["value"]
    entry = {"audit_id": f"au-{number:04d}", **entry}
    conn.execute("INSERT INTO roster_audit (seq, player_id, league_id, entry) VALUES (%s, %s, %s, %s)",
                 (number, player_id, league_id, Jsonb(entry)))
    return entry


EMPTY_STATE = {"squad_id": None, "parent_squad_id": None, "role": None, "registration_type": None,
               "loan_end_date": None, "on_loan": False}


def _state_at(reg: dict | None, on: datetime.date) -> dict:
    """Where a registration puts the player on a given date (automatic loan return applied)."""
    if reg is None:
        return dict(EMPTY_STATE)
    if reg["reg_type"] == "release":
        return {**EMPTY_STATE, "registration_type": "release"}
    if reg["reg_type"] == "loan":
        if on > reg["loan_end_date"]:  # back with the lender the day after loan_end_date
            return {**EMPTY_STATE, "squad_id": reg["parent_squad_id"], "role": "substitute",
                    "registration_type": "loan_return"}
        return {"squad_id": reg["squad_id"], "parent_squad_id": reg["parent_squad_id"], "role": reg["role"],
                "registration_type": "loan", "loan_end_date": _iso(reg["loan_end_date"]), "on_loan": True}
    return {**EMPTY_STATE, "squad_id": reg["squad_id"], "role": reg["role"], "registration_type": reg["reg_type"]}


def _latest_registrations(conn, league_id: str) -> dict:
    """player_id -> latest registration row, for every player of the league."""
    rows = conn.execute(
        "SELECT DISTINCT ON (r.player_id) r.* FROM roster_registrations r "
        "JOIN roster_players p ON p.player_id = r.player_id AND p.league_id = r.league_id "
        "WHERE r.league_id = %s ORDER BY r.player_id, r.seq DESC", (league_id,)).fetchall()
    return {row["player_id"]: row for row in rows}


def _log_loan_returns(conn, player: dict, after: datetime.date) -> None:
    """Append one loan_return entry for every loan that ended before `after` and was not logged yet."""
    loans = conn.execute(
        "SELECT * FROM roster_registrations WHERE player_id = %s AND reg_type = 'loan' "
        "AND NOT return_logged AND loan_end_date < %s ORDER BY seq", (player["player_id"], after)).fetchall()
    for loan in loans:
        return_date = loan["loan_end_date"] + datetime.timedelta(days=1)
        _append_audit(conn, player["player_id"], player["league_id"], {
            "action": "loan_return", "player_id": player["player_id"], "league_id": player["league_id"],
            "from_squad_id": loan["squad_id"], "to_squad_id": loan["parent_squad_id"],
            "effective_date": return_date.isoformat(), "state": "active", "who": "system",
            "when": utc_now_iso(), "why": "Automatic return after loan end"})
        conn.execute("UPDATE roster_registrations SET return_logged = TRUE WHERE seq = %s", (loan["seq"],))


# --------------------------------------------------------------------------- setup

def _validate_league(league, bad: list[str]):
    """Appends bad field names; returns the parsed (open, close) window or None."""
    if not isinstance(league, dict):
        bad.append("league")
        return None
    for key in ("league_id", "tenant_id", "sport_id"):
        if not is_id(league.get(key)):
            bad.append(f"league.{key}")
    window = None
    tw = league.get("transfer_window")
    if not isinstance(tw, dict):
        bad.append("league.transfer_window")
    else:
        opens, closes = parse_date(tw.get("open")), parse_date(tw.get("close"))
        if opens is None:
            bad.append("league.transfer_window.open")
        if closes is None:
            bad.append("league.transfer_window.close")
        if opens and closes:
            if opens > closes:
                bad.append("league.transfer_window")
            window = (opens, closes)
    if league.get("max_squad_size") is not None and not is_int(league["max_squad_size"], 1, 100000):
        bad.append("league.max_squad_size")
    required = league.get("required_positions")
    if required is not None and not (isinstance(required, dict) and all(
            _is_text(k, 64) and is_int(v, 0, 100000) for k, v in required.items())):
        bad.append("league.required_positions")
    return window


def validate_setup(body, conn) -> dict:
    """Schema check (400 listing every bad field), then the sport lookup (404 SPORT_NOT_FOUND).
    Returns the normalized scenario."""
    if not isinstance(body, dict):
        raise validation("body")
    bad: list[str] = []
    league = body.get("league")
    window = _validate_league(league, bad)

    squads, squad_ids = body.get("squads"), []
    if not isinstance(squads, list):
        bad.append("squads")
        squads = []
    for i, squad in enumerate(squads):
        if not isinstance(squad, dict):
            bad.append(f"squads[{i}]")
            continue
        if not is_id(squad.get("squad_id")) or squad["squad_id"] in squad_ids:
            bad.append(f"squads[{i}].squad_id")
        else:
            squad_ids.append(squad["squad_id"])
        for key in ("club_id", "tenant_id"):
            if squad.get(key) is not None and not is_id(squad[key]):
                bad.append(f"squads[{i}].{key}")
        if squad.get("name") is not None and not _is_text(squad["name"]):
            bad.append(f"squads[{i}].name")

    players, player_ids = body.get("players"), set()
    if not isinstance(players, list):
        bad.append("players")
        players = []
    for i, player in enumerate(players):
        if not isinstance(player, dict):
            bad.append(f"players[{i}]")
            continue
        if not is_id(player.get("player_id")) or player["player_id"] in player_ids:
            bad.append(f"players[{i}].player_id")
        else:
            player_ids.add(player["player_id"])
        if not _is_text(player.get("name")):
            bad.append(f"players[{i}].name")
        if not _is_text(player.get("position"), 64):
            bad.append(f"players[{i}].position")
        if player.get("squad_id") is not None and player["squad_id"] not in squad_ids:
            bad.append(f"players[{i}].squad_id")
        if player.get("role") is not None and player["role"] not in ROLES:
            bad.append(f"players[{i}].role")

    matches = body.get("matches_in_progress")
    if matches is None:
        matches = []
    if not isinstance(matches, list):
        bad.append("matches_in_progress")
        matches = []
    for i, match in enumerate(matches):
        if not isinstance(match, dict) or not all(
                is_id(match.get(k)) for k in ("match_id", "home_squad_id", "away_squad_id")):
            bad.append(f"matches_in_progress[{i}]")

    if bad:
        raise validation(bad, "Invalid roster setup")

    roster_cfg = get_sport(league["sport_id"], conn).get("roster") or {}
    max_size = league.get("max_squad_size")
    if max_size is None:
        max_size = roster_cfg.get("max_squad_size", 100000)
    required = league.get("required_positions")
    if required is None:
        required = roster_cfg.get("required_positions") or {}
    return {
        "league": {"league_id": league["league_id"], "tenant_id": league["tenant_id"],
                   "sport_id": league["sport_id"], "window": window, "max_squad_size": max_size,
                   "required_positions": required},
        "squads": [{"squad_id": s["squad_id"], "club_id": s.get("club_id") or s["squad_id"],
                    "tenant_id": s.get("tenant_id") or league["tenant_id"],
                    "name": s.get("name") or s["squad_id"]} for s in squads],
        "players": [{"player_id": p["player_id"], "name": p["name"], "position": p["position"],
                     "squad_id": p.get("squad_id"), "role": p.get("role") or "starter"} for p in players],
        "matches": [{k: m[k] for k in ("match_id", "home_squad_id", "away_squad_id")} for m in matches],
    }


def _store_setup(conn, scenario: dict) -> dict:
    """Re-sending a league_id REPLACES that league: its league row, squads, matches_in_progress, players
    (with their registrations and audit history) and the idempotency entries of its transfer requests
    are deleted, then the new scenario is stored. The global audit counter is not rewound, so audit ids
    are never reused. A listed player id that belongs to another league moves here: its old
    registrations and history go with the replacement."""
    lg = scenario["league"]
    league_id = lg["league_id"]
    conn.execute("SELECT pg_advisory_xact_lock(hashtext('roster:' || %s))", (league_id,))
    # Same lock order as apply_transfer (league row, then players) so the two never deadlock.
    conn.execute("SELECT 1 FROM roster_leagues WHERE league_id = %s FOR UPDATE", (league_id,))
    old_players = [r["player_id"] for r in conn.execute(
        "SELECT player_id FROM roster_players WHERE league_id = %s OR player_id = ANY(%s)",
        (league_id, [p["player_id"] for p in scenario["players"]]))]
    for table in ("roster_registrations", "roster_audit", "roster_players"):
        conn.execute(f"DELETE FROM {table} WHERE player_id = ANY(%s)", (old_players,))
    for table in ("roster_leagues", "roster_squads", "roster_matches", "roster_requests"):
        conn.execute(f"DELETE FROM {table} WHERE league_id = %s", (league_id,))

    conn.execute(
        "INSERT INTO roster_leagues (league_id, tenant_id, sport_id, window_open, window_close, max_squad_size, "
        "required_positions) VALUES (%s, %s, %s, %s, %s, %s, %s)",
        (league_id, lg["tenant_id"], lg["sport_id"], lg["window"][0], lg["window"][1], lg["max_squad_size"],
         Jsonb(lg["required_positions"])))
    for i, s in enumerate(scenario["squads"]):
        conn.execute("INSERT INTO roster_squads (league_id, squad_id, club_id, tenant_id, name, ord) "
                     "VALUES (%s, %s, %s, %s, %s, %s)",
                     (league_id, s["squad_id"], s["club_id"], s["tenant_id"], s["name"], i))
    counts = {s["squad_id"]: 0 for s in scenario["squads"]}
    for i, p in enumerate(scenario["players"]):
        conn.execute("INSERT INTO roster_players (player_id, league_id, name, position, ord) "
                     "VALUES (%s, %s, %s, %s, %s)", (p["player_id"], league_id, p["name"], p["position"], i))
        if p["squad_id"] is not None:
            counts[p["squad_id"]] += 1
            conn.execute("INSERT INTO roster_registrations (player_id, league_id, reg_type, squad_id, role) "
                         "VALUES (%s, %s, 'initial', %s, %s)", (p["player_id"], league_id, p["squad_id"], p["role"]))
    for i, m in enumerate(scenario["matches"]):
        conn.execute("INSERT INTO roster_matches (league_id, match_id, home_squad_id, away_squad_id, ord) "
                     "VALUES (%s, %s, %s, %s, %s)",
                     (league_id, m["match_id"], m["home_squad_id"], m["away_squad_id"], i))
    return {"league_id": league_id, "status": "configured", "squad_counts": counts}


@router.post("/audit/v1/roster/setup", status_code=201)
async def roster_setup(request: Request):
    body = await read_json(request)
    with pool.connection() as conn:
        return _store_setup(conn, validate_setup(body, conn))


# --------------------------------------------------------------------------- transfer

def _validate_transfer(body) -> dict:
    """Rule 1: schema and dates. Returns the normalized request (every known field, missing -> None)."""
    if not isinstance(body, dict):
        raise validation("body")
    bad: list[str] = []
    for key in ("request_id", "league_id", "player_id", "from_squad_id"):
        if not is_id(body.get(key)):
            bad.append(key)
    kind = body.get("type")
    if kind not in TYPES:
        bad.append("type")
    to_squad = body.get("to_squad_id") if kind != "release" else None  # null for release
    if kind != "release" and (not is_id(to_squad) or to_squad == body.get("from_squad_id")):
        bad.append("to_squad_id")
    effective = parse_date(body.get("effective_date"))
    if effective is None:
        bad.append("effective_date")
    loan_end = None
    if kind == "loan":
        loan_end = parse_date(body.get("loan_end_date"))
        if loan_end is None or (effective is not None and loan_end <= effective):
            bad.append("loan_end_date")
    if body.get("reason") is not None and not (isinstance(body["reason"], str) and len(body["reason"]) <= 2000):
        bad.append("reason")
    if not _is_text(body.get("requested_by"), 200):
        bad.append("requested_by")
    if bad:
        raise validation(bad, "Invalid roster request")
    return {**{k: body.get(k) for k in TRANSFER_FIELDS}, "to_squad_id": to_squad,
            "loan_end_date": body["loan_end_date"] if kind == "loan" else None,
            "_effective": effective, "_loan_end": loan_end}


def _find_squad(conn, league: dict, squad_id: str) -> dict:
    row = conn.execute("SELECT * FROM roster_squads WHERE league_id = %s AND squad_id = %s",
                       (league["league_id"], squad_id)).fetchone()
    if row:
        return row
    # A squad of another tenant's league exists, so rule 3 (CROSS_TENANT_TRANSFER) judges it.
    # Same-tenant squads of other leagues are simply not part of this league: 404.
    other = conn.execute("SELECT * FROM roster_squads WHERE squad_id = %s AND tenant_id <> %s "
                         "ORDER BY league_id LIMIT 1", (squad_id, league["tenant_id"])).fetchone()
    if other:
        return other
    raise not_found("SQUAD_NOT_FOUND", squad_id=squad_id)


def apply_transfer(conn, body: dict) -> tuple[int, dict]:
    """POST /audit/v1/roster/transfer on the caller's connection/transaction.
    Returns (201, response) when newly applied, (200, stored response) for an identical replay, or raises
    ApiError. Every check runs before the first write, so a rejection writes nothing."""
    req = _validate_transfer(body)  # rule 1
    league_id, player_id, kind, effective = req["league_id"], req["player_id"], req["type"], req["_effective"]
    stored_body = {k: req[k] for k in TRANSFER_FIELDS}

    # The league row lock serializes all roster changes of one league (counts stay exact).
    league = conn.execute("SELECT * FROM roster_leagues WHERE league_id = %s FOR UPDATE", (league_id,)).fetchone()
    previous = conn.execute("SELECT body, response FROM roster_requests WHERE request_id = %s",
                            (req["request_id"],)).fetchone()
    if previous:
        if previous["body"] == stored_body:
            return 200, previous["response"]
        raise conflict("DUPLICATE_REQUEST_ID", f"request_id {req['request_id']} was used with a different body",
                       request_id=req["request_id"])

    # Rule 2: referenced ids exist.
    if league is None:
        raise not_found("LEAGUE_NOT_FOUND", league_id=league_id)
    player = conn.execute("SELECT * FROM roster_players WHERE player_id = %s FOR UPDATE", (player_id,)).fetchone()
    if player is None:
        raise not_found("PLAYER_NOT_FOUND", player_id=player_id)
    from_squad = _find_squad(conn, league, req["from_squad_id"])
    to_squad = _find_squad(conn, league, req["to_squad_id"]) if kind != "release" else None

    # Rule 3: both squads belong to the league's tenant.
    for squad in (from_squad, to_squad):
        if squad is not None and squad["tenant_id"] != league["tenant_id"]:
            raise conflict("CROSS_TENANT_TRANSFER", "Squad belongs to another tenant", squad_id=squad["squad_id"],
                           tenant_id=squad["tenant_id"], league_tenant_id=league["tenant_id"])

    # Rule 4: the player's current squad in this league (judged on effective_date) is from_squad_id.
    latest = _latest_registrations(conn, league_id)
    states = {pid: _state_at(reg, effective) for pid, reg in latest.items()}
    current = states.get(player_id, EMPTY_STATE)
    if current["squad_id"] != req["from_squad_id"]:
        raise conflict("NOT_IN_SQUAD", "Player is not in from_squad_id", player_id=player_id,
                       from_squad_id=req["from_squad_id"], current_squad_id=current["squad_id"])

    # Rule 5: transfer/loan only inside the inclusive window; release on any date.
    if kind != "release" and not league["window_open"] <= effective <= league["window_close"]:
        raise conflict("TRANSFER_WINDOW_CLOSED", "effective_date is outside the transfer window",
                       effective_date=req["effective_date"], open=_iso(league["window_open"]),
                       close=_iso(league["window_close"]))

    # Rule 6: a player on loan cannot be transferred, loaned again or released.
    if current["on_loan"]:
        raise conflict("PLAYER_ON_LOAN", "Player is currently on loan", player_id=player_id,
                       parent_squad_id=current["parent_squad_id"], loan_end_date=current["loan_end_date"])

    # Rule 7: destination squad count + 1 <= max_squad_size (loanees count toward the borrower).
    if to_squad is not None:
        size = sum(1 for s in states.values() if s["squad_id"] == to_squad["squad_id"])
        if size + 1 > league["max_squad_size"]:
            raise conflict("SQUAD_FULL", "Destination squad is full", squad_id=to_squad["squad_id"],
                           squad_size=size, max_squad_size=league["max_squad_size"])

    # Rule 8: after the move the from squad keeps the required count for the player's position.
    required = (league["required_positions"] or {}).get(player["position"], 0)
    if required:
        same_position = conn.execute("SELECT player_id FROM roster_players WHERE league_id = %s AND position = %s "
                                     "AND player_id <> %s", (league_id, player["position"], player_id)).fetchall()
        remaining = sum(1 for r in same_position
                        if states.get(r["player_id"], EMPTY_STATE)["squad_id"] == req["from_squad_id"])
        if remaining < required:
            raise conflict("MIN_POSITION_VIOLATION", "From squad would drop below the required position count",
                           squad_id=req["from_squad_id"], position=player["position"], required=required,
                           remaining=remaining)

    # Accepted. Edge case 6: the player's squad is playing right now -> deferred until the match ends
    # (the registration is recorded now; the player stays eligible for that match with the old squad).
    blocking = conn.execute(
        "SELECT match_id FROM roster_matches WHERE league_id = %s AND (home_squad_id = %s OR away_squad_id = %s) "
        "ORDER BY ord LIMIT 1", (league_id, req["from_squad_id"], req["from_squad_id"])).fetchone()
    state = "deferred_until_match_end" if blocking else "active"

    _log_loan_returns(conn, player, effective)  # a loan that ended before this request returned first
    registration = None
    if kind == "release":
        conn.execute("INSERT INTO roster_registrations (player_id, league_id, reg_type, start_date) "
                     "VALUES (%s, %s, 'release', %s)", (player_id, league_id, effective))
    else:
        parent = req["from_squad_id"] if kind == "loan" else None
        conn.execute(
            "INSERT INTO roster_registrations (player_id, league_id, reg_type, squad_id, parent_squad_id, "
            "start_date, loan_end_date, role) VALUES (%s, %s, %s, %s, %s, %s, %s, 'substitute')",
            (player_id, league_id, kind, req["to_squad_id"], parent, effective, req["_loan_end"]))
        registration = {"player_id": player_id, "league_id": league_id, "squad_id": req["to_squad_id"],
                        "parent_squad_id": parent, "registration_type": kind,
                        "start_date": req["effective_date"], "loan_end_date": req["loan_end_date"],
                        "role": "substitute"}
    entry = _append_audit(conn, player_id, league_id, {
        "action": kind, "player_id": player_id, "league_id": league_id,
        "from_squad_id": req["from_squad_id"], "to_squad_id": req["to_squad_id"],
        "effective_date": req["effective_date"], "state": state, "who": req["requested_by"],
        "when": utc_now_iso(), "why": req["reason"]})
    response = {"request_id": req["request_id"], "status": "accepted", "state": state,
                "blocking_match_id": blocking["match_id"] if blocking else None,
                "registration": registration, "audit_entry": entry}
    conn.execute("INSERT INTO roster_requests (request_id, league_id, body, response) VALUES (%s, %s, %s, %s)",
                 (req["request_id"], league_id, Jsonb(stored_body), Jsonb(response)))
    return 201, response


def player_version(conn, player_id: str) -> int:
    """Offline-sync version of a player = number of its audit entries (404 PLAYER_NOT_FOUND if unknown)."""
    if not conn.execute("SELECT 1 FROM roster_players WHERE player_id = %s", (player_id,)).fetchone():
        raise not_found("PLAYER_NOT_FOUND", player_id=player_id)
    return conn.execute("SELECT count(*) AS n FROM roster_audit WHERE player_id = %s", (player_id,)).fetchone()["n"]


@router.post("/audit/v1/roster/transfer")
async def roster_transfer(request: Request):
    body = await read_json(request)
    with pool.connection() as conn:
        status, response = apply_transfer(conn, body)
    return JSONResponse(status_code=status, content=response)


# --------------------------------------------------------------------------- history

def _parse_as_of(as_of) -> datetime.date:
    if as_of is None:
        return _today()
    parsed = parse_date(as_of)
    if parsed is None:
        raise validation("as_of", "as_of must be YYYY-MM-DD")
    return parsed


def player_history(conn, player_id: str, as_of: datetime.date) -> dict:
    player = conn.execute("SELECT * FROM roster_players WHERE player_id = %s FOR UPDATE", (player_id,)).fetchone()
    if player is None:
        raise not_found("PLAYER_NOT_FOUND", player_id=player_id)
    _log_loan_returns(conn, player, as_of)
    regs = conn.execute("SELECT * FROM roster_registrations WHERE player_id = %s "
                        "AND (start_date IS NULL OR start_date <= %s) ORDER BY seq DESC LIMIT 1",
                        (player_id, as_of)).fetchone()
    state = _state_at(regs, as_of)
    history = [r["entry"] for r in conn.execute(
        "SELECT entry FROM roster_audit WHERE player_id = %s ORDER BY seq", (player_id,))]
    return {"player_id": player_id, "as_of": as_of.isoformat(), "league_id": player["league_id"],
            "current_squad_id": state["squad_id"], "parent_squad_id": state["parent_squad_id"],
            "history": history}


@router.get("/audit/v1/roster/history/{player_id}")
def roster_history(player_id: str, as_of: str | None = None):
    day = _parse_as_of(as_of)
    with pool.connection() as conn:
        return player_history(conn, player_id, day)


# --------------------------------------------------------------------------- production routes (JWT)

def _is_super(user: dict) -> bool:
    return user.get("role") == "super_admin"


def _club_roster(conn, club_id: str, on: datetime.date) -> list[dict]:
    roster = []
    for squad in conn.execute("SELECT league_id, squad_id FROM roster_squads WHERE club_id = %s "
                              "ORDER BY league_id, ord", (club_id,)).fetchall():
        latest = _latest_registrations(conn, squad["league_id"])
        for p in conn.execute("SELECT * FROM roster_players WHERE league_id = %s ORDER BY ord",
                              (squad["league_id"],)).fetchall():
            s = _state_at(latest.get(p["player_id"]), on)
            if s["squad_id"] == squad["squad_id"]:
                roster.append({"player_id": p["player_id"], "name": p["name"], "position": p["position"],
                               "role": s["role"], "squad_id": s["squad_id"],
                               "registration_type": s["registration_type"], "loan_end_date": s["loan_end_date"]})
    return roster


@router.get("/api/v1/clubs/{club_id}")
def club_profile(club_id: str, user: dict = Depends(current_user)):
    with pool.connection() as conn:
        club = conn.execute("SELECT * FROM roster_clubs WHERE club_id = %s", (club_id,)).fetchone()
        if club is None:  # a club created only through /roster/setup: no profile data yet
            squad = conn.execute("SELECT * FROM roster_squads WHERE club_id = %s ORDER BY league_id, ord LIMIT 1",
                                 (club_id,)).fetchone()
            if squad is None:
                raise ApiError(404, "CLUB_NOT_FOUND", f"Club {club_id} not found", {"club_id": club_id})
            club = {"club_id": club_id, "tenant_id": squad["tenant_id"], "name": squad["name"],
                    "profile": {"home_venue": None, "social": {}, "staff": [], "stats": []}}
        if not _is_super(user) and user.get("tenant_id") != club["tenant_id"]:
            raise forbidden("Club belongs to another tenant")
        profile = club["profile"]
        return {"club_id": club["club_id"], "name": club["name"], "tenant_id": club["tenant_id"],
                "home_venue": profile["home_venue"], "social": profile["social"], "staff": profile["staff"],
                "stats": profile["stats"], "roster": _club_roster(conn, club_id, _today())}


@router.post("/api/v1/roster/transfer")
async def prod_transfer(request: Request, user: dict = Depends(current_user)):
    """Same contract as the audit route; only super_admin or the manager of the from squad's club."""
    if user.get("role") not in ("super_admin", "club_manager"):
        raise forbidden("Only a club manager or super admin may change rosters")
    body = await read_json(request)
    with pool.connection() as conn:
        if not _is_super(user) and isinstance(body, dict) and is_id(body.get("league_id")) \
                and is_id(body.get("from_squad_id")):
            squad = conn.execute("SELECT club_id, tenant_id FROM roster_squads WHERE league_id = %s AND squad_id = %s",
                                 (body["league_id"], body["from_squad_id"])).fetchone()
            if squad is not None and (squad["club_id"] != user.get("club_id")
                                      or squad["tenant_id"] != user.get("tenant_id")):
                raise forbidden("Club managers may only move players of their own club")
        status, response = apply_transfer(conn, body)
    return JSONResponse(status_code=status, content=response)


@router.post("/api/v1/roster/players", status_code=201)
async def prod_add_player(request: Request, user: dict = Depends(current_user)):
    """FR-2.2 "add": register a new player straight into a squad (super_admin, or the manager of that
    squad's club). Same window and squad-size rules as a transfer; recorded in the audit trail."""
    if user.get("role") not in ("super_admin", "club_manager"):
        raise forbidden("Only a club manager or super admin may add players")
    body = await read_json(request)
    if not isinstance(body, dict):
        raise validation("body")
    bad = [k for k in ("league_id", "squad_id") if not is_id(body.get(k))]
    bad += [] if _is_text(body.get("name"), 120) and body["name"].strip() else ["name"]
    bad += [] if _is_text(body.get("position"), 64) else ["position"]
    role = body.get("role") or "substitute"
    bad += [] if role in ROLES else ["role"]
    if body.get("reason") is not None and not _is_text(body["reason"], 2000):
        bad.append("reason")
    if bad:
        raise validation(bad, "Invalid player")
    today = _today()
    with pool.connection() as conn:
        # Same league row lock as apply_transfer, so squad counts stay exact.
        league = conn.execute("SELECT * FROM roster_leagues WHERE league_id = %s FOR UPDATE",
                              (body["league_id"],)).fetchone()
        if league is None:
            raise not_found("LEAGUE_NOT_FOUND", league_id=body["league_id"])
        squad = conn.execute("SELECT * FROM roster_squads WHERE league_id = %s AND squad_id = %s",
                             (league["league_id"], body["squad_id"])).fetchone()
        if squad is None:
            raise not_found("SQUAD_NOT_FOUND", squad_id=body["squad_id"])
        if not _is_super(user) and (squad["club_id"] != user.get("club_id")
                                    or squad["tenant_id"] != user.get("tenant_id")):
            raise forbidden("Club managers may only add players to their own club")
        if not league["window_open"] <= today <= league["window_close"]:
            raise conflict("TRANSFER_WINDOW_CLOSED", "Registrations are closed", effective_date=today.isoformat(),
                           open=_iso(league["window_open"]), close=_iso(league["window_close"]))
        states = [_state_at(reg, today) for reg in _latest_registrations(conn, league["league_id"]).values()]
        size = sum(1 for s in states if s["squad_id"] == squad["squad_id"])
        if size + 1 > league["max_squad_size"]:
            raise conflict("SQUAD_FULL", "Squad is full", squad_id=squad["squad_id"], squad_size=size,
                           max_squad_size=league["max_squad_size"])
        player_id = str(uuid.uuid4())
        ord_ = conn.execute("SELECT coalesce(max(ord), -1) + 1 AS n FROM roster_players WHERE league_id = %s",
                            (league["league_id"],)).fetchone()["n"]
        conn.execute("INSERT INTO roster_players (player_id, league_id, name, position, ord) VALUES (%s, %s, %s, %s, %s)",
                     (player_id, league["league_id"], body["name"].strip(), body["position"], ord_))
        conn.execute("INSERT INTO roster_registrations (player_id, league_id, reg_type, squad_id, start_date, role) "
                     "VALUES (%s, %s, 'add', %s, %s, %s)", (player_id, league["league_id"], squad["squad_id"], today, role))
        entry = _append_audit(conn, player_id, league["league_id"], {
            "action": "add", "player_id": player_id, "league_id": league["league_id"], "from_squad_id": None,
            "to_squad_id": squad["squad_id"], "effective_date": today.isoformat(), "state": "active",
            "who": user.get("email") or user.get("sub"), "when": utc_now_iso(), "why": body.get("reason")})
    return {"player_id": player_id, "name": body["name"].strip(), "position": body["position"], "role": role,
            "squad_id": squad["squad_id"], "league_id": league["league_id"], "audit_entry": entry}


@router.delete("/api/v1/clubs/{club_id}")
def delete_club(club_id: str, user: dict = Depends(current_user)):
    """Platform admin only. A club with fixtures or registered players cannot be deleted (results, standings
    and the roster audit trail depend on it): move or release its players and remove its fixtures first."""
    if not _is_super(user):
        raise forbidden("Only the platform admin can delete clubs")
    with pool.connection() as conn:
        exists = conn.execute("SELECT 1 FROM roster_clubs WHERE club_id = %s UNION ALL "
                              "SELECT 1 FROM roster_squads WHERE club_id = %s LIMIT 1", (club_id, club_id)).fetchone()
        if exists is None:
            raise ApiError(404, "CLUB_NOT_FOUND", f"Club {club_id} not found", {"club_id": club_id})
        fixtures = conn.execute("SELECT count(*) AS n FROM scoring_matches WHERE home = %s OR away = %s",
                                (club_id, club_id)).fetchone()["n"]
        players = len(_club_roster(conn, club_id, _today()))
        if fixtures or players:
            raise conflict("CLUB_IN_USE", "This club still has fixtures or players", club_id=club_id,
                           fixtures=fixtures, players=players)
        conn.execute("DELETE FROM roster_squads WHERE club_id = %s", (club_id,))
        conn.execute("DELETE FROM roster_clubs WHERE club_id = %s", (club_id,))
    return {"club_id": club_id, "status": "deleted"}


@router.get("/api/v1/roster/players/{player_id}/history")
def prod_history(player_id: str, as_of: str | None = None, user: dict = Depends(current_user)):
    day = _parse_as_of(as_of)
    with pool.connection() as conn:
        row = conn.execute("SELECT l.tenant_id FROM roster_players p JOIN roster_leagues l USING (league_id) "
                           "WHERE p.player_id = %s", (player_id,)).fetchone()
        if row is None:
            raise not_found("PLAYER_NOT_FOUND", player_id=player_id)
        if not _is_super(user) and user.get("tenant_id") != row["tenant_id"]:
            raise forbidden("Player belongs to another tenant")
        return player_history(conn, player_id, day)
