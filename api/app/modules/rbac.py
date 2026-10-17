"""Identity, five-tier RBAC and API security (spec 5.13, FR-2.1, FR-5.1, NFR-5).

* RBAC is a DATABASE POLICY MATRIX: table rbac_policies holds (role, action, scope)
  rows; every decision (probe routes and the exported can()) reads it from the DB.
  Scopes:  any          platform-wide (super admin)
           tenant       resource belongs to the caller's tenant
           own_league   the league in the caller's league_id claim
           own_club     the club in the caller's club_id claim (or a player of that club)
           self         the player in the caller's player_id claim
  Tenant isolation is absolute: every scope except `any` also requires the
  resource's tenant to equal the caller's tenant.
* Decision for an id that does not exist at all: callers holding an `any` policy
  (super admin) get 404 *_NOT_FOUND; scoped callers get 403, because a scoped
  role can never be allowed on an unknown resource and answering 404 there would
  be an existence oracle across tenants.
* Rate limiting: in-memory sliding-window log per client IP, 100 requests per
  rolling 10 s on /api/v1/*; exceed -> 429 RATE_LIMITED + Retry-After.
* Passwords are stored as PBKDF2-HMAC-SHA256 hashes, never plaintext.
"""
import collections
import hashlib
import hmac
import math
import threading
import time

from fastapi import APIRouter, Depends, Request
from starlette.concurrency import run_in_threadpool

from ..auth import create_token, current_user, forbidden, unauthenticated
from ..db import pool
from ..errors import ApiError, not_found, validation
from .util import is_id, read_json

SCHEMA = """
CREATE TABLE IF NOT EXISTS rbac_tenants (
    tenant_id       TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    logo_url        TEXT NOT NULL,
    primary_color   TEXT NOT NULL,
    secondary_color TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS rbac_leagues (
    league_id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES rbac_tenants (tenant_id),
    name      TEXT NOT NULL,
    sport_id  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS rbac_clubs (
    club_id   TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES rbac_tenants (tenant_id),
    name      TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS rbac_players (
    player_id TEXT PRIMARY KEY,
    club_id   TEXT NOT NULL REFERENCES rbac_clubs (club_id),
    name      TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS rbac_users (
    user_id       TEXT PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL,
    display_name  TEXT NOT NULL,
    tenant_id     TEXT REFERENCES rbac_tenants (tenant_id),
    league_id     TEXT REFERENCES rbac_leagues (league_id),
    club_id       TEXT REFERENCES rbac_clubs (club_id),
    player_id     TEXT REFERENCES rbac_players (player_id)
);
CREATE TABLE IF NOT EXISTS rbac_policies (
    role   TEXT NOT NULL,
    action TEXT NOT NULL,
    scope  TEXT NOT NULL,
    PRIMARY KEY (role, action, scope)
);
"""

# --------------------------------------------------------------------------- seed data

TENANTS = [
    ("tenant-alpha", "Alpha Sports", "https://placehold.co/256x256/1E40AF/FFFFFF/png?text=ALPHA",
     "#1E40AF", "#F59E0B"),
    ("tenant-beta", "Beta Athletics", "https://placehold.co/256x256/047857/FFFFFF/png?text=BETA",
     "#047857", "#DC2626"),
]
LEAGUES = [
    ("league-alpha-1", "tenant-alpha", "Alpha Premier League", "football"),
    ("league-alpha-2", "tenant-alpha", "Alpha Champions Cup", "football"),
    ("league-beta-1", "tenant-beta", "Beta Super League", "football"),
]
CLUBS = [
    ("club-alpha-1", "tenant-alpha", "Alpha United"),
    ("club-alpha-2", "tenant-alpha", "Alpha Rovers"),
    ("club-beta-1", "tenant-beta", "Beta City"),
]
PLAYERS = [
    ("player-alpha-1", "club-alpha-1", "Ali Khan"),
    ("player-alpha-2", "club-alpha-2", "Bilal Ahmed"),
    ("player-beta-1", "club-beta-1", "Omar Farooq"),
]
DEMO_PASSWORD = "Nascon@26"
# (user_id, email, role, display_name, tenant_id, league_id, club_id, player_id)
USERS = [
    ("user-admin", "admin@nascon.test", "super_admin", "Platform Admin", None, None, None, None),
    ("user-organizer", "organizer@nascon.test", "league_organizer", "League Organizer",
     "tenant-alpha", "league-alpha-1", None, None),
    ("user-manager", "manager@nascon.test", "club_manager", "Club Manager",
     "tenant-alpha", None, "club-alpha-1", None),
    ("user-player", "player@nascon.test", "player", "Ali Khan",
     "tenant-alpha", None, "club-alpha-1", "player-alpha-1"),
    ("user-viewer", "viewer@nascon.test", "viewer", "General Viewer", "tenant-alpha", None, None, None),
]

