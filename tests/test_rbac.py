"""RBAC, probe routes, login/me/leagues and rate limiting (spec 5.13, 8.3, FR-5.1, NFR-5).

Negative authorization tests cover every role boundary of the expected matrix."""
import base64
import json

import pytest

from app import auth
from app.modules import rbac

ROLES = ["super_admin", "league_organizer", "club_manager", "player", "viewer"]
A, D = 200, 403

# (method, path template, target) -> expected status per role, in ROLES order (spec 5.13 matrix).
MATRIX = [
    ("POST", "/audit/v1/rbac/tenants", None, [A, D, D, D, D]),
    ("POST", "/audit/v1/rbac/leagues/{}/fixtures", "own_league_id", [A, A, D, D, D]),
    ("POST", "/audit/v1/rbac/leagues/{}/fixtures", "other_league_id", [A, D, D, D, D]),
    ("POST", "/audit/v1/rbac/leagues/{}/fixtures", "foreign_league_id", [A, D, D, D, D]),
    ("POST", "/audit/v1/rbac/clubs/{}/roster", "own_club_id", [A, D, A, D, D]),
    ("POST", "/audit/v1/rbac/clubs/{}/roster", "other_club_id", [A, D, D, D, D]),
    ("POST", "/audit/v1/rbac/clubs/{}/roster", "foreign_club_id", [A, D, D, D, D]),
    ("POST", "/audit/v1/rbac/clubs/{}/products", "own_club_id", [A, D, A, D, D]),
    ("POST", "/audit/v1/rbac/clubs/{}/products", "other_club_id", [A, D, D, D, D]),
    ("POST", "/audit/v1/rbac/clubs/{}/products", "foreign_club_id", [A, D, D, D, D]),
    ("PATCH", "/audit/v1/rbac/players/{}", "own_player_id", [A, D, A, A, D]),
    ("PATCH", "/audit/v1/rbac/players/{}", "other_player_id", [A, D, D, D, D]),
    ("PATCH", "/audit/v1/rbac/players/{}", "foreign_player_id", [A, D, D, D, D]),
    ("GET", "/audit/v1/rbac/clubs/{}", "own_club_id", [A, A, A, A, A]),
    ("GET", "/audit/v1/rbac/clubs/{}", "other_club_id", [A, A, A, A, A]),
    ("GET", "/audit/v1/rbac/clubs/{}", "foreign_club_id", [A, D, D, D, D]),
    ("GET", "/audit/v1/rbac/platform/config", None, [A, D, D, D, D]),
]
CASES = [(m, p, t, role, exp[i]) for m, p, t, exp in MATRIX for i, role in enumerate(ROLES)]

ACCOUNTS = {
    "super_admin": "admin@nascon.test", "league_organizer": "organizer@nascon.test",
    "club_manager": "manager@nascon.test", "player": "player@nascon.test", "viewer": "viewer@nascon.test",
}


@pytest.fixture(scope="module")
def matrix(api):
    api.reset()
    r = api.post("/audit/v1/rbac-matrix")
    assert r.status_code == 200, r.text
    return r.json()


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def b64url(obj) -> str:
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()


@pytest.fixture(autouse=True)
def _fresh_limits():
    rbac.reset_rate_limits()
    yield
    rbac.reset_rate_limits()


# ------------------------------------------------------------------------ rbac-matrix

def test_matrix_shape(matrix):
    assert set(matrix) == {"tokens", "context"}
    assert list(matrix["tokens"]) == ROLES
    assert all(isinstance(t, str) and t.count(".") == 2 for t in matrix["tokens"].values())
    assert matrix["context"] == {
        "tenant_id": "tenant-alpha", "foreign_tenant_id": "tenant-beta",
        "own_league_id": "league-alpha-1", "other_league_id": "league-alpha-2",
        "foreign_league_id": "league-beta-1",
        "own_club_id": "club-alpha-1", "other_club_id": "club-alpha-2", "foreign_club_id": "club-beta-1",
        "own_player_id": "player-alpha-1", "other_player_id": "player-alpha-2",
        "foreign_player_id": "player-beta-1",
    }


