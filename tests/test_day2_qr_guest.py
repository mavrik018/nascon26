"""Part II 5.6 dynamic QR deep links + exports, 5.7 guest cart merge (Edge cases 2 and 4)."""
import hashlib
import hmac
import json
import os
import threading

import pytest

L, M = "var-jersey-001-L", "var-jersey-001-M"
GUEST = "guest_anon_tok_7721"
MOBILE_UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/126.0 Mobile Safari/537.36"


def ref_sign(entity_id, payload):
    """Appendix A reference recipe, independent of app.signing."""
    msg = entity_id + "|" + json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hmac.new(os.environ.get("DAY2_SALT", "").encode(), msg.encode(), hashlib.sha256).hexdigest()


def merge_body(**kw):
    body = {"guest_token": GUEST, "registered_user_id": "player-alpha-1",
            "guest_cart": [{"variant_id": L, "quantity": 1}], "test_write_block": True}
    body.update(kw)
    return body


def post_event(api, event_id, type_, payload=None):
    r = api.post("/audit/v1/events", json={"event_id": event_id, "match_id": "match-m1", "type": type_,
                                           "payload": payload or {}})
    assert r.status_code in (200, 201), r.text


# --------------------------------------------------------------------------- 5.6 QR resolve

def test_qr_match_m1_spec_example(api):
    api.reset()
    r = api.get("/audit/v1/qr/match-m1")
    assert r.status_code == 200, r.text
    b = r.json()
    assert {k: v for k, v in b.items() if k != "signature"} == {
        "entity_id": "match-m1", "entity_type": "match", "entity_status": "in_progress",
        "short_url": "http://localhost:8080/q/m1-live", "target_route": "/web/matches/match-m1/live",
        "deep_link_uri": "nascon://entity/match-m1", "scan_count": 1,
        "export_formats": {"svg": "http://localhost:8080/audit/v1/qr/match-m1/export.svg",
                           "png": "http://localhost:8080/audit/v1/qr/match-m1/export.png",
                           "pdf": "http://localhost:8080/audit/v1/qr/match-m1/export.pdf"}}
    assert b["signature"] == ref_sign("match-m1", {"entity_id": "match-m1", "short_url": b["short_url"],
                                                   "target_route": b["target_route"]})


@pytest.mark.parametrize("entity_id,etype,code,route", [
    ("player-alpha-1", "player", "p-alpha-1", "/web/players/player-alpha-1"),
    ("club-alpha-1", "club", "c-alpha-1", "/web/clubs/club-alpha-1"),
])
def test_qr_seeded_player_and_club(api, entity_id, etype, code, route):
    api.reset()
    b = api.get(f"/audit/v1/qr/{entity_id}").json()
    assert (b["entity_type"], b["entity_status"], b["short_url"], b["target_route"], b["scan_count"]) == \
        (etype, "active", f"http://localhost:8080/q/{code}", route, 1)


def test_qr_inspect_does_not_count_and_scans_accumulate(api):
    api.reset()
    assert api.get("/audit/v1/qr/match-m1?inspect=true").json()["scan_count"] == 0
    assert api.get("/audit/v1/qr/match-m1").json()["scan_count"] == 1
    assert api.get("/audit/v1/qr/match-m1", headers={"User-Agent": MOBILE_UA}).json()["scan_count"] == 2
    assert api.get("/audit/v1/qr/match-m1?inspect=true").json()["scan_count"] == 2