# Actions. The first seven are the spec 5.13 probes; the rest serve production routes.
TENANT_CREATE = "tenant:create"          # P1
LEAGUE_FIXTURES = "league:fixtures"      # P2
CLUB_ROSTER = "club:roster"              # P3
CLUB_PRODUCTS = "club:products"          # P4
PLAYER_UPDATE = "player:update"          # P5
CLUB_READ = "club:read"                  # P6
PLATFORM_CONFIG = "platform:config"      # P7
LEAGUE_READ = "league:read"
LEAGUE_SCORE = "league:score"
PLAYER_READ = "player:read"
ALL_ACTIONS = [TENANT_CREATE, LEAGUE_FIXTURES, CLUB_ROSTER, CLUB_PRODUCTS, PLAYER_UPDATE, CLUB_READ,
               PLATFORM_CONFIG, LEAGUE_READ, LEAGUE_SCORE, PLAYER_READ]
READS = [(CLUB_READ, "tenant"), (LEAGUE_READ, "tenant"), (PLAYER_READ, "tenant")]
POLICIES = (
    [("super_admin", action, "any") for action in ALL_ACTIONS]
    + [("league_organizer", LEAGUE_FIXTURES, "own_league"), ("league_organizer", LEAGUE_SCORE, "own_league")]
    + [("club_manager", CLUB_ROSTER, "own_club"), ("club_manager", CLUB_PRODUCTS, "own_club"),
       ("club_manager", PLAYER_UPDATE, "own_club")]
    + [("player", PLAYER_UPDATE, "self")]
    + [(role, action, scope) for role in ("league_organizer", "club_manager", "player", "viewer")
       for action, scope in READS]
)

# ------------------------------------------------------------------------ password hashing

PBKDF2_ITERATIONS = 120_000


def _pbkdf2(password: str, salt: bytes, iterations: int = PBKDF2_ITERATIONS) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)


def hash_password(password: str, user_id: str) -> str:
    """Deterministic per-user salt so every reset seeds identical rows."""
    salt = f"nascon26:{user_id}".encode("utf-8")
    return f"pbkdf2_sha256${PBKDF2_ITERATIONS}${salt.hex()}${_pbkdf2(password, salt).hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iterations, salt_hex, digest_hex = stored.split("$")
        if algo != "pbkdf2_sha256":
            return False
        candidate = _pbkdf2(password, bytes.fromhex(salt_hex), int(iterations))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(candidate.hex(), digest_hex)


_HASH_CACHE: dict[str, str] = {}


def _seed_hash(user_id: str) -> str:
    # Hashing is deliberately slow; reset runs often, so hash each seed user once per process.
    if user_id not in _HASH_CACHE:
        _HASH_CACHE[user_id] = hash_password(DEMO_PASSWORD, user_id)
    return _HASH_CACHE[user_id]


_DUMMY_HASH = hash_password("not-a-real-password", "no-such-user")

# ------------------------------------------------------------------------------- reset


