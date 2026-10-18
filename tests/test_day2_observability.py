"""Part II 5.9 / NFR-6 / NFR-9: Prometheus /metrics and privacy erasure."""
import re
import time

import pytest

METRICS = {"nascon_active_ws_connections": "gauge", "nascon_active_streams_total": "gauge",
           "nascon_stream_bitrate_kbps": "gauge", "nascon_dlq_depth": "gauge", "nascon_qr_scans_total": "counter"}
ERASED = {"user_id": "player-alpha-1", "status": "anonymized", "pii_retained": False, "tokens_wiped": True}


def test_metrics_prometheus_text(api):
    api.reset()
    r = api.get("/metrics")
    assert r.status_code == 200
    assert r.headers["content-type"] == "text/plain; version=0.0.4"
    for name, kind in METRICS.items():
        assert f"# HELP {name} " in r.text and f"# TYPE {name} {kind}\n" in r.text
        assert re.search(rf"^{name} \d+$", r.text, re.M), name
    assert "nascon_dlq_depth 0\n" in r.text


@pytest.mark.in_process
def test_metrics_survive_missing_tables_and_db_errors(api, monkeypatch):
    from app.modules import observability
    api.reset()
    values = {name: value for name, _, _, value in observability.collect()}
    assert set(values) == set(METRICS) and all(isinstance(v, int) for v in values.values())

    def broken(*_a, **_k):
        raise RuntimeError("db down")

    monkeypatch.setattr(observability.pool, "connection", broken)
    assert all(v == 0 for _, _, _, v in observability.collect())


def test_privacy_erase_anonymizes_and_is_idempotent(api):
    api.reset()
    login = {"email": "player@nascon.test", "password": "Nascon@26"}
    token = api.post("/api/v1/auth/login", json=login).json()["token"]
    assert api.post("/api/v1/chat", json={"chat_room_id": "room-p", "text": "hello"},
                    headers={"Authorization": f"Bearer {token}"}).status_code == 201
    start = time.monotonic()
    r = api.delete("/audit/v1/privacy/user/player-alpha-1")
    assert time.monotonic() - start < 1
    assert (r.status_code, r.json()) == (200, ERASED)
    senders = {m["sender"] for m in api.get("/api/v1/public/chat/room-p").json()}
    assert len(senders) == 1 and senders.pop().startswith("anonymized-")
    assert api.post("/api/v1/auth/login", json=login).status_code == 401  # email wiped
    again = api.delete("/audit/v1/privacy/user/player-alpha-1")
    assert (again.status_code, again.json()) == (200, ERASED)


@pytest.mark.in_process
def test_privacy_erase_wipes_roster_name(api):
    from app.db import pool
    api.reset()
    assert api.delete("/audit/v1/privacy/user/player-alpha-1").status_code == 200
    with pool.connection() as conn:
        assert conn.execute("SELECT name FROM roster_players WHERE player_id = 'player-alpha-1'"
                            ).fetchone()["name"] == "Anonymized User"
        assert conn.execute("SELECT display_name FROM rbac_users WHERE user_id = 'user-player'"
                            ).fetchone()["display_name"] == "Anonymized User"


@pytest.mark.in_process
def test_privacy_erase_revokes_merged_guest_tokens_and_cart(api):
    from app.db import pool
    api.reset()
    with pool.connection() as conn:
        if conn.execute("SELECT to_regclass('guest_merges') IS NOT NULL OR to_regclass('member_carts') IS NOT NULL"
                        " AS owned").fetchone()["owned"]:
            pytest.skip("guest-cart module owns these tables now; its own tests cover them")
        # stand-ins for the guest-cart module's tables, dropped again below
        conn.execute("CREATE TABLE guest_merges (guest_token TEXT, registered_user_id TEXT)")
        conn.execute("CREATE TABLE member_carts (user_id TEXT, variant_id TEXT)")
        conn.execute("INSERT INTO guest_merges VALUES ('guest_anon_tok_7721', 'user-player')")
        conn.execute("INSERT INTO member_carts VALUES ('user-player', 'var-jersey-001-L')")
    try:
        assert api.delete("/audit/v1/privacy/user/player-alpha-1").status_code == 200
        with pool.connection() as conn:
            assert conn.execute("SELECT revoked FROM guest_tokens WHERE guest_token = 'guest_anon_tok_7721'"
                                ).fetchone()["revoked"] is True
            assert conn.execute("SELECT count(*) AS n FROM member_carts").fetchone()["n"] == 0
    finally:
        with pool.connection() as conn:
            conn.execute("DROP TABLE guest_merges, member_carts")


def test_privacy_erase_unknown_user_404(api):
    api.reset()
    r = api.delete("/audit/v1/privacy/user/nobody-here")
    assert r.status_code == 404 and r.json()["error"]["code"] == "PLAYER_NOT_FOUND"
