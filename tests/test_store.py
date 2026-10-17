"""Store: checkout pipeline, inventory, receipts (spec 5.12, 5.3, NFR-3) and the mobile store API."""
import base64
import io
import threading

import pytest
from pypdf import PdfReader

M, L = "var-jersey-001-M", "var-jersey-001-L"


def order(order_id="ord-001", items=None, discount_code=None, token="tok_success", customer_id="cust-001"):
    return {"order_id": order_id, "customer_id": customer_id,
            "items": items if items is not None else [{"variant_id": M, "quantity": 1}],
            "discount_code": discount_code, "payment": {"token": token}}


def inv(api, variant_id):
    r = api.get(f"/audit/v1/inventory/{variant_id}")
    assert r.status_code == 200, r.text
    return r.json()


def err(r, status, code):
    assert r.status_code == status, r.text
    body = r.json()
    assert set(body) == {"error"} and set(body["error"]) == {"code", "message", "details"}
    assert body["error"]["code"] == code
    return body["error"]["details"]


def pdf_text(b64: str) -> str:
    raw = base64.b64decode(b64)
    assert raw.startswith(b"%PDF")
    return "".join(page.extract_text() for page in PdfReader(io.BytesIO(raw)).pages)


def bearer(**claims):
    from app.auth import create_token
    return {"Authorization": "Bearer " + create_token({"sub": "user-player-1", "role": "player",
                                                        "tenant_id": "tenant-alpha", **claims})}


# --------------------------------------------------------------------------- signature (Appendix A)

def test_appendix_a_signature_vector():
    from app.signing import sign
    assert sign("evt-1", {"team_id": "t1", "event_type": "goal"}, salt="demo-salt") == \
        "972a8b558690b19121cc5bea84978f85e8eb15a3735018db36616bab1d7ec501"


def test_money_format():
    from app.modules.store import money
    assert money(450000) == "PKR 4500.00"
    assert money(810005) == "PKR 8100.05"
    assert money(0) == "PKR 0.00"
    assert money(123456789) == "PKR 1234567.89"


# --------------------------------------------------------------------------- baseline + inventory

def test_inventory_after_reset(api):
    api.reset()
    assert inv(api, M) == {"variant_id": M, "stock": 1, "reserved": 0}
    assert inv(api, L) == {"variant_id": L, "stock": 5, "reserved": 0}
    api.reset(stock={M: 7, L: 0, "var-unknown-x": 3})
    assert inv(api, M)["stock"] == 7 and inv(api, L)["stock"] == 0


def test_inventory_unknown_variant(api):
    api.reset()
    assert err(api.get("/audit/v1/inventory/var-nope"), 404, "VARIANT_NOT_FOUND") == {"variant_id": "var-nope"}


# --------------------------------------------------------------------------- success

def test_checkout_success_exact_shape(api):
    import os
    from app.signing import sign
    api.reset()
    r = api.post("/audit/v1/checkout", json=order())
    assert r.status_code == 201, r.text
    body = r.json()
    paid_at = body["receipt"]["payload"]["paid_at"]
    item = {"variant_id": M, "quantity": 1, "unit_price_minor": 450000}
    assert list(body) == ["order_id", "status", "currency", "items", "subtotal_minor", "discount_minor",
                          "total_minor", "payment", "receipt"]
    assert {k: v for k, v in body.items() if k != "receipt"} == {
        "order_id": "ord-001", "status": "paid", "currency": "PKR", "items": [item],
        "subtotal_minor": 450000, "discount_minor": 0, "total_minor": 450000,
        "payment": {"authorization_id": "auth_1", "capture_id": "cap_1", "state": "captured"},
    }
    assert set(body["receipt"]) == {"payload", "signature", "pdf_base64"}
    assert body["receipt"]["payload"] == {
        "order_id": "ord-001", "customer_id": "cust-001", "items": [item], "subtotal_minor": 450000,
        "discount_minor": 0, "total_minor": 450000, "currency": "PKR", "paid_at": paid_at}
    import re
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", paid_at)
    sig = body["receipt"]["signature"]
    assert re.fullmatch(r"[0-9a-f]{64}", sig)
    assert sig == sign("ord-001", body["receipt"]["payload"], salt=os.environ["DAY1_SALT"])
    text = pdf_text(body["receipt"]["pdf_base64"])
    assert "ord-001" in text and "PKR 4500.00" in text and "cust-001" in text and M in text
    assert inv(api, M) == {"variant_id": M, "stock": 0, "reserved": 0}


