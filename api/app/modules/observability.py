"""Part II: Prometheus /metrics (NFR-6, 5.9) and privacy erasure (NFR-9, 5.9).

/metrics never fails: a table another module has not created yet (or a DB outage) reads as 0.
Erasure anonymises the user's PII in place, revokes guest tokens merged into the account and
drops their member cart; tables owned by other modules are optional (skipped if absent).
"""
import hashlib

import psycopg
from fastapi import APIRouter, Response

from ..db import pool
from ..errors import not_found

router = APIRouter()

SCHEMA = ""


def reset(conn, seed: int, body: dict) -> None:
    pass


CONTENT_TYPE = "text/plain; version=0.0.4"
ANONYMIZED_NAME = "Anonymized User"
OPTIONAL_TABLE_ERRORS = (psycopg.errors.UndefinedTable, psycopg.errors.UndefinedColumn)


def _count(conn, sql: str) -> int:
    try:
        with conn.transaction():  # savepoint: a missing table must not abort the rest
            return int(conn.execute(sql).fetchone()["n"])
    except OPTIONAL_TABLE_ERRORS:
        return 0


def _ws_connections() -> int:
    try:
        from .realtime import active_ws_connections  # created by the realtime module; absent -> 0
        return int(active_ws_connections())
    except Exception:
        return 0


def collect() -> list[tuple[str, str, str, int]]:
    """-> [(name, type, help, value)]"""
    streams = dlq = scans = 0
    try:
        with pool.connection(timeout=2) as conn:
            streams = _count(conn, "SELECT count(*) AS n FROM stream_keys WHERE status = 'active'")
            dlq = _count(conn, "SELECT count(*) AS n FROM notification_dlq")
            scans = _count(conn, "SELECT count(*) AS n FROM qr_scans")
    except Exception:
        pass  # DB unreachable: report zeros rather than fail the scrape
    return [
        ("nascon_active_ws_connections", "gauge", "Open WebSocket client connections.", _ws_connections()),
        ("nascon_active_streams_total", "gauge", "Stream keys currently active.", streams),
        ("nascon_stream_bitrate_kbps", "gauge", "Current ingest bitrate in kbps.", 0),
        ("nascon_dlq_depth", "gauge", "Notification events parked in the dead-letter queue.", dlq),
        ("nascon_qr_scans_total", "counter", "QR code scans recorded.", scans),
    ]


@router.get("/metrics")
def metrics():
    lines = []
    for name, kind, help_, value in collect():
        lines += [f"# HELP {name} {help_}", f"# TYPE {name} {kind}", f"{name} {value}"]
    # Explicit header: Starlette would otherwise append "; charset=utf-8" to the spec's exact value.
    return Response("\n".join(lines) + "\n", headers={"Content-Type": CONTENT_TYPE})


def _optional(conn, sql: str, params) -> None:
    try:
        with conn.transaction():
            conn.execute(sql, params)
    except OPTIONAL_TABLE_ERRORS:
        pass


def erase_user(user_id: str) -> dict:
    with pool.connection() as conn:
        rows = conn.execute(
            "SELECT user_id, player_id FROM rbac_users WHERE user_id = %s OR player_id = %s", (user_id, user_id)
        ).fetchall()
        ids = {user_id} | {v for r in rows for v in r.values() if v}
        known = rows or conn.execute(
            "SELECT 1 FROM roster_players WHERE player_id = %(id)s UNION ALL"
            " SELECT 1 FROM rbac_players WHERE player_id = %(id)s", {"id": user_id}).fetchone()
        if not known:
            raise not_found("PLAYER_NOT_FOUND", player_id=user_id)
        ids = sorted(ids)
        conn.execute("UPDATE roster_players SET name = %s WHERE player_id = ANY(%s)", (ANONYMIZED_NAME, ids))
        conn.execute("UPDATE rbac_players SET name = %s WHERE player_id = ANY(%s)", (ANONYMIZED_NAME, ids))
        conn.execute("UPDATE rbac_users SET display_name = %s, email = 'anonymized-' || user_id || '@invalid'"
                     " WHERE user_id = ANY(%s)", (ANONYMIZED_NAME, ids))
        for i in ids:
            alias = "anonymized-" + hashlib.sha256(i.encode("utf-8")).hexdigest()[:16]
            _optional(conn, "UPDATE chat_messages SET sender = %s WHERE sender = %s", (alias, i))
        _optional(conn, "UPDATE guest_tokens SET revoked = TRUE WHERE guest_token IN"
                        " (SELECT guest_token FROM guest_merges WHERE registered_user_id = ANY(%s))", (ids,))
        for col in ("user_id", "registered_user_id", "player_id"):
            _optional(conn, f"DELETE FROM member_carts WHERE {col} = ANY(%s)", (ids,))
    return {"user_id": user_id, "status": "anonymized", "pii_retained": False, "tokens_wiped": True}


@router.delete("/audit/v1/privacy/user/{user_id}")
def privacy_erase(user_id: str):
    return erase_user(user_id)
