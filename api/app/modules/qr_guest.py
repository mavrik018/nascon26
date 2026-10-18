"""Part II: dynamic QR deep links (5.6, FR-4.1, NFR-9) and guest cart merge (5.7, FR-4.4, Edge case 4).

QR: the short_url of an entity never changes; target_route, entity_status and signature are computed
on every request from the live event log, so a printed poster follows the match (Edge case 2).
Scan telemetry keeps only (entity_id, device family, UTC minute bucket): no IP, user agent or cookies.

Cart merge: guest_token and user are locked with transaction advisory locks, so simultaneous identical
retries serialise; the first merges, the rest replay the stored response (never double-add).
Merging fills a cart only; inventory is neither reserved nor decremented.
"""
import io

import segno
from fastapi import APIRouter, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import RedirectResponse, Response
from fpdf import FPDF
from psycopg.types.json import Jsonb

from ..db import pool
from ..errors import conflict, not_found, validation
from ..signing import canonical, sign_day2
from . import day2, scoring
from .store import PRICE_SQL
from .util import is_int, read_json

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS qr_codes (
    entity_id   TEXT PRIMARY KEY,
    entity_type TEXT NOT NULL CHECK (entity_type IN ('match', 'player', 'club', 'costream')),
    short_code  TEXT NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS qr_scans (
    id            BIGSERIAL PRIMARY KEY,
    entity_id     TEXT NOT NULL,
    device_family TEXT NOT NULL CHECK (device_family IN ('mobile', 'desktop')),
    bucket        TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS qr_scans_entity ON qr_scans (entity_id);
CREATE TABLE IF NOT EXISTS member_carts (
    user_id    TEXT NOT NULL,
    variant_id TEXT NOT NULL,
    quantity   INTEGER NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (user_id, variant_id)
);
CREATE TABLE IF NOT EXISTS guest_merges (
    guest_token        TEXT PRIMARY KEY,
    registered_user_id TEXT NOT NULL,
    request            JSONB NOT NULL,
    response           JSONB NOT NULL
);
"""

BASE_URL = "http://localhost:8080"
SEED_QR = [("match-m1", "match", "m1-live"), ("player-alpha-1", "player", "p-alpha-1"),
           ("club-alpha-1", "club", "c-alpha-1")]
PREFIXES = [("match-", "match"), ("player-", "player"), ("club-", "club"), ("cs-session-", "costream")]
EXPORT_TYPES = {"svg": "image/svg+xml", "png": "image/png", "pdf": "application/pdf"}
MOBILE_MARKERS = ("mobi", "android", "iphone", "ipad")


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM qr_scans")
    conn.execute("DELETE FROM qr_codes")
    for entity_id, entity_type, code in SEED_QR:
        conn.execute("INSERT INTO qr_codes (entity_id, entity_type, short_code) VALUES (%s, %s, %s)",
                     (entity_id, entity_type, code))
    conn.execute("DELETE FROM member_carts")
    conn.execute("DELETE FROM guest_merges")


# --------------------------------------------------------------------------- QR resolution

def _entity_type(entity_id: str):
    return next((t for prefix, t in PREFIXES if entity_id.startswith(prefix)), None)


def _costream_status(conn, session_id: str):
    """The co-stream table belongs to another module; tolerate it being absent or shaped differently."""
    if conn.execute("SELECT to_regclass('costream_sessions') AS t").fetchone()["t"] is None:
        return None
    try:
        with conn.transaction():  # savepoint: a column mismatch must not poison the outer transaction
            row = conn.execute("SELECT * FROM costream_sessions WHERE session_id = %s", (session_id,)).fetchone()
    except Exception:
        return None
    return None if row is None else (row.get("status") or "active")


def _entity_exists(conn, entity_id: str, entity_type: str) -> bool:
    if entity_type == "match":
        return scoring.load_match(conn, entity_id) is not None
    if entity_type == "player":
        return day2.player_exists(conn, entity_id)
    if entity_type == "club":
        return conn.execute("SELECT 1 FROM roster_clubs WHERE club_id = %(c)s UNION ALL "
                            "SELECT 1 FROM roster_squads WHERE club_id = %(c)s LIMIT 1",
                            {"c": entity_id}).fetchone() is not None
    return _costream_status(conn, entity_id) is not None


def _mapping(conn, entity_id: str) -> dict:
    """The QR mapping for entity_id, created on first use for an existing match/player/club/co-stream."""
    row = conn.execute("SELECT * FROM qr_codes WHERE entity_id = %s", (entity_id,)).fetchone()
    if row:
        return row
    entity_type = _entity_type(entity_id)
    if entity_type and _entity_exists(conn, entity_id, entity_type):
        conn.execute("INSERT INTO qr_codes (entity_id, entity_type, short_code) VALUES (%s, %s, %s) "
                     "ON CONFLICT DO NOTHING", (entity_id, entity_type, entity_id))
        row = conn.execute("SELECT * FROM qr_codes WHERE entity_id = %s", (entity_id,)).fetchone()
        if row:
            return row
    raise not_found("QR_NOT_FOUND", entity_id=entity_id)


def _live(conn, qr: dict) -> tuple[str, str]:
    """(entity_status, target_route), computed now from the database."""
    entity_id, entity_type = qr["entity_id"], qr["entity_type"]
    if entity_type == "match":
        match = scoring.load_match(conn, entity_id)
        if match is None:
            raise not_found("QR_NOT_FOUND", entity_id=entity_id)
        status = scoring.project_state(match, scoring.match_sport(conn, match),
                                       scoring.load_events(conn, entity_id))["status"]
        page = {"upcoming": "preview", "in_progress": "live", "completed": "vod"}.get(status)
        return status, (f"/web/matches/{entity_id}/{page}" if page
                        else f"/web/matches/{entity_id}/notice?state={status}")
    if entity_type == "player":
        return "active", f"/web/players/{entity_id}"
    if entity_type == "club":
        return "active", f"/web/clubs/{entity_id}"
    return _costream_status(conn, entity_id) or "active", f"/web/costream/{entity_id}"


def _record_scan(conn, entity_id: str, request: Request) -> None:
    ua = request.headers.get("user-agent", "").lower()  # read once for the family, never stored
    family = "mobile" if any(m in ua for m in MOBILE_MARKERS) else "desktop"
    conn.execute("INSERT INTO qr_scans (entity_id, device_family, bucket) "
                 "VALUES (%s, %s, date_trunc('minute', now()))", (entity_id, family))


def short_url(qr: dict) -> str:
    return f"{BASE_URL}/q/{qr['short_code']}"


@router.get("/audit/v1/qr/{entity_id}")
def resolve_qr(entity_id: str, request: Request, inspect: bool = False):
    with pool.connection() as conn:
        qr = _mapping(conn, entity_id)
        status, route = _live(conn, qr)
        if not inspect:
            _record_scan(conn, entity_id, request)
        scans = conn.execute("SELECT count(*) AS n FROM qr_scans WHERE entity_id = %s", (entity_id,)).fetchone()["n"]
    url = short_url(qr)
    return {
        "entity_id": entity_id, "entity_type": qr["entity_type"], "entity_status": status,
        "short_url": url, "target_route": route, "deep_link_uri": f"nascon://entity/{entity_id}",
        "scan_count": scans,
        "export_formats": {f: f"{BASE_URL}/audit/v1/qr/{entity_id}/export.{f}" for f in EXPORT_TYPES},
        "signature": sign_day2(entity_id, {"entity_id": entity_id, "short_url": url, "target_route": route}),
    }


def _pdf(png: bytes, entity_id: str, url: str) -> bytes:
    pdf = FPDF(format="A4")
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 24)
    pdf.cell(0, 14, "Scan to watch on NaSCon", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.image(io.BytesIO(png), x=45, y=35, w=120, h=120)
    pdf.set_y(165)
    pdf.set_font("Helvetica", "", 16)
    for line in (entity_id, url):
        pdf.cell(0, 10, line.encode("latin-1", "replace").decode("latin-1"), align="C",
                 new_x="LMARGIN", new_y="NEXT")
    return bytes(pdf.output())


@router.get("/audit/v1/qr/{entity_id}/export.{fmt}")
def export_qr(entity_id: str, fmt: str):
    if fmt not in EXPORT_TYPES:
        raise validation("fmt", "fmt must be svg, png or pdf")
    with pool.connection() as conn:
        qr = _mapping(conn, entity_id)
    url = short_url(qr)
    code, buf = segno.make(url, error="m"), io.BytesIO()
    code.save(buf, kind="svg" if fmt == "svg" else "png", scale=10, border=4)
    body = _pdf(buf.getvalue(), entity_id, url) if fmt == "pdf" else buf.getvalue()
    return Response(body, media_type=EXPORT_TYPES[fmt],
                    headers={"Content-Disposition": f'inline; filename="qr-{entity_id}.{fmt}"'})


@router.get("/q/{short_code}")
def short_link(short_code: str, request: Request):
    with pool.connection() as conn:
        qr = conn.execute("SELECT * FROM qr_codes WHERE short_code = %s", (short_code,)).fetchone()
        if qr is None:
            raise not_found("QR_NOT_FOUND", short_code=short_code)
        _, route = _live(conn, qr)
        _record_scan(conn, qr["entity_id"], request)
    return RedirectResponse(route, status_code=302)


# --------------------------------------------------------------------------- guest cart merge

def _validate_merge(body) -> dict:
    if not isinstance(body, dict):
        raise validation("body", "Body must be a JSON object")
    fields = []
    if not (isinstance(body.get("guest_token"), str) and body["guest_token"].startswith(day2.GUEST_PREFIX)):
        fields.append("guest_token")
    if not (isinstance(body.get("registered_user_id"), str) and body["registered_user_id"]):
        fields.append("registered_user_id")
    cart = body.get("guest_cart")
    if not (isinstance(cart, list) and 1 <= len(cart) <= 10):
        fields.append("guest_cart")
    else:
        for item in cart:
            if not isinstance(item, dict):
                fields.append("guest_cart")
                continue
            if not (isinstance(item.get("variant_id"), str) and item["variant_id"]):
                fields.append("guest_cart.variant_id")
            if not is_int(item.get("quantity"), 1):
                fields.append("guest_cart.quantity")
    if not isinstance(body.get("test_write_block", True), bool):
        fields.append("test_write_block")
    if fields:
        raise validation(sorted(set(fields)))
    return body


def _active_cart(conn, user_id: str) -> dict:
    rows = conn.execute(
        f"SELECT c.variant_id, c.quantity, {PRICE_SQL} AS unit_price_minor FROM member_carts c "
        "JOIN store_variants v USING (variant_id) WHERE c.user_id = %s ORDER BY c.variant_id", (user_id,)).fetchall()
    items = [{"variant_id": r["variant_id"], "quantity": r["quantity"], "unit_price_minor": r["unit_price_minor"]}
             for r in rows]
    return {"user_id": user_id, "currency": "PKR", "total_items": sum(i["quantity"] for i in items),
            "subtotal_minor": sum(i["quantity"] * i["unit_price_minor"] for i in items), "items": items}


def cart_merge(body) -> dict:
    body = _validate_merge(body)
    token, user_id = body["guest_token"], body["registered_user_id"]
    incoming: dict[str, int] = {}
    for item in body["guest_cart"]:
        incoming[item["variant_id"]] = incoming.get(item["variant_id"], 0) + item["quantity"]
    request = {"registered_user_id": user_id, "guest_cart": body["guest_cart"]}

    with pool.connection() as conn:
        day2.require_player(conn, user_id)
        stock = {r["variant_id"]: r["stock"] for r in conn.execute(
            "SELECT variant_id, stock FROM store_variants WHERE variant_id = ANY(%s)", (list(incoming),)).fetchall()}
        for variant_id in incoming:
            if variant_id not in stock:
                raise not_found("VARIANT_NOT_FOUND", variant_id=variant_id)

        # Always token first, then user: concurrent merges cannot deadlock, identical retries serialise.
        conn.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", ("guest-merge-token:" + token,))
        conn.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", ("guest-merge-user:" + user_id,))
        done = conn.execute("SELECT request, response FROM guest_merges WHERE guest_token = %s", (token,)).fetchone()
        if done:
            if canonical(done["request"]) == canonical(request):
                return done["response"]
            raise conflict("GUEST_TOKEN_ALREADY_MERGED", "This guest token has already been merged.",
                           guest_token=token)

        existing = {r["variant_id"]: r["quantity"] for r in conn.execute(
            "SELECT variant_id, quantity FROM member_carts WHERE user_id = %s", (user_id,)).fetchall()}
        for variant_id in sorted(incoming):
            # "capped by available stock": anything over the cap is refused, so the cap never silently drops items
            if existing.get(variant_id, 0) + incoming[variant_id] > stock[variant_id]:
                raise conflict("OUT_OF_STOCK", f"Variant {variant_id} does not have enough stock.",
                               variant_id=variant_id)

        verified, rejection = False, None
        if body.get("test_write_block", True) and day2.is_guest_token(token):
            # The same rule the guest_write_block middleware applies to every write request.
            verified, rejection = True, day2.guest_forbidden(token).status

        for variant_id in sorted(incoming):
            conn.execute("INSERT INTO member_carts (user_id, variant_id, quantity) VALUES (%s, %s, %s) "
                         "ON CONFLICT (user_id, variant_id) DO UPDATE "
                         "SET quantity = member_carts.quantity + EXCLUDED.quantity",
                         (user_id, variant_id, incoming[variant_id]))
        cart = _active_cart(conn, user_id)
        response = {
            "guest_token": token, "write_block_verified": verified, "write_rejection_code": rejection,
            "cart_merged": True, "active_cart": cart,
            "signature": sign_day2(token, {"cart_merged": True, "guest_token": token, "registered_user_id": user_id,
                                           "total_items": cart["total_items"], "write_rejection_code": rejection}),
        }
        conn.execute("INSERT INTO guest_merges (guest_token, registered_user_id, request, response) "
                     "VALUES (%s, %s, %s, %s)", (token, user_id, Jsonb(request), Jsonb(response)))
    return response


@router.post("/audit/v1/guest/cart-merge")
async def guest_cart_merge(request: Request):
    return await run_in_threadpool(cart_merge, await read_json(request))