def test_checkout_discount_and_multi_item_math(api):
    api.reset(stock={M: 3, L: 5})
    r = api.post("/audit/v1/checkout", json=order(
        items=[{"variant_id": L, "quantity": 2}, {"variant_id": M, "quantity": 1}], discount_code="WELCOME10"))
    assert r.status_code == 201, r.text
    b = r.json()
    assert [i["variant_id"] for i in b["items"]] == [L, M]  # request order kept
    assert b["subtotal_minor"] == 1350000
    assert b["discount_minor"] == 135000
    assert b["total_minor"] == 1215000
    p = b["receipt"]["payload"]
    assert p["subtotal_minor"] - p["discount_minor"] == p["total_minor"]
    text = pdf_text(b["receipt"]["pdf_base64"])
    assert "PKR 12150.00" in text and "PKR 1350.00" in text
    assert inv(api, M)["stock"] == 2 and inv(api, L)["stock"] == 3


def test_discount_floors(api):
    api.reset()
    # scarf 1500.00 x 7 = 10500.00 -> 10% = 1050.00 ; wallpaper 500.00 x 3 = 1500 -> exact
    r = api.post("/audit/v1/checkout", json=order(
        items=[{"variant_id": "var-scarf-001-STD", "quantity": 7}], discount_code="WELCOME10"))
    assert r.json()["discount_minor"] == 105000
    from app.modules import store
    assert store._build_response(
        {"order_id": "o", "customer_id": "c", "items": [{"variant_id": "v", "quantity": 1}], "token": "t"},
        {"v": {"price_minor": 99999}}, 10, {"authorization_id": "auth_9", "capture_id": "cap_9"},
    )["discount_minor"] == 9999


def test_hostile_customer_id_is_plain_data(api):
    api.reset()
    cust = "x'; DROP TABLE store_orders;-- <script>alert(\"1\")</script> é中"
    r = api.post("/audit/v1/checkout", json=order(customer_id=cust))
    assert r.status_code == 201, r.text
    assert r.json()["receipt"]["payload"]["customer_id"] == cust
    assert "<script>" in pdf_text(r.json()["receipt"]["pdf_base64"])


# --------------------------------------------------------------------------- idempotency

def test_identical_replay_returns_stored_result(api):
    api.reset(stock={M: 1})
    first = api.post("/audit/v1/checkout", json=order())
    assert first.status_code == 201
    replay = api.post("/audit/v1/checkout", json={**order(), "unknown_field": True})
    assert replay.status_code == 200
    assert replay.json() == first.json()  # same paid_at, same signature, same pdf
    assert inv(api, M) == {"variant_id": M, "stock": 0, "reserved": 0}


def test_same_order_id_different_body_conflicts(api):
    api.reset(stock={M: 5})
    assert api.post("/audit/v1/checkout", json=order()).status_code == 201
    r = api.post("/audit/v1/checkout", json=order(items=[{"variant_id": M, "quantity": 2}]))
    assert err(r, 409, "DUPLICATE_ORDER_ID") == {"order_id": "ord-001"}
    err(api.post("/audit/v1/checkout", json=order(discount_code="WELCOME10")), 409, "DUPLICATE_ORDER_ID")
    assert inv(api, M)["stock"] == 4


def test_failed_order_id_identical_retry_reruns_but_different_body_is_409(api):
    api.reset(stock={M: 1})
    err(api.post("/audit/v1/checkout", json=order(token="tok_declined")), 402, "PAYMENT_DECLINED")
    err(api.post("/audit/v1/checkout", json=order(token="tok_declined")), 402, "PAYMENT_DECLINED")
    # spec 5.12: same id + different body -> 409, even after a failed attempt
    err(api.post("/audit/v1/checkout", json=order(token="tok_success")), 409, "DUPLICATE_ORDER_ID")
    r = api.post("/audit/v1/checkout", json=order(order_id="ord-retry", token="tok_success"))
    assert r.status_code == 201


