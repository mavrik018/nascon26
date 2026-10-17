"""Core infrastructure: health, reset, error envelope, 400 for malformed input, 1 MB limit."""


def test_health_ok(api):
    r = api.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_reset_default_baseline(api):
    r = api.post("/audit/v1/reset")
    assert r.status_code == 200
    assert r.json() == {
        "status": "reset_complete", "seed": 42,
        "sports": ["football", "basketball", "cricket", "esports"],
        "tenants": ["tenant-alpha", "tenant-beta"],
        "stock": {"var-jersey-001-M": 1, "var-jersey-001-L": 5},
    }


def test_reset_with_seed_and_stock(api):
    r = api.post("/audit/v1/reset", json={"seed": 7, "stock": {"var-jersey-001-M": 3}})
    assert r.status_code == 200
    assert r.json()["seed"] == 7
    assert r.json()["stock"] == {"var-jersey-001-M": 3, "var-jersey-001-L": 5}


def test_reset_rejects_malformed_json(api):
    r = api.post("/audit/v1/reset", data="{bad", headers={"Content-Type": "application/json"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"


def test_unknown_route_uses_error_envelope(api):
    r = api.get("/definitely-not-a-route")
    assert r.status_code == 404
    assert set(r.json()["error"]) == {"code", "message", "details"}


def test_body_over_1mb_rejected(api):
    r = api.post("/audit/v1/sports", data=b"x" * (1024 * 1024 + 1), headers={"Content-Type": "application/json"})
    assert r.status_code == 413
    assert r.json()["error"]["code"] == "PAYLOAD_TOO_LARGE"