def reset(conn, seed: int, body: dict) -> None:
    for table in ("rbac_policies", "rbac_users", "rbac_players", "rbac_clubs", "rbac_leagues", "rbac_tenants"):
        conn.execute(f"DELETE FROM {table}")
    with conn.cursor() as cur:
        cur.executemany("INSERT INTO rbac_tenants VALUES (%s, %s, %s, %s, %s)", TENANTS)
        cur.executemany("INSERT INTO rbac_leagues VALUES (%s, %s, %s, %s)", LEAGUES)
        cur.executemany("INSERT INTO rbac_clubs VALUES (%s, %s, %s)", CLUBS)
        cur.executemany("INSERT INTO rbac_players VALUES (%s, %s, %s)", PLAYERS)
        cur.executemany(
            "INSERT INTO rbac_users (user_id, email, password_hash, role, display_name, tenant_id,"
            " league_id, club_id, player_id) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
            [(u[0], u[1], _seed_hash(u[0]), *u[2:]) for u in USERS])
        cur.executemany("INSERT INTO rbac_policies VALUES (%s, %s, %s)", POLICIES)
    reset_rate_limits()

# ------------------------------------------------------------------------- policy engine

ALLOW, DENY, MISSING = "allow", "deny", "missing"


def _resolve(conn, resource_type: str, resource_id: str | None) -> dict | None:
    """The resource's ownership facts, or None if it does not exist.
    Resources without an id (tenant creation, platform config) resolve to {}."""
    if resource_type in ("tenant", "platform") and resource_id is None:
        return {}
    if not is_id(resource_id):
        return None
    if resource_type == "tenant":
        sql = "SELECT tenant_id FROM rbac_tenants WHERE tenant_id = %s"
    elif resource_type == "league":
        sql = "SELECT tenant_id, league_id FROM rbac_leagues WHERE league_id = %s"
    elif resource_type == "club":
        sql = "SELECT tenant_id, club_id FROM rbac_clubs WHERE club_id = %s"
    elif resource_type == "player":
        sql = ("SELECT c.tenant_id, p.club_id, p.player_id FROM rbac_players p"
               " JOIN rbac_clubs c ON c.club_id = p.club_id WHERE p.player_id = %s")
    else:
        return None
    return conn.execute(sql, (resource_id,)).fetchone()


def _scope_matches(scope: str, claims: dict, resource: dict) -> bool:
    if scope == "any":
        return True
    tenant = claims.get("tenant_id")
    if not tenant or resource.get("tenant_id") != tenant:
        return False  # absolute tenant isolation
    if scope == "tenant":
        return True
    if scope == "own_league":
        return resource.get("league_id") is not None and resource.get("league_id") == claims.get("league_id")
    if scope == "own_club":
        return resource.get("club_id") is not None and resource.get("club_id") == claims.get("club_id")
    if scope == "self":
        return resource.get("player_id") is not None and resource.get("player_id") == claims.get("player_id")
    return False


def scopes_for(conn, role: str, action: str) -> list[str]:
    rows = conn.execute("SELECT scope FROM rbac_policies WHERE role = %s AND action = %s ORDER BY scope",
                        (role, action)).fetchall()
    return [r["scope"] for r in rows]


def evaluate(conn, claims: dict, action: str, resource_type: str, resource_id: str | None) -> str:
    """ALLOW, DENY, or MISSING (resource does not exist and the caller holds an `any` policy)."""
    scopes = scopes_for(conn, claims.get("role"), action)
    if not scopes:
        return DENY
    resource = _resolve(conn, resource_type, resource_id)
    if resource is None:
        return MISSING if "any" in scopes else DENY
    return ALLOW if any(_scope_matches(s, claims, resource) for s in scopes) else DENY


def can(conn, claims: dict, action: str, resource_type: str, resource_id: str | None = None) -> bool:
    """Policy-matrix check for production routes. A platform-wide (`any`) policy allows even an
    unknown id, so the route itself can answer 404; scoped roles are never allowed on unknown ids."""
    return evaluate(conn, claims, action, resource_type, resource_id) != DENY


def require(conn, claims: dict, action: str, resource_type: str, resource_id: str | None = None) -> None:
    """Raise 403 FORBIDDEN unless can(...)."""
    if not can(conn, claims, action, resource_type, resource_id):
        raise forbidden()

# ------------------------------------------------------------------------- rate limiting

RATE_LIMIT = 100
RATE_WINDOW_SECONDS = 10.0
# The lead's middleware sets this scope key once it has counted a request, so the
# route-level dependency below does not count the same request twice.
RATE_LIMIT_SCOPE_FLAG = "nascon.rate_limit_checked"