@pytest.mark.in_process
def test_in_flight_twin_times_out_as_duplicate(api, monkeypatch):
    from app.db import pool
    from app.modules import store
    api.reset()
    with pool.connection() as conn:  # simulate an identical request stuck between reserve and settle
        conn.execute("INSERT INTO store_orders (order_id, customer_id, request, status) "
                     "VALUES ('ord-001', 'cust-001', %s, 'pending')",
                     (store.Jsonb(store._fingerprint(store._parse_order(order()))),))
    monkeypatch.setattr(store, "REPLAY_WAIT_SECONDS", 0.1)
    err(api.post("/audit/v1/checkout", json=order()), 409, "DUPLICATE_ORDER_ID")


# --------------------------------------------------------------------------- errors and ordering

def test_out_of_stock(api):
    api.reset(stock={M: 0})
    assert err(api.post("/audit/v1/checkout", json=order()), 409, "OUT_OF_STOCK") == {"variant_id": M}
    assert inv(api, M) == {"variant_id": M, "stock": 0, "reserved": 0}


def test_multi_item_all_or_nothing(api):
    api.reset(stock={M: 1, L: 1})
    r = api.post("/audit/v1/checkout", json=order(items=[{"variant_id": M, "quantity": 1},
                                                          {"variant_id": L, "quantity": 2}]))
    assert err(r, 409, "OUT_OF_STOCK") == {"variant_id": L}
    assert inv(api, M) == {"variant_id": M, "stock": 1, "reserved": 0}
    assert inv(api, L) == {"variant_id": L, "stock": 1, "reserved": 0}
    # the order id was not consumed and stock is intact
    ok = api.post("/audit/v1/checkout", json=order(items=[{"variant_id": M, "quantity": 1},
                                                           {"variant_id": L, "quantity": 1}]))
    assert ok.status_code == 201


@pytest.mark.parametrize("token,code", [("tok_declined", "PAYMENT_DECLINED"),
                                        ("tok_capture_fail", "PAYMENT_CAPTURE_FAILED"),
                                        ("tok_whatever", "PAYMENT_DECLINED")])
def test_payment_failures_release_stock(api, token, code):
    api.reset(stock={M: 1})
    err(api.post("/audit/v1/checkout", json=order(token=token)), 402, code)
    assert inv(api, M) == {"variant_id": M, "stock": 1, "reserved": 0}
    r = api.post("/audit/v1/checkout", json=order(order_id="ord-002"))
    assert r.status_code == 201
    assert inv(api, M) == {"variant_id": M, "stock": 0, "reserved": 0}


def test_capture_fail_consumes_authorization_number(api):
    api.reset(stock={M: 2})
    err(api.post("/audit/v1/checkout", json=order(token="tok_capture_fail")), 402, "PAYMENT_CAPTURE_FAILED")
    r = api.post("/audit/v1/checkout", json=order(order_id="ord-002"))
    assert r.json()["payment"] == {"authorization_id": "auth_2", "capture_id": "cap_2", "state": "captured"}


def test_unknown_variant_404(api):
    api.reset()
    r = api.post("/audit/v1/checkout", json=order(items=[{"variant_id": M, "quantity": 1},
                                                          {"variant_id": "var-ghost", "quantity": 1}]))
    assert err(r, 404, "VARIANT_NOT_FOUND") == {"variant_id": "var-ghost"}


def test_invalid_discount_code(api):
    api.reset()
    for code in ("NOPE", "welcome10", ""):
        err(api.post("/audit/v1/checkout", json=order(discount_code=code)), 400, "INVALID_DISCOUNT_CODE")
    assert inv(api, M)["stock"] == 1


def test_validation_order_404_before_discount_and_400_before_404(api):
    api.reset()
    err(api.post("/audit/v1/checkout", json=order(items=[{"variant_id": "var-ghost", "quantity": 1}],
                                                   discount_code="NOPE")), 404, "VARIANT_NOT_FOUND")
    err(api.post("/audit/v1/checkout", json=order(items=[{"variant_id": "var-ghost", "quantity": 0}])),
        400, "VALIDATION_ERROR")