def test_matrix_tokens_claims_and_lifetime(matrix):
    claims = {role: auth.decode_token(t) for role, t in matrix["tokens"].items()}
    assert claims["super_admin"]["tenant_id"] is None
    for role in ROLES[1:]:
        assert claims[role]["tenant_id"] == "tenant-alpha"
        assert claims[role]["role"] == role
    assert claims["league_organizer"]["league_id"] == "league-alpha-1"
    assert claims["club_manager"]["club_id"] == "club-alpha-1"
    assert claims["player"]["player_id"] == "player-alpha-1"
    for c in claims.values():
        assert c["exp"] - c["iat"] >= 3600


def test_matrix_with_body_and_auth_header_still_200(api):
    r = api.post("/audit/v1/rbac-matrix", json={"x": 1}, headers={"Authorization": "Bearer junk"})
    assert r.status_code == 200


# ---------------------------------------------------------------------------- probes

@pytest.mark.parametrize("method,path,target,role,expected", CASES,
                         ids=[f"{m}-{p}-{t}-{r}" for m, p, t, r, _ in CASES])
def test_probe_matrix(api, matrix, method, path, target, role, expected):
    url = path.format(matrix["context"][target]) if target else path
    kwargs = {"json": {}} if method in ("POST", "PATCH") else {}
    r = api.request(method, url, headers=bearer(matrix["tokens"][role]), **kwargs)
    assert r.status_code == expected, (role, url, r.text)
    if expected == 200:
        assert r.json() == {"authorized": True}
    else:
        body = r.json()
        assert body["error"]["code"] == "FORBIDDEN"
        assert isinstance(body["error"]["details"], dict)


def test_probe_ignores_body_and_does_not_mutate(api, matrix):
    tok = matrix["tokens"]["super_admin"]
    r = api.post("/audit/v1/rbac/tenants", data="{not json", headers={**bearer(tok),
                                                                      "Content-Type": "application/json"})
    assert r.status_code == 200
    r = api.patch("/audit/v1/rbac/players/player-alpha-1", json={"name": 5}, headers=bearer(tok))
    assert r.status_code == 200
    r = api.post("/audit/v1/rbac/tenants", headers=bearer(tok))  # no body at all
    assert r.status_code == 200
    assert api.post("/audit/v1/rbac-matrix").json()["context"]["own_player_id"] == "player-alpha-1"


def test_denied_role_with_malformed_body_is_403_not_400(api, matrix):
    r = api.post("/audit/v1/rbac/tenants", data="{bad", headers={**bearer(matrix["tokens"]["viewer"]),
                                                                  "Content-Type": "application/json"})
    assert r.status_code == 403


@pytest.mark.parametrize("path,code", [
    ("/audit/v1/rbac/leagues/no-such-league/fixtures", "LEAGUE_NOT_FOUND"),
    ("/audit/v1/rbac/clubs/no-such-club/roster", "CLUB_NOT_FOUND"),
    ("/audit/v1/rbac/clubs/no-such-club/products", "CLUB_NOT_FOUND"),
    ("/audit/v1/rbac/players/no-such-player", "PLAYER_NOT_FOUND"),
    ("/audit/v1/rbac/clubs/no-such-club", "CLUB_NOT_FOUND"),
])
def test_nonexistent_ids(api, matrix, path, code):
    method = "PATCH" if "/players/" in path else ("GET" if path.endswith("no-such-club") else "POST")
    r = api.request(method, path, headers=bearer(matrix["tokens"]["super_admin"]), json={})
    assert r.status_code == 404
    assert r.json()["error"]["code"] == code
    # Scoped roles never learn whether an id exists: 403.
    for role in ROLES[1:]:
        r = api.request(method, path, headers=bearer(matrix["tokens"][role]), json={})
        assert r.status_code == 403, (role, path)


@pytest.mark.parametrize("bad_id", ["x'; DROP TABLE rbac_users;--", "<script>alert(1)</script>",
                                    "a" * 300, "%00", "..", "club alpha 1", "éé"])
