"""FR-2.3 / spec 5.12: merchandise store, concurrency-safe checkout, signed PDF receipts.

Checkout pipeline (spec 5.2 validation order, then 5.12 processing order):

  1. schema (400 VALIDATION_ERROR) -> variants exist (404 VARIANT_NOT_FOUND)
     -> discount code (400 INVALID_DISCOUNT_CODE)
  2. claim the order_id (idempotency): identical replay of a paid order -> 200 with
     the stored response; same id + different body -> 409 DUPLICATE_ORDER_ID
  3. reserve ALL items in one short transaction with conditional UPDATEs
     (stock >= q), rows locked in sorted variant_id order so multi-item orders
     cannot deadlock. Any shortfall rolls the whole transaction back -> 409 OUT_OF_STOCK.
  4. mock gateway + second short transaction: capture -> reservation committed
     (reserved returns to 0, stock stays decremented), order "paid", receipt stored;
     decline / capture failure -> reservation released (stock restored) -> 402.

Failed attempts (409 OUT_OF_STOCK, 402) do not consume the order_id: the spec only
defines replay for successes, so a client may retry the same order_id (e.g. with a new
payment token). Replaying an identical failed request simply runs again and, the
mock gateway being deterministic, returns the same error.

Every order status transition appends an `order_status_changed` row to
store_domain_events, the internal queue (transactional outbox).
"""
import base64
import time

from fastapi import APIRouter, Depends, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, Response
from fpdf import FPDF
from psycopg.types.json import Json, Jsonb