def test_validation_after_success_wins_over_duplicate(api):
    api.reset()
    assert api.post("/audit/v1/checkout", json=order()).status_code == 201
    err(api.post("/audit/v1/checkout", json=order(items=[])), 400, "VALIDATION_ERROR")


@pytest.mark.parametrize("mutate,field", [
    (lambda b: b.pop("order_id"), "order_id"),
    (lambda b: b.update(order_id="bad id|x"), "order_id"),
    (lambda b: b.update(order_id="x" * 65), "order_id"),
    (lambda b: b.update(order_id=123), "order_id"),
    (lambda b: b.pop("customer_id"), "customer_id"),
    (lambda b: b.update(customer_id=""), "customer_id"),
    (lambda b: b.update(customer_id=42), "customer_id"),
    (lambda b: b.update(customer_id="c" * 201), "customer_id"),
    (lambda b: b.pop("items"), "items"),
    (lambda b: b.update(items=[]), "items"),
    (lambda b: b.update(items="x"), "items"),
    (lambda b: b.update(items=[{"variant_id": f"v{i}", "quantity": 1} for i in range(11)]), "items"),
    (lambda b: b.update(items=["x"]), "items"),
    (lambda b: b.update(items=[{"variant_id": M, "quantity": 1}, {"variant_id": M, "quantity": 2}]), "items"),
    (lambda b: b.update(items=[{"variant_id": M, "quantity": 0}]), "items.quantity"),
    (lambda b: b.update(items=[{"variant_id": M, "quantity": 11}]), "items.quantity"),
    (lambda b: b.update(items=[{"variant_id": M, "quantity": True}]), "items.quantity"),
    (lambda b: b.update(items=[{"variant_id": M, "quantity": 1.5}]), "items.quantity"),
    (lambda b: b.update(items=[{"variant_id": M, "quantity": "1"}]), "items.quantity"),
    (lambda b: b.update(items=[{"quantity": 1}]), "items.variant_id"),
    (lambda b: b.update(items=[{"variant_id": "x'; DROP TABLE store_variants;--", "quantity": 1}]),
     "items.variant_id"),
    (lambda b: b.update(discount_code=10), "discount_code"),
    (lambda b: b.pop("payment"), "payment.token"),
    (lambda b: b.update(payment="tok_success"), "payment.token"),
    (lambda b: b.update(payment={"token": 1}), "payment.token"),
    (lambda b: b.update(payment={"token": ""}), "payment.token"),
])
def test_schema_validation(api, mutate, field):
    api.reset()
    body = order()
    mutate(body)
    details = err(api.post("/audit/v1/checkout", json=body), 400, "VALIDATION_ERROR")
    assert field in details["fields"]
    assert inv(api, M) == {"variant_id": M, "stock": 1, "reserved": 0}


@pytest.mark.parametrize("raw", ["{bad json", "[]", "null", "\"str\"", ""])
def test_malformed_bodies(api, raw):
    r = api.post("/audit/v1/checkout", data=raw, headers={"Content-Type": "application/json"})
    err(r, 400, "VALIDATION_ERROR")


def test_missing_discount_code_key_is_null(api):
    api.reset()
    body = order()
    body.pop("discount_code")
    assert api.post("/audit/v1/checkout", json=body).status_code == 201


@pytest.mark.in_process
def test_unexpected_failure_after_reserve_releases_stock(api, monkeypatch):
    from app.modules import store

    def boom(*_a, **_k):
        raise RuntimeError("pdf engine down")
    api.reset()
    monkeypatch.setattr(store, "receipt_pdf", boom)
    with pytest.raises(RuntimeError):
        store.checkout(order())
    assert inv(api, M) == {"variant_id": M, "stock": 1, "reserved": 0}


# --------------------------------------------------------------------------- NFR-3 concurrency