def test_dynamic_target_mutation_after_match_end(api):
    """Edge case 2: same short_url, new target_route and signature."""
    api.reset()
    before = api.get("/audit/v1/qr/match-m1?inspect=true").json()
    post_event(api, "qr-end-1", "match_end")
    after = api.get("/audit/v1/qr/match-m1?inspect=true").json()
    assert after["short_url"] == before["short_url"] == "http://localhost:8080/q/m1-live"
    assert (after["entity_status"], after["target_route"]) == ("completed", "/web/matches/match-m1/vod")
    assert after["signature"] != before["signature"]
    assert after["signature"] == ref_sign("match-m1", {"entity_id": "match-m1", "short_url": after["short_url"],
                                                       "target_route": "/web/matches/match-m1/vod"})
    r = api.get("/q/m1-live", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "/web/matches/match-m1/vod"


def test_abandoned_match_routes_to_notice(api):
    api.reset()
    post_event(api, "qr-abandon-1", "status_change", {"status": "abandoned", "reason": "floodlight failure"})
    b = api.get("/audit/v1/qr/match-m1?inspect=true").json()
    assert (b["entity_status"], b["target_route"]) == ("abandoned", "/web/matches/match-m1/notice?state=abandoned")


def test_short_link_redirects_and_counts(api):
    api.reset()
    r = api.get("/q/m1-live", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "/web/matches/match-m1/live"
    assert api.get("/q/p-alpha-1", follow_redirects=False).headers["location"] == "/web/players/player-alpha-1"
    assert api.get("/audit/v1/qr/match-m1?inspect=true").json()["scan_count"] == 1


def test_unknown_qr_404(api):
    api.reset()
    for path in ("/audit/v1/qr/match-nope", "/audit/v1/qr/whatever", "/q/nope",
                 "/audit/v1/qr/match-nope/export.svg"):
        r = api.get(path, follow_redirects=False)
        assert r.status_code == 404 and r.json()["error"]["code"] == "QR_NOT_FOUND", path


def test_existing_unmapped_entity_gets_stable_mapping(api):
    api.reset()
    b = api.get("/audit/v1/qr/player-beta-2").json()
    assert (b["entity_type"], b["short_url"]) == ("player", "http://localhost:8080/q/player-beta-2")
    assert api.get("/q/player-beta-2", follow_redirects=False).headers["location"] == "/web/players/player-beta-2"
    assert api.get("/audit/v1/qr/player-beta-2?inspect=true").json()["scan_count"] == 2


@pytest.mark.in_process
def test_scans_store_no_pii(api):
    from app.db import pool
    api.reset()
    api.get("/audit/v1/qr/match-m1", headers={"User-Agent": MOBILE_UA})
    api.get("/q/m1-live", follow_redirects=False, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0)"})
    with pool.connection() as conn:
        cols = {r["column_name"] for r in conn.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'qr_scans'").fetchall()}
        rows = conn.execute("SELECT device_family, bucket FROM qr_scans ORDER BY id").fetchall()
    assert cols == {"id", "entity_id", "device_family", "bucket"}
    assert [r["device_family"] for r in rows] == ["mobile", "desktop"]
    assert all(r["bucket"].second == 0 and r["bucket"].microsecond == 0 for r in rows)


# --------------------------------------------------------------------------- 5.6 exports

def test_exports(api):
    api.reset()
    svg = api.get("/audit/v1/qr/match-m1/export.svg")
    assert svg.status_code == 200 and svg.headers["content-type"].startswith("image/svg+xml")
    assert svg.content.lstrip()[:5] in (b"<svg ", b"<?xml")
    png = api.get("/audit/v1/qr/match-m1/export.png")
    assert png.headers["content-type"] == "image/png" and png.content[:8] == b"\x89PNG\r\n\x1a\n"
    pdf = api.get("/audit/v1/qr/match-m1/export.pdf")
    assert pdf.headers["content-type"] == "application/pdf" and pdf.content.startswith(b"%PDF-")
    assert api.get("/audit/v1/qr/match-m1?inspect=true").json()["scan_count"] == 0  # exports are not scans
    r = api.get("/audit/v1/qr/match-m1/export.gif")
    assert r.status_code == 400 and r.json()["error"]["details"]["fields"] == ["fmt"]


# --------------------------------------------------------------------------- 5.7 cart merge

def test_cart_merge_spec_example_and_replay(api):
    api.reset()
    r = api.post("/audit/v1/guest/cart-merge", json=merge_body())
    assert r.status_code == 200, r.text
    b = r.json()
    assert {k: v for k, v in b.items() if k != "signature"} == {
        "guest_token": GUEST, "write_block_verified": True, "write_rejection_code": 403, "cart_merged": True,
        "active_cart": {"user_id": "player-alpha-1", "currency": "PKR", "total_items": 1, "subtotal_minor": 450000,
                        "items": [{"variant_id": L, "quantity": 1, "unit_price_minor": 450000}]}}
    assert b["signature"] == ref_sign(GUEST, {"cart_merged": True, "guest_token": GUEST,
                                              "registered_user_id": "player-alpha-1", "total_items": 1,
                                              "write_rejection_code": 403})
    replay = api.post("/audit/v1/guest/cart-merge", json=merge_body())
    assert replay.status_code == 200 and replay.json() == b
    # test_write_block is not part of the replay identity (guest_token, registered_user_id, guest_cart)
    assert api.post("/audit/v1/guest/cart-merge", json=merge_body(test_write_block=False)).json() == b


@pytest.mark.parametrize("change", [{"registered_user_id": "player-alpha-2"},
                                   {"guest_cart": [{"variant_id": L, "quantity": 2}]}])
def test_reused_token_different_payload_409(api, change):
    api.reset()
    assert api.post("/audit/v1/guest/cart-merge", json=merge_body()).status_code == 200
    r = api.post("/audit/v1/guest/cart-merge", json=merge_body(**change))
    assert r.status_code == 409 and r.json()["error"]["code"] == "GUEST_TOKEN_ALREADY_MERGED"


def test_merge_sums_existing_and_sorts(api):
    api.reset()
    api.post("/audit/v1/guest/cart-merge", json=merge_body(guest_token="guest_a", test_write_block=False))
    b = api.post("/audit/v1/guest/cart-merge", json=merge_body(
        guest_token="guest_b", guest_cart=[{"variant_id": M, "quantity": 1}, {"variant_id": L, "quantity": 1},
                                           {"variant_id": L, "quantity": 1}])).json()
    assert [(i["variant_id"], i["quantity"]) for i in b["active_cart"]["items"]] == [(L, 3), (M, 1)]
    assert (b["active_cart"]["total_items"], b["active_cart"]["subtotal_minor"]) == (4, 4 * 450000)
    first = api.post("/audit/v1/guest/cart-merge", json=merge_body(guest_token="guest_a", test_write_block=False))
    assert (first.json()["write_block_verified"], first.json()["write_rejection_code"]) == (False, None)


def test_out_of_stock(api):
    api.reset(stock={L: 2})
    r = api.post("/audit/v1/guest/cart-merge", json=merge_body(guest_cart=[{"variant_id": L, "quantity": 3}]))
    assert r.status_code == 409 and r.json()["error"]["code"] == "OUT_OF_STOCK"
    assert r.json()["error"]["details"] == {"variant_id": L}
    # merged quantity (existing cart + incoming) counts
    assert api.post("/audit/v1/guest/cart-merge", json=merge_body(
        guest_token="guest_x", guest_cart=[{"variant_id": L, "quantity": 2}])).status_code == 200
    r = api.post("/audit/v1/guest/cart-merge", json=merge_body(guest_token="guest_y"))
    assert r.status_code == 409 and r.json()["error"]["details"] == {"variant_id": L}


def test_not_found_order(api):
    api.reset()
    r = api.post("/audit/v1/guest/cart-merge", json=merge_body(registered_user_id="player-ghost",
                                                               guest_cart=[{"variant_id": "var-ghost", "quantity": 1}]))
    assert r.status_code == 404 and r.json()["error"]["code"] == "PLAYER_NOT_FOUND"
    r = api.post("/audit/v1/guest/cart-merge", json=merge_body(guest_cart=[{"variant_id": "var-ghost", "quantity": 1}]))
    assert r.status_code == 404 and r.json()["error"]["code"] == "VARIANT_NOT_FOUND"
    assert r.json()["error"]["details"] == {"variant_id": "var-ghost"}


@pytest.mark.parametrize("body,fields", [
    (merge_body(guest_token="anon_1"), ["guest_token"]),
    (merge_body(guest_token=""), ["guest_token"]),
    (merge_body(registered_user_id=5), ["registered_user_id"]),
    (merge_body(guest_cart=[]), ["guest_cart"]),
    (merge_body(guest_cart=[{"variant_id": L, "quantity": 1}] * 11), ["guest_cart"]),
    (merge_body(guest_cart=[{"variant_id": L, "quantity": 0}]), ["guest_cart.quantity"]),
    (merge_body(guest_cart=[{"quantity": 1}]), ["guest_cart.variant_id"]),
    (merge_body(test_write_block="yes"), ["test_write_block"]),
    ([], ["body"]),
])
def test_validation(api, body, fields):
    r = api.post("/audit/v1/guest/cart-merge", json=body)
    assert r.status_code == 400 and r.json()["error"] == {
        "code": "VALIDATION_ERROR", "message": r.json()["error"]["message"], "details": {"fields": fields}}


def test_malformed_json_400(api):
    r = api.post("/audit/v1/guest/cart-merge", data="{bad", headers={"Content-Type": "application/json"})
    assert r.status_code == 400 and r.json()["error"]["code"] == "VALIDATION_ERROR"


def test_concurrent_identical_merges_add_once(api):
    """Edge case 4: simultaneous identical retries -> all 200, total_items 1, no inventory touched."""
    api.reset()
    barrier = threading.Barrier(10)
    results = []

    def go():
        barrier.wait()
        results.append(api.post("/audit/v1/guest/cart-merge", json=merge_body()))

    threads = [threading.Thread(target=go) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert [r.status_code for r in results] == [200] * 10
    assert {r.json()["active_cart"]["total_items"] for r in results} == {1}
    assert len({r.json()["signature"] for r in results}) == 1
    assert api.get(f"/audit/v1/inventory/{L}").json() == {"variant_id": L, "stock": 5, "reserved": 0}