from ..auth import current_user, forbidden
from ..db import pool
from ..errors import ApiError, conflict, not_found, validation
from ..signing import sign
from .util import is_id, is_int, read_json, utc_now_iso

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS store_products (
    product_id  TEXT PRIMARY KEY,
    tenant_id   TEXT NOT NULL,
    name        TEXT NOT NULL,
    category    TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT ''
);
ALTER TABLE store_products ADD COLUMN IF NOT EXISTS image_url TEXT;
CREATE TABLE IF NOT EXISTS store_variants (
    variant_id  TEXT PRIMARY KEY,
    product_id  TEXT NOT NULL REFERENCES store_products(product_id) ON DELETE CASCADE,
    position    INTEGER NOT NULL DEFAULT 0,
    label       TEXT NOT NULL,
    size        TEXT,
    color       TEXT,
    price_minor BIGINT NOT NULL CHECK (price_minor >= 0),
    currency    TEXT NOT NULL DEFAULT 'PKR',
    stock       INTEGER NOT NULL CHECK (stock >= 0),
    reserved    INTEGER NOT NULL DEFAULT 0 CHECK (reserved >= 0)
);
CREATE TABLE IF NOT EXISTS store_discount_codes (
    code    TEXT PRIMARY KEY,
    percent INTEGER NOT NULL CHECK (percent BETWEEN 0 AND 100)
);
CREATE TABLE IF NOT EXISTS store_orders (
    order_id    TEXT PRIMARY KEY,
    customer_id TEXT NOT NULL,
    request     JSONB NOT NULL,
    status      TEXT NOT NULL,
    error_code  TEXT,
    response    JSON,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS store_domain_events (
    event_seq    BIGSERIAL PRIMARY KEY,
    event_type   TEXT NOT NULL,
    aggregate_id TEXT NOT NULL,
    payload      JSONB NOT NULL,
    published    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE SEQUENCE IF NOT EXISTS store_payment_seq;
"""

CURRENCY = "PKR"
MAX_ITEMS = 10
MAX_QUANTITY = 10
MAX_CUSTOMER_ID = 200
POST_PAID = ("paid", "packed", "shipped", "delivered", "refunded")
REPLAY_WAIT_SECONDS = 4.0  # how long an identical request waits for its in-flight twin

# (product_id, tenant_id, name, category, description, variants)
# variant: (variant_id, label, size, color, price_minor, default_stock)
BASELINE_PRODUCTS = [
    ("prod-jersey-001", "tenant-alpha", "Alpha FC Home Jersey", "apparel",
     "Official Alpha FC home jersey, season 2026.",
     [("var-jersey-001-M", "Medium", "M", "Red", 450000, 1),
      ("var-jersey-001-L", "Large", "L", "Red", 450000, 5)]),
    ("prod-scarf-001", "tenant-alpha", "Alpha FC Supporter Scarf", "accessories",
     "Knitted supporter scarf in club colours.",
     [("var-scarf-001-STD", "One size", None, "Red/White", 150000, 25)]),
    ("prod-cap-001", "tenant-alpha", "Alpha FC Cap", "accessories",
     "Adjustable cotton cap with embroidered crest.",
     [("var-cap-001-BLK", "Black", None, "Black", 120000, 15),
      ("var-cap-001-WHT", "White", None, "White", 120000, 10)]),
    ("prod-wallpaper-001", "tenant-alpha", "Alpha FC Digital Wallpaper Pack", "digital",
     "Ten high-resolution wallpapers for phone and desktop.",
     [("var-wallpaper-001-HD", "HD download", None, None, 50000, 1000)]),
    ("prod-jersey-b01", "tenant-beta", "Beta Athletics Training Top", "apparel",
     "Lightweight training top for Beta Athletics.",
     [("var-jersey-b01-M", "Medium", "M", "Blue", 400000, 10)]),
]
DISCOUNT_CODES = {"WELCOME10": 10}


def reset(conn, seed: int, body: dict) -> None:
    stock_overrides = body.get("stock") or {}
    conn.execute("DELETE FROM store_domain_events")
    conn.execute("DELETE FROM store_orders")
    conn.execute("DELETE FROM store_variants")
    conn.execute("DELETE FROM store_products")
    conn.execute("DELETE FROM store_discount_codes")
    conn.execute("ALTER SEQUENCE store_payment_seq RESTART WITH 1")
    conn.execute("ALTER SEQUENCE store_domain_events_event_seq_seq RESTART WITH 1")
    for product_id, tenant_id, name, category, description, variants in BASELINE_PRODUCTS:
        conn.execute(
            "INSERT INTO store_products (product_id, tenant_id, name, category, description) "
            "VALUES (%s, %s, %s, %s, %s)", (product_id, tenant_id, name, category, description))
        for position, (variant_id, label, size, color, price, default_stock) in enumerate(variants):
            conn.execute(
                "INSERT INTO store_variants (variant_id, product_id, position, label, size, color, "
                "price_minor, currency, stock) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
                (variant_id, product_id, position, label, size, color, price, CURRENCY,
                 stock_overrides.get(variant_id, default_stock)))
    for code, percent in DISCOUNT_CODES.items():
        conn.execute("INSERT INTO store_discount_codes (code, percent) VALUES (%s, %s)", (code, percent))


# --------------------------------------------------------------------------- validation

def _parse_order(body, default_customer: str | None = None) -> dict:
    """Schema check (400). Returns the normalised order; items keep request order."""
    if not isinstance(body, dict):
        raise validation("body")
    fields: list[str] = []

    order_id = body.get("order_id")
    if not is_id(order_id):
        fields.append("order_id")

    # customer_id is free text (may contain quotes / <script>): stored as plain data.
    customer_id = body.get("customer_id")
    if customer_id is None:
        customer_id = default_customer
    if not isinstance(customer_id, str) or not 1 <= len(customer_id) <= MAX_CUSTOMER_ID:
        fields.append("customer_id")

    items = body.get("items")
    parsed_items = []
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
        fields.append("items")
    else:
        for item in items:
            if not isinstance(item, dict):
                fields.append("items")
                continue
            if not is_id(item.get("variant_id")):
                fields += ["items", "items.variant_id"]
            if not is_int(item.get("quantity"), 1, MAX_QUANTITY):
                fields += ["items", "items.quantity"]
            parsed_items.append({"variant_id": item.get("variant_id"), "quantity": item.get("quantity")})
        variant_ids = [str(i["variant_id"]) for i in parsed_items]
        if len(set(variant_ids)) != len(variant_ids):
            fields.append("items")

    discount_code = body.get("discount_code")
    if discount_code is not None and not isinstance(discount_code, str):
        fields.append("discount_code")

    payment = body.get("payment")
    token = payment.get("token") if isinstance(payment, dict) else None
    if not isinstance(token, str) or not token:
        fields.append("payment.token")

    if fields:
        raise validation(list(dict.fromkeys(fields)))
    return {"order_id": order_id, "customer_id": customer_id, "items": parsed_items,
            "discount_code": discount_code, "token": token}


def _fingerprint(order: dict) -> dict:
    """What 'identical request' means for idempotency (unknown fields are ignored)."""
    return {"customer_id": order["customer_id"], "discount_code": order["discount_code"],
            "token": order["token"],
            "items": sorted([i["variant_id"], i["quantity"]] for i in order["items"])}


# --------------------------------------------------------------------------- phase A: check, claim, reserve

def _load_variants(conn, order: dict, tenant_id: str | None) -> dict:
    ids = [i["variant_id"] for i in order["items"]]
    rows = conn.execute(
        "SELECT v.variant_id, v.price_minor, p.tenant_id FROM store_variants v "
        "JOIN store_products p USING (product_id) WHERE v.variant_id = ANY(%s)", (ids,)).fetchall()
    variants = {r["variant_id"]: r for r in rows}
    for variant_id in ids:
        if variant_id not in variants:
            raise not_found("VARIANT_NOT_FOUND", variant_id=variant_id)
    if tenant_id is not None and any(v["tenant_id"] != tenant_id for v in variants.values()):
        raise forbidden("Variant belongs to another tenant")
    return variants


def _discount_percent(conn, code: str | None) -> int:
    if code is None:
        return 0
    row = conn.execute("SELECT percent FROM store_discount_codes WHERE code = %s", (code,)).fetchone()
    if row is None:
        raise ApiError(400, "INVALID_DISCOUNT_CODE", "Unknown discount code", {"discount_code": code})
    return row["percent"]


def _emit(conn, order_id: str, status: str, previous: str | None, **extra) -> None:
    payload = {"order_id": order_id, "status": status, "previous_status": previous, **extra}
    conn.execute("INSERT INTO store_domain_events (event_type, aggregate_id, payload) VALUES (%s, %s, %s)",
                 ("order_status_changed", order_id, Jsonb(payload)))


def _claim(conn, order: dict) -> tuple[str, dict | None]:
    """Reserve the order_id. Returns ("new", None), ("replay", response) or ("wait", None)."""
    fingerprint = _fingerprint(order)
    inserted = conn.execute(
        "INSERT INTO store_orders (order_id, customer_id, request, status) VALUES (%s, %s, %s, 'pending') "
        "ON CONFLICT (order_id) DO NOTHING RETURNING order_id",
        (order["order_id"], order["customer_id"], Jsonb(fingerprint))).fetchone()
    if inserted:
        _emit(conn, order["order_id"], "pending", None)
        return "new", None
    existing = conn.execute("SELECT request, status, response FROM store_orders WHERE order_id = %s FOR UPDATE",
                            (order["order_id"],)).fetchone()
    if existing is None:  # pragma: no cover - removed by a concurrent reset; caller retries
        return "wait", None
    if existing["request"] != fingerprint:  # spec 5.12: same id, different body -> 409, even after a failure
        raise conflict("DUPLICATE_ORDER_ID", f"Order {order['order_id']} already exists with a different body",
                       order_id=order["order_id"])
    if existing["status"] == "cancelled":  # an identical retry of a failed attempt runs again
        conn.execute("UPDATE store_orders SET status = 'pending', customer_id = %s, request = %s, "
                     "error_code = NULL, updated_at = now() WHERE order_id = %s",
                     (order["customer_id"], Jsonb(fingerprint), order["order_id"]))
        _emit(conn, order["order_id"], "pending", "cancelled")
        return "new", None
    if existing["request"] != fingerprint:
        raise conflict("DUPLICATE_ORDER_ID", f"Order {order['order_id']} already exists with a different body",
                       order_id=order["order_id"])
    if existing["status"] in POST_PAID:
        return "replay", existing["response"]
    return "wait", None  # identical request still in flight


def _reserve(conn, items: list[dict]) -> None:
    """All-or-nothing: an exception here rolls back every reservation of this transaction."""
    for item in sorted(items, key=lambda i: i["variant_id"]):
        row = conn.execute(
            "UPDATE store_variants SET stock = stock - %(q)s, reserved = reserved + %(q)s "
            "WHERE variant_id = %(v)s AND stock >= %(q)s RETURNING stock",
            {"q": item["quantity"], "v": item["variant_id"]}).fetchone()
        if row is None:
            raise conflict("OUT_OF_STOCK", f"Variant {item['variant_id']} has no stock left.",
                           variant_id=item["variant_id"])


def _prepare(order: dict, tenant_id: str | None) -> tuple[str, dict | None, dict, int]:
    with pool.connection() as conn:
        variants = _load_variants(conn, order, tenant_id)
        percent = _discount_percent(conn, order["discount_code"])
        state, stored = _claim(conn, order)
        if state == "new":
            _reserve(conn, order["items"])
    return state, stored, variants, percent


# --------------------------------------------------------------------------- phase B: gateway + settle

def _gateway(conn, token: str) -> dict:
    """Mock payment gateway. Unknown tokens behave like tok_declined."""
    if token not in ("tok_success", "tok_capture_fail"):
        return {"state": "declined", "error": "PAYMENT_DECLINED"}
    n = conn.execute("SELECT nextval('store_payment_seq') AS n").fetchone()["n"]
    if token == "tok_capture_fail":  # authorized, capture fails, authorization voided
        return {"state": "voided", "error": "PAYMENT_CAPTURE_FAILED", "authorization_id": f"auth_{n}"}
    return {"state": "captured", "authorization_id": f"auth_{n}", "capture_id": f"cap_{n}"}


def money(minor: int) -> str:
    """450000 -> 'PKR 4500.00' (major units, two decimals, no thousands separator)."""
    return f"{CURRENCY} {minor // 100}.{minor % 100:02d}"


def _pdf_text(value) -> str:
    # Core PDF fonts are Latin-1 only; anything else is replaced, never an error.
    return str(value).encode("latin-1", "replace").decode("latin-1")


def receipt_pdf(payload: dict, signature: str) -> bytes:
    pdf = FPDF(format="A4")
    pdf.set_title(_pdf_text(f"Receipt {payload['order_id']}"))
    pdf.add_page()
    pdf.set_font("helvetica", "B", 16)
    pdf.cell(0, 10, "Club Merchandise Store - Receipt", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("helvetica", size=11)
    lines = [f"Order: {payload['order_id']}", f"Customer: {payload['customer_id']}",
             f"Paid at: {payload['paid_at']}", "", "Items:"]
    lines += [f"  {i['variant_id']}  x{i['quantity']}  @ {money(i['unit_price_minor'])}"
              f"  = {money(i['quantity'] * i['unit_price_minor'])}" for i in payload["items"]]
    lines += ["", f"Subtotal: {money(payload['subtotal_minor'])}", f"Discount: {money(payload['discount_minor'])}",
              f"Total: {money(payload['total_minor'])}", "", f"Signature: {signature}"]
    for line in lines:
        pdf.multi_cell(0, 7, _pdf_text(line), new_x="LMARGIN", new_y="NEXT")
    return bytes(pdf.output())


def _build_response(order: dict, variants: dict, percent: int, payment: dict) -> dict:
    def priced_items():
        return [{"variant_id": i["variant_id"], "quantity": i["quantity"],
                 "unit_price_minor": variants[i["variant_id"]]["price_minor"]} for i in order["items"]]

    subtotal = sum(i["quantity"] * variants[i["variant_id"]]["price_minor"] for i in order["items"])
    discount = subtotal * percent // 100
    total = subtotal - discount
    payload = {"order_id": order["order_id"], "customer_id": order["customer_id"], "items": priced_items(),
               "subtotal_minor": subtotal, "discount_minor": discount, "total_minor": total,
               "currency": CURRENCY, "paid_at": utc_now_iso()}
    signature = sign(order["order_id"], payload)
    pdf = receipt_pdf(payload, signature)
    return {
        "order_id": order["order_id"], "status": "paid", "currency": CURRENCY, "items": priced_items(),
        "subtotal_minor": subtotal, "discount_minor": discount, "total_minor": total,
        "payment": {"authorization_id": payment["authorization_id"], "capture_id": payment["capture_id"],
                    "state": "captured"},
        "receipt": {"payload": payload, "signature": signature,
                    "pdf_base64": base64.b64encode(pdf).decode("ascii")},
    }


def _release(conn, order: dict, error_code: str) -> None:
    for item in sorted(order["items"], key=lambda i: i["variant_id"]):
        conn.execute("UPDATE store_variants SET stock = stock + %(q)s, reserved = reserved - %(q)s "
                     "WHERE variant_id = %(v)s", {"q": item["quantity"], "v": item["variant_id"]})
    conn.execute("UPDATE store_orders SET status = 'cancelled', error_code = %s, updated_at = now() "
                 "WHERE order_id = %s", (error_code, order["order_id"]))
    _emit(conn, order["order_id"], "cancelled", "pending", reason=error_code)


def _commit(conn, order: dict, response: dict) -> None:
    for item in sorted(order["items"], key=lambda i: i["variant_id"]):
        conn.execute("UPDATE store_variants SET reserved = reserved - %(q)s WHERE variant_id = %(v)s",
                     {"q": item["quantity"], "v": item["variant_id"]})
    conn.execute("UPDATE store_orders SET status = 'paid', response = %s, updated_at = now() WHERE order_id = %s",
                 (Json(response), order["order_id"]))
    _emit(conn, order["order_id"], "paid", "pending")


def _settle(order: dict, variants: dict, percent: int) -> dict:
    try:
        with pool.connection() as conn:
            payment = _gateway(conn, order["token"])
            if payment["state"] == "captured":
                response = _build_response(order, variants, percent, payment)
                _commit(conn, order, response)
                return response
            _release(conn, order, payment["error"])
    except Exception:
        # Anything unexpected after reserving: give the stock back, then surface the error.
        with pool.connection() as conn:
            _release(conn, order, "INTERNAL_ERROR")
        raise
    message = "Payment was declined" if payment["error"] == "PAYMENT_DECLINED" else "Payment capture failed"
    raise ApiError(402, payment["error"], message, {"order_id": order["order_id"]})


def checkout(body, default_customer: str | None = None, tenant_id: str | None = None) -> tuple[int, dict]:
    """The whole pipeline; returns (http_status, response_body) or raises ApiError."""
    order = _parse_order(body, default_customer)
    deadline = time.monotonic() + REPLAY_WAIT_SECONDS
    while True:
        state, stored, variants, percent = _prepare(order, tenant_id)
        if state == "replay":
            return 200, stored
        if state == "new":
            return 201, _settle(order, variants, percent)
        if time.monotonic() > deadline:
            raise conflict("DUPLICATE_ORDER_ID", "An identical order is still being processed",
                           order_id=order["order_id"])
        time.sleep(0.05)


def inventory(variant_id: str) -> dict:
    with pool.connection() as conn:
        row = conn.execute("SELECT variant_id, stock, reserved FROM store_variants WHERE variant_id = %s",
                           (variant_id,)).fetchone()
    if row is None:
        raise not_found("VARIANT_NOT_FOUND", variant_id=variant_id)
    return dict(row)


# --------------------------------------------------------------------------- audit routes (spec 5.12)

@router.post("/audit/v1/checkout")
async def audit_checkout(request: Request):
    body = await read_json(request)
    status, response = await run_in_threadpool(checkout, body)
    return JSONResponse(status_code=status, content=response)


@router.get("/audit/v1/inventory/{variant_id}")
def audit_inventory(variant_id: str):
    return inventory(variant_id)


# --------------------------------------------------------------------------- mobile / production routes (JWT)

def _tenant_scope(user: dict) -> str | None:
    """None = platform-wide (super admin)."""
    return None if user.get("role") == "super_admin" else user.get("tenant_id")


@router.get("/api/v1/store/products")
def list_products(user: dict = Depends(current_user)):
    tenant_id = _tenant_scope(user)
    with pool.connection() as conn:
        products = conn.execute(
            "SELECT product_id, tenant_id, name, category, description, image_url FROM store_products "
            "WHERE %(t)s::text IS NULL OR tenant_id = %(t)s ORDER BY product_id", {"t": tenant_id}).fetchall()
        variants = conn.execute(
            "SELECT product_id, variant_id, label, size, color, price_minor, currency, stock "
            "FROM store_variants ORDER BY product_id, position, variant_id").fetchall()
    by_product: dict[str, list] = {}
    for v in variants:
        by_product.setdefault(v.pop("product_id"), []).append(v)
    return [{**p, "variants": by_product.get(p["product_id"], [])} for p in products]


MANAGER_ROLES = ("super_admin", "club_manager")


@router.post("/api/v1/store/products", status_code=201)
async def create_product(request: Request, user: dict = Depends(current_user)):
    """Store management (club manager of the tenant, or platform admin): add a product
    with its variants. Buyers cannot create products."""
    if user.get("role") not in MANAGER_ROLES:
        raise ApiError(403, "FORBIDDEN", "Only club managers and admins can add merchandise")
    body = await read_json(request)
    if not isinstance(body, dict):
        raise validation("body")
    bad = []
    name = body.get("name")
    if not isinstance(name, str) or not name.strip() or len(name) > 120:
        bad.append("name")
    category = body.get("category", "apparel")
    if not isinstance(category, str) or not category.strip() or len(category) > 40:
        bad.append("category")
    image_url = body.get("image_url")
    if image_url is not None and (not isinstance(image_url, str) or len(image_url) > 500
                                  or not image_url.startswith(("http://", "https://"))):
        bad.append("image_url")
    description = body.get("description", "")
    if not isinstance(description, str) or len(description) > 1000:
        bad.append("description")
    variants = body.get("variants")
    if not isinstance(variants, list) or not 1 <= len(variants) <= 20:
        bad.append("variants")
    else:
        for v in variants:
            if not (isinstance(v, dict) and isinstance(v.get("label"), str) and v["label"].strip()
                    and is_int(v.get("price_minor"), 0) and is_int(v.get("stock"), 0)):
                bad.append("variants")
                break
    tenant_id = body.get("tenant_id") if user.get("role") == "super_admin" else user.get("tenant_id")
    if not isinstance(tenant_id, str) or not tenant_id:
        tenant_id = "tenant-alpha" if user.get("role") == "super_admin" else None
        if tenant_id is None:
            bad.append("tenant_id")
    if bad:
        raise validation(bad, "Invalid product")
    import time
    product_id = f"prod-{int(time.time() * 1000)}"
    with pool.connection() as conn:
        conn.execute("INSERT INTO store_products (product_id, tenant_id, name, category, description, image_url)"
                     " VALUES (%s, %s, %s, %s, %s, %s)",
                     (product_id, tenant_id, name.strip(), category.strip(), description, image_url))
        for i, v in enumerate(variants):
            conn.execute(
                "INSERT INTO store_variants (variant_id, product_id, position, label, size, color, price_minor, stock)"
                " VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
                (f"{product_id}-v{i + 1}", product_id, i, v["label"].strip(), v.get("size"), v.get("color"),
                 v["price_minor"], v["stock"]))
    return {"product_id": product_id, "tenant_id": tenant_id, "name": name.strip(), "category": category.strip(),
            "description": description, "image_url": image_url,
            "variants": [{"variant_id": f"{product_id}-v{i + 1}", "label": v["label"].strip(), "size": v.get("size"),
                          "color": v.get("color"), "price_minor": v["price_minor"], "currency": "PKR",
                          "stock": v["stock"]} for i, v in enumerate(variants)]}


@router.post("/api/v1/store/checkout")
async def store_checkout(request: Request, user: dict = Depends(current_user)):
    body = await read_json(request)
    status, response = await run_in_threadpool(checkout, body, user.get("sub"), _tenant_scope(user))
    return JSONResponse(status_code=status, content=response)


@router.get("/api/v1/store/orders/{order_id}/receipt.pdf")
def order_receipt(order_id: str, user: dict = Depends(current_user)):
    with pool.connection() as conn:
        row = conn.execute("SELECT customer_id, response FROM store_orders WHERE order_id = %s AND response IS NOT NULL",
                           (order_id,)).fetchone()
    if row is None:
        raise not_found("ORDER_NOT_FOUND", order_id=order_id)
    if user.get("role") != "super_admin" and row["customer_id"] != user.get("sub"):
        raise forbidden("Only the ordering customer may download this receipt")
    pdf = base64.b64decode(row["response"]["receipt"]["pdf_base64"])
    return Response(content=pdf, media_type="application/pdf",
                    headers={"Content-Disposition": f'inline; filename="receipt-{order_id}.pdf"'})


# --------------------------------------------------------------------------- order lifecycle (FR-2.3)

TRANSITIONS = {"packed": ("paid",), "shipped": ("packed",), "delivered": ("shipped",),
               "refunded": ("paid", "packed", "shipped", "delivered")}


def _order_tenant(conn, request: dict) -> str | None:
    ids = [item[0] for item in (request or {}).get("items", [])]
    row = conn.execute("SELECT p.tenant_id FROM store_variants v JOIN store_products p USING (product_id) "
                       "WHERE v.variant_id = ANY(%s) LIMIT 1", (ids,)).fetchone()
    return row["tenant_id"] if row else None


def change_status(order_id: str, body, user: dict) -> dict:
    new = body.get("status") if isinstance(body, dict) else None
    if not isinstance(new, str) or new not in TRANSITIONS:
        raise validation("status")
    if user.get("role") not in MANAGER_ROLES:
        raise forbidden("Only club managers and admins can change order status")
    with pool.connection() as conn:
        row = conn.execute("SELECT status, request FROM store_orders WHERE order_id = %s FOR UPDATE",
                           (order_id,)).fetchone()
        if row is None:
            raise not_found("ORDER_NOT_FOUND", order_id=order_id)
        if user.get("role") != "super_admin" and _order_tenant(conn, row["request"]) != user.get("tenant_id"):
            raise forbidden("Order belongs to another tenant")
        old = row["status"]
        if old not in TRANSITIONS[new]:
            raise conflict("ILLEGAL_TRANSITION", f"Cannot move order from {old} to {new}",
                           order_id=order_id, from_status=old, to_status=new)
        if new == "refunded":
            for variant_id, quantity in sorted(row["request"].get("items", [])):
                conn.execute("UPDATE store_variants SET stock = stock + %s WHERE variant_id = %s",
                             (quantity, variant_id))
        conn.execute("UPDATE store_orders SET status = %s, updated_at = now() WHERE order_id = %s", (new, order_id))
        _emit(conn, order_id, new, old)
    return {"order_id": order_id, "status": new}


@router.post("/api/v1/store/orders/{order_id}/status")
async def order_status(order_id: str, request: Request, user: dict = Depends(current_user)):
    body = await read_json(request)
    return await run_in_threadpool(change_status, order_id, body, user)


@router.get("/api/v1/store/orders")
def list_orders(user: dict = Depends(current_user)):
    with pool.connection() as conn:
        rows = conn.execute(
            "SELECT order_id, customer_id, request, status, (response->>'total_minor')::bigint AS total_minor, "
            "created_at FROM store_orders ORDER BY created_at DESC, order_id").fetchall()
        if user.get("role") == "super_admin":
            picked = rows
        elif user.get("role") == "club_manager":
            picked = [r for r in rows if _order_tenant(conn, r["request"]) == user.get("tenant_id")]
        else:
            picked = [r for r in rows if r["customer_id"] == user.get("sub")]
    return [{"order_id": r["order_id"], "status": r["status"], "total_minor": r["total_minor"],
             "created_at": r["created_at"].isoformat()} for r in picked]