def test_twenty_buyers_last_unit(api):
    api.reset(stock={M: 1})
    barrier = threading.Barrier(20)
    results = [None] * 20

    def buy(i):
        barrier.wait()
        r = api.post("/audit/v1/checkout", json=order(order_id=f"ord-burst-{i:02d}", customer_id=f"cust-{i}"))
        results[i] = (r.status_code, r.json())

    threads = [threading.Thread(target=buy, args=(i,)) for i in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    statuses = sorted(s for s, _ in results)
    assert statuses == [201] + [409] * 19
    assert all(b["error"]["code"] == "OUT_OF_STOCK" and b["error"]["details"] == {"variant_id": M}
               for s, b in results if s == 409)
    assert inv(api, M) == {"variant_id": M, "stock": 0, "reserved": 0}


@pytest.mark.in_process
def test_concurrent_direct_calls_never_oversell(api):
    """Same burst against the pipeline function itself, with larger stock and mixed outcomes."""
    from app.errors import ApiError
    from app.modules.store import checkout
    api.reset(stock={L: 5})
    barrier = threading.Barrier(20)
    outcomes = []
    lock = threading.Lock()

    def buy(i):
        barrier.wait()
        token = "tok_declined" if i % 4 == 0 else "tok_success"
        try:
            status, _ = checkout(order(order_id=f"ord-d-{i}", items=[{"variant_id": L, "quantity": 1}], token=token))
        except ApiError as e:
            status = e.code
        with lock:
            outcomes.append(status)

    threads = [threading.Thread(target=buy, args=(i,)) for i in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    # declined buyers hold a reservation for a moment, so some buyers may see OUT_OF_STOCK
    sold = outcomes.count(201)
    assert 1 <= sold <= 5 and len(outcomes) == 20
    assert set(outcomes) <= {201, "OUT_OF_STOCK", "PAYMENT_DECLINED"}
    assert inv(api, L) == {"variant_id": L, "stock": 5 - sold, "reserved": 0}


def test_concurrent_identical_replays_charge_once(api):
    api.reset(stock={L: 5})
    barrier = threading.Barrier(8)
    results = []

    def buy():
        barrier.wait()
        results.append(api.post("/audit/v1/checkout", json=order(items=[{"variant_id": L, "quantity": 1}])))

    threads = [threading.Thread(target=buy) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert sorted(r.status_code for r in results) == [200] * 7 + [201]
    assert len({r.json()["receipt"]["signature"] for r in results}) == 1
    assert inv(api, L) == {"variant_id": L, "stock": 4, "reserved": 0}


# --------------------------------------------------------------------------- domain events (internal queue)

@pytest.mark.in_process
def test_domain_events_emitted(api):
    from app.db import pool
    api.reset(stock={M: 1})
    api.post("/audit/v1/checkout", json=order(order_id="ord-x", token="tok_declined"))
    api.post("/audit/v1/checkout", json=order(order_id="ord-y"))
    with pool.connection() as conn:
        rows = conn.execute("SELECT event_type, payload FROM store_domain_events ORDER BY event_seq").fetchall()
    assert all(r["event_type"] == "order_status_changed" for r in rows)
    assert [(r["payload"]["order_id"], r["payload"]["status"]) for r in rows] == [
        ("ord-x", "pending"), ("ord-x", "cancelled"), ("ord-y", "pending"), ("ord-y", "paid")]
    api.reset()
    with pool.connection() as conn:
        assert conn.execute("SELECT count(*) AS n FROM store_domain_events").fetchone()["n"] == 0


# --------------------------------------------------------------------------- mobile store API

def test_products_require_auth(api):
    err(api.get("/api/v1/store/products"), 401, "UNAUTHENTICATED")
    err(api.post("/api/v1/store/checkout", json=order()), 401, "UNAUTHENTICATED")
    err(api.get("/api/v1/store/orders/ord-001/receipt.pdf"), 401, "UNAUTHENTICATED")


def test_products_tenant_filter(api):
    api.reset()
    r = api.get("/api/v1/store/products", headers=bearer())
    assert r.status_code == 200
    products = r.json()
    assert {p["tenant_id"] for p in products} == {"tenant-alpha"}
    jersey = next(p for p in products if p["product_id"] == "prod-jersey-001")
    assert set(jersey) == {"product_id", "tenant_id", "name", "category", "description", "variants"}
    assert jersey["category"] == "apparel"
    assert [v["variant_id"] for v in jersey["variants"]] == [M, L]
    assert jersey["variants"][0] == {"variant_id": M, "label": "Medium", "size": "M", "color": "Red",
                                     "price_minor": 450000, "currency": "PKR", "stock": 1}
    assert {p["category"] for p in products} >= {"apparel", "accessories", "digital"}
    everything = api.get("/api/v1/store/products", headers=bearer(role="super_admin", tenant_id=None)).json()
    assert {p["tenant_id"] for p in everything} == {"tenant-alpha", "tenant-beta"}


def test_mobile_checkout_and_receipt_download(api):
    api.reset()
    body = order(order_id="ord-mob-1", items=[{"variant_id": "var-cap-001-BLK", "quantity": 2}])
    body.pop("customer_id")
    r = api.post("/api/v1/store/checkout", json=body, headers=bearer())
    assert r.status_code == 201, r.text
    assert r.json()["receipt"]["payload"]["customer_id"] == "user-player-1"
    assert api.post("/api/v1/store/checkout", json=body, headers=bearer()).status_code == 200
    pdf = api.get("/api/v1/store/orders/ord-mob-1/receipt.pdf", headers=bearer())
    assert pdf.status_code == 200
    assert pdf.headers["content-type"] == "application/pdf"
    assert pdf.content.startswith(b"%PDF") and "PKR 2400.00" in pdf_text(base64.b64encode(pdf.content))
    admin = api.get("/api/v1/store/orders/ord-mob-1/receipt.pdf", headers=bearer(role="super_admin", sub="admin"))
    assert admin.status_code == 200
    err(api.get("/api/v1/store/orders/ord-mob-1/receipt.pdf", headers=bearer(sub="someone-else")), 403, "FORBIDDEN")
    err(api.get("/api/v1/store/orders/ord-none/receipt.pdf", headers=bearer()), 404, "ORDER_NOT_FOUND")


def test_mobile_checkout_cross_tenant_forbidden(api):
    api.reset()
    body = order(order_id="ord-mob-2", items=[{"variant_id": "var-jersey-b01-M", "quantity": 1}])
    err(api.post("/api/v1/store/checkout", json=body, headers=bearer()), 403, "FORBIDDEN")
    ok = api.post("/api/v1/store/checkout", json=body, headers=bearer(role="super_admin"))
    assert ok.status_code == 201
    assert inv(api, "var-jersey-b01-M")["stock"] == 9


def test_receipt_of_failed_order_not_found(api):
    api.reset()
    api.post("/audit/v1/checkout", json=order(token="tok_declined", customer_id="user-player-1"))
    err(api.get("/api/v1/store/orders/ord-001/receipt.pdf", headers=bearer()), 404, "ORDER_NOT_FOUND")


def test_pdf_generation_is_fast():
    import time
    from app.modules.store import receipt_pdf
    payload = {"order_id": "ord-1", "customer_id": "c", "paid_at": "2026-10-17T11:20:05Z",
               "items": [{"variant_id": M, "quantity": 1, "unit_price_minor": 450000}] * 10,
               "subtotal_minor": 4500000, "discount_minor": 0, "total_minor": 4500000, "currency": "PKR"}
    start = time.perf_counter()
    raw = receipt_pdf(payload, "a" * 64)
    assert time.perf_counter() - start < 0.5
    assert raw.startswith(b"%PDF")


def _login(api, who):
    r = api.post("/api/v1/auth/login", json={"email": f"{who}@nascon.test", "password": "Nascon@26"})
    return {"Authorization": f"Bearer {r.json()['token']}"}


def test_manager_adds_product_and_buyers_cannot(api):
    api.reset()
    body = {"name": "Alpha Scarf", "category": "accessories", "description": "Warm",
            "variants": [{"label": "One size", "price_minor": 150000, "stock": 12}]}
    r = api.post("/api/v1/store/products", json=body, headers=_login(api, "manager"))
    assert r.status_code == 201 and r.json()["tenant_id"] == "tenant-alpha"
    pid = r.json()["product_id"]
    listed = api.get("/api/v1/store/products", headers=_login(api, "player")).json()
    assert any(p["product_id"] == pid and p["variants"][0]["stock"] == 12 for p in listed)
    assert api.post("/api/v1/store/products", json=body, headers=_login(api, "player")).status_code == 403
    assert api.post("/api/v1/store/products", json={**body, "variants": []},
                    headers=_login(api, "admin")).status_code == 400