def test_injection_like_ids_never_5xx(api, matrix, bad_id):
    for role in ("super_admin", "viewer"):
        r = api.get(f"/audit/v1/rbac/clubs/{bad_id}", headers=bearer(matrix["tokens"][role]))
        assert r.status_code in (403, 404), r.text
    r = api.get("/audit/v1/rbac/clubs/club-alpha-1", headers=bearer(matrix["tokens"]["viewer"]))
    assert r.status_code == 200


# ----------------------------------------------------------------------- 401 paths

def _tampered(token: str) -> str:
    head, payload, sig = token.split(".")
    return f"{head}.{payload}.{sig[:-2]}{'AA' if sig[-2:] != 'AA' else 'BB'}"


def _alg_none(token: str) -> str:
    claims = auth.decode_token(token)
    return f"{b64url({'alg': 'none', 'typ': 'JWT'})}.{b64url(claims)}."


def _payload_swap(token: str) -> str:
    head, _, sig = token.split(".")
    claims = auth.decode_token(token)
    claims["role"] = "super_admin"
    return f"{head}.{b64url(claims)}.{sig}"


@pytest.mark.parametrize("make_headers", [
    lambda t: {},
    lambda t: {"Authorization": ""},
    lambda t: {"Authorization": "Bearer"},
    lambda t: {"Authorization": "Bearer   "},
    lambda t: {"Authorization": f"Basic {t['super_admin']}"},
    lambda t: {"Authorization": t["super_admin"]},
    lambda t: {"Authorization": "Bearer garbage.token.value"},
    lambda t: {"Authorization": "Bearer not-even-a-jwt"},
    lambda t: bearer(_tampered(t["super_admin"])),
    lambda t: bearer(_alg_none(t["super_admin"])),
    lambda t: bearer(_payload_swap(t["viewer"])),
    lambda t: bearer(auth.create_token({"sub": "user-admin", "role": "super_admin", "tenant_id": None}, hours=-1)),
    lambda t: bearer(auth.create_token({"sub": "user-admin", "role": "root", "tenant_id": None})),
], ids=["missing", "empty", "bearer-only", "bearer-blank", "basic-scheme", "no-scheme", "garbage", "not-jwt",
        "tampered", "alg-none", "payload-swap", "expired", "unknown-role"])
@pytest.mark.parametrize("method,path", [("GET", "/audit/v1/rbac/platform/config"),
                                         ("POST", "/audit/v1/rbac/tenants"),
                                         ("PATCH", "/audit/v1/rbac/players/player-beta-1")])
def test_invalid_tokens_are_401(api, matrix, make_headers, method, path):
    r = api.request(method, path, headers=make_headers(matrix["tokens"]), json={})
    assert r.status_code == 401, r.text
    assert r.json()["error"]["code"] == "UNAUTHENTICATED"


def test_tokens_survive_reset(api, matrix):
    api.reset()
    r = api.get("/audit/v1/rbac/clubs/club-alpha-2", headers=bearer(matrix["tokens"]["player"]))
    assert r.status_code == 200


# --------------------------------------------------------------------------- login