_clock = time.monotonic
_hits: dict[str, collections.deque] = {}
_hits_lock = threading.Lock()


def check_rate_limit(client_ip: str, now: float | None = None) -> int | None:
    """Record one request from client_ip. Returns None when allowed, otherwise the
    Retry-After seconds (integer >= 1). Rejected requests are not recorded."""
    now = _clock() if now is None else now
    with _hits_lock:
        log = _hits.setdefault(client_ip, collections.deque())
        while log and log[0] <= now - RATE_WINDOW_SECONDS:
            log.popleft()
        if len(log) >= RATE_LIMIT:
            return max(1, math.ceil(log[0] + RATE_WINDOW_SECONDS - now))
        log.append(now)
        if len(_hits) > 10_000:  # keep memory bounded: forget idle clients
            for ip in [ip for ip, q in _hits.items() if not q or q[-1] <= now - RATE_WINDOW_SECONDS]:
                del _hits[ip]
        return None


def reset_rate_limits() -> None:
    with _hits_lock:
        _hits.clear()


def rate_limited_error(retry_after: int) -> ApiError:
    return ApiError(429, "RATE_LIMITED", f"Too many requests; retry in {retry_after} s",
                    {"retry_after": retry_after}, headers={"Retry-After": str(retry_after)})


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def rate_limited(request: Request) -> None:
    """FastAPI dependency applying the /api/v1 limit (no-op if a middleware already counted it)."""
    if request.scope.get(RATE_LIMIT_SCOPE_FLAG):
        return
    request.scope[RATE_LIMIT_SCOPE_FLAG] = True
    retry_after = check_rate_limit(client_ip(request))
    if retry_after is not None:
        raise rate_limited_error(retry_after)

# ------------------------------------------------------------------------------ routes

router = APIRouter()
api = APIRouter(dependencies=[Depends(rate_limited)])

USER_COLUMNS = "user_id, email, role, display_name, tenant_id, league_id, club_id, player_id"


def _claims_for(user: dict) -> dict:
    claims = {"sub": user["user_id"], "role": user["role"], "tenant_id": user["tenant_id"]}
    for key in ("league_id", "club_id", "player_id"):
        if user[key] is not None:
            claims[key] = user[key]
    return claims


def _profile(conn, user: dict) -> dict:
    tenant = None
    if user["tenant_id"]:
        tenant = conn.execute("SELECT tenant_id, name, logo_url, primary_color, secondary_color"
                              " FROM rbac_tenants WHERE tenant_id = %s", (user["tenant_id"],)).fetchone()
    return {"user": {k: user[k] for k in USER_COLUMNS.split(", ")}, "tenant": tenant}


@router.post("/audit/v1/rbac-matrix")
def rbac_matrix():
    with pool.connection() as conn:
        users = conn.execute(f"SELECT {USER_COLUMNS} FROM rbac_users").fetchall()
    tokens = {u["role"]: create_token(_claims_for(u)) for u in users}
    return {
        "tokens": {role: tokens[role] for role in
                   ("super_admin", "league_organizer", "club_manager", "player", "viewer")},
        "context": {
            "tenant_id": "tenant-alpha", "foreign_tenant_id": "tenant-beta",
            "own_league_id": "league-alpha-1", "other_league_id": "league-alpha-2",
            "foreign_league_id": "league-beta-1",
            "own_club_id": "club-alpha-1", "other_club_id": "club-alpha-2", "foreign_club_id": "club-beta-1",
            "own_player_id": "player-alpha-1", "other_player_id": "player-alpha-2",
            "foreign_player_id": "player-beta-1",
        },
    }


NOT_FOUND_CODES = {"league": ("LEAGUE_NOT_FOUND", "league_id"), "club": ("CLUB_NOT_FOUND", "club_id"),
                   "player": ("PLAYER_NOT_FOUND", "player_id")}


def _probe(claims: dict, action: str, resource_type: str, resource_id: str | None = None) -> dict:
    """Authorize only: no body is read, nothing is mutated."""
    with pool.connection() as conn:
        decision = evaluate(conn, claims, action, resource_type, resource_id)
    if decision == ALLOW:
        return {"authorized": True}
    if decision == MISSING:
        code, key = NOT_FOUND_CODES[resource_type]
        raise not_found(code, **{key: resource_id})
    raise forbidden(f"Role {claims.get('role')} may not perform {action}")


@router.post("/audit/v1/rbac/tenants")
def probe_create_tenant(claims: dict = Depends(current_user)):
    return _probe(claims, TENANT_CREATE, "tenant")


@router.post("/audit/v1/rbac/leagues/{league_id}/fixtures")
def probe_league_fixtures(league_id: str, claims: dict = Depends(current_user)):
    return _probe(claims, LEAGUE_FIXTURES, "league", league_id)


@router.post("/audit/v1/rbac/clubs/{club_id}/roster")
def probe_club_roster(club_id: str, claims: dict = Depends(current_user)):
    return _probe(claims, CLUB_ROSTER, "club", club_id)


@router.post("/audit/v1/rbac/clubs/{club_id}/products")
def probe_club_products(club_id: str, claims: dict = Depends(current_user)):
    return _probe(claims, CLUB_PRODUCTS, "club", club_id)


@router.patch("/audit/v1/rbac/players/{player_id}")
def probe_player_update(player_id: str, claims: dict = Depends(current_user)):
    return _probe(claims, PLAYER_UPDATE, "player", player_id)


@router.get("/audit/v1/rbac/clubs/{club_id}")
def probe_club_read(club_id: str, claims: dict = Depends(current_user)):
    return _probe(claims, CLUB_READ, "club", club_id)


@router.get("/audit/v1/rbac/platform/config")
def probe_platform_config(claims: dict = Depends(current_user)):
    return _probe(claims, PLATFORM_CONFIG, "platform")


@api.get("/api/v1/ping")
def ping():
    return {"pong": True}


def _login(email: str, password: str) -> dict:
    with pool.connection() as conn:
        user = conn.execute(f"SELECT {USER_COLUMNS}, password_hash FROM rbac_users WHERE email = %s",
                            (email.strip().lower(),)).fetchone()
        # Hash even for unknown emails so response time does not reveal which emails exist.
        ok = verify_password(password, user["password_hash"] if user else _DUMMY_HASH)
        if not user or not ok:
            raise unauthenticated("Invalid email or password")
        return {"token": create_token(_claims_for(user)), **_profile(conn, user)}


@api.post("/api/v1/auth/login")
async def login(request: Request):
    body = await read_json(request)
    if not isinstance(body, dict):
        raise validation("body")
    bad = [f for f in ("email", "password")
           if not isinstance(body.get(f), str) or not body[f].strip() or len(body[f]) > 256
           or "\x00" in body[f]]  # PostgreSQL text cannot hold NUL: reject instead of a 5xx
    if bad:
        raise validation(bad)
    return await run_in_threadpool(_login, body["email"], body["password"])


def _user_of(conn, claims: dict) -> dict:
    user = conn.execute(f"SELECT {USER_COLUMNS} FROM rbac_users WHERE user_id = %s",
                        (str(claims.get("sub")),)).fetchone()
    if not user:
        raise unauthenticated("User no longer exists")
    return user


@api.get("/api/v1/me")
def me(claims: dict = Depends(current_user)):
    with pool.connection() as conn:
        return _profile(conn, _user_of(conn, claims))


@api.get("/api/v1/leagues")
def list_leagues(claims: dict = Depends(current_user)):
    with pool.connection() as conn:
        _user_of(conn, claims)
        rows = conn.execute("SELECT league_id, name, tenant_id, sport_id FROM rbac_leagues"
                            " ORDER BY league_id").fetchall()
        # Visibility is decided by the policy matrix, league by league.
        resources = [{"tenant_id": r["tenant_id"], "league_id": r["league_id"]} for r in rows]
        scopes = scopes_for(conn, claims.get("role"), LEAGUE_READ)
    return [r for r, res in zip(rows, resources) if any(_scope_matches(s, claims, res) for s in scopes)]


router.include_router(api)