@pytest.mark.parametrize("role,email", list(ACCOUNTS.items()))
def test_login_each_demo_account(api, role, email):
    api.reset()
    r = api.post("/api/v1/auth/login", json={"email": email, "password": "Nascon@26"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert set(body) == {"token", "user", "tenant"}
    user = body["user"]
    assert set(user) == {"user_id", "email", "role", "display_name", "tenant_id", "league_id", "club_id",
                         "player_id"}
    assert user["role"] == role and user["email"] == email
    claims = auth.decode_token(body["token"])
    assert claims["role"] == role and claims["sub"] == user["user_id"]
    if role == "super_admin":
        assert body["tenant"] is None and user["tenant_id"] is None
    else:
        assert body["tenant"]["tenant_id"] == "tenant-alpha"
        assert body["tenant"]["name"] == "Alpha Sports"
        assert set(body["tenant"]) == {"tenant_id", "name", "logo_url", "primary_color", "secondary_color"}
        assert body["tenant"]["primary_color"].startswith("#")


def test_login_token_works_on_probes(api):
    api.reset()
    tok = api.post("/api/v1/auth/login", json={"email": "manager@nascon.test",
                                               "password": "Nascon@26"}).json()["token"]
    assert api.post("/audit/v1/rbac/clubs/club-alpha-1/roster", headers=bearer(tok)).status_code == 200
    assert api.post("/audit/v1/rbac/clubs/club-alpha-2/roster", headers=bearer(tok)).status_code == 403


def test_login_email_case_insensitive(api):
    api.reset()
    r = api.post("/api/v1/auth/login", json={"email": " Viewer@NASCON.test ", "password": "Nascon@26"})
    assert r.status_code == 200
    assert r.json()["user"]["role"] == "viewer"


@pytest.mark.parametrize("body", [
    {"email": "admin@nascon.test", "password": "wrong"},
    {"email": "admin@nascon.test", "password": "nascon@26"},
    {"email": "nobody@nascon.test", "password": "Nascon@26"},
    {"email": "x' OR '1'='1", "password": "x' OR '1'='1"},
])
def test_login_wrong_credentials_401(api, body):
    api.reset()
    r = api.post("/api/v1/auth/login", json=body)
    assert r.status_code == 401
    assert r.json()["error"] == {"code": "UNAUTHENTICATED", "message": "Invalid email or password",
                                 "details": {}}


@pytest.mark.parametrize("body,fields", [
    ({}, ["email", "password"]),
    ({"email": "admin@nascon.test"}, ["password"]),
    ({"password": "Nascon@26"}, ["email"]),
    ({"email": 5, "password": True}, ["email", "password"]),
    ({"email": "", "password": "Nascon@26"}, ["email"]),
    ({"email": "a\x00b@nascon.test", "password": "Nascon@26"}, ["email"]),
    ({"email": "admin@nascon.test", "password": "p" * 300}, ["password"]),
])
def test_login_invalid_body_400(api, body, fields):
    r = api.post("/api/v1/auth/login", json=body)
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"
    assert r.json()["error"]["details"]["fields"] == fields


@pytest.mark.parametrize("raw", ["{bad json", "[1, 2]", "\"str\"", ""])
def test_login_malformed_400(api, raw):
    r = api.post("/api/v1/auth/login", data=raw, headers={"Content-Type": "application/json"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"


@pytest.mark.in_process
def test_password_hashes_not_plaintext():
    from app.db import pool
    with pool.connection() as conn:
        rows = conn.execute("SELECT user_id, password_hash FROM rbac_users").fetchall()
    assert len(rows) == 5
    for row in rows:
        assert "Nascon@26" not in row["password_hash"]
        assert row["password_hash"].startswith("pbkdf2_sha256$")
        assert rbac.verify_password("Nascon@26", row["password_hash"])
    assert not rbac.verify_password("Nascon@26", "md5$1$00$00")
    assert not rbac.verify_password("Nascon@26", "garbage")


# ------------------------------------------------------------------------ me / leagues

def test_me(api, matrix):
    api.reset()
    r = api.get("/api/v1/me", headers=bearer(matrix["tokens"]["player"]))
    assert r.status_code == 200
    body = r.json()
    assert body["user"] == {"user_id": "user-player", "email": "player@nascon.test", "role": "player",
                            "display_name": body["user"]["display_name"], "tenant_id": "tenant-alpha",
                            "league_id": None, "club_id": "club-alpha-1", "player_id": "player-alpha-1"}
    assert body["tenant"]["tenant_id"] == "tenant-alpha"
    admin = api.get("/api/v1/me", headers=bearer(matrix["tokens"]["super_admin"])).json()
    assert admin["tenant"] is None and admin["user"]["role"] == "super_admin"


def test_me_requires_token_and_existing_user(api):
    assert api.get("/api/v1/me").status_code == 401
    ghost = auth.create_token({"sub": "user-ghost", "role": "viewer", "tenant_id": "tenant-alpha"})
    r = api.get("/api/v1/me", headers=bearer(ghost))
    assert r.status_code == 401 and r.json()["error"]["code"] == "UNAUTHENTICATED"
    assert api.get("/api/v1/leagues", headers=bearer(ghost)).status_code == 401


def test_leagues_visibility(api, matrix):
    api.reset()
    r = api.get("/api/v1/leagues", headers=bearer(matrix["tokens"]["viewer"]))
    assert r.status_code == 200
    leagues = r.json()
    assert [lg["league_id"] for lg in leagues] == ["league-alpha-1", "league-alpha-2"]
    assert set(leagues[0]) == {"league_id", "name", "tenant_id", "sport_id"}
    assert all(lg["tenant_id"] == "tenant-alpha" and lg["sport_id"] == "football" for lg in leagues)
    all_ids = [lg["league_id"] for lg in
               api.get("/api/v1/leagues", headers=bearer(matrix["tokens"]["super_admin"])).json()]
    assert all_ids == ["league-alpha-1", "league-alpha-2", "league-beta-1"]
    assert api.get("/api/v1/leagues").status_code == 401


# --------------------------------------------------------------------- can() helper

@pytest.mark.in_process
def test_can_helper_for_other_modules(matrix):
    from app.db import pool
    t = {role: auth.decode_token(tok) for role, tok in matrix["tokens"].items()}
    with pool.connection() as conn:
        assert rbac.can(conn, t["league_organizer"], rbac.LEAGUE_SCORE, "league", "league-alpha-1")
        assert not rbac.can(conn, t["league_organizer"], rbac.LEAGUE_SCORE, "league", "league-beta-1")
        assert rbac.can(conn, t["viewer"], rbac.PLAYER_READ, "player", "player-alpha-2")
        assert not rbac.can(conn, t["viewer"], rbac.PLAYER_READ, "player", "player-beta-1")
        assert rbac.can(conn, t["viewer"], rbac.LEAGUE_READ, "tenant", "tenant-alpha") is True
        assert not rbac.can(conn, t["viewer"], rbac.LEAGUE_READ, "tenant", "tenant-beta")
        # super admin: allowed even on unknown ids (route answers 404 itself)
        assert rbac.can(conn, t["super_admin"], rbac.CLUB_ROSTER, "club", "nope")
        assert not rbac.can(conn, t["club_manager"], rbac.CLUB_ROSTER, "club", "nope")
        assert not rbac.can(conn, t["club_manager"], rbac.CLUB_ROSTER, "spaceship", "club-alpha-1")
        assert not rbac.can(conn, t["club_manager"], "unknown:action", "club", "club-alpha-1")
        assert not rbac.can(conn, {"role": "viewer"}, rbac.CLUB_READ, "club", "club-alpha-1")  # no tenant
        assert not rbac.can(conn, {**t["viewer"], "tenant_id": "tenant-alpha"}, rbac.CLUB_READ, "club", None)
        rbac.require(conn, t["club_manager"], rbac.CLUB_PRODUCTS, "club", "club-alpha-1")
        with pytest.raises(Exception) as exc:
            rbac.require(conn, t["player"], rbac.CLUB_PRODUCTS, "club", "club-alpha-1")
        assert exc.value.status == 403 and exc.value.code == "FORBIDDEN"


def test_unknown_scope_never_matches():
    assert not rbac._scope_matches("galaxy", {"tenant_id": "t"}, {"tenant_id": "t"})


@pytest.mark.in_process
def test_policy_matrix_lives_in_db(api, matrix):
    """Changing a policy row changes the decision: the matrix is data, not code."""
    from app.db import pool
    api.reset()
    tok = matrix["tokens"]["viewer"]
    assert api.get("/audit/v1/rbac/clubs/club-alpha-1", headers=bearer(tok)).status_code == 200
    with pool.connection() as conn:
        conn.execute("DELETE FROM rbac_policies WHERE role = 'viewer' AND action = %s", (rbac.CLUB_READ,))
    assert api.get("/audit/v1/rbac/clubs/club-alpha-1", headers=bearer(tok)).status_code == 403
    api.reset()
    assert api.get("/audit/v1/rbac/clubs/club-alpha-1", headers=bearer(tok)).status_code == 200


@pytest.mark.in_process
def test_reset_is_repeatable(api):
    from app.db import pool

    def snapshot():
        with pool.connection() as conn:
            return [conn.execute(f"SELECT * FROM {t} ORDER BY 1, 2").fetchall()
                    for t in ("rbac_tenants", "rbac_leagues", "rbac_clubs", "rbac_players", "rbac_users",
                              "rbac_policies")]
    api.reset()
    first = snapshot()
    api.reset()
    assert snapshot() == first


# --------------------------------------------------------------------- rate limiting

def test_ping(api):
    r = api.get("/api/v1/ping")
    assert r.status_code == 200 and r.json() == {"pong": True}


def test_check_rate_limit_sliding_window():
    ip = "203.0.113.7"
    for i in range(100):
        assert rbac.check_rate_limit(ip, now=1000.0 + i * 0.01) is None
    retry = rbac.check_rate_limit(ip, now=1001.0)
    assert retry == 9  # oldest hit at 1000.0 leaves the window at 1010.0
    assert rbac.check_rate_limit("198.51.100.1", now=1001.0) is None  # per IP
    assert rbac.check_rate_limit(ip, now=1009.5) == 1
    assert rbac.check_rate_limit(ip, now=1010.0) is None  # first hit expired -> room for one
    assert rbac.check_rate_limit(ip, now=1010.0) is not None
    assert rbac.check_rate_limit(ip, now=1021.0) is None  # all expired


def test_rate_limit_spec_probe_simulated():
    """150 requests within 5 s: first allowed, >= 40 limited with Retry-After, 11 s later allowed."""
    ip = "192.0.2.10"
    results = [rbac.check_rate_limit(ip, now=50.0 + i * (5.0 / 150)) for i in range(150)]
    assert results[0] is None
    limited = [r for r in results if r is not None]
    assert len(limited) == 50 and all(isinstance(r, int) and 1 <= r <= 10 for r in limited)
    assert rbac.check_rate_limit(ip, now=55.0 + 11) is None


def test_rate_limit_memory_pruned():
    for i in range(10_001):
        rbac.check_rate_limit(f"10.0.{i // 256}.{i % 256}", now=1.0)
    rbac.check_rate_limit("10.99.99.99", now=100.0)
    assert len(rbac._hits) == 1


def test_rate_limit_over_http(api):
    statuses = []
    for _ in range(150):
        r = api.get("/api/v1/ping")
        statuses.append(r.status_code)
        if r.status_code == 429:
            last = r
    assert statuses[0] == 200
    assert statuses.count(429) >= 40
    assert last.json()["error"]["code"] == "RATE_LIMITED"
    assert int(last.headers["Retry-After"]) >= 1
    # Login and me are limited too; audit routes and /health are exempt.
    assert api.post("/api/v1/auth/login", json={}).status_code == 429
    assert api.get("/health").status_code == 200
    assert api.post("/audit/v1/rbac-matrix").status_code == 200


@pytest.mark.in_process
def test_rate_limit_uses_injected_clock(api, monkeypatch):
    clock = [5000.0]
    monkeypatch.setattr(rbac, "_clock", lambda: clock[0])
    for _ in range(100):
        assert api.get("/api/v1/ping").status_code == 200
    assert api.get("/api/v1/ping").status_code == 429
    clock[0] += 11
    assert api.get("/api/v1/ping").status_code == 200


def test_middleware_flag_skips_double_count():
    class Req:
        scope = {rbac.RATE_LIMIT_SCOPE_FLAG: True}
        client = None
    for _ in range(200):
        rbac.rate_limited(Req())
    assert rbac._hits == {}
    assert rbac.client_ip(Req()) == "unknown"